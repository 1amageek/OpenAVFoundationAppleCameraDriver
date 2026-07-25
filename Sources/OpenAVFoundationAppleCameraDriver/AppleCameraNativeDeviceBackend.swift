@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import OpenAVFoundationDriver

actor AppleCameraNativeDeviceBackend:
  AppleCameraDeviceBackend,
  AppleCameraStreamRuntime
{
  private struct Graph {
    let session: AVFoundation.AVCaptureSession
    let input: AVFoundation.AVCaptureDeviceInput
    var format: CaptureDeviceFormatDescriptor
    var frameRate: Double?
    var controls: CaptureDeviceControls
    var output: AVFoundation.AVCaptureVideoDataOutput?
    var callbackQueue: DispatchQueue?
    var delegate: AppleVideoSampleDelegate?
    var delivery: AppleSampleBufferDelivery?
    var eventRelay: AppleCameraStreamEventRelay?
    var eventMonitor: AppleCameraSessionEventMonitor?
    var streamID: UInt64?
    var isRunning = false
  }

  private let driverID: CaptureDriverID
  private let deviceID: CaptureDeviceID
  private let device: AVFoundation.AVCaptureDevice
  private let restoreAutoFrameRate: Bool
  private let originalFormat: AVFoundation.AVCaptureDevice.Format
  private let originalControls: CaptureDeviceControls

  private var graph: Graph?
  private var streamIDs = AppleCameraStreamIDSequence()
  private var lifecycle = AppleCameraBackendLifecycle()

  init(
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID,
    device: AVFoundation.AVCaptureDevice
  ) throws(CaptureContractError) {
    self.driverID = driverID
    self.deviceID = deviceID
    self.device = device
    originalFormat = device.activeFormat
    originalControls =
      try AppleCameraControlCapabilitiesFactory.currentConfiguration(
        for: device
      )
    if #available(macOS 15.0, *) {
      restoreAutoFrameRate = device.isAutoVideoFrameRateEnabled
    } else {
      restoreAutoFrameRate = false
    }
  }

  func requireAvailable() throws(CaptureDriverError) {
    try lifecycle.requireAvailable(
      driverID: driverID,
      deviceID: deviceID
    )
    guard device.isConnected else {
      throw .deviceDisconnected(deviceID)
    }
    guard !device.isSuspended else {
      throw .deviceSuspended(deviceID)
    }
  }

  func configure(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) throws(CaptureDriverError) {
    try requireAvailable()
    guard graph?.streamID == nil else {
      throw .deviceBusy(deviceID)
    }
    try validate(frameRate: frameRate, for: format)
    try validateTargetConfiguration(
      format: format,
      frameRate: frameRate,
      controls: controls
    )

    if graph == nil {
      graph = try makeGraph(
        format: format,
        frameRate: frameRate,
        controls: controls
      )
      return
    }

    guard var existingGraph = graph else {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: 1
      )
    }
    let previousFormat = existingGraph.format
    let previousFrameRate = existingGraph.frameRate
    let previousControls = existingGraph.controls
    do {
      try apply(
        format: format,
        frameRate: frameRate,
        controls: controls,
        input: existingGraph.input,
        session: existingGraph.session
      )
      try validateNativeConfiguration(
        format: format,
        frameRate: frameRate,
        controls: controls
      )
    } catch {
      do {
        try apply(
          format: previousFormat,
          frameRate: previousFrameRate,
          controls: previousControls,
          input: existingGraph.input,
          session: existingGraph.session
        )
        try validateNativeConfiguration(
          format: previousFormat,
          frameRate: previousFrameRate,
          controls: previousControls
        )
      } catch {
        lifecycle.invalidateAfterConfigurationRollback()
        throw .backendFailure(
          driverID: driverID,
          deviceID: deviceID,
          operation: .configuration,
          code: 2
        )
      }
      throw error
    }
    existingGraph.format = format
    existingGraph.frameRate = frameRate
    existingGraph.controls = controls
    graph = existingGraph
  }

  func stream(
    format: CaptureDeviceFormatDescriptor,
    streamID descriptorStreamID: CaptureStreamID,
    connectionConfiguration: CaptureVideoConnectionConfiguration,
    sink: any CaptureSampleSink,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void
  ) throws(CaptureDriverError) -> any CaptureStream {
    try requireAvailable()
    guard var existingGraph = graph else {
      throw .unsupportedConfiguration(deviceID)
    }
    guard existingGraph.streamID == nil else {
      throw .deviceBusy(deviceID)
    }
    guard existingGraph.format == format else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    guard let dimensions = format.dimensions else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    try validateNativeConfiguration(
      format: format,
      frameRate: existingGraph.frameRate,
      controls: existingGraph.controls
    )

    let output = AVFoundation.AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    let pixelFormat = OSType(format.mediaSubtype.rawValue)
    guard output.availableVideoPixelFormatTypes.contains(pixelFormat) else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
      kCVPixelBufferWidthKey as String: dimensions.width,
      kCVPixelBufferHeightKey as String: dimensions.height,
    ]

    let bridge: AppleSampleBufferBridge
    do {
      bridge = try AppleSampleBufferBridge(format: format)
    } catch {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .configuration,
        code: error.code
      )
    }

    let runtimeStreamID = try streamIDs.next(
      driverID: driverID,
      deviceID: deviceID
    )
    let eventRelay = AppleCameraStreamEventRelay(
      deviceID: deviceID,
      terminalHandler: { [weak self] in
        Task {
          await self?.requestStop(
            streamID: runtimeStreamID,
            failureHandler: failureHandler
          )
        }
      }
    )
    let delivery = AppleSampleBufferDelivery(
      driverID: driverID,
      deviceID: deviceID,
      bridge: bridge,
      sink: sink,
      failureHandler: failureHandler,
      terminalHandler: {
        eventRelay.requestStop()
      },
      failureEventHandler: { failure in
        eventRelay.offer(.failed(failure))
      }
    )
    let delegate = AppleVideoSampleDelegate(
      delivery: delivery,
      eventRelay: eventRelay
    )
    let callbackQueue = DispatchQueue(
      label: "openavfoundation.apple-camera.samples"
    )

    existingGraph.session.beginConfiguration()
    guard existingGraph.session.canAddOutput(output) else {
      existingGraph.session.commitConfiguration()
      throw .unsupportedConfiguration(deviceID)
    }
    existingGraph.session.addOutput(output)
    existingGraph.session.commitConfiguration()

    do {
      guard output.availableVideoPixelFormatTypes.contains(pixelFormat)
      else {
        throw CaptureDriverError.unsupportedFormat(
          deviceID: deviceID,
          formatID: format.formatID
        )
      }
      guard let connection = output.connection(with: .video) else {
        throw CaptureDriverError.unsupportedConfiguration(deviceID)
      }
      try AppleCameraVideoConnectionBridge.apply(
        connectionConfiguration,
        to: connection,
        deviceID: deviceID,
        streamID: descriptorStreamID
      )
      try validateNativeConfiguration(
        format: format,
        frameRate: existingGraph.frameRate,
        controls: existingGraph.controls
      )
      // Session topology changes may clear the device's locked duration.
      // Reapply the configured duration only after the final graph exists.
      try apply(
        format: format,
        frameRate: existingGraph.frameRate,
        controls: existingGraph.controls,
        input: existingGraph.input,
        session: existingGraph.session
      )
      try validateNativeConfiguration(
        format: format,
        frameRate: existingGraph.frameRate,
        controls: existingGraph.controls
      )
      try AppleCameraVideoConnectionBridge.validate(
        connectionConfiguration,
        on: connection,
        deviceID: deviceID,
        streamID: descriptorStreamID
      )
    } catch {
      let configurationError: CaptureDriverError
      if let driverError = error as? CaptureDriverError {
        configurationError = driverError
      } else {
        configurationError = .backendFailure(
          driverID: driverID,
          deviceID: deviceID,
          operation: .configuration,
          code: Int64((error as NSError).code)
        )
      }
      existingGraph.session.beginConfiguration()
      existingGraph.session.removeOutput(output)
      existingGraph.session.commitConfiguration()

      do {
        try validateNativeConfiguration(
          format: format,
          frameRate: existingGraph.frameRate,
          controls: existingGraph.controls
        )
        try apply(
          format: format,
          frameRate: existingGraph.frameRate,
          controls: existingGraph.controls,
          input: existingGraph.input,
          session: existingGraph.session
        )
        try validateNativeConfiguration(
          format: format,
          frameRate: existingGraph.frameRate,
          controls: existingGraph.controls
        )
      } catch {
        lifecycle.invalidateAfterTopologyRollback()
        throw .backendFailure(
          driverID: driverID,
          deviceID: deviceID,
          operation: .configuration,
          code: 3
        )
      }
      throw configurationError
    }

    output.setSampleBufferDelegate(
      delegate,
      queue: callbackQueue
    )
    let eventMonitor = AppleCameraSessionEventMonitor(
      driverID: driverID,
      deviceID: deviceID,
      session: existingGraph.session,
      relay: eventRelay
    )

    existingGraph.output = output
    existingGraph.callbackQueue = callbackQueue
    existingGraph.delegate = delegate
    existingGraph.delivery = delivery
    existingGraph.eventRelay = eventRelay
    existingGraph.eventMonitor = eventMonitor
    existingGraph.streamID = runtimeStreamID
    existingGraph.isRunning = false
    graph = existingGraph

    return AppleCameraStream(
      deviceID: deviceID,
      streamID: runtimeStreamID,
      runtime: self,
      eventRelay: eventRelay
    )
  }

  func startStream(
    identifiedBy streamID: UInt64
  ) throws(CaptureDriverError) {
    try requireAvailable()
    guard var existingGraph = graph,
      existingGraph.streamID == streamID
    else {
      throw .deviceDisconnected(deviceID)
    }
    guard !existingGraph.isRunning else {
      return
    }

    existingGraph.session.startRunning()
    guard existingGraph.session.isRunning else {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .start,
        code: 1
      )
    }
    existingGraph.isRunning = true
    graph = existingGraph
  }

  func shutdownStream(
    identifiedBy streamID: UInt64
  ) throws(CaptureDriverError) {
    guard let existingGraph = graph else {
      return
    }
    guard existingGraph.streamID == streamID else {
      return
    }
    stopStream(existingGraph)
  }

  func shutdown() throws(CaptureDriverError) {
    guard !lifecycle.isShutdown else {
      return
    }

    var resetError: CaptureDriverError?
    if let existingGraph = graph {
      if existingGraph.streamID != nil {
        stopStream(existingGraph)
      }
      do {
        try applyNative(
          nativeFormat: originalFormat,
          frameRate: nil,
          controls: originalControls,
          formatID: existingGraph.format.formatID,
          input: existingGraph.input,
          session: existingGraph.session
        )
      } catch {
        resetError = error
      }
    }

    if let resetError {
      throw resetError
    }
    graph = nil
    lifecycle.finishShutdown()
  }

  private func makeGraph(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) throws(CaptureDriverError) -> Graph {
    let input: AVFoundation.AVCaptureDeviceInput
    do {
      input = try AVFoundation.AVCaptureDeviceInput(device: device)
    } catch {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .open,
        code: Int64((error as NSError).code)
      )
    }

    let session = AVFoundation.AVCaptureSession()
    // `.inputPriority` is unavailable on macOS. The default `.high` preset may
    // influence device configuration, so the committed topology is validated
    // below before this graph can be published.
    session.beginConfiguration()
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw .deviceBusy(deviceID)
    }
    session.addInput(input)
    session.commitConfiguration()

    try validateTargetConfiguration(
      format: format,
      frameRate: frameRate,
      controls: controls
    )
    try apply(
      format: format,
      frameRate: frameRate,
      controls: controls,
      input: input,
      session: session
    )
    try validateNativeConfiguration(
      format: format,
      frameRate: frameRate,
      controls: controls
    )
    return Graph(
      session: session,
      input: input,
      format: format,
      frameRate: frameRate,
      controls: controls
    )
  }

  private func stopStream(_ existingGraph: Graph) {
    existingGraph.eventRelay?.shutdown()
    existingGraph.delivery?.shutdown()
    existingGraph.output?.setSampleBufferDelegate(nil, queue: nil)
    if existingGraph.isRunning {
      existingGraph.session.stopRunning()
    }
    if let output = existingGraph.output {
      existingGraph.session.beginConfiguration()
      existingGraph.session.removeOutput(output)
      existingGraph.session.commitConfiguration()
    }

    var retainedGraph = existingGraph
    retainedGraph.output = nil
    retainedGraph.callbackQueue = nil
    retainedGraph.delegate = nil
    retainedGraph.delivery = nil
    retainedGraph.eventRelay = nil
    retainedGraph.eventMonitor = nil
    retainedGraph.streamID = nil
    retainedGraph.isRunning = false
    graph = retainedGraph
  }

  private func requestStop(
    streamID: UInt64,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void
  ) {
    do {
      try shutdownStream(identifiedBy: streamID)
    } catch {
      failureHandler(error)
    }
  }

  private func apply(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls,
    input: AVFoundation.AVCaptureDeviceInput,
    session: AVFoundation.AVCaptureSession
  ) throws(CaptureDriverError) {
    let nativeFormat = try AppleCameraSnapshotFactory(
      driverID: driverID
    ).nativeFormat(
      identifiedBy: format.formatID,
      on: device,
      deviceID: deviceID
    )
    try applyNative(
      nativeFormat: nativeFormat,
      frameRate: frameRate,
      controls: controls,
      formatID: format.formatID,
      input: input,
      session: session
    )
  }

  private func applyNative(
    nativeFormat: AVFoundation.AVCaptureDevice.Format,
    frameRate: Double?,
    controls: CaptureDeviceControls,
    formatID: CaptureDeviceFormatID,
    input: AVFoundation.AVCaptureDeviceInput,
    session: AVFoundation.AVCaptureSession
  ) throws(CaptureDriverError) {
    session.beginConfiguration()
    do {
      try AppleCameraDeviceConfigurationBridge.apply(
        format: nativeFormat,
        frameRate: frameRate,
        controls: controls,
        restoreAutoFrameRate: restoreAutoFrameRate,
        formatID: formatID,
        driverID: driverID,
        deviceID: deviceID,
        device: device,
        input: input
      )
      session.commitConfiguration()
    } catch {
      session.commitConfiguration()
      throw error
    }
  }

  private func validateTargetConfiguration(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) throws(CaptureDriverError) {
    let nativeFormat = try AppleCameraSnapshotFactory(
      driverID: driverID
    ).nativeFormat(
      identifiedBy: format.formatID,
      on: device,
      deviceID: deviceID
    )
    try validate(
      frameRate: frameRate,
      for: format
    )
    try validateNativeFormat(nativeFormat, against: format)
    try AppleCameraDeviceConfigurationBridge.validatePortable(
      controls: controls,
      deviceID: deviceID
    )
  }

  private func validate(
    frameRate: Double?,
    for format: CaptureDeviceFormatDescriptor
  ) throws(CaptureDriverError) {
    guard let frameRate else {
      return
    }
    guard AppleCameraSnapshotFactory.supports(
      frameRate: frameRate,
      ranges: format.frameRateRanges
    ) else {
      throw .unsupportedFrameRate(
        deviceID: deviceID,
        formatID: format.formatID,
        frameRate: frameRate
      )
    }
  }

  private func validateActiveFormat(
    _ format: CaptureDeviceFormatDescriptor
  ) throws(CaptureDriverError) {
    guard let dimensions = format.dimensions else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    let nativeDescription = device.activeFormat.formatDescription
    let nativeSubtype = CMFormatDescriptionGetMediaSubType(
      nativeDescription
    )
    let nativeDimensions = CMVideoFormatDescriptionGetDimensions(
      nativeDescription
    )
    guard
      nativeSubtype == OSType(format.mediaSubtype.rawValue),
      Int(nativeDimensions.width) == dimensions.width,
      Int(nativeDimensions.height) == dimensions.height
    else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
  }

  private func validateNativeFormat(
    _ nativeFormat: AVFoundation.AVCaptureDevice.Format,
    against format: CaptureDeviceFormatDescriptor
  ) throws(CaptureDriverError) {
    guard let dimensions = format.dimensions else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    let nativeDescription = nativeFormat.formatDescription
    let nativeSubtype = CMFormatDescriptionGetMediaSubType(
      nativeDescription
    )
    let nativeDimensions = CMVideoFormatDescriptionGetDimensions(
      nativeDescription
    )
    guard
      nativeSubtype == OSType(format.mediaSubtype.rawValue),
      Int(nativeDimensions.width) == dimensions.width,
      Int(nativeDimensions.height) == dimensions.height
    else {
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
  }

  private func validateNativeConfiguration(
    format: CaptureDeviceFormatDescriptor,
    frameRate: Double?,
    controls: CaptureDeviceControls
  ) throws(CaptureDriverError) {
    try validateActiveFormat(format)
    if let frameRate {
      let supported = device.activeFormat.videoSupportedFrameRateRanges
        .contains { range in
          range.minFrameRate <= frameRate
            && frameRate <= range.maxFrameRate
        }
      guard supported else {
        throw .unsupportedFrameRate(
          deviceID: deviceID,
          formatID: format.formatID,
          frameRate: frameRate
        )
      }
    }
    try AppleCameraDeviceConfigurationBridge.validate(
      controls: controls,
      deviceID: deviceID,
      device: device
    )
  }
}
