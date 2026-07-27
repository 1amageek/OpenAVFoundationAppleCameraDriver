# Apple Camera Driver Design

## Scope

This package imports Apple's AVFoundation only on macOS and adapts physical or
virtual Mac cameras to `OpenAVFoundationDriver`. It does not modify the shared
OpenAVFoundation graph and is not a production Jetson backend.

## API evidence

The implementation was checked against the installed macOS 27 SDK symbol graph
and headers for `AVCaptureDevice`, `AVCaptureSession`, and
`AVCaptureVideoDataOutput`. Apple documentation was read with `remark`.

## Ownership

`AppleCameraPixelBuffer` owns one `+1` retain of the Apple `CVPixelBuffer` and
directly implements the OpenCoreVideo pixel-buffer contract for both packed
BGRA and planar NV12. The unchanged opaque address bits are stored behind the
same `Mutex` contract used by every target rather than weakening isolation with
`nonisolated(unsafe)`. A short owner borrow reconstructs a strong local native
reference; Core Video locking and the caller callback occur after that mutex is
released. The owner releases the retain exactly once in `deinit`.

Each OpenCoreVideo borrow locks the Apple pixel buffer, obtains the current
packed or plane base address, invokes the scoped `Span` callback, and unlocks
it. The pixel pointer never escapes the callback and the driver does not
materialize media bytes.

The fused buffer owns the Core Video reference directly and does not allocate
separate storage, buffer, or per-plane owner wrappers. It also conforms to
`CVPlanarStorageLease`, connecting Apple's native owner to the same single-owner
contract intended for DMA-BUF and `NvBufSurface`. The bridge caches one immutable
OpenCoreMedia format description for the negotiated stream. OpenCoreMedia stores
the single image timing value as a scalar, while preserving its public
array-taking API.

Core Video image attachments, Core Media bearer attachments, and Core Media
per-sample attachments cross the bridge with their propagation mode intact.
Property-list scalars and recursive arrays/dictionaries are represented by
typed portable values. An unsupported Core Foundation value fails the sample
bridge with a typed error; it is never discarded silently. Pixel ownership
remains zero-copy. Binary attachment metadata is copied once because the
portable value must own it beyond the native Core Foundation borrow.

Detailed copy, allocation, shutdown, and future move-only ownership boundaries
are recorded in [LOW_LEVEL_PIPELINE.md](LOW_LEVEL_PIPELINE.md).

## Shared-state review matrix

This package is macOS-only. WASM and Embedded columns are therefore unavailable
by package contract rather than alternate unsynchronized implementations.

| Logical state | Native storage and isolation | Read entry | Mutation entry | Shutdown or release | WASM / Embedded |
|---|---|---|---|---|---|
| Native pixel owner | `Mutex<UInt>` containing unchanged retained-reference address bits | `nativePixelBuffer()` creates a strong local reference | Initializer only | `deinit` performs the exactly-once unmanaged release | Not built |
| Pixel read-lock phase | `Mutex<State>` | `withReadLock` | `withReadLock` | Final reader unlocks Core Video | Not built |
| Sample delivery gate | `Mutex<State>` plus the Apple callback-boundary `DispatchGroup` | `offer` | `offer`, `shutdown` | Gate closes before waiting for accepted in-flight work | Not built |
| Device handle and stream phase | Actor-isolated enums | Actor methods | Actor methods | Actor `shutdown` is terminal | Not built |
| Native session graph | `AppleCameraNativeDeviceBackend` actor | Backend actor methods | Backend actor methods | Actor detaches delegate, output, and session | Not built |
| Backend validity | Actor-isolated `AppleCameraBackendLifecycle` | Every public backend operation | Rollback invalidation and successful cleanup | Invalidated state retains the graph until cleanup succeeds | Not built |
| Hot-plug observation | `AppleCameraDeviceEventSubscription` actor | Actor refresh | Actor refresh and notification tasks | Actor removes every observer token | Not built |
| Stream event delivery | `Mutex<State>` with a bounded pending-event queue | Synchronous drain snapshots one sink/event pair | Native notification and drop callbacks enqueue events | Terminal failure, sink stop, or shutdown clears the sink and queue | Not built |

No mutex critical section contains `await`, Apple session I/O, sink delivery,
event emission, or an external callback.

## Configuration, format, and termination contracts

Discovery enumerates every native NV12/BGRA format, including its exact
dimensions and frame-rate ranges. The active supported native format is
preferred; otherwise the first supported native format is selected. Cameras
whose formats all require an unimplemented conversion are omitted by this
provider without affecting compatible devices.
The handle validates the complete portable configuration, including controls,
before the native backend is called. The backend actor owns the Apple device,
session, input, output, and stream state. It revalidates the native subtype,
dimensions, and selected frame-rate range before construction, after the input
commit, and after the output commit. It reapplies the selected frame duration
after the final topology exists. A topology that changes the advertised native
format fails explicitly instead of accepting an AVFoundation conversion.

On macOS 26 and later, the backend uses
`AVCaptureDeviceInput.activeLockedVideoFrameDuration` after checking both locked
duration capability and the device minimum duration. Earlier systems use the
device minimum and maximum duration properties. Both paths pass through a small
Objective-C exception bridge because Apple documents invalid duration setters as
raising `NSInvalidArgumentException`, which Swift cannot catch. Lock failures,
unsupported durations, and exceptions are mapped to `CaptureDriverError`.
Selecting no explicit frame rate removes the previous override and restores the
auto-frame-rate state that existed when the backend opened.
The Objective-C boundary takes one device configuration lock and snapshots the
native format, duration, auto-frame-rate state, focus, exposure, and
white-balance configuration before mutation. Any unsupported result or
exception rolls every mutated value back while the lock is held; rollback
failure has its own typed result and is never reported as successful
configuration. macOS does not provide the custom lens-position, custom
exposure, white-balance-gain, or zoom APIs used on Apple mobile platforms, so
those capabilities are not advertised and portable requests fail with typed
control errors before native mutation.

The public device handle admits one backend operation at a time. Actor
reentrancy across an awaited backend call therefore produces a typed
`deviceBusy` result for a concurrent operation rather than allowing native and
facade configuration state to commit in different orders. Each public stream
uses the same gate across runtime suspension points, makes repeated start and
shutdown calls idempotent, and remains terminal if native teardown reports a
failure after partial cleanup.
Stream identifiers are issued by a nonwrapping sequence. `UInt64.max` is valid
once; the following allocation fails with a typed streaming error rather than
reusing an identifier.

If configuration rollback or stream-topology rollback fails, the native backend
becomes fail-closed. It retains the graph needed to retry restoration during
`shutdown()`, but every later non-shutdown operation fails with the original
typed rollback code. A failed cleanup leaves this state intact for another
idempotent shutdown attempt; only successful restoration discards the graph and
commits the terminal shutdown state.

After configuration, stream creation connects the output, revalidates output
availability, and requests the negotiated pixel type and dimensions. Every
received pixel buffer is validated against both. A mismatch is a typed terminal
failure.

Device observation installs native connection observers before taking its
authoritative discovery snapshot. The actor serializes the initial snapshot,
subsequent topology diffs, failure termination, and idempotent shutdown.
Observation never emits a delta before the initial snapshot.
Duplicate device identifiers in the initial or refreshed snapshot are a typed
observation failure and stop the subscription; dictionary overwrite is never
used as a fallback.

Each stream advertises interruption, source-drop, and terminal-failure events.
Native session notifications and dropped-sample callbacks enter a
`Mutex<State>` relay, which preserves order and invokes the external sink only
after releasing the lock. The pending control-event queue is bounded; overflow
is a typed terminal streaming failure. macOS does not expose
`AVCaptureSystemPressureState` or the interruption-reason key, so pressure is
not advertised and an interruption uses an explicit platform reason code.
Sample-bridge failure enters this relay as `.failed`; with a sink it is
delivered exactly once before termination, and without a sink the same relay
still requests backend stop. External sinks and terminal callbacks execute
outside the relay mutex.

Video connection configuration passes the four portable quarter-turn rotation
angles to the native rotation-angle API, applies mirroring policy only when the
connection reports support, and validates the resulting native properties.
Stabilization is not available in the macOS API and is therefore neither
advertised nor silently ignored.

Sink stop, bridge failure, and explicit shutdown first close a synchronized
delivery gate. Explicit shutdown waits for a bounded in-flight sink offer,
detaches the Apple delegate, and then stops the session. Because the gate closes
first, already queued callbacks reject their frame without entering the bridge
or sink. Callback-triggered
termination schedules a task onto the native backend actor rather than stopping
the session synchronously from the callback, avoiding an AVFoundation
callback/stop deadlock.

## Current differences

- The driver exposes every verified native NV12 or BGRA format and preserves
  exact native format identity.
- Apple does not expose the `.inputPriority` session preset on macOS. The
  backend therefore accepts the default `.high` preset only when post-commit
  validation proves that it preserved the advertised native format.
- Native formats outside that set require a future conversion-capability
  contract and are not advertised by this provider.
- Asynchronous sample-bridge failure is reported through the provider's required
  failure handler, closes delivery, and requests native session termination.
