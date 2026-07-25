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

The driver advertises every supported camera-native NV12/BGRA format and
revalidates the selected format after connecting the output. It does not
advertise an unverified conversion.
Pixel storage is not copied by the driver. CPU consumers borrow packed bytes or
individual planes while one balanced native read lock is held. Apple GPU
consumers may use the scoped native Core Video projection.
Image-buffer, sample-buffer, and per-sample attachments preserve propagation
mode and recursive property-list structure through typed portable values.
Unsupported native value types fail explicitly instead of disappearing.

The negotiated format description is reused across frames. Runtime dimensions
are validated before delivery, and terminal delivery state requests shutdown on
the native backend actor instead of stopping AVFoundation from its callback.
`configure(_:)` returns success only after the native session, device input,
requested frame duration, and portable focus/exposure/white-balance controls
have been applied and validated. The macOS 26 locked-duration API is preferred;
the legacy duration setters and device controls share one Objective-C
transaction and rollback boundary so failures remain typed. Device observation
emits one authoritative snapshot before native connection and disconnection
deltas. Streams expose ordered interruption, resume, dropped-frame, and terminal
failure events, plus validated orientation and mirroring configuration.
See [LOW_LEVEL_PIPELINE.md](LOW_LEVEL_PIPELINE.md) for ownership, allocation, and
future move-only and GPU presentation boundaries.

See [APPLE_API_TRACE.md](APPLE_API_TRACE.md) for the Apple capture families used
by this adapter and explicit macOS availability differences.

## Verification

The deterministic package tests use the repository's pinned Swift 6.4 snapshot:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test \
  -scheme OpenAVFoundationAppleCameraDriver \
  -destination 'platform=macOS' \
  -only-testing:OpenAVFoundationAppleCameraDriverTests \
  -maximum-test-execution-time-allowance 60 \
  SWIFT_EXEC=/Users/1amageek/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a.xctoolchain/usr/bin/swiftc
```

`AppleCameraLiveTests` is an opt-in compile-time test. An xctest host without
camera authorization cannot establish live behavior, so the signed
CameraEmulator app is the authoritative live frame, stop, and restart check.
