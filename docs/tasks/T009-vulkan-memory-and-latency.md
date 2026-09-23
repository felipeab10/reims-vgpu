# T009: Vulkan memory accounting and latency investigation

## Goal

Explain the VRAM growth and frame-time instability seen in the macOS guest, then
make evidence-backed improvements without regressing the already improved image
stability. Keep memory accounting and latency diagnosis as related but separate
tracks: high retained memory is not automatically a leak, and low FPS is not
automatically caused by VRAM pressure.

Do not add a global VRAM cap, change slab eviction policy, or tune rendering
behavior until measurements identify a specific cause and a test can validate
the change. Preserve guest disks and do not merge upstream changes as part of
this task.

## Existing instrumentation

The working tree already contains instrumentation for:

- `vk_memory_live`: successful Vulkan allocations and matching frees, grouped
  by allocation site, heap, memory type, and property flags; includes
  `unmatched_frees`.
- `vk_memory_budget`: Vulkan driver's heap size, dynamic budget, usage, and
  availability.
- `image_pool_levels` and `buffer_slab_levels`: image populations and slab
  backing versus carved bytes.
- `drain_duty`, `host_window_loop`, and `engine_delta`: worker duty, draw/present
  cadence, fresh versus stale frames, rendering work, and selected timing
  counters.
- Host-side NVML: total device memory/utilization/temperature; this is system
  wide and must not be confused with the Reims process ledger.

See [`../vulkan-memory-map.md`](../vulkan-memory-map.md) for source ownership,
counter semantics, and known instrumentation boundaries. Verify all direct
allocation/free paths when new allocator paths are introduced.

## Current evidence and caveats

The idle RTX 3050 baseline was approximately 503 MiB process device-local,
536 MiB Vulkan heap-0 driver usage, 526 MiB NVML, and 400 MiB image-slab backing.
An exploratory browser sequence raised local usage to about 1,160 MiB and slab
backing to 1,056 MiB; the ledger reported zero unmatched frees. The final idle
sample remained at that level for about 90 seconds. This is evidence of
retention, not proof of a leak or of unnecessary duplication.

The exploratory sequence is **not a valid per-stage A/B**: `open -a Safari URL`
created new tabs, and navigating only the selected tab to `about:blank` left
prior probe tabs active in the background. The browser probes were later closed
explicitly. Reuse one Safari tab in future runs, verify the exact URL before and
after every phase, and do not label a white screenshot as idle unless all load
pages are confirmed stopped.

Exploratory `16x6` and `24x6` canvas loads showed roughly 53–59 fresh host-window
draws/s, worker duty around 0.58–0.76, draw time reaching roughly 678 ms per
one-second sample, and IRQ wait around 183–256 ms/s. Flush time was generally
small. Images showed no visible artifacts and QMP remained running. These
counters suggest where to investigate, but they do not identify a bottleneck;
host-window draws/s are not an exact measurement of Safari FPS.

The first corrected single-tab moderate sample (`8x6`, `tex=512`) reused the
same Safari tab for the probe and then `about:blank`. During ~30 seconds of the
probe, the ledger held steady at 1,552 MiB device-local / 1,448 MiB of slab
backing, driver heap-0 usage 1,585 MiB, and NVML 1,643 MiB; no unmatched frees
were reported. `drain_duty` was ~0.62–0.64, `draw_us` ~565–583 ms/s, IRQ wait
~186–224 ms/s, and the host window recorded 51–58 fresh draws/s. After
navigating that same tab to `about:blank`, memory and slab levels did not change
over the next 30 seconds and duty fell to ~0.003. The guest image stayed clean
and QMP remained `running`.

This run did not have a true immediate pre-navigation idle ledger sample: the
first reading was captured shortly after opening the page. It therefore shows
stability during the moderate phase and no short-term trim on stop, but cannot
attribute the 1,552 MiB level to that phase alone. Compare future runs against
a stable idle sample captured before navigation.

## Test protocol

1. Start from a recorded idle state. Record the QEMU command/build identity,
   guest OS, backend, display/window path, environment flags, GPU identity, and
   whether any VRAM limit or slab-reclaim patch is enabled.
2. Confirm SSH readiness. Use one Safari tab and the local deterministic probe;
   verify the requested URL and `hidden`/focus state. Keep the VM window visible
   and windowed (not fullscreen) for screenshot-based freeze/glitch detection.
3. For each independent phase, collect a pre-sample, then synchronized samples
   at 1-second intervals during load and after returning that same tab to
   `about:blank`. Save screenshots at baseline, early load, peak/steady load,
   and recovery. Record guest clock progression, QMP status, and serial/panic
   evidence.
4. Capture at least `vk_memory_live`, `vk_memory_budget`,
   `image_pool_levels`, `buffer_slab_levels`, `drain_duty`, `host_window_loop`,
   relevant `engine_delta` counters, plus NVML and host CPU/QEMU utilization.
   Preserve raw output and exact probe parameters.
5. Use a ladder of light → moderate → heavy → one extra-heavy level, with idle
   recovery between stages. Increase only while the guest image remains valid,
   the guest clock advances, QMP is running, and frames remain fresh. Stop the
   load and preserve evidence immediately on a black/stale window, panic,
   device loss, or severe host/guest instability.
6. Repeat a candidate fix against the same baseline and workload. Change one
   factor at a time. Report medians and tail frame times, not only a single FPS
   sample.

## Questions to answer

- Which allocation sites/categories account for the growth in device-local
  bytes? How much is image backing, buffer/staging, guest import, and driver
  overhead?
- Do frees balance allocations? Which Vulkan objects remain live after the
  browser has stopped, and which slabs are empty, carved, pinned, or awaiting
  GPU completion?
- Does the observed memory plateau represent useful reusable cache, resources
  still referenced by guest surfaces, delayed fence retirement, or an
  avoidable duplicate/copy?
- At the point frame times worsen, are `draw_us`, IRQ/fence waits, flush,
  scheduler gaps, CPU use, or GPU utilization the dominant correlated cost?
- Does the same workload recover after it is truly stopped? Does memory, fresh
  present cadence, and frame-time distribution return to baseline, and on what
  timescale?

## Acceptance criteria

- Every successful engine-owned `VkDeviceMemory` allocation is attributed and
  has a matching free, or is explicitly documented as intentionally live.
- Memory totals reconcile within documented driver/allocator overhead; slab
  backing, carved occupancy, and live resource bytes are not conflated.
- A reproducible test distinguishes live resources from retained empty slab
  capacity and correlates memory with frame-time/present degradation.
- Any optimization has a focused test where possible and a repeatable runtime
  A/B showing its effect on memory, FPS/frame-time tails, and visual integrity.
- No global memory cap or reclaim-policy change is accepted solely because
  NVML usage is high; avoid trading correct rendering for an apparently better
  FPS score.

## Next action

Next, collect a true 60-second idle ledger before navigation, then run a fixed
60-second moderate phase and 90-second idle recovery in that same tab. Add
browser frame-time/FPS capture to the host telemetry. Before changing source,
inspect the existing timing counters and allocator/pool ownership to identify
missing attribution or the highest-cost interval. Preserve the current user
changes and do not use `orca-ide`.
