import Foundation
import OpenAVFoundationDriver
import Synchronization
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera device events")
struct AppleCameraDeviceEventSubscriptionTests {
  @Test("Observation emits one snapshot followed by topology deltas")
  func topologyDeltas() async throws {
    let driverID = try CaptureDriverID("apple.test.camera")
    let initial = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 1
    )
    let updated = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 2
    )
    let connected = try descriptor(
      driverID: driverID,
      localID: "camera-b",
      revision: 1
    )
    let source = DeviceDescriptorSource([initial])
    let sink = DeviceEventSink()
    let subscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: sink,
      failureHandler: { _ in },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try source.snapshot()
      }
    )

    try await subscription.start()
    #expect(sink.events == [.snapshot([initial])])

    source.replace(with: [updated, connected])
    await subscription.refresh()
    #expect(
      sink.events == [
        .snapshot([initial]),
        .updated(updated),
        .connected(connected),
      ]
    )

    source.replace(with: [connected])
    await subscription.refresh()
    #expect(
      sink.events == [
        .snapshot([initial]),
        .updated(updated),
        .connected(connected),
        .disconnected(initial.deviceID),
      ]
    )

    await subscription.shutdown()
    await subscription.shutdown()
  }

  @Test("Native notifications trigger a refreshed snapshot")
  func notificationRefresh() async throws {
    let driverID = try CaptureDriverID("apple.test.notification")
    let initial = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 1
    )
    let connected = try descriptor(
      driverID: driverID,
      localID: "camera-b",
      revision: 1
    )
    let source = DeviceDescriptorSource([initial])
    let sink = DeviceEventSink()
    let center = NotificationCenter()
    let connectedName = Notification.Name(
      "OpenAVFoundationAppleCameraDriverTests.connected"
    )
    let disconnectedName = Notification.Name(
      "OpenAVFoundationAppleCameraDriverTests.disconnected"
    )
    let subscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: sink,
      failureHandler: { _ in },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try source.snapshot()
      },
      notificationCenter: center,
      connectedNotification: connectedName,
      disconnectedNotification: disconnectedName
    )

    try await subscription.start()
    source.replace(with: [initial, connected])
    center.post(name: connectedName, object: nil)

    try await waitForEventCount(2, in: sink)
    #expect(sink.events.last == .connected(connected))

    await subscription.shutdown()
    source.replace(with: [initial])
    center.post(name: disconnectedName, object: nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(sink.events.count == 2)
  }

  @Test("Provider observation uses the injected discovery boundary")
  func providerObservationPath() async throws {
    let driverID = try CaptureDriverID("apple.test.provider")
    let initial = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 1
    )
    let connected = try descriptor(
      driverID: driverID,
      localID: "camera-b",
      revision: 1
    )
    let source = DeviceDescriptorSource([initial])
    let sink = DeviceEventSink()
    let center = NotificationCenter()
    let connectedName = Notification.Name(
      "OpenAVFoundationAppleCameraDriverTests.provider-connected"
    )
    let disconnectedName = Notification.Name(
      "OpenAVFoundationAppleCameraDriverTests.provider-disconnected"
    )
    let provider = AppleCameraProvider(
      driverID: driverID,
      failureHandler: { _ in },
      descriptorSource: {
        (_: CaptureDiscoveryRequest)
          throws(CaptureDriverError) -> [CaptureDeviceDescriptor] in
        try source.snapshot()
      },
      notificationCenter: center,
      connectedNotification: connectedName,
      disconnectedNotification: disconnectedName
    )
    let subscription = try await provider.deviceEventSubscription(
      matching: CaptureDiscoveryRequest(mediaType: .video),
      sink: sink
    )

    try await subscription.start()
    #expect(sink.events == [.snapshot([initial])])

    source.replace(with: [initial, connected])
    center.post(name: connectedName, object: nil)
    try await waitForEventCount(2, in: sink)
    #expect(sink.events.last == .connected(connected))
    try await subscription.shutdown()
  }

  @Test("Sink stop and refresh failure terminate observation")
  func terminalPaths() async throws {
    let driverID = try CaptureDriverID("apple.test.terminal")
    let initial = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 1
    )
    let source = DeviceDescriptorSource([initial])
    let stopSink = DeviceEventSink(stopAfter: 1)
    let stoppedSubscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: stopSink,
      failureHandler: { _ in },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try source.snapshot()
      }
    )

    try await stoppedSubscription.start()
    await #expect(throws: CaptureDriverError.self) {
      try await stoppedSubscription.start()
    }

    let failure = CaptureDriverError.backendFailure(
      driverID: driverID,
      deviceID: nil,
      operation: .observation,
      code: 77
    )
    let failingSource = DeviceDescriptorSource([initial])
    let failureSink = DeviceEventSink()
    let failures = DriverFailureRecorder()
    let failingSubscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: failureSink,
      failureHandler: { error in
        failures.record(error)
      },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try failingSource.snapshot()
      }
    )

    try await failingSubscription.start()
    failingSource.fail(with: failure)
    await failingSubscription.refresh()
    #expect(failures.errors == [failure])
    await #expect(throws: CaptureDriverError.self) {
      try await failingSubscription.start()
    }
  }

  @Test("Duplicate device identifiers terminate observation explicitly")
  func duplicateDeviceIdentifiers() async throws {
    let driverID = try CaptureDriverID("apple.test.duplicates")
    let first = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 1
    )
    let duplicate = try descriptor(
      driverID: driverID,
      localID: "camera-a",
      revision: 2
    )
    let expectedFailure = CaptureDriverError.backendFailure(
      driverID: driverID,
      deviceID: first.deviceID,
      operation: .observation,
      code: 2
    )

    let initialSource = DeviceDescriptorSource([first, duplicate])
    let initialSubscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: DeviceEventSink(),
      failureHandler: { _ in },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try initialSource.snapshot()
      }
    )
    await #expect(throws: expectedFailure) {
      try await initialSubscription.start()
    }

    let refreshSource = DeviceDescriptorSource([first])
    let failures = DriverFailureRecorder()
    let refreshSubscription = AppleCameraDeviceEventSubscription(
      driverID: driverID,
      sink: DeviceEventSink(),
      failureHandler: { error in
        failures.record(error)
      },
      snapshot: { () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor] in
        try refreshSource.snapshot()
      }
    )
    try await refreshSubscription.start()
    refreshSource.replace(with: [first, duplicate])
    await refreshSubscription.refresh()

    #expect(failures.errors == [expectedFailure])
    await #expect(throws: CaptureDriverError.self) {
      try await refreshSubscription.start()
    }
  }

  private func descriptor(
    driverID: CaptureDriverID,
    localID: String,
    revision: UInt64
  ) throws -> CaptureDeviceDescriptor {
    let deviceID = try CaptureDeviceID(
      driverID: driverID,
      localID: localID
    )
    return try CaptureDeviceDescriptor(
      deviceID: deviceID,
      deviceTypeID: try CaptureDeviceTypeID("camera"),
      localizedName: localID,
      manufacturer: "Test",
      modelID: "Test",
      position: .external,
      mediaTypes: [.video],
      capabilityRevision: revision
    )
  }

  private func waitForEventCount(
    _ count: Int,
    in sink: DeviceEventSink
  ) async throws {
    for _ in 0..<100 {
      if sink.events.count >= count {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for device event delivery")
  }
}

private final class DeviceDescriptorSource: Sendable {
  private struct State: Sendable {
    var descriptors: [CaptureDeviceDescriptor]
    var failure: CaptureDriverError?
  }

  private let state: Mutex<State>

  init(_ descriptors: [CaptureDeviceDescriptor]) {
    state = Mutex(State(descriptors: descriptors, failure: nil))
  }

  func snapshot() throws(CaptureDriverError)
    -> [CaptureDeviceDescriptor]
  {
    try state.withLock { state throws(CaptureDriverError) in
      if let failure = state.failure {
        throw failure
      }
      return state.descriptors
    }
  }

  func replace(with descriptors: [CaptureDeviceDescriptor]) {
    state.withLock { state in
      state.descriptors = descriptors
      state.failure = nil
    }
  }

  func fail(with failure: CaptureDriverError) {
    state.withLock { state in
      state.failure = failure
    }
  }
}

private final class DeviceEventSink: CaptureDeviceEventSink {
  private struct State: Sendable {
    var events: [CaptureDeviceEvent] = []
    let stopAfter: Int?
  }

  private let state: Mutex<State>

  init(stopAfter: Int? = nil) {
    state = Mutex(State(stopAfter: stopAfter))
  }

  var events: [CaptureDeviceEvent] {
    state.withLock { state in
      state.events
    }
  }

  func offer(
    _ event: CaptureDeviceEvent
  ) -> CaptureDeviceEventDisposition {
    state.withLock { state in
      state.events.append(event)
      if let stopAfter = state.stopAfter,
        state.events.count >= stopAfter
      {
        return .stop
      }
      return .accepted
    }
  }
}

private final class DriverFailureRecorder: Sendable {
  private let state = Mutex<[CaptureDriverError]>([])

  var errors: [CaptureDriverError] {
    state.withLock { state in
      state
    }
  }

  func record(_ error: CaptureDriverError) {
    state.withLock { state in
      state.append(error)
    }
  }
}
