@preconcurrency import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import OpenAVFoundationDriver
import Synchronization

final class AppleVideoSampleDelegate:
    NSObject,
    AVFoundation.AVCaptureVideoDataOutputSampleBufferDelegate
{
    private let delivery: AppleSampleBufferDelivery
    private let eventRelay: AppleCameraStreamEventRelay

    init(
        delivery: AppleSampleBufferDelivery,
        eventRelay: AppleCameraStreamEventRelay
    ) {
        self.delivery = delivery
        self.eventRelay = eventRelay
    }

    func captureOutput(
        _ output: AVFoundation.AVCaptureOutput,
        didOutput sampleBuffer: CoreMedia.CMSampleBuffer,
        from connection: AVFoundation.AVCaptureConnection
    ) {
        delivery.offer(sampleBuffer)
    }

    func captureOutput(
        _ output: AVFoundation.AVCaptureOutput,
        didDrop sampleBuffer: CoreMedia.CMSampleBuffer,
        from connection: AVFoundation.AVCaptureConnection
    ) {
        eventRelay.offerDrop(
            presentationTimeStamp: AppleSampleBufferBridge.portableTime(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ),
            reason: Self.dropReason(from: sampleBuffer)
        )
    }

    static func dropReason(
        from sampleBuffer: CoreMedia.CMSampleBuffer
    ) -> CaptureStreamDropReason {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) else {
            return .platform(code: 0)
        }
        if CFEqual(value, kCMSampleBufferDroppedFrameReason_FrameWasLate) {
            return .frameWasLate
        }
        if CFEqual(value, kCMSampleBufferDroppedFrameReason_OutOfBuffers) {
            return .outOfBuffers
        }
        if CFEqual(value, kCMSampleBufferDroppedFrameReason_Discontinuity) {
            return .discontinuity
        }
        return .platform(code: 0)
    }
}

final class AppleSampleBufferDelivery: Sendable {
    private struct State: Sendable {
        var isStopped = false
    }

    private let driverID: CaptureDriverID
    private let deviceID: CaptureDeviceID
    private let bridge: AppleSampleBufferBridge
    private let sink: any CaptureSampleSink
    private let failureHandler:
        @Sendable (CaptureDriverError) -> Void
    private let terminalHandler: @Sendable () -> Void
    private let failureEventHandler:
        @Sendable (CaptureDriverError) -> Void
    private let state = Mutex(State())
    private let inFlightOffers = DispatchGroup()

    init(
        driverID: CaptureDriverID,
        deviceID: CaptureDeviceID,
        bridge: AppleSampleBufferBridge,
        sink: any CaptureSampleSink,
        failureHandler:
            @escaping @Sendable (CaptureDriverError) -> Void,
        terminalHandler: @escaping @Sendable () -> Void,
        failureEventHandler:
            @escaping @Sendable (CaptureDriverError) -> Void = { _ in }
    ) {
        self.driverID = driverID
        self.deviceID = deviceID
        self.bridge = bridge
        self.sink = sink
        self.failureHandler = failureHandler
        self.terminalHandler = terminalHandler
        self.failureEventHandler = failureEventHandler
    }

    func offer(_ sampleBuffer: CoreMedia.CMSampleBuffer) {
        inFlightOffers.enter()
        let shouldOffer = state.withLock { state -> Bool in
            guard !state.isStopped else {
                return false
            }
            return true
        }
        guard shouldOffer else {
            inFlightOffers.leave()
            return
        }
        defer {
            inFlightOffers.leave()
        }

        do {
            let sample = try bridge.sample(
                from: sampleBuffer
            )
            if sink.offer(sample) == .stop {
                let becameStopped = stopDelivery()
                if becameStopped {
                    terminalHandler()
                }
            }
        } catch {
            let becameStopped = stopDelivery()
            guard becameStopped else {
                return
            }
            let failure = CaptureDriverError.backendFailure(
                driverID: driverID,
                deviceID: deviceID,
                operation: .streaming,
                code: error.code
            )
            failureEventHandler(failure)
            failureHandler(failure)
        }
    }

    func shutdown() {
        _ = stopDelivery()
        // CaptureSampleSink.offer is synchronous and includes callback
        // processing time. Sinks must return promptly and keep unbounded I/O
        // off this path; waiting here closes the explicit shutdown boundary
        // after every accepted in-flight callback returns.
        inFlightOffers.wait()
    }

    private func stopDelivery() -> Bool {
        state.withLock { state in
            guard !state.isStopped else {
                return false
            }
            state.isStopped = true
            return true
        }
    }
}
