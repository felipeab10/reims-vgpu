#![expect(
    clippy::single_range_in_vec_init,
    reason = "a list of one range is the argument the log and the harvest take"
)]
#![allow(clippy::disallowed_methods)] // test scaffolding: real-time waits for the device's thread

use std::ops::Range;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use reims_vgpu_core::memory::dirty::{DirtyLog, DirtyStamp, GRANULE, PAGE_SIZE};
use reims_vgpu_core::sync::Mutex;

use super::*;

const G: u64 = GRANULE;
const P: u64 = PAGE_SIZE;

/// A log that hands out fixed runs and keeps what the harvest published.
struct FakeLog {
    runs: Vec<Range<u64>>,
    ended: Mutex<Option<(DirtyStamp, Vec<u64>)>>,
}

impl FakeLog {
    fn new(runs: Vec<Range<u64>>) -> FakeLog {
        FakeLog {
            runs,
            ended: Mutex::new(None),
        }
    }

    fn words(&self) -> Vec<u64> {
        self.ended
            .lock()
            .as_ref()
            .map(|(_, w)| w.clone())
            .unwrap_or_default()
    }
}

impl HarvestLog for FakeLog {
    fn begin(&self, watched: &mut Vec<Range<u64>>) -> Option<DirtyStamp> {
        watched.clone_from(&self.runs);
        Some(7)
    }

    fn end(&self, stamp: DirtyStamp, written: &[u64]) -> bool {
        *self.ended.lock() = Some((stamp, written.to_vec()));
        true
    }
}

/// A clear KVM was asked for: the slot, the first page, the pages and the bitmap.
type Clear = (u32, u64, u32, Vec<u64>);

/// KVM's log of each slot, a set of dirty pages, and the clears it was asked for.
#[derive(Default)]
struct FakeKvm {
    dirty: Mutex<Vec<(u32, Vec<u64>)>>,
    refuse_get: Vec<u32>,
    clears: Arc<Mutex<Vec<Clear>>>,
    gets: Arc<AtomicU32>,
}

impl FakeKvm {
    fn with(dirty: &[(u32, &[u64])]) -> FakeKvm {
        FakeKvm {
            dirty: Mutex::new(dirty.iter().map(|(s, p)| (*s, p.to_vec())).collect()),
            ..FakeKvm::default()
        }
    }
}

impl KvmLog for FakeKvm {
    fn get(&self, slot: u32, bitmap: &mut [u64]) -> bool {
        self.gets.fetch_add(1, Ordering::SeqCst);
        if self.refuse_get.contains(&slot) {
            return false;
        }
        bitmap.fill(0);
        for (s, pages) in self.dirty.lock().iter() {
            if *s == slot {
                for &p in pages {
                    bitmap[(p / 64) as usize] |= 1 << (p % 64);
                }
            }
        }
        true
    }

    fn clear(&self, slot: u32, first_page: u64, num_pages: u32, bitmap: &[u64]) -> bool {
        assert_eq!(first_page % 64, 0);
        self.clears
            .lock()
            .push((slot, first_page, num_pages, bitmap.to_vec()));
        let mut d = self.dirty.lock();
        for (s, pages) in d.iter_mut() {
            if *s == slot {
                pages.retain(|&p| {
                    let i = p.wrapping_sub(first_page);
                    !(p >= first_page && i < u64::from(num_pages) && bits(bitmap, i, 1) == 1)
                });
            }
        }
        true
    }
}

/// The host's slots, its own writes (pages of its record) and what it was asked.
#[derive(Default)]
struct FakeHost {
    slots: Vec<KvmSlot>,
    own: Mutex<Vec<u64>>,
    reads_itself: bool,
    flush_fails: bool,
    starts: AtomicU32,
    flushes: AtomicU32,
    takes: Mutex<Vec<(u64, u64)>>,
}

impl DirtyHost for FakeHost {
    fn start(&self) {
        self.starts.fetch_add(1, Ordering::SeqCst);
    }

    fn flush_vcpus(&self, timeout: Duration) -> bool {
        assert_eq!(timeout, Duration::from_millis(4));
        self.flushes.fetch_add(1, Ordering::SeqCst);
        !self.flush_fails
    }

    fn for_each_slot(&self, slot: &mut dyn FnMut(KvmSlot)) -> bool {
        if self.reads_itself {
            return false;
        }
        self.slots.iter().for_each(|s| slot(*s));
        true
    }

    fn take_host_writes(&self, host_offset: u64, length: u64, words: &mut [u64]) {
        assert_eq!(host_offset % G, 0);
        assert_eq!(length % G, 0);
        assert_eq!(words.len() as u64, length / G);
        self.takes.lock().push((host_offset, length));
        let first = host_offset / P;
        self.own.lock().retain(|&p| {
            let i = p.wrapping_sub(first);
            if p >= first && i < length / P {
                words[(i / 64) as usize] |= 1 << (i % 64);
                false
            } else {
                true
            }
        });
    }
}

fn slot(slot: u32, gpa: u64, length: u64, host_offset: u64) -> KvmSlot {
    KvmSlot {
        slot,
        guest_physical_address: gpa,
        length,
        host_offset,
    }
}

fn run(runs: Vec<Range<u64>>, host: &FakeHost, kvm: &FakeKvm, flush: bool) -> Vec<u64> {
    let log = FakeLog::new(runs);
    assert_eq!(
        harvest(&log, host, kvm, flush, &mut Scratch::default()),
        Some(7)
    );
    log.words()
}

#[test]
fn bits_read_and_set_across_words() {
    let mut b = vec![0u64; 3];
    set_bits(&mut b, 60, 0b1_0110);
    assert_eq!(b, vec![0x6000_0000_0000_0000, 0b1, 0]);
    assert_eq!(bits(&b, 60, 5), 0b1_0110);
    assert_eq!(bits(&b, 61, 1), 1);
    assert_eq!(bits(&b, 0, 64), 0x6000_0000_0000_0000);
    assert_eq!(bits(&b, 64, 64), 1);
    assert_eq!(bits(&b, 190, 64), 0, "past the end reads as zero");
}

/// A slot's watched pages KVM shows written are published, cleared and no others, and the
/// host's own writes join them; the unwatched page keeps its bit in KVM's log.
#[test]
fn a_harvest_takes_exactly_the_watched_pages_written() {
    let kvm = FakeKvm::with(&[(0, &[5, 128, 200, 703])]);
    let host = FakeHost {
        slots: vec![slot(0, 0, 1 << 30, 1 << 20)],
        own: Mutex::new(vec![(1 << 20) / P + 640 + 3]),
        ..FakeHost::default()
    };
    let words = run(vec![2 * G..4 * G, 10 * G..11 * G], &host, &kvm, false);
    assert_eq!(words, vec![1, 1 << 8, (1 << 3) | (1 << 63)]);
    let clears = kvm.clears.lock().clone();
    assert_eq!(clears.len(), 1, "one clear a slot");
    let (s, first, num, bitmap) = &clears[0];
    assert_eq!((*s, *first, *num), (0, 128, 704 - 128));
    assert_eq!(bitmap[0], 1);
    assert_eq!(bitmap[1], 1 << 8);
    assert_eq!(bitmap[8], 1 << 63);
    assert_eq!(*kvm.dirty.lock(), vec![(0, vec![5])]);
    assert_eq!(
        *host.takes.lock(),
        vec![((1 << 20) + 2 * G, 2 * G), ((1 << 20) + 10 * G, G)]
    );
    assert_eq!(host.flushes.load(Ordering::SeqCst), 0);
}

/// What no logged slot of address space 0 answers for reads as written: a page outside every
/// slot, and SMM's address space only adds its writes.
#[test]
fn unanswered_pages_read_as_written() {
    let kvm = FakeKvm::with(&[(1 << 16, &[64 + 2])]);
    let host = FakeHost {
        slots: vec![slot(0, 0, G * 2, 0), slot(1 << 16, 0, G * 2, 0)],
        ..FakeHost::default()
    };
    let words = run(vec![0..3 * G], &host, &kvm, false);
    assert_eq!(words, vec![0, 1 << 2, !0]);
    assert_eq!(
        host.takes.lock().len(),
        1,
        "the host's writes are taken once, for space 0"
    );
}

/// A slot that starts inside a granule answers for its pages, and its granule's host writes
/// cannot be taken a word at a time, so that granule reads as written; so does one whose host
/// offset is out of step with its guest address.
#[test]
fn granules_the_host_cannot_take_whole_read_as_written() {
    let kvm = FakeKvm::default();
    let host = FakeHost {
        slots: vec![
            slot(0, 0, 160 * P, 0),
            slot(1, 192 * P, 64 * P, 192 * P),
            slot(2, 5 * G, G, 5 * G + P),
        ],
        ..FakeHost::default()
    };
    let words = run(vec![0..4 * G, 5 * G..6 * G], &host, &kvm, false);
    assert_eq!(words, vec![0, 0, !0, 0, !0]);
    let clears = kvm.clears.lock().clone();
    assert!(clears.is_empty(), "nothing written, nothing cleared");
}

/// A host that reads its log itself, a flush past its time and a read KVM refuses give every
/// page as written, and a refused read clears nothing.
#[test]
fn a_harvest_that_cannot_answer_gives_every_page() {
    let one = || FakeHost {
        slots: vec![slot(0, 0, 4 * G, 0)],
        ..FakeHost::default()
    };
    let host = FakeHost {
        reads_itself: true,
        ..one()
    };
    assert_eq!(
        run(vec![0..2 * G], &host, &FakeKvm::default(), false),
        vec![!0, !0]
    );

    let host = FakeHost {
        flush_fails: true,
        ..one()
    };
    let kvm = FakeKvm::default();
    assert_eq!(run(vec![0..2 * G], &host, &kvm, true), vec![!0, !0]);
    assert_eq!(host.flushes.load(Ordering::SeqCst), 1);
    assert_eq!(
        kvm.gets.load(Ordering::SeqCst),
        0,
        "no read after a failed flush"
    );

    let kvm = FakeKvm {
        refuse_get: vec![0],
        ..FakeKvm::with(&[(0, &[1])])
    };
    assert_eq!(run(vec![0..2 * G], &one(), &kvm, true), vec![!0, !0]);
    assert!(kvm.clears.lock().is_empty());
}

/// The device's thread starts the log at the first harvest it is asked for, and publishes each.
#[test]
fn the_thread_harvests_what_the_log_requests() {
    let host = Arc::new(FakeHost {
        slots: vec![slot(0, 0, 4 * G, 0)],
        ..FakeHost::default()
    });
    let kvm = FakeKvm::with(&[(0, &[3])]);
    let gets = kvm.gets.clone();
    let h = Harvester::with_kvm(&[0..4 * G], host.clone(), Box::new(kvm), false);
    h.log().watch(&[0..G]);
    for _ in 0..2 {
        let stamp = h.log().request();
        let deadline = Instant::now() + Duration::from_secs(5);
        while h.log().published() < stamp {
            assert!(Instant::now() < deadline, "harvest {stamp} never published");
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    assert_eq!(host.starts.load(Ordering::SeqCst), 1);
    assert!(gets.load(Ordering::SeqCst) >= 2);
    drop(h);
}

/// A log the harvester never started still drops cleanly.
#[test]
fn a_harvester_drops_without_a_harvest() {
    let host = Arc::new(FakeHost::default());
    let h = Harvester::with_kvm(&[0..G], host.clone(), Box::new(FakeKvm::default()), false);
    let _: &Arc<DirtyLog> = h.log();
    drop(h);
    assert_eq!(host.starts.load(Ordering::SeqCst), 0);
}
