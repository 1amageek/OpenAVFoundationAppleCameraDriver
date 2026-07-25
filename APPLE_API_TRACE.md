# Apple Camera Driver API Trace

## Baseline

- Review date: 2026-07-25
- SDK: macOS 27.0 from the active Xcode beta
- Documentation: Apple Developer Documentation read with `remark`
- Local evidence: AVFoundation and Core Video headers, SDK symbol graphs, package
  source, deterministic behavior tests, and a pre-refactor live camera baseline

## Adapter trace

| Apple family | Adapter use | Status | Remaining behavior |
|---|---|---|---|
| Camera authorization | `AVCaptureDevice` authorization APIs | Implemented | None for video |
| Device discovery | `AVCaptureDevice.DiscoverySession` and connection notifications | Implemented | None for video topology |
| Format inspection | Every native `AVCaptureDevice.Format`, dimensions, subtype, and frame-rate range | Implemented | None for native NV12/BGRA |
| Device configuration | Native format, locked/automatic frame duration, focus/exposure/white-balance modes and points, Objective-C exception mapping, and transactional rollback | Implemented | Custom focus/exposure/white-balance values and zoom are unavailable in the macOS API |
| Capture session | `AVCaptureSession` construction, lifecycle, interruption, recovery, and runtime-error notifications | Implemented | macOS does not expose the interruption-reason key |
| Device input | `AVCaptureDeviceInput` | Implemented | Audio is outside this driver |
| Video data output | `AVCaptureVideoDataOutput`, sample callback, and dropped-sample callback | Implemented | None for dropped-frame reporting |
| Sample bridge | Apple `CMSampleBuffer` to OpenCoreMedia image sample, bearer attachments, and per-sample attachments | Implemented | None for image samples |
| Pixel bridge | Apple `CVPixelBuffer` retained owner, scoped borrow, and Metal texture projection | Implemented | None |
| Orientation and mirroring | Connection rotation-angle and mirroring properties with post-validation | Implemented | None for advertised modes |
| Stabilization | `AVCaptureConnection` stabilization API | Unsupported on macOS | Not advertised; requests fail before backend mutation |
| System pressure | `AVCaptureSystemPressureState` | Unsupported on macOS | Not advertised by the macOS driver |

## Boundary

The adapter advertises only native NV12 and BGRA frames that it can route without
copying pixel bytes. Unsupported formats remain undiscovered rather than being
silently converted. Adding another native format requires an explicit
conversion capability; the current provider does not expose or silently
convert it.

`CaptureDeviceHandle.configure(_:)` validates the complete portable request and
returns only after the native input/session and duration setting are applied.
Apple-documented duration exceptions are caught in the platform bridge and
reported as typed driver failures rather than terminating the process.
