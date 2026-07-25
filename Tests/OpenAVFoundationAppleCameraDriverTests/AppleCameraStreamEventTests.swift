import AVFoundation
import CoreMedia
import OpenAVFoundationDriver
import OpenCoreMedia
import Synchronization
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera stream events")
struct AppleCameraStreamEventTests {
  @Test("Declared macOS events are ordered and pressure is not advertised")
  func orderedEvents() throws {
    let fixture = try EventFixture()
    let sink = RecordingEventSink()
    try fixture.relay.setSink(sink)
    try fixture.relay.beginStart()

    fixture.relay.offer(.interrupted(.platform(code: 0)))
    fixture.relay.offer(.resumed)
    fixture.relay.offerDrop(
      presentationTimeStamp: OpenCoreMedia.CMTime.zero,
      reason: .frameWasLate
    )

    #expect(
      fixture.relay.capabilities
        == [.interruptions, .sourceDrops, .terminalFailures]
    )
    #expect(!fixture.relay.capabilities.contains(.systemPressure))
    #expect(
      sink.events == [
        .interrupted(.platform(code: 0)),
        .resumed,
        .dropped(
          CaptureStreamDropEvent(
            presentationTimeStamp: OpenCoreMedia.CMTime.zero,
            cumulativeCount: 1,
            reason: .frameWasLate
          )
        ),
      ]
    )
  }

  @Test("A terminal failure is final and requests one shutdown")
  func terminalFailure() throws {
    let stopCount = Mutex(0)
    let fixture = try EventFixture {
      stopCount.withLock { $0 += 1 }
    }
    let sink = RecordingEventSink()
    try fixture.relay.setSink(sink)
    try fixture.relay.beginStart()
    let failure = CaptureDriverError.backendFailure(
      driverID: fixture.deviceID.driverID,
      deviceID: fixture.deviceID,
      operation: .streaming,
      code: 77
    )

    fixture.relay.offer(.failed(failure))
    fixture.relay.offer(.resumed)

    #expect(sink.events == [.failed(failure)])
    #expect(stopCount.withLock { $0 } == 1)
    #expect(
      throws: CaptureDriverError.deviceDisconnected(fixture.deviceID)
    ) {
      try fixture.relay.setSink(sink)
    }
  }

  @Test("A terminal failure without an event sink still requests shutdown")
  func terminalFailureWithoutSink() throws {
    let stopCount = Mutex(0)
    let fixture = try EventFixture {
      stopCount.withLock { $0 += 1 }
    }
    try fixture.relay.beginStart()
    let failure = CaptureDriverError.backendFailure(
      driverID: fixture.deviceID.driverID,
      deviceID: fixture.deviceID,
      operation: .streaming,
      code: 78
    )

    fixture.relay.offer(.failed(failure))
    fixture.relay.offer(.failed(failure))

    #expect(stopCount.withLock { $0 } == 1)
    #expect(
      throws: CaptureDriverError.deviceDisconnected(fixture.deviceID)
    ) {
      try fixture.relay.setSink(RecordingEventSink())
    }
  }

  @Test("A sink stop disposition requests shutdown outside the callback")
  func sinkStop() throws {
    let stopCount = Mutex(0)
    let fixture = try EventFixture {
      stopCount.withLock { $0 += 1 }
    }
    let sink = RecordingEventSink(disposition: .stop)
    try fixture.relay.setSink(sink)
    try fixture.relay.beginStart()

    fixture.relay.offer(.resumed)

    #expect(sink.events == [.resumed])
    #expect(stopCount.withLock { $0 } == 1)
  }

  @Test("Native session notifications map to portable events")
  func sessionNotifications() throws {
    let fixture = try EventFixture()
    let sink = RecordingEventSink()
    try fixture.relay.setSink(sink)
    try fixture.relay.beginStart()
    let center = NotificationCenter()
    let session = AVCaptureSession()
    let monitor = AppleCameraSessionEventMonitor(
      driverID: fixture.deviceID.driverID,
      deviceID: fixture.deviceID,
      session: session,
      relay: fixture.relay,
      notificationCenter: center
    )

    center.post(
      name: AVCaptureSession.wasInterruptedNotification,
      object: session
    )
    center.post(
      name: AVCaptureSession.interruptionEndedNotification,
      object: session
    )
    _ = monitor

    #expect(
      sink.events == [
        .interrupted(.platform(code: 0)),
        .resumed,
      ]
    )
  }

  @Test("Native runtime error maps to one terminal typed failure")
  func runtimeError() throws {
    let fixture = try EventFixture()
    let sink = RecordingEventSink()
    try fixture.relay.setSink(sink)
    try fixture.relay.beginStart()
    let center = NotificationCenter()
    let session = AVCaptureSession()
    let monitor = AppleCameraSessionEventMonitor(
      driverID: fixture.deviceID.driverID,
      deviceID: fixture.deviceID,
      session: session,
      relay: fixture.relay,
      notificationCenter: center
    )
    let nativeError = NSError(
      domain: AVFoundationErrorDomain,
      code: -11_800
    )

    center.post(
      name: AVCaptureSession.runtimeErrorNotification,
      object: session,
      userInfo: [AVCaptureSessionErrorKey: nativeError]
    )
    _ = monitor

    #expect(
      sink.events == [
        .failed(
          .backendFailure(
            driverID: fixture.deviceID.driverID,
            deviceID: fixture.deviceID,
            operation: .streaming,
            code: -11_800
          )
        )
      ]
    )
  }

  @Test("Dropped frame reasons preserve native semantics")
  func droppedFrameReasons() throws {
    let sample = try AppleCameraTestFixtures.sampleBuffer(
      width: 4,
      height: 2,
      pixelFormat: kCVPixelFormatType_32BGRA
    )
    CMSetAttachment(
      sample,
      key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
      value: kCMSampleBufferDroppedFrameReason_OutOfBuffers,
      attachmentMode: kCMAttachmentMode_ShouldNotPropagate
    )

    #expect(
      AppleVideoSampleDelegate.dropReason(from: sample)
        == .outOfBuffers
    )
  }

  @Test("Portable orientation uses supported native rotation angles")
  func rotationAngles() throws {
    #expect(
      AppleCameraVideoConnectionBridge.rotationAngle(
        for: .landscapeRight
      ) == 0
    )
    #expect(
      AppleCameraVideoConnectionBridge.rotationAngle(
        for: .portrait
      ) == 90
    )
    #expect(
      AppleCameraVideoConnectionBridge.rotationAngle(
        for: .landscapeLeft
      ) == 180
    )
    #expect(
      AppleCameraVideoConnectionBridge.rotationAngle(
        for: .portraitUpsideDown
      ) == 270
    )
    #expect(
      try AppleCameraVideoConnectionBridge.capabilities()
        .supportedStabilizationModes.isEmpty
    )
  }
}

private struct EventFixture {
  let deviceID: CaptureDeviceID
  let relay: AppleCameraStreamEventRelay

  init(
    terminalHandler: @escaping @Sendable () -> Void = {}
  ) throws {
    deviceID = try CaptureDeviceID(
      driverID: CaptureDriverID("apple.test.events"),
      localID: "camera"
    )
    relay = AppleCameraStreamEventRelay(
      deviceID: deviceID,
      terminalHandler: terminalHandler
    )
  }
}

final class RecordingEventSink:
  CaptureStreamEventSink,
  Sendable
{
  private let disposition: CaptureStreamEventDisposition
  private let storage = Mutex<[CaptureStreamEvent]>([])

  init(
    disposition: CaptureStreamEventDisposition = .continueStreaming
  ) {
    self.disposition = disposition
  }

  var events: [CaptureStreamEvent] {
    storage.withLock { $0 }
  }

  func offer(
    _ event: CaptureStreamEvent
  ) -> CaptureStreamEventDisposition {
    storage.withLock { $0.append(event) }
    return disposition
  }
}
