# Apple Camera Driver API Trace

## Baseline

- Review date: 2026-07-24
- SDK: macOS 27.0 from the active Xcode beta
- Documentation: Apple Developer Documentation read with `remark`
- Local evidence: AVFoundation and Core Video headers, SDK symbol graphs, package
  source, behavior tests, and live camera smoke

## Adapter trace

| Apple family | Adapter use | Status | Remaining behavior |
|---|---|---|---|
| Camera authorization | `AVCaptureDevice` authorization APIs | Implemented | None for video |
| Device discovery | `AVCaptureDevice.DiscoverySession` | Partial | Hot-plug observation |
| Format inspection | Active `AVCaptureDevice.Format` | Partial | Full format enumeration and selection |
| Device configuration | Active native format request | Partial | Explicit frame-rate application and controls |
| Capture session | `AVCaptureSession` construction and lifecycle | Implemented | Interruption and recovery events |
| Device input | `AVCaptureDeviceInput` | Implemented | Audio is outside this driver |
| Video data output | `AVCaptureVideoDataOutput` | Implemented | Drop callback and pressure reporting |
| Sample bridge | Apple `CMSampleBuffer` to OpenCoreMedia image sample | Implemented | Attachment propagation |
| Pixel bridge | Apple `CVPixelBuffer` retained owner and scoped borrow | Implemented | Metal texture projection tests |
| Orientation and stabilization | Connection/device properties | Planned | Capability and configuration contracts |
| System pressure | `AVCaptureSystemPressureState` | Planned | Driver event contract |

## Boundary

The adapter advertises only native NV12 and BGRA frames that it can route without
copying pixel bytes. Unsupported formats remain undiscovered rather than being
silently converted. The source marker on that branch records the completion
condition for a future explicit conversion capability.
