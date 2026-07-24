# Low-Level Camera Pipeline

## Objective

The Apple camera driver is a conformance and performance proving ground for
future V4L2, GStreamer, and Jetson drivers. The hot path preserves the platform
pixel owner, avoids media materialization, bounds callback work, and makes every
remaining copy explicit.

```text
Apple CMSampleBuffer
        │ retains
        ▼
Apple CVPixelBuffer
        │ retained by one fused owner/view
        ▼
AppleCameraPixelBuffer
        ├─ BGRA: lock → borrowing Span<UInt8> → unlock
        ├─ NV12 Y: lock → borrowing Span<UInt8> → unlock
        └─ NV12 CbCr: lock → borrowing Span<UInt8> → unlock
        │ retained payload reference
        ▼
CMImageSampleBuffer
        │ same reference through routing
        ▼
CaptureSampleSink
```

## Copy and allocation boundaries

| Boundary | Pixel copy | Current allocation behavior |
|---|---:|---|
| Apple sample to OpenCoreVideo | No | One fused owner/view per frame |
| OpenCoreVideo to OpenCoreMedia | No | One sample facade per frame |
| Driver to OpenAVFoundation | No | Same sample reference |
| CameraEmulator Core Image input | No CPU materialization | Native `CVPixelBuffer` projection |
| Core Image to SwiftUI | Framework render target | One `CGImage` presentation value |

The bridge creates one immutable format description per negotiated stream and
reuses it for every sample. `CMImageSampleBuffer` stores its single image timing
value directly rather than retaining a one-element timing array. The public
array-taking API and its boundary value remain, so the pipeline does not claim
whole-frame zero-allocation.

`AppleCameraPixelBuffer` directly retains the Apple `CVPixelBuffer` and conforms
to both the OpenCoreVideo image-buffer and shared planar-storage contracts. A
planar frame therefore does not allocate one owner wrapper per plane. Every
Swift `Span` remains scoped to the Core Video lock and cannot escape the
callback.

## Negotiated format invariant

Capabilities advertise the camera's active native format only when it is a
supported BGRA or NV12 variant. Discovery omits incompatible native formats
rather than advertising an unverified conversion. After the output is connected
to its session, Runtime rechecks that the advertised format remains available
before applying `videoSettings`. Every incoming frame is then checked against
the negotiated pixel type and dimensions. A mismatch is a terminal typed bridge
failure; it is never accepted under the advertised format.

## Terminal and shutdown invariant

```text
sink .stop / bridge failure
          │ close delivery gate
          ├─ reject queued callbacks
          ├─ report typed failure when applicable
          └─ asynchronously request native stop

explicit shutdown
          │ close delivery gate
          ├─ wait for the bounded in-flight offer
          ├─ detach Apple delegate
          └─ stop AVCaptureSession
```

The callback does not synchronously stop `AVCaptureSession`, because Apple may
wait for callback completion. Native termination is scheduled on the serial
control queue after the delivery gate is closed. Explicit shutdown waits only
for the nonblocking `CaptureSampleSink.offer` contract and performs no wait while
holding a mutex.

## Move-only ownership boundary

The Apple-compatible sample graph uses reference semantics intentionally:
`CMSampleBuffer` is an `AnyObject` contract and future capture fan-out requires
shared lease identity. A move-only `~Copyable` frame owner should not be inserted
into this API without defining how a single owner is promoted into an explicit
shared lease.

A future lower-level observation or inference extension may use a move-only
`CaptureFrameLease` before fan-out. That design must cover:

- consuming transfer from a driver;
- explicit promotion to shared ownership;
- DMA-BUF, NVMM, IOSurface, Metal, and CUDA handles;
- plane-aware NV12 borrowing;
- deterministic release and backpressure;
- Native, WASM, and Embedded lowering.

It is intentionally separate from the current correctness and allocation
reduction slice.

## Completed performance slice

1. Native full-range and video-range NV12 negotiation with connected-output
   revalidation.
2. One fused packed/planar Apple owner with scoped plane borrows.
3. Native Core Image projection without a `Data` materialization.
4. Live native NV12 Video Range 1920x1080 validation.

## Next performance slice

1. Add allocation and copy counters around the callback and render boundaries.
2. Present the IOSurface through a Metal texture cache without creating a
   per-frame `CGImage`.
3. Import platform surfaces directly into CUDA at the inference edge.
4. Define the move-only pre-fan-out frame lease after the multi-output ownership
   contract is complete.
