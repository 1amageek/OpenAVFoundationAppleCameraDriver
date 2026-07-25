@testable import OpenAVFoundationAppleCameraDriver
import Dispatch
import OpenAVFoundationDriver
import OpenCoreMedia
import Synchronization
import Testing

@Suite("Apple sample delivery")
struct AppleSampleBufferDeliveryTests {
    @Test("Sink stop closes delivery and requests native termination once")
    func sinkStop() throws {
        let sink = SampleSinkProbe(disposition: .stop)
        let terminal = InvocationProbe()
        let failure = FailureProbe()
        let delivery = try makeDelivery(
            sink: sink,
            terminal: terminal,
            failure: failure
        )
        let sample = try AppleCameraTestFixtures.sampleBuffer(
            width: 4,
            height: 2
        )

        delivery.offer(sample)
        delivery.offer(sample)

        #expect(sink.invocationCount == 1)
        #expect(terminal.invocationCount == 1)
        #expect(failure.invocationCount == 0)
    }

    @Test("Explicit shutdown prevents queued sample delivery")
    func explicitShutdown() throws {
        let sink = SampleSinkProbe(disposition: .accepted)
        let terminal = InvocationProbe()
        let failure = FailureProbe()
        let delivery = try makeDelivery(
            sink: sink,
            terminal: terminal,
            failure: failure
        )

        delivery.shutdown()
        delivery.offer(
            try AppleCameraTestFixtures.sampleBuffer(
                width: 4,
                height: 2
            )
        )

        #expect(sink.invocationCount == 0)
        #expect(terminal.invocationCount == 0)
        #expect(failure.invocationCount == 0)
    }

    @Test("Bridge failure closes delivery before reporting failure")
    func bridgeFailure() throws {
        let sink = SampleSinkProbe(disposition: .accepted)
        let terminal = InvocationProbe()
        let failure = FailureProbe()
        let driverID = try CaptureDriverID(
            "apple.avfoundation.camera"
        )
        let deviceID = try CaptureDeviceID(
            driverID: driverID,
            localID: "test-camera"
        )
        let eventSink = RecordingEventSink()
        let relay = AppleCameraStreamEventRelay(
            deviceID: deviceID,
            terminalHandler: {
                terminal.record()
            }
        )
        try relay.setSink(eventSink)
        try relay.beginStart()
        let delivery = AppleSampleBufferDelivery(
            driverID: driverID,
            deviceID: deviceID,
            bridge: try AppleSampleBufferBridge(
                format: AppleCameraTestFixtures.format(
                    width: 4,
                    height: 2
                )
            ),
            sink: sink,
            failureHandler: { error in
                failure.record(error)
            },
            terminalHandler: {
                relay.requestStop()
            },
            failureEventHandler: { error in
                relay.offer(.failed(error))
            }
        )

        delivery.offer(
            try AppleCameraTestFixtures.sampleBuffer(
                width: 2,
                height: 2
            )
        )

        #expect(sink.invocationCount == 0)
        #expect(terminal.invocationCount == 1)
        #expect(failure.invocationCount == 1)
        #expect(eventSink.events.count == 1)
        guard case .failed = eventSink.events[0] else {
            Issue.record("Bridge failure did not emit a terminal event")
            return
        }
    }

    @Test("Shutdown waits for the accepted in-flight offer")
    func inFlightShutdown() async throws {
        let sink = BlockingSampleSinkProbe()
        let terminal = InvocationProbe()
        let failure = FailureProbe()
        let driverID = try CaptureDriverID(
            "apple.avfoundation.camera"
        )
        let deviceID = try CaptureDeviceID(
            driverID: driverID,
            localID: "test-camera"
        )
        let delivery = AppleSampleBufferDelivery(
            driverID: driverID,
            deviceID: deviceID,
            bridge: try AppleSampleBufferBridge(
                format: AppleCameraTestFixtures.format(
                    width: 4,
                    height: 2
                )
            ),
            sink: sink,
            failureHandler: { error in
                failure.record(error)
            },
            terminalHandler: {
                terminal.record()
            }
        )
        let sample = try AppleCameraTestFixtures.sampleBuffer(
            width: 4,
            height: 2
        )
        let shutdownFinished = InvocationProbe()

        let offerTask = Task {
            delivery.offer(sample)
        }
        await sink.started.wait()
        let shutdownTask = Task {
            delivery.shutdown()
            shutdownFinished.record()
        }
        await Task.yield()
        #expect(shutdownFinished.invocationCount == 0)

        sink.proceed.signal()
        await offerTask.value
        await shutdownTask.value

        #expect(shutdownFinished.invocationCount == 1)
        #expect(failure.invocationCount == 0)
        #expect(terminal.invocationCount == 0)
    }

    private func makeDelivery(
        sink: SampleSinkProbe,
        terminal: InvocationProbe,
        failure: FailureProbe
    ) throws -> AppleSampleBufferDelivery {
        let driverID = try CaptureDriverID(
            "apple.avfoundation.camera"
        )
        let deviceID = try CaptureDeviceID(
            driverID: driverID,
            localID: "test-camera"
        )
        return AppleSampleBufferDelivery(
            driverID: driverID,
            deviceID: deviceID,
            bridge: try AppleSampleBufferBridge(
                format: AppleCameraTestFixtures.format(
                    width: 4,
                    height: 2
                )
            ),
            sink: sink,
            failureHandler: { error in
                failure.record(error)
            },
            terminalHandler: {
                terminal.record()
            }
        )
    }
}

private final class SampleSinkProbe: CaptureSampleSink, Sendable {
    private struct State: Sendable {
        var invocationCount = 0
    }

    private let state = Mutex(State())
    private let disposition: CaptureSampleDisposition

    init(disposition: CaptureSampleDisposition) {
        self.disposition = disposition
    }

    var invocationCount: Int {
        state.withLock { state in
            state.invocationCount
        }
    }

    func offer(
        _ sampleBuffer: any OpenCoreMedia.CMSampleBuffer
    ) -> CaptureSampleDisposition {
        state.withLock { state in
            state.invocationCount += 1
        }
        return disposition
    }
}

private final class InvocationProbe: Sendable {
    private let count = Mutex(0)

    var invocationCount: Int {
        count.withLock { count in count }
    }

    func record() {
        count.withLock { count in
            count += 1
        }
    }
}

private final class FailureProbe: Sendable {
    private let count = Mutex(0)

    var invocationCount: Int {
        count.withLock { count in count }
    }

    func record(_ error: CaptureDriverError) {
        count.withLock { count in
            count += 1
        }
    }
}

private final class BlockingSampleSinkProbe:
    CaptureSampleSink,
    Sendable
{
    let started = AsyncSignal()
    let proceed = DispatchSemaphore(value: 0)

    func offer(
        _ sampleBuffer: any OpenCoreMedia.CMSampleBuffer
    ) -> CaptureSampleDisposition {
        started.signal()
        proceed.wait()
        return .accepted
    }
}

private final class AsyncSignal: Sendable {
    private struct State: Sendable {
        var isSignaled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { state in
            state.isSignaled = true
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                guard !state.isSignaled else {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}
