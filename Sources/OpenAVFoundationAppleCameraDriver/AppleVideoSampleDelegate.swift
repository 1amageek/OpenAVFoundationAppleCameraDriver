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

    init(delivery: AppleSampleBufferDelivery) {
        self.delivery = delivery
    }

    func captureOutput(
        _ output: AVFoundation.AVCaptureOutput,
        didOutput sampleBuffer: CoreMedia.CMSampleBuffer,
        from connection: AVFoundation.AVCaptureConnection
    ) {
        delivery.offer(sampleBuffer)
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
    private let state = Mutex(State())
    private let inFlightOffers = DispatchGroup()

    init(
        driverID: CaptureDriverID,
        deviceID: CaptureDeviceID,
        bridge: AppleSampleBufferBridge,
        sink: any CaptureSampleSink,
        failureHandler:
            @escaping @Sendable (CaptureDriverError) -> Void,
        terminalHandler: @escaping @Sendable () -> Void
    ) {
        self.driverID = driverID
        self.deviceID = deviceID
        self.bridge = bridge
        self.sink = sink
        self.failureHandler = failureHandler
        self.terminalHandler = terminalHandler
    }

    func offer(_ sampleBuffer: CoreMedia.CMSampleBuffer) {
        let shouldOffer = state.withLock { state -> Bool in
            guard !state.isStopped else {
                return false
            }
            inFlightOffers.enter()
            return true
        }
        guard shouldOffer else {
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
            failureHandler(
                .backendFailure(
                    driverID: driverID,
                    deviceID: deviceID,
                    operation: .streaming,
                    code: error.code
                )
            )
            terminalHandler()
        }
    }

    func shutdown() {
        _ = stopDelivery()
        // CaptureSampleSink is contractually nonblocking. Waiting here closes
        // the explicit shutdown boundary without retaining queued frame leases.
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
