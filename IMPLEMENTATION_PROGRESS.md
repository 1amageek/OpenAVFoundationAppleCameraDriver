# Apple Camera Driver Implementation Progress

## Apple API trace

- [x] Adapter use of Apple capture families is recorded
- [x] Native-format and frame-rate partial branches have source markers
- [x] Remaining hot-plug, interruption, pressure, and orientation work is tracked

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
- [x] direct Apple pixel-buffer ownership without a wrapper allocation
- [x] negotiated pixel format and dimension request with per-frame validation
- [x] stream-scoped immutable format-description reuse
- [x] synchronized delivery gate and bounded in-flight shutdown
- [x] callback-safe native termination request
- [x] Native NV12 full-range and video-range output
- [x] Driver configuration accepts every advertised pixel format
- [x] connected-output format revalidation before video settings
- [x] incompatible native formats are omitted without failing discovery
- [ ] Public capture-graph format selection and frame-rate selection
- [ ] Hot-plug notifications

## Verification

- [x] 17 native driver behavior tests pass
- [x] address identity and retained pixel lifetime pass
- [x] packed and planar address identity and retained lifetime pass
- [x] nested Y/CbCr plane borrowing under one native lock passes
- [x] Core Image projection survives native sample release
- [x] native pixel-format advertising policy passes
- [x] format-description reuse, dimension rejection, and pixel-format rejection
      pass
- [x] sink stop, failure stop, queued delivery rejection, and in-flight shutdown
      pass
- [x] live native NV12 Video Range 1920x1080 capture and correct color rendering
      pass
- [x] explicit stop with stable frame count and restart pass

The CameraEmulator passes the native pixel buffer to Core Image without
materializing CPU bytes. Core Image creates the `CGImage` presentation value.
The driver and OpenCoreVideo/OpenCoreMedia routing path do not copy pixel bytes.
