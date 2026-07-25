import OpenAVFoundationDriver
import Synchronization
import Testing

@testable import OpenAVFoundationAppleCameraDriver

#if OPENAVFOUNDATION_LIVE_CAMERA_TEST
private let liveCameraTestsEnabled = true
#else
private let liveCameraTestsEnabled = false
#endif

@Suite("Apple camera live")
struct AppleCameraLiveTests {
  @Test(
    "Native backend applies fixed and automatic frame rates across restart",
    .enabled(if: liveCameraTestsEnabled),
    .timeLimit(.minutes(1))
  )
  func fixedThenAutomaticRestart() async throws {
    let provider = try AppleCameraProvider { error in
      Issue.record("Live provider failure: \(error)")
    }
    var authorization = await provider.authorizationStatus(for: .video)
    if authorization == .notDetermined {
      authorization = try await provider.requestAccess(for: .video)
    }
    try #require(
      authorization == .authorized,
      "The live camera test requires camera authorization"
    )

    let descriptors = try await provider.devices(
      matching: CaptureDiscoveryRequest(mediaType: .video)
    )
    let descriptor = try #require(descriptors.first)
    let handle = try await provider.deviceHandle(
      for: descriptor.deviceID
    )

    do {
      let snapshot = try await handle.snapshot()
      let format = try #require(
        snapshot.capabilities.formats.first { format in
          format.frameRateRanges.contains { range in
            range.minimum <= 30 && 30 <= range.maximum
          }
        },
        "The live camera must advertise a native 30 fps format"
      )
      let fixedConfiguration = try CaptureDeviceConfiguration(
        deviceID: descriptor.deviceID,
        capabilityRevision: snapshot.capabilities.revision,
        formatID: format.formatID,
        frameRate: 30
      )
      let automaticConfiguration = try CaptureDeviceConfiguration(
        deviceID: descriptor.deviceID,
        capabilityRevision: snapshot.capabilities.revision,
        formatID: format.formatID,
        frameRate: nil
      )

      try await verifyStream(
        handle: handle,
        configuration: fixedConfiguration
      )
      try await verifyStream(
        handle: handle,
        configuration: automaticConfiguration
      )
      try await handle.shutdown()
    } catch {
      do {
        try await handle.shutdown()
      } catch {
        Issue.record("Live camera cleanup failed: \(error)")
      }
      throw error
    }
  }

  private func verifyStream(
    handle: any CaptureDeviceHandle,
    configuration: CaptureDeviceConfiguration
  ) async throws {
    _ = try await handle.configure(configuration)
    let sink = LiveCameraSampleSink()
    let stream = try await handle.stream(
      for: CaptureStreamRequest(configuration: configuration),
      sink: sink
    )
    try await stream.start()
    try await waitForSample(sink)
    try await stream.shutdown()
    let stoppedCount = sink.sampleCount
    try await Task.sleep(for: .milliseconds(200))
    #expect(sink.sampleCount == stoppedCount)
  }

  private func waitForSample(
    _ sink: LiveCameraSampleSink
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while sink.sampleCount == 0 && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sink.sampleCount > 0)
  }
}

private final class LiveCameraSampleSink: CaptureSampleSink {
  private let count = Mutex(0)

  var sampleCount: Int {
    count.withLock { count in count }
  }

  func offer(
    _ sampleBuffer: any CMSampleBuffer
  ) -> CaptureSampleDisposition {
    count.withLock { count in count += 1 }
    return .accepted
  }
}
