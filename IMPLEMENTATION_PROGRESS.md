# Apple Camera Driver Implementation Progress

## Apple API trace

- [x] Adapter use of Apple capture families is recorded
- [x] Native-format capability policy is explicit and has no placeholder branch
- [x] Platform availability for interruption, pressure, orientation,
      stabilization, and mirroring is recorded

## Required implementation

- [x] macOS camera authorization mapping
- [x] physical and virtual video-device discovery
- [x] driver-namespaced device identity
- [x] native NV12/BGRA capability discovery without unverified conversion
- [x] opened handle lifecycle
- [x] Apple capture session construction
- [x] synchronous sample-sink delivery
- [x] scoped zero-copy packed and planar Apple pixel-buffer ownership
- [x] typed bridge and lifecycle failures
- [x] one fused Apple pixel-buffer owner/view without a copied storage allocation
- [x] negotiated pixel format and dimension request with per-frame validation
- [x] stream-scoped immutable format-description reuse
- [x] synchronized delivery gate and bounded in-flight shutdown
- [x] callback-safe native termination request
- [x] Native NV12 full-range and video-range output
- [x] Driver configuration accepts every advertised pixel format
- [x] output settings before connection plus post-commit format revalidation
- [x] incompatible native formats are omitted without failing discovery
- [x] active native-format validation and frame-rate application
- [x] Hot-plug notifications with authoritative initial snapshot
- [x] complete control validation before native configuration
- [x] native session/input application before configuration success
- [x] macOS 26 locked-duration path and typed Objective-C exception boundary
- [x] explicit frame-rate removal and auto-frame-rate restoration
- [x] actor-isolated native graph and stream lifecycle
- [x] transactional frame-duration rollback with distinct rollback failure
- [x] handle-level operation gate across backend suspension points
- [x] stream-level operation gate across runtime suspension points
- [x] active-format and frame-rate revalidation after input and output commits
- [x] recursive Core Video and Core Media attachment propagation
- [x] typed rejection of unsupported native attachment value types
- [x] nonwrapping stream identity allocation with typed exhaustion
- [x] complete native NV12/BGRA format enumeration and exact format selection
- [x] mode and point-of-interest capabilities for focus and exposure
- [x] white-balance mode capabilities
- [x] atomic native format, frame-rate, and device-control configuration
- [x] rollback of native format, frame-rate, and controls after partial failure
- [x] typed rejection of macOS-unavailable custom controls and zoom
- [x] stream interruption, resume, runtime-error, and source-drop events
- [x] ordered bounded event delivery with terminal overflow failure
- [x] orientation and mirroring application with native post-validation
- [x] typed rejection of unadvertised macOS stabilization
- [x] explicit omission of system-pressure capability on macOS
- [x] Metal texture projection retains the exact native pixel-buffer owner
- [x] rollback failure invalidates later operations while retaining cleanup
      state for a retryable shutdown
- [x] sample-bridge failure emits one terminal event before backend stop
- [x] terminal failure stops the backend even without an event sink
- [x] duplicate discovery identifiers terminate observation explicitly

## Verification

- [x] 55 deterministic native driver behavior tests pass with the Swift 6.4
      snapshot against the resolved URL dependency graph
- [x] the same deterministic suite passes with Thread Sanitizer enabled
- [x] one opt-in live-camera test compiles and is skipped by the deterministic
      run; the xctest host is not currently camera-authorized
- [x] address identity and retained pixel lifetime pass
- [x] callback-backed native storage remains retained and releases exactly once
      with wrapper destruction
- [x] bridged sample retains the exact native `CVPixelBuffer` object identity
- [x] packed and planar address identity and retained lifetime pass
- [x] nested Y/CbCr plane borrowing under one native lock passes
- [x] Core Image projection survives native sample release
- [x] native pixel-format advertising policy passes
- [x] format-description reuse, dimension rejection, and pixel-format rejection
      pass
- [x] sink stop, failure stop, queued delivery rejection, and in-flight shutdown
      pass
- [x] frame-rate range validation and reciprocal duration policy pass
- [x] hot-plug snapshot, topology diff, sink stop, failure, and shutdown pass
- [x] handle configuration success/failure commit ordering and unsupported
      control rejection pass
- [x] public provider observation path with injected discovery and notifications
      passes
- [x] concurrent configure and shutdown operations fail with typed busy errors
- [x] concurrent stream start and shutdown fail with typed busy errors
- [x] handle and stream shutdown failures leave their public facades terminal
- [x] propagating and non-propagating image, bearer, and per-sample
      attachments pass, including recursive containers and unsigned bounds
- [x] unsupported native attachment values fail through the typed bridge
- [x] stream identity exhaustion fails rather than wrapping or reusing an ID
- [x] configuration and topology rollback failures reject every later
      non-shutdown backend operation
- [x] failed cleanup retains invalidated state for a later idempotent shutdown
- [x] bridge failure reaches `.failed`, stops exactly once, and still stops
      when no runtime-event sink is installed
- [x] duplicate initial and refreshed device snapshots fail observation rather
      than silently overwriting a descriptor
- [ ] Address Sanitizer cannot link this mixed Objective-C and Swift snapshot
      build because Xcode clang expects
      `___asan_version_mismatch_check_apple_clang_2100`; this toolchain mismatch
      is not counted as passing verification
- [ ] live native capture, stop, and restart revalidated after the native-backend
      actor refactor
- [ ] live macOS 27 camera attachment types revalidated against the recursive
      typed bridge; the first pre-reset frame reported typed attachment failure
      and the current signed app is waiting at the locked-screen TCC boundary

## Historical live evidence

Before the native-backend actor refactor, CameraEmulator verified native NV12
Video Range 1920x1080 capture, correct color rendering, stable stop, and restart.
That result remains useful regression context but is not current proof for the
refactored path or the new attachment bridge.

CameraEmulator consumes the native pixel buffer through the Core Image
projection without materializing CPU bytes. Core Image creates the `CGImage`
presentation value. Revalidation of that application path is the remaining live
check above; the driver and OpenCoreVideo/OpenCoreMedia bridge itself preserves
pixel-buffer identity in deterministic tests.
