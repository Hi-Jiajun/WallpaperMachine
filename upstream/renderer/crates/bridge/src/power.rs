use std::{
    ffi::c_void,
    fmt, ptr,
    sync::{
        Arc, Mutex, MutexGuard, PoisonError,
        atomic::{AtomicBool, Ordering},
    },
    thread,
};

use objc2_core_foundation::{
    CFRetained, CFRunLoop, CFRunLoopRunResult, CFRunLoopSource, CFRunLoopSourceContext, CFString,
    CFTimeInterval, CFType, kCFRunLoopDefaultMode,
};
use objc2_io_kit::{
    IOPSCopyPowerSourcesInfo, IOPSGetProvidingPowerSourceType, IOPSNotificationCreateRunLoopSource,
    kIOPMACPowerKey, kIOPMBatteryPowerKey, kIOPMUPSPowerKey,
};

use crate::{
    actor::{BridgeActorHandle, messages::SetPowerSource},
    engine::EngineFacade,
};

/// How long one pass of the watcher's run loop may sleep: the value `CFRunLoopRun` itself uses
/// for "no timeout". A pass ends earlier when `IOKit` reports a change or the thread is woken
/// through [`WatcherSignal`], so nothing wakes the thread while the power source is unchanged.
const IDLE_WAIT: CFTimeInterval = 1.0e10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerSource {
    External,
    Battery,
    Unknown,
}

/// Follows plugging in and unplugging, and hands each change to the bridge actor.
///
/// The thread behind it sleeps in its run loop until `IOKit` reports a change or the watcher is
/// dropped; dropping wakes it, so shutdown never waits on a timeout.
#[derive(Debug)]
pub(crate) struct PowerWatcher {
    signal: Arc<WatcherSignal>,
    worker: Option<thread::JoinHandle<()>>,
}

impl PowerWatcher {
    #[allow(clippy::single_call_fn)]
    pub(crate) fn spawn<E: EngineFacade + Clone>(actor: BridgeActorHandle<E>) -> Self {
        Self::spawn_with(SystemPowerSource::current, move |source| {
            match actor.blocking_ask(SetPowerSource {
                source,
                initial_sample: false,
            }) {
                Ok(_) => true,
                Err(error) => {
                    log::debug!("power source update skipped: {error}");
                    false
                }
            }
        })
    }

    /// Starts the watcher thread. `read` samples the power source; `deliver` hands a changed
    /// source to its consumer and reports whether the consumer took it. The source sampled here
    /// counts as already delivered.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn spawn_with(
        read: impl Fn() -> PowerSource + Send + 'static,
        deliver: impl FnMut(PowerSource) -> bool + Send + 'static,
    ) -> Self {
        let delivered = read();
        let signal = Arc::new(WatcherSignal::default());
        let event_loop = PowerEventLoop {
            context: Box::new(PowerNotificationContext {
                read: Box::new(read),
                deliver: Box::new(deliver),
                delivered,
            }),
            signal: Arc::clone(&signal),
        };
        let worker = thread::Builder::new()
            .name("wallpaper-bridge-power-watcher".to_string())
            .spawn(move || event_loop.run())
            .ok();

        Self { signal, worker }
    }
}

impl Drop for PowerWatcher {
    fn drop(&mut self) {
        self.signal.stop.store(true, Ordering::SeqCst);
        self.signal.notify();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// What the owner of a [`PowerWatcher`] uses to reach its thread while that thread sleeps.
#[derive(Debug, Default)]
struct WatcherSignal {
    stop: AtomicBool,
    /// Present from the moment the thread's run loop is ready to be woken until it stops.
    wake: Mutex<Option<RunLoopWake>>,
}

impl WatcherSignal {
    fn should_stop(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    fn publish(&self, wake: RunLoopWake) {
        *self.wake() = Some(wake);
    }

    fn unpublish(&self) {
        *self.wake() = None;
    }

    /// Ends the thread's current wait. A signal sent while the loop is not running stays
    /// pending, so it is seen on the loop's next pass; one sent before the handle is published
    /// finds nothing to wake, and the thread reads the stop flag only after publishing.
    fn notify(&self) {
        if let Some(wake) = self.wake().as_ref() {
            wake.source.signal();
            wake.run_loop.wake_up();
        }
    }

    fn wake(&self) -> MutexGuard<'_, Option<RunLoopWake>> {
        self.wake.lock().unwrap_or_else(PoisonError::into_inner)
    }

    #[cfg(test)]
    fn is_asleep(&self) -> bool {
        self.wake()
            .as_ref()
            .is_some_and(|wake| wake.run_loop.is_waiting())
    }
}

/// A run loop and the source that wakes it.
struct RunLoopWake {
    run_loop: CFRetained<CFRunLoop>,
    source: CFRetained<CFRunLoopSource>,
}

// SAFETY: `CFRunLoopSourceSignal` and `CFRunLoopWakeUp` are the calls Apple documents for waking
// a run loop from another thread, and a retained `CFRunLoop` or `CFRunLoopSource` may be
// released on any thread. `objc2-core-foundation` marks these types `!Send` and `!Sync`
// conservatively. `RunLoopWake` offers nothing else, and its fields are only reached through
// `WatcherSignal`, which serialises them behind a mutex.
unsafe impl Send for RunLoopWake {}

impl fmt::Debug for RunLoopWake {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RunLoopWake")
            .finish_non_exhaustive()
    }
}

#[allow(clippy::single_call_fn)]
extern "C-unwind" fn wake_source_perform(_info: *mut c_void) {}

/// A source that does nothing when it runs. Signalling it is only how the thread is woken.
#[allow(clippy::single_call_fn)]
fn create_wake_source() -> Option<CFRetained<CFRunLoopSource>> {
    let mut context = CFRunLoopSourceContext {
        version: 0,
        info: ptr::null_mut(),
        retain: None,
        release: None,
        copyDescription: None,
        equal: None,
        hash: None,
        schedule: None,
        cancel: None,
        perform: Some(wake_source_perform),
    };
    // SAFETY: `context` is a fully initialised version-0 context that outlives the call, and
    // `CFRunLoopSourceCreate` copies it, so no pointer to it is kept. A null allocator selects
    // the default allocator. `info` is null and `wake_source_perform` never reads it.
    unsafe { CFRunLoopSource::new(None, 0, ptr::from_mut(&mut context)) }
}

#[derive(Debug)]
pub(crate) struct SystemPowerSource;

impl SystemPowerSource {
    pub(crate) fn current() -> PowerSource {
        IOPSCopyPowerSourcesInfo()
            .map(|snapshot| PowerSourceSnapshot { snapshot })
            .map_or(PowerSource::Unknown, |snapshot| snapshot.current())
    }
}

#[derive(Debug)]
struct PowerSourceSnapshot {
    snapshot: CFRetained<CFType>,
}

impl PowerSourceSnapshot {
    fn current(&self) -> PowerSource {
        let Some(source) = self.providing_source_type() else {
            return PowerSource::Unknown;
        };
        PowerSource::from(source.as_ref())
    }

    fn providing_source_type(&self) -> Option<CFRetained<CFString>> {
        // SAFETY: `snapshot` is the opaque value returned by
        // `IOPSCopyPowerSourcesInfo`, which is exactly the input contract for
        // `IOPSGetProvidingPowerSourceType`.
        unsafe { IOPSGetProvidingPowerSourceType(Some(&self.snapshot)) }
    }
}

impl From<&CFString> for PowerSource {
    fn from(source: &CFString) -> Self {
        if Self::source_matches(source, kIOPMACPowerKey) {
            Self::External
        } else if Self::source_matches(source, kIOPMBatteryPowerKey)
            || Self::source_matches(source, kIOPMUPSPowerKey)
        {
            Self::Battery
        } else {
            Self::Unknown
        }
    }
}

impl PowerSource {
    fn source_matches(source: &CFString, expected: &std::ffi::CStr) -> bool {
        let expected = CFString::from_str(
            expected
                .to_str()
                .expect("IOKit power source constants are valid UTF-8"),
        );
        source == expected.as_ref()
    }
}

struct PowerEventLoop {
    context: Box<PowerNotificationContext>,
    signal: Arc<WatcherSignal>,
}

impl PowerEventLoop {
    fn run(mut self) {
        let Some(run_loop) = CFRunLoop::current() else {
            log::debug!("power source watcher skipped: current run loop unavailable");
            return;
        };
        // SAFETY: CoreFoundation exposes this immutable process-wide constant.
        let Some(mode) = (unsafe { kCFRunLoopDefaultMode }) else {
            log::debug!("power source watcher skipped: default run loop mode unavailable");
            return;
        };
        let Some(wake_source) = create_wake_source() else {
            log::debug!("power source watcher skipped: wake source unavailable");
            return;
        };
        let Some(power_source) = self.context.create_run_loop_source() else {
            log::debug!("power source watcher skipped: IOKit notification source unavailable");
            return;
        };

        run_loop.add_source(Some(&power_source), Some(mode));
        run_loop.add_source(Some(&wake_source), Some(mode));
        // Publish before reading the stop flag: a stop requested earlier is seen here, and one
        // requested later finds the handle and leaves a signal pending for the loop.
        self.signal.publish(RunLoopWake {
            run_loop: run_loop.clone(),
            source: wake_source.clone(),
        });
        while !self.signal.should_stop() {
            let outcome = CFRunLoop::run_in_mode(Some(mode), IDLE_WAIT, true);
            if outcome == CFRunLoopRunResult::Finished {
                // Nothing is left to wait for; looping again would spin.
                log::debug!("power source watcher stopped: run loop has no sources");
                break;
            }
        }
        // From here a late `notify` has nothing to wake.
        self.signal.unpublish();
        run_loop.remove_source(Some(&power_source), Some(mode));
        run_loop.remove_source(Some(&wake_source), Some(mode));
        power_source.invalidate();
        wake_source.invalidate();
        log::debug!("power source watcher stopped");
    }
}

struct PowerNotificationContext {
    read: Box<dyn Fn() -> PowerSource + Send>,
    deliver: Box<dyn FnMut(PowerSource) -> bool + Send>,
    /// The last source the consumer took. It moves only once `deliver` says it was taken, so a
    /// source the consumer turned down is offered again the next time.
    delivered: PowerSource,
}

impl PowerNotificationContext {
    fn create_run_loop_source(&mut self) -> Option<CFRetained<CFRunLoopSource>> {
        let context = ptr::from_mut(self).cast::<c_void>();
        // SAFETY: `context` points to the boxed `PowerNotificationContext` owned by
        // `PowerEventLoop::run`. That box outlives the run-loop source and is not moved
        // while callbacks may fire. The callback casts it back to the same type.
        unsafe { IOPSNotificationCreateRunLoopSource(Some(handle_power_change), context) }
    }

    fn reconcile(&mut self) {
        let next = (self.read)();
        if next == self.delivered {
            return;
        }
        if (self.deliver)(next) {
            self.delivered = next;
        }
    }
}

/// Receives `IOKit` power-source change callbacks for [`PowerWatcher`].
///
/// # Safety
///
/// `context` must be the pointer created by
/// [`PowerNotificationContext::create_run_loop_source`].
pub unsafe extern "C-unwind" fn handle_power_change(context: *mut c_void) {
    // SAFETY: The run-loop source was created with a pointer to a live
    // `PowerNotificationContext`, and `PowerEventLoop::run` keeps that box
    // pinned in place until after the source is removed and invalidated.
    let Some(context) = (unsafe { context.cast::<PowerNotificationContext>().as_mut() }) else {
        return;
    };
    context.reconcile();
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::c_void,
        ptr,
        sync::{Arc, Mutex, mpsc},
        thread,
        time::{Duration, Instant},
    };

    use objc2_core_foundation::{CFRunLoop, CFRunLoopRunResult, CFString, kCFRunLoopDefaultMode};
    use objc2_io_kit::{kIOPMACPowerKey, kIOPMBatteryPowerKey, kIOPMUPSPowerKey};

    use super::{
        PowerNotificationContext, PowerSource, PowerWatcher, RunLoopWake, WatcherSignal,
        create_wake_source, handle_power_change,
    };

    /// How long a watcher that has nothing left to wait for may take to finish. The loop used to
    /// wake every five seconds to check a flag, so a shutdown that waits on a timeout misses it.
    const PROMPT: Duration = Duration::from_secs(1);

    #[test]
    fn power_source_classifier_maps_ac_to_external_power() {
        let source = TestPowerSource::from_iokit_constant(kIOPMACPowerKey);

        assert_eq!(PowerSource::from(source.as_ref()), PowerSource::External);
    }

    #[test]
    fn power_source_classifier_maps_battery_and_ups_to_battery_power() {
        let battery = TestPowerSource::from_iokit_constant(kIOPMBatteryPowerKey);
        let ups = TestPowerSource::from_iokit_constant(kIOPMUPSPowerKey);

        assert_eq!(PowerSource::from(battery.as_ref()), PowerSource::Battery);
        assert_eq!(PowerSource::from(ups.as_ref()), PowerSource::Battery);
    }

    #[test]
    fn power_source_classifier_preserves_unknown_source() {
        let source = CFString::from_static_str("unexpected source");

        assert_eq!(PowerSource::from(source.as_ref()), PowerSource::Unknown);
    }

    #[test]
    fn dropping_the_watcher_does_not_wait_for_a_timeout() {
        let watcher = PowerWatcher::spawn_with(|| PowerSource::External, |_| true);
        wait_until_asleep(&watcher);

        let started = Instant::now();
        drop(watcher);

        assert!(
            started.elapsed() < PROMPT,
            "a sleeping watcher took {:?} to stop",
            started.elapsed()
        );
    }

    #[test]
    fn dropping_right_after_spawn_always_returns_promptly() {
        for round in 0..50 {
            let watcher = PowerWatcher::spawn_with(|| PowerSource::External, |_| true);
            assert!(
                drops_within(watcher, PROMPT),
                "watcher {round} was still running a second after it was dropped"
            );
        }
    }

    #[test]
    fn a_wake_signalled_before_the_loop_runs_ends_its_next_wait() {
        let run_loop = CFRunLoop::current().expect("test thread has a run loop");
        // SAFETY: CoreFoundation exposes this immutable process-wide constant.
        let mode = unsafe { kCFRunLoopDefaultMode }.expect("default run loop mode");
        let source = create_wake_source().expect("wake source");
        run_loop.add_source(Some(&source), Some(mode));
        let signal = WatcherSignal::default();
        signal.publish(RunLoopWake {
            run_loop: run_loop.clone(),
            source: source.clone(),
        });

        signal.notify();
        // Only a bound for the failing case: a lost signal would sleep out all of it.
        let outcome = CFRunLoop::run_in_mode(Some(mode), 10.0, true);

        run_loop.remove_source(Some(&source), Some(mode));
        source.invalidate();
        assert_eq!(outcome, CFRunLoopRunResult::HandledSource);
    }

    #[test]
    fn a_changed_power_source_is_delivered_once() {
        let source = Arc::new(Mutex::new(PowerSource::External));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let mut context = fake_context(&source, &delivered, 0);

        deliver_callback(&mut context);
        assert!(delivered.lock().unwrap().is_empty());

        *source.lock().unwrap() = PowerSource::Battery;
        deliver_callback(&mut context);
        deliver_callback(&mut context);

        assert_eq!(*delivered.lock().unwrap(), [PowerSource::Battery]);
    }

    #[test]
    fn a_delivery_the_actor_rejected_is_retried() {
        let source = Arc::new(Mutex::new(PowerSource::External));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let mut context = fake_context(&source, &delivered, 1);

        *source.lock().unwrap() = PowerSource::Battery;
        deliver_callback(&mut context);
        deliver_callback(&mut context);
        deliver_callback(&mut context);

        // Offered again after the rejection, then left alone once taken.
        assert_eq!(
            *delivered.lock().unwrap(),
            [PowerSource::Battery, PowerSource::Battery]
        );
    }

    /// A context reading `source`, recording what it delivers, and turning down the first
    /// `rejections` deliveries. It starts out having delivered external power.
    fn fake_context(
        source: &Arc<Mutex<PowerSource>>,
        delivered: &Arc<Mutex<Vec<PowerSource>>>,
        rejections: usize,
    ) -> PowerNotificationContext {
        let source = Arc::clone(source);
        let delivered = Arc::clone(delivered);
        let mut rejections_left = rejections;
        PowerNotificationContext {
            read: Box::new(move || *source.lock().unwrap()),
            deliver: Box::new(move |next| {
                delivered.lock().unwrap().push(next);
                if rejections_left > 0 {
                    rejections_left -= 1;
                    return false;
                }
                true
            }),
            delivered: PowerSource::External,
        }
    }

    fn deliver_callback(context: &mut PowerNotificationContext) {
        // SAFETY: `context` is a live `PowerNotificationContext`, which is what the callback
        // casts its pointer back to.
        unsafe { handle_power_change(ptr::from_mut(context).cast::<c_void>()) };
    }

    /// Waits until the watcher's thread is asleep in its run loop. This is the state the old
    /// five-second loop could be caught in, so the check that follows is about waking it.
    #[allow(clippy::single_call_fn)]
    fn wait_until_asleep(watcher: &PowerWatcher) {
        let give_up = Instant::now() + Duration::from_secs(30);
        while !watcher.signal.is_asleep() {
            assert!(
                Instant::now() < give_up,
                "the watcher thread never went to sleep in its run loop"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    /// Drops `watcher` on another thread so a watcher that never stops fails the test instead
    /// of hanging it.
    #[allow(clippy::single_call_fn)]
    fn drops_within(watcher: PowerWatcher, limit: Duration) -> bool {
        let (done, finished) = mpsc::channel();
        let _ = thread::spawn(move || {
            drop(watcher);
            let _ = done.send(());
        });
        finished.recv_timeout(limit).is_ok()
    }

    struct TestPowerSource;

    impl TestPowerSource {
        fn from_iokit_constant(
            value: &'static std::ffi::CStr,
        ) -> objc2_core_foundation::CFRetained<CFString> {
            CFString::from_str(value.to_str().expect("IOKit constants are UTF-8"))
        }
    }
}
