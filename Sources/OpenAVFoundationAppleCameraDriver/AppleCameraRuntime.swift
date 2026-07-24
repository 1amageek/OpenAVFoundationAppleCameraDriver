@preconcurrency import AVFoundation
import CoreVideo
import Dispatch
import Foundation
import OpenAVFoundationDriver

final class AppleCameraRuntime: Sendable {
  private let control: AppleCameraRuntimeControl
  private let callbackQueue: DispatchQueue
  private let delivery: AppleSampleBufferDelivery
  nonisolated(unsafe) private let delegate: AppleVideoSampleDelegate

  init(
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID,
    format: CaptureDeviceFormatDescriptor,
    device: AppleCaptureDeviceReference,
    sink: any CaptureSampleSink,
    failureHandler:
      @escaping @Sendable (CaptureDriverError) -> Void
  ) throws(CaptureDriverError) {
    callbackQueue = DispatchQueue(
      label: "openavfoundation.apple-camera.samples"
    )

    let session = AVFoundation.AVCaptureSession()
    let output = AVFoundation.AVCaptureVideoDataOutput()
    let input: AVFoundation.AVCaptureDeviceInput
    do {
      input = try AVFoundation.AVCaptureDeviceInput(
        device: device.value
      )
    } catch {
      throw .backendFailure(
        driverID: driverID,
        deviceID: deviceID,
        operation: .open,
        code: Int64((error as NSError).code)
      )
    }

    session.beginConfiguration()
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw .deviceBusy(deviceID)
    }
    session.addInput(input)

    output.alwaysDiscardsLateVideoFrames = true
    guard let dimensions = format.dimensions else {
      session.commitConfiguration()
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    let pixelFormat = OSType(format.mediaSubtype.rawValue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw .unsupportedConfiguration(deviceID)
    }
    session.addOutput(output)

    guard
      output.availableVideoPixelFormatTypes.contains(
        pixelFormat
      )
    else {
      session.commitConfiguration()
      throw .unsupportedFormat(
        deviceID: deviceID,
        formatID: format.formatID
      )
    }
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        Int(pixelFormat),
      kCVPixelBufferWidthKey as String: dimensions.width,
      kCVPixelBufferHeightKey as String: dimensions.height,
    ]
    session.commitConfiguration()

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
    let control = AppleCameraRuntimeControl(
      driverID: driverID,
      deviceID: deviceID,
      session: session,
      output: output
    )
    let delivery = AppleSampleBufferDelivery(
      driverID: driverID,
      deviceID: deviceID,
      bridge: bridge,
      sink: sink,
      failureHandler: failureHandler,
      terminalHandler: {
        control.requestStop()
      }
    )
    let delegate = AppleVideoSampleDelegate(delivery: delivery)
    output.setSampleBufferDelegate(
      delegate,
      queue: callbackQueue
    )

    self.control = control
    self.delivery = delivery
    self.delegate = delegate
  }

  func start() throws(CaptureDriverError) {
    try control.start()
  }

  func stop() throws(CaptureDriverError) {
    delivery.shutdown()
    control.stop()
  }
}
