//! The guest's RAM handed to a device whole, where the device takes no view of the guest's pages
//! through dma-bufs (`super::import`'s `imports_need_files`, NVIDIA's 615 driver): the runtime
//! imports it by pointer itself, in chunks, as objects over it are made, and takes each no-copy
//! object's pages as runs of that RAM ([`runs`]) instead of an import of the object's own view,
//! so such an object takes no kernel mapping a page.
//!
//! - **What is handed.** Each lease's ranges of the guest's RAM (`super::files`'s
//!   `lease_guest_memory`): the host's own shared mappings of the files it named, writable, mapped
//!   while the lease lives. Nothing else: read-only memory, files of zeros, twins and the library's
//!   own memory answer no runs, and keep the imports they have.
//! - **To whom.** Every device that needs imported pages mapped from their files, as each such
//!   device is learned ([`device_needs_ram`]) and as each lease is made ([`lease`]): a device made
//!   after a lease gets its RAM then, and a lease made after the device gets it at once.
//! - **For how long.** A device's use of a lease's RAM goes with the lease ([`LeasedRam`]'s drop),
//!   which drops after core's teardown released every object over the RAM; the runtime frees the
//!   RAM's imports once no command buffer holds them.
//! - **Nothing may discard the RAM's pages** while a device uses it (a balloon, free page
//!   reporting, memory hot-unplug): the device holds the pages it imported, and would go on
//!   reading the old ones. The VMs `reims-ctl` makes have none.
//!
//! The registry's lock is a leaf: the runtime is called after it is let go.

use std::ops::Range;
use std::ptr::NonNull;
use std::sync::{Arc, Weak};

use metal2vulkan_runtime as rt;
use reims_vgpu_core::sync::Mutex;

use super::files;

/// One lease's RAM as the devices are handed it: the runtime's RAM of its ranges (`None` where
/// the runtime refused them), and each device's use of it, which ends with the lease, before the
/// RAM is let go.
#[derive(Debug)]
pub(crate) struct LeasedRam {
    uses: Mutex<Vec<rt::HostRamUse>>,
    ram: Option<Arc<rt::HostRam>>,
}

/// The devices that take the RAM, and the leases' RAM alive now.
struct Registry {
    devices: Vec<rt::Device>,
    leases: Vec<Weak<LeasedRam>>,
}

static REGISTRY: Mutex<Registry> = Mutex::new(Registry {
    devices: Vec::new(),
    leases: Vec::new(),
});

/// A lease's RAM, `ranges` (each a host address and a length), with the answers of its dirty log
/// where `logged` (the device's log over the RAM, `super::dirty`), handed to every device that
/// takes it now, and to each one learned while the answer lives.
pub(crate) fn lease(ranges: &[(u64, u64)], logged: bool) -> Arc<LeasedRam> {
    let ram = Arc::new(LeasedRam {
        uses: Mutex::new(Vec::new()),
        ram: runtime_ram(ranges, logged).map(Arc::new),
    });
    let devices = {
        let mut registry = REGISTRY.lock();
        registry.leases.retain(|l| l.strong_count() > 0);
        registry.leases.push(Arc::downgrade(&ram));
        registry.devices.clone()
    };
    for device in &devices {
        hand(device, &ram);
    }
    ram
}

/// Hands `device`, which needs imported pages mapped from their files, every lease's RAM alive
/// now, and every one made after.
pub(crate) fn device_needs_ram(device: &rt::Device) {
    let leases: Vec<Arc<LeasedRam>> = {
        let mut registry = REGISTRY.lock();
        registry.devices.push(device.clone());
        registry.leases.iter().filter_map(Weak::upgrade).collect()
    };
    for ram in &leases {
        hand(device, ram);
    }
}

/// The runtime's RAM of `ranges`, with the dirty log's answers for all of it where `logged`;
/// `None`, with a warning, where the runtime refuses them.
fn runtime_ram(ranges: &[(u64, u64)], logged: bool) -> Option<rt::HostRam> {
    let pairs: Vec<(NonNull<u8>, u64)> = (ranges.iter())
        .filter_map(|&(at, length)| {
            Some((
                NonNull::new(std::ptr::with_exposed_provenance_mut(at.try_into().ok()?))?,
                length,
            ))
        })
        .collect();
    // SAFETY: each range is the host's own mapping of the guest's RAM, which the host keeps
    // mapped, readable and writable, with the same backing, while any device made over its
    // memory map lives (`docs/api.md`, `RvgMemoryRange`); every device's use of it goes with the
    // lease, which drops after core's teardown, and the runtime holds the RAM no longer than its
    // uses and the objects and command buffers over it.
    let ram = match unsafe { rt::HostRam::new(&pairs, None) } {
        Ok(ram) => ram,
        Err(refusal) => {
            log::warn!(
                target: "reims_vgpu_vulkan::os",
                "the guest's RAM is not handed to devices whole ({refusal}): buffers over its \
                 pages keep imports of their own"
            );
            return None;
        }
    };
    let dirty = logged
        .then(|| {
            ranges
                .first()
                .and_then(|&(at, _)| super::dirty::ImportDirty::of_ram(at))
        })
        .flatten();
    Some(match dirty {
        Some(dirty) => ram.with_dirty_pages(Arc::new(dirty)),
        None => ram,
    })
}

/// Hands `device` the lease's RAM, keeping its use with the lease. A device that takes no RAM
/// (no import of host memory by its pointer) keeps today's imports, said once.
fn hand(device: &rt::Device, ram: &LeasedRam) {
    let Some(host_ram) = &ram.ram else {
        return;
    };
    match device.use_host_ram(host_ram) {
        Ok(used) => ram.uses.lock().push(used),
        Err(refusal) => {
            static SAID: std::sync::Once = std::sync::Once::new();
            SAID.call_once(|| {
                log::info!(
                    target: "reims_vgpu_vulkan::os",
                    "{}: the guest's RAM is not used whole ({refusal}): buffers over its pages \
                     keep imports of their own",
                    device.properties().name
                );
            });
        }
    }
}

/// The runs of the guest's RAM behind `length` bytes from `start`, which the runtime asks of a
/// no-copy object's import window (`super::import`'s `host_memory`): host addresses in the leases'
/// ranges, in the bytes' order; `None` where a byte is no writable page of the RAM
/// (`super::files`'s `guest_ram_runs`), and the object keeps today's import.
pub(crate) fn runs(start: u64, length: u64) -> Option<Vec<Range<u64>>> {
    let runs = files::guest_ram_runs(start, length)?;
    Some(runs.into_iter().map(|(at, n)| at..at + n).collect())
}

#[cfg(test)]
mod tests {
    use std::os::fd::AsRawFd as _;

    use reims_vgpu_core::host::HostPtr;
    use reims_vgpu_core::num::{ToU64 as _, ToUsize as _};
    use reims_vgpu_core::platform::HostRange;
    use reims_vgpu_core::platform::blit::{BlitCmd, BlitEncoder as _};
    use reims_vgpu_core::platform::command::{CommandBuffer as _, CommandQueue as _};
    use reims_vgpu_core::platform::device::GpuDevice as _;
    use reims_vgpu_core::platform::types::NsRange;
    use reims_vgpu_core::raise::OnFault;

    use super::super::import::imports_need_files;
    use super::super::vm::memfd;
    use super::super::{PAGE, lease_guest_memory};
    use crate::gpu::device::tests::dev;
    use crate::os::GuestRamFile;

    const MIB: u64 = 1 << 20;

    /// Where the device needs imported pages mapped from their files (NVIDIA's), it uses the
    /// guest's RAM whole: a no-copy buffer over one run of it is bound in the RAM's chunk, which
    /// the device imports once, a second buffer in the chunk importing nothing more, and the GPU's
    /// fill through each reaches the RAM. A device that takes views through dma-bufs is handed no
    /// RAM, and its buffers import their pages as before. Either way the bytes are the GPU's. The
    /// flag is the process's, which nextest runs this test alone in.
    #[test]
    fn a_buffer_over_one_run_of_the_ram_is_bound_in_its_chunk() {
        let device = dev();
        let length = 8 * MIB;
        let fd = memfd(length).unwrap();
        // SAFETY: a fresh shared mapping of the file, which the test unmaps after the lease and
        // every buffer over it.
        let start = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                length.to_usize(),
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd.as_raw_fd(),
                0,
            )
        };
        assert_ne!(start, libc::MAP_FAILED);
        let at = start.addr().to_u64();
        let lease = lease_guest_memory(
            [GuestRamFile {
                host: at,
                guest: 0,
                length,
                fd,
                offset: 0,
            }],
            None,
        );
        let counts = || {
            let c = device.raw.work_counts();
            (c.host_ram_chunks_imported, c.chunk_bound_buffers_made)
        };
        let before = counts();
        let over = |offset: u64, length: u64| {
            // SAFETY: pages of the test's RAM, mapped until after the buffer is dropped.
            let bytes =
                unsafe { HostRange::new(HostPtr::from_addr((at + offset).to_usize()), length) };
            (device.new_buffer_over_host_memory(OnFault::Die, bytes, 0, None))
                .unwrap()
                .unwrap()
        };
        let a = over(MIB, 2 * PAGE);
        let b = over(3 * MIB, PAGE);
        let made = (counts().0 - before.0, counts().1 - before.1);
        match imports_need_files() {
            true => assert_eq!(made, (1, 2), "bound in one chunk"),
            false => assert_eq!(made, (0, 0), "no RAM handed"),
        }
        let q = device.new_command_queue().unwrap();
        let cb = q.command_buffer(OnFault::Die).unwrap().unwrap();
        let e = cb.blit_encoder(OnFault::Die).unwrap().unwrap();
        for (buffer, value) in [(&a, 0x5a), (&b, 0xa5)] {
            let fill = BlitCmd::FillBuffer {
                buffer,
                range: NsRange::new(0x10, PAGE - 0x20),
                value,
            };
            e.encode(OnFault::Die, fill).unwrap();
        }
        e.encode(OnFault::Die, BlitCmd::EndEncoding).unwrap();
        cb.commit(OnFault::Die).unwrap();
        cb.wait_until_completed(OnFault::Die).unwrap();
        assert!(cb.error().is_none(), "{:?}", cb.error());
        // SAFETY: the RAM, mapped readable, which no GPU work uses now.
        let read = |offset: u64| unsafe {
            std::ptr::with_exposed_provenance::<u8>((at + offset).to_usize()).read_volatile()
        };
        let a_bytes = [
            read(MIB + 0xf),
            read(MIB + 0x10),
            read(MIB + PAGE - 0x11),
            read(MIB + PAGE - 0x10),
        ];
        assert_eq!(a_bytes, [0, 0x5a, 0x5a, 0]);
        let b_bytes = [
            read(3 * MIB + 0xf),
            read(3 * MIB + 0x10),
            read(3 * MIB + PAGE - 0x11),
        ];
        assert_eq!(b_bytes, [0, 0xa5, 0xa5]);
        drop((cb, e, q, a, b, lease));
        // SAFETY: the mapping made above, which nothing uses any more.
        assert_eq!(unsafe { libc::munmap(start, length.to_usize()) }, 0);
    }
}
