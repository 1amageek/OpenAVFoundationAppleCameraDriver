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

`AppleCameraPixelBuffer` retains one Apple `CVPixelBuffer` and directly
implements the OpenCoreVideo pixel-buffer contract for both packed BGRA and
planar NV12. Each OpenCoreVideo borrow locks the Apple pixel buffer, obtains the
current packed or plane base address, invokes the scoped `Span` callback, and
unlocks it. The pointer never escapes the callback and the driver does not
materialize media bytes.

The fused buffer owns the Core Video reference directly and does not allocate
separate storage, buffer, or per-plane owner wrappers. It also conforms to
`CVPlanarStorageLease`, connecting Apple's native owner to the same single-owner
contract intended for DMA-BUF and `NvBufSurface`. The bridge caches one immutable
OpenCoreMedia format description for the negotiated stream. OpenCoreMedia stores
the single image timing value as a scalar, while preserving its public
array-taking API.

Detailed copy, allocation, shutdown, and future move-only ownership boundaries
are recorded in [LOW_LEVEL_PIPELINE.md](LOW_LEVEL_PIPELINE.md).

## Format and termination contracts

Discovery advertises the camera's active native format only when it is supported
NV12/BGRA. Cameras whose active native format requires an unimplemented
conversion are omitted by this provider without affecting compatible devices.
Runtime connects the output, revalidates availability before applying settings,
and requests the negotiated pixel type and dimensions. Every received pixel
buffer is validated against both. A mismatch is a typed terminal failure.

Sink stop, bridge failure, and explicit shutdown first close a synchronized
delivery gate. Explicit shutdown waits for a bounded in-flight sink offer before
detaching the Apple delegate. Callback-triggered native stop is scheduled on the
serial control queue rather than called synchronously from the callback, avoiding
an AVFoundation callback/stop deadlock.

## Current differences

- The driver exposes one verified native NV12 or BGRA format for the active
  camera dimensions.
- Native formats outside that set require a future conversion-capability
  contract and are not advertised by this provider.
- Explicit frame-rate configuration is rejected rather than ignored.
- Asynchronous sample-bridge failure is reported through the provider's required
  failure handler, closes delivery, and requests native session termination.
