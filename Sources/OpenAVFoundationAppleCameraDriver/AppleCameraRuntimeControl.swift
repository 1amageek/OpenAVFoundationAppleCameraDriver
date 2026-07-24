@preconcurrency import AVFoundation
import Dispatch
import OpenAVFoundationDriver
import Synchronization

final class AppleCameraRuntimeControl: Sendable {
    private enum State: Sendable {
        case idle
        case running
        case stopped
    }

    private let driverID: CaptureDriverID
    private let deviceID: CaptureDeviceID
    private let controlQueue: DispatchQueue
    private let state = Mutex(State.idle)

    // These legacy AVFoundation reference types are confined to controlQueue
    // after initialization and never cross the sample callback boundary.
    nonisolated(unsafe) private let session:
        AVFoundation.AVCaptureSession
    nonisolated(unsafe) private let output:
        AVFoundation.AVCaptureVideoDataOutput

    init(
        driverID: CaptureDriverID,
        deviceID: CaptureDeviceID,
        session: AVFoundation.AVCaptureSession,
        output: AVFoundation.AVCaptureVideoDataOutput
    ) {
        self.driverID = driverID
        self.deviceID = deviceID
        self.session = session
        self.output = output
        controlQueue = DispatchQueue(
            label: "openavfoundation.apple-camera.control"
        )
    }

    func start() throws(CaptureDriverError) {
        let result: Result<Void, CaptureDriverError> = controlQueue.sync {
            let currentState = state.withLock { state in
                state
            }
            switch currentState {
            case .running:
                return .success(())
            case .stopped:
                return .failure(.deviceDisconnected(deviceID))
            case .idle:
                break
            }

            session.startRunning()
            guard session.isRunning else {
                return .failure(.backendFailure(
                    driverID: driverID,
                    deviceID: deviceID,
                    operation: .start,
                    code: 1
                ))
            }
            state.withLock { state in
                state = .running
            }
            return .success(())
        }
        try result.get()
    }

    func stop() {
        controlQueue.sync {
            stopOnControlQueue()
        }
    }

    func requestStop() {
        controlQueue.async { [self] in
            stopOnControlQueue()
        }
    }

    private func stopOnControlQueue() {
        let shouldStop = state.withLock { state -> Bool in
            switch state {
            case .idle, .stopped:
                state = .stopped
                return false
            case .running:
                state = .stopped
                return true
            }
        }

        output.setSampleBufferDelegate(nil, queue: nil)
        if shouldStop {
            session.stopRunning()
        }
    }
}
