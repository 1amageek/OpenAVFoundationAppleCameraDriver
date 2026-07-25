import OpenAVFoundationDriver
import Testing

@testable import OpenAVFoundationAppleCameraDriver

@Suite("Apple camera device handle")
struct AppleCameraDeviceHandleTests {
  @Test("Configure applies the native backend before committing state")
  func configureAppliesBackend() async throws {
    let fixture = try HandleFixture()
    let backend = FakeAppleCameraDeviceBackend()
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let fixedRate = try fixture.configuration(frameRate: 30)

    _ = try await handle.configure(fixedRate)
    #expect(await backend.appliedFrameRates() == [30])

    let automaticRate = try fixture.configuration(frameRate: nil)
    _ = try await handle.configure(automaticRate)
    #expect(await backend.appliedFrameRates() == [30, nil])
  }

  @Test("Unsupported controls fail before reaching the native backend")
  func unsupportedControls() async throws {
    let fixture = try HandleFixture()
    let backend = FakeAppleCameraDeviceBackend()
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let controls = try CaptureDeviceControls(
      zoom: try CaptureZoomConfiguration(factor: 2)
    )
    let configuration = try fixture.configuration(
      frameRate: nil,
      controls: controls
    )

    do {
      _ = try await handle.configure(configuration)
      Issue.record("Unsupported controls must not be accepted")
    } catch let error {
      #expect(
        error == .unsupportedControl(
          deviceID: fixture.deviceID,
          controlID: .zoom
        )
      )
    }
    #expect(await backend.appliedFrameRates().isEmpty)
  }

  @Test("A backend failure does not commit a configuration")
  func failedApplyDoesNotCommit() async throws {
    let fixture = try HandleFixture()
    let failure = CaptureDriverError.backendFailure(
      driverID: fixture.driverID,
      deviceID: fixture.deviceID,
      operation: .configuration,
      code: 77
    )
    let backend = FakeAppleCameraDeviceBackend(
      configurationFailure: failure
    )
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let configuration = try fixture.configuration(frameRate: 30)

    await #expect(throws: failure) {
      _ = try await handle.configure(configuration)
    }
    let sink = DiscardingSampleSink()
    await #expect(
      throws: CaptureDriverError.unsupportedConfiguration(
        fixture.deviceID
      )
    ) {
      _ = try await handle.stream(
        for: CaptureStreamRequest(configuration: configuration),
        sink: sink
      )
    }
    #expect(await backend.streamRequestCount() == 0)
  }

  @Test("Stream forwards validated video connection configuration")
  func videoConnectionConfiguration() async throws {
    let fixture = try HandleFixture()
    let backend = FakeAppleCameraDeviceBackend()
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let configuration = try fixture.configuration(frameRate: 30)
    _ = try await handle.configure(configuration)
    let connectionConfiguration =
      CaptureVideoConnectionConfiguration(
        orientation: .portrait,
        mirroringMode: .disabled
      )

    _ = try await handle.stream(
      for: CaptureStreamRequest(
        configuration: configuration,
        videoConnectionConfiguration: connectionConfiguration
      ),
      sink: DiscardingSampleSink()
    )

    #expect(
      await backend.appliedConnectionConfigurations()
        == [connectionConfiguration]
    )
  }

  @Test("Unsupported macOS stabilization fails before the backend")
  func unsupportedStabilization() async throws {
    let fixture = try HandleFixture()
    let backend = FakeAppleCameraDeviceBackend()
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let configuration = try fixture.configuration(frameRate: 30)
    _ = try await handle.configure(configuration)
    let streamID = try #require(
      fixture.snapshot.capabilities.streams.first?.streamID
    )
    let request = CaptureStreamRequest(
      streamID: streamID,
      configuration: configuration,
      videoConnectionConfiguration:
        CaptureVideoConnectionConfiguration(
          stabilizationMode: .standard
        )
    )

    await #expect(
      throws: CaptureDriverError.unsupportedVideoStabilizationMode(
        deviceID: fixture.deviceID,
        streamID: streamID,
        mode: .standard
      )
    ) {
      _ = try await handle.stream(
        for: request,
        sink: DiscardingSampleSink()
      )
    }
    #expect(await backend.appliedConnectionConfigurations().isEmpty)
  }

  @Test(
    "Concurrent handle operations fail busy while backend work is suspended",
    .timeLimit(.minutes(1))
  )
  func concurrentOperationsFailBusy() async throws {
    let fixture = try HandleFixture()
    let backend = SuspendedConfigurationBackend(
      deviceID: fixture.deviceID
    )
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )
    let configuration = try fixture.configuration(frameRate: 30)
    let firstConfiguration = Task {
      try await handle.configure(configuration)
    }

    while !(await backend.hasEnteredConfiguration()) {
      await Task.yield()
    }

    await #expect(
      throws: CaptureDriverError.deviceBusy(fixture.deviceID)
    ) {
      _ = try await handle.configure(configuration)
    }
    await #expect(
      throws: CaptureDriverError.deviceBusy(fixture.deviceID)
    ) {
      try await handle.shutdown()
    }

    await backend.resumeConfiguration()
    _ = try await firstConfiguration.value
    try await handle.shutdown()
  }

  @Test(
    "Concurrent stream operations fail busy across runtime suspension",
    .timeLimit(.minutes(1))
  )
  func concurrentStreamOperationsFailBusy() async throws {
    let fixture = try HandleFixture()
    let runtime = SuspendedStreamRuntime()
    let stream = AppleCameraStream(
      deviceID: fixture.deviceID,
      streamID: 41,
      runtime: runtime,
      eventRelay: AppleCameraStreamEventRelay(
        deviceID: fixture.deviceID,
        terminalHandler: {}
      )
    )
    let firstStart = Task {
      try await stream.start()
    }

    while !(await runtime.hasEnteredStart()) {
      await Task.yield()
    }

    await #expect(
      throws: CaptureDriverError.deviceBusy(fixture.deviceID)
    ) {
      try await stream.start()
    }
    await #expect(
      throws: CaptureDriverError.deviceBusy(fixture.deviceID)
    ) {
      try await stream.shutdown()
    }

    await runtime.resumeStart()
    try await firstStart.value
    try await stream.start()
    #expect(await runtime.startInvocationCount() == 1)

    try await stream.shutdown()
    try await stream.shutdown()
    #expect(await runtime.shutdownInvocationCount() == 1)
  }

  @Test("Handle remains terminal after native shutdown failure")
  func handleShutdownFailureIsTerminal() async throws {
    let fixture = try HandleFixture()
    let failure = CaptureDriverError.backendFailure(
      driverID: fixture.driverID,
      deviceID: fixture.deviceID,
      operation: .shutdown,
      code: 81
    )
    let backend = FakeAppleCameraDeviceBackend(
      shutdownFailure: failure
    )
    let handle = AppleCameraDeviceHandle(
      snapshot: fixture.snapshot,
      backend: backend,
      failureHandler: { _ in }
    )

    await #expect(throws: failure) {
      try await handle.shutdown()
    }
    await #expect(
      throws: CaptureDriverError.deviceDisconnected(fixture.deviceID)
    ) {
      _ = try await handle.snapshot()
    }
    try await handle.shutdown()
    #expect(await backend.shutdownInvocationCount() == 1)
  }

  @Test("Stream remains terminal after native shutdown failure")
  func streamShutdownFailureIsTerminal() async throws {
    let fixture = try HandleFixture()
    let failure = CaptureDriverError.backendFailure(
      driverID: fixture.driverID,
      deviceID: fixture.deviceID,
      operation: .shutdown,
      code: 82
    )
    let runtime = SuspendedStreamRuntime(
      suspendsStart: false,
      shutdownFailure: failure
    )
    let stream = AppleCameraStream(
      deviceID: fixture.deviceID,
      streamID: 42,
      runtime: runtime,
      eventRelay: AppleCameraStreamEventRelay(
        deviceID: fixture.deviceID,
        terminalHandler: {}
      )
    )

    await #expect(throws: failure) {
      try await stream.shutdown()
    }
    await #expect(
      throws: CaptureDriverError.deviceDisconnected(fixture.deviceID)
    ) {
      try await stream.start()
    }
    try await stream.shutdown()
    #expect(await runtime.shutdownInvocationCount() == 1)
  }
}

private struct HandleFixture {
  let driverID: CaptureDriverID
  let deviceID: CaptureDeviceID
  let formatID: CaptureDeviceFormatID
  let snapshot: CaptureDeviceSnapshot

  init() throws {
    driverID = try CaptureDriverID("apple.test.handle")
    deviceID = try CaptureDeviceID(
      driverID: driverID,
      localID: "camera"
    )
    formatID = try CaptureDeviceFormatID("nv12-1920x1080")
    let format = CaptureDeviceFormatDescriptor(
      formatID: formatID,
      mediaType: .video,
      mediaSubtype: CaptureMediaSubtype(rawValue: 875_704_438),
      dimensions: try CaptureDimensions(width: 1_920, height: 1_080),
      frameRateRanges: [
        try CaptureFrameRateRange(minimum: 24, maximum: 60)
      ]
    )
    let descriptor = try CaptureDeviceDescriptor(
      deviceID: deviceID,
      deviceTypeID: try CaptureDeviceTypeID("camera"),
      localizedName: "Camera",
      manufacturer: "Test",
      modelID: "Test",
      position: .external,
      mediaTypes: [.video],
      capabilityRevision: 1
    )
    let streamID = try CaptureStreamID("video")
    let stream = try CaptureStreamDescriptor(
      streamID: streamID,
      mediaType: .video,
      formatIDs: [formatID],
      eventCapabilities: [
        .interruptions,
        .sourceDrops,
        .terminalFailures,
      ],
      videoConnectionCapabilities:
        try AppleCameraVideoConnectionBridge.capabilities()
    )
    let capabilities = try CaptureDeviceCapabilities(
      deviceID: deviceID,
      revision: 1,
      formats: [format],
      preferredFormatID: formatID,
      supportsConcurrentStreams: false,
      streams: [stream],
      supportedStreamCombinations: [
        try CaptureStreamCombination(streamIDs: [streamID])
      ]
    )
    snapshot = try CaptureDeviceSnapshot(
      descriptor: descriptor,
      capabilities: capabilities
    )
  }

  func configuration(
    frameRate: Double?,
    controls: CaptureDeviceControls = .none
  ) throws -> CaptureDeviceConfiguration {
    try CaptureDeviceConfiguration(
      deviceID: deviceID,
      capabilityRevision: snapshot.capabilities.revision,
      formatID: formatID,
      frameRate: frameRate,
      controls: controls
    )
  }
}

private actor FakeAppleCameraDeviceBackend:
  AppleCameraDeviceBackend,
  AppleCameraStreamRuntime
{
  private var frameRates: [Double?] = []
  private var connectionConfigurations:
    [CaptureVideoConnectionConfiguration] = []
  private var streams = 0
  private var shutdowns = 0
  private let configurationFailure: CaptureDriverError?
  private let shutdownFailure: CaptureDriverError?

  init(
    configurationFailure: CaptureDriverError? = nil,
    shutdownFailure: CaptureDriverError? = nil
  ) {
    self.configurationFailure = configurationFailure
    self.shutdownFailure = shutdownFailure
  }

  func requireAvailable() {}

  func configure(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) throws(CaptureDriverError) {
    if let configurationFailure {
      throw configurationFailure
    }
    frameRates.append(frameRate)
  }

  func stream(
    format: CaptureDeviceFormatDescriptor,
    streamID: CaptureStreamID,
    connectionConfiguration: CaptureVideoConnectionConfiguration,
    sink: any CaptureSampleSink,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void
  ) -> any CaptureStream {
    streams += 1
    connectionConfigurations.append(connectionConfiguration)
    return FakeAppleCameraStream(
      deviceID: formatIDDeviceIDFallback(format),
      runtime: self
    )
  }

  func shutdown() throws(CaptureDriverError) {
    shutdowns += 1
    if let shutdownFailure {
      throw shutdownFailure
    }
  }

  func startStream(
    identifiedBy streamID: UInt64
  ) {}

  func shutdownStream(
    identifiedBy streamID: UInt64
  ) {}

  func appliedFrameRates() -> [Double?] {
    frameRates
  }

  func streamRequestCount() -> Int {
    streams
  }

  func appliedConnectionConfigurations()
    -> [CaptureVideoConnectionConfiguration]
  {
    connectionConfigurations
  }

  func shutdownInvocationCount() -> Int {
    shutdowns
  }

  private func formatIDDeviceIDFallback(
    _ format: CaptureDeviceFormatDescriptor
  ) -> CaptureDeviceID {
    // The fake stream is not reached by the failure-path tests. Its identity is
    // constructed once so the backend still satisfies the complete contract.
    do {
      let driverID = try CaptureDriverID("apple.test.fake-stream")
      return try CaptureDeviceID(
        driverID: driverID,
        localID: format.formatID.rawValue
      )
    } catch {
      preconditionFailure("Static test identifiers must remain valid")
    }
  }
}

private actor FakeAppleCameraStream: CaptureStream {
  nonisolated let deviceID: CaptureDeviceID
  private let runtime: any AppleCameraStreamRuntime

  init(
    deviceID: CaptureDeviceID,
    runtime: any AppleCameraStreamRuntime
  ) {
    self.deviceID = deviceID
    self.runtime = runtime
  }

  func start() async throws(CaptureDriverError) {
    try await runtime.startStream(identifiedBy: 1)
  }

  func shutdown() async throws(CaptureDriverError) {
    try await runtime.shutdownStream(identifiedBy: 1)
  }
}

private actor SuspendedConfigurationBackend:
  AppleCameraDeviceBackend
{
  private let deviceID: CaptureDeviceID
  private var configurationContinuation:
    CheckedContinuation<Void, Never>?
  private var enteredConfiguration = false
  private var isShutdown = false

  init(deviceID: CaptureDeviceID) {
    self.deviceID = deviceID
  }

  func requireAvailable() throws(CaptureDriverError) {
    guard !isShutdown else {
      throw .deviceDisconnected(deviceID)
    }
  }

  func configure(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) async {
    enteredConfiguration = true
    await withCheckedContinuation { continuation in
      configurationContinuation = continuation
    }
  }

  func stream(
    format: CaptureDeviceFormatDescriptor,
    streamID: CaptureStreamID,
    connectionConfiguration: CaptureVideoConnectionConfiguration,
    sink: any CaptureSampleSink,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void
  ) throws(CaptureDriverError) -> any CaptureStream {
    throw .unsupportedConfiguration(deviceID)
  }

  func shutdown() {
    isShutdown = true
  }

  func hasEnteredConfiguration() -> Bool {
    enteredConfiguration
  }

  func resumeConfiguration() {
    configurationContinuation?.resume()
    configurationContinuation = nil
  }
}

private actor SuspendedStreamRuntime: AppleCameraStreamRuntime {
  private let suspendsStart: Bool
  private let shutdownFailure: CaptureDriverError?
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var enteredStart = false
  private var startCount = 0
  private var shutdownCount = 0

  init(
    suspendsStart: Bool = true,
    shutdownFailure: CaptureDriverError? = nil
  ) {
    self.suspendsStart = suspendsStart
    self.shutdownFailure = shutdownFailure
  }

  func startStream(
    identifiedBy streamID: UInt64
  ) async {
    startCount += 1
    enteredStart = true
    guard suspendsStart else {
      return
    }
    await withCheckedContinuation { continuation in
      startContinuation = continuation
    }
  }

  func shutdownStream(
    identifiedBy streamID: UInt64
  ) throws(CaptureDriverError) {
    shutdownCount += 1
    if let shutdownFailure {
      throw shutdownFailure
    }
  }

  func hasEnteredStart() -> Bool {
    enteredStart
  }

  func resumeStart() {
    startContinuation?.resume()
    startContinuation = nil
  }

  func startInvocationCount() -> Int {
    startCount
  }

  func shutdownInvocationCount() -> Int {
    shutdownCount
  }
}

private final class DiscardingSampleSink: CaptureSampleSink {
  func offer(
    _ sampleBuffer: any CMSampleBuffer
  ) -> CaptureSampleDisposition {
    .accepted
  }
}
