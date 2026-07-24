# OpenAVFoundationAppleCameraDriver

A macOS-only concrete `CaptureDeviceProvider` backed by Apple's AVFoundation.
It is a development and conformance driver for exercising the same
OpenAVFoundation graph that Linux, Jetson, browser, and Embedded drivers use.

```text
Apple camera
    -> Apple AVCaptureVideoDataOutput
    -> fused BGRA/NV12 CVPixelBuffer owner
    -> scoped packed or plane borrow
    -> OpenCoreVideo
    -> OpenCoreMedia
    -> CaptureSampleSink
```

The driver advertises a supported camera-native NV12/BGRA format and revalidates
it after connecting the output. It does not advertise an unverified conversion.
Pixel storage is not copied by the driver. CPU consumers borrow packed bytes or
individual planes while one balanced native read lock is held. Apple GPU
consumers may use the scoped native Core Video projection.

The negotiated format description is reused across frames. Runtime dimensions
are validated before delivery, and terminal delivery state stops the native
capture session without synchronously stopping AVFoundation from its callback.
See [LOW_LEVEL_PIPELINE.md](LOW_LEVEL_PIPELINE.md) for ownership, allocation, and
future move-only and GPU presentation boundaries.

See [APPLE_API_TRACE.md](APPLE_API_TRACE.md) for the Apple capture families used
by this adapter and the remaining partial behavior.
