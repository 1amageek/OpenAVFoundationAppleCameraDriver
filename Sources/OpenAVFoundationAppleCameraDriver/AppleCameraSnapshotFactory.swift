@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import OpenAVFoundationDriver

struct AppleCameraSnapshotFactory: Sendable {
  let driverID: CaptureDriverID

  func snapshot(
    for reference: AppleCaptureDeviceReference
  ) throws(CaptureDriverError) -> CaptureDeviceSnapshot {
    let device = reference.value
    let activeFormat = device.activeFormat
    let formatDescription = activeFormat.formatDescription
    let nativeSubtype = CMFormatDescriptionGetMediaSubType(
      formatDescription
    )
    let nativeDimensions = CMVideoFormatDescriptionGetDimensions(
      formatDescription
    )

    let dimensions: CaptureDimensions
    let deviceID: CaptureDeviceID
    let deviceTypeID: CaptureDeviceTypeID
    do {
      dimensions = try CaptureDimensions(
        width: Int(nativeDimensions.width),
        height: Int(nativeDimensions.height)
      )
      deviceID = try CaptureDeviceID(
        driverID: driverID,
        localID: device.uniqueID
      )
      deviceTypeID = try CaptureDeviceTypeID(
        portableDeviceType(for: device).rawValue
      )
    } catch {
      throw .contractViolation(driverID: driverID, error: error)
    }

    let pixelFormats = Self.supportedPixelFormats(
      nativeSubtype: nativeSubtype
    )
    guard !pixelFormats.isEmpty else {
      throw .unsupportedConfiguration(deviceID)
    }

    let revision = capabilityRevision(
      device: device,
      dimensions: dimensions,
      nativeSubtype: nativeSubtype,
      outputPixelFormats: pixelFormats
    )

    do {
      return try makeSnapshot(
        device: device,
        deviceID: deviceID,
        deviceTypeID: deviceTypeID,
        dimensions: dimensions,
        revision: revision,
        pixelFormats: pixelFormats
      )
    } catch {
      throw .contractViolation(driverID: driverID, error: error)
    }
  }

  private func makeSnapshot(
    device: AVFoundation.AVCaptureDevice,
    deviceID: CaptureDeviceID,
    deviceTypeID: CaptureDeviceTypeID,
    dimensions: CaptureDimensions,
    revision: UInt64,
    pixelFormats: [OSType]
  ) throws(CaptureContractError) -> CaptureDeviceSnapshot {
    let descriptor = try CaptureDeviceDescriptor(
      deviceID: deviceID,
      deviceTypeID: deviceTypeID,
      localizedName: device.localizedName,
      manufacturer: device.manufacturer,
      modelID: device.modelID,
      position: portablePosition(for: device),
      mediaTypes: [.video],
      capabilityRevision: revision,
      isConnected: device.isConnected,
      isSuspended: device.isSuspended
    )
    var formats: [CaptureDeviceFormatDescriptor] = []
    formats.reserveCapacity(pixelFormats.count)
    for pixelFormat in pixelFormats {
      let formatID = try CaptureDeviceFormatID(
        formatName(
          pixelFormat: pixelFormat,
          dimensions: dimensions
        )
      )
      formats.append(
        CaptureDeviceFormatDescriptor(
          formatID: formatID,
          mediaType: .video,
          mediaSubtype: CaptureMediaSubtype(
            rawValue: UInt32(pixelFormat)
          ),
          dimensions: dimensions
        )
      )
    }
    guard let preferredFormatID = formats.first?.formatID else {
      throw CaptureContractError.missingFormats(
        deviceID: deviceID
      )
    }
    let capabilities = try CaptureDeviceCapabilities(
      deviceID: deviceID,
      revision: revision,
      formats: formats,
      preferredFormatID: preferredFormatID,
      supportsConcurrentStreams: false
    )
    return try CaptureDeviceSnapshot(
      descriptor: descriptor,
      capabilities: capabilities
    )
  }

  static func supportedPixelFormats(
    nativeSubtype: OSType
  ) -> [OSType] {
    switch nativeSubtype {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_32BGRA:
      return [nativeSubtype]
    default:
      // FIXME(INCOMPLETE_IMPLEMENTATION): Discovery currently exposes only native
      // NV12 or BGRA formats that the production bridge can route without a
      // payload copy. It must not advertise other formats until an explicit
      // conversion capability and its copy/allocation budget are implemented.
      return []
    }
  }

  private func formatName(
    pixelFormat: OSType,
    dimensions: CaptureDimensions
  ) -> String {
    let prefix: String
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      prefix = "nv12-full"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      prefix = "nv12-video"
    case kCVPixelFormatType_32BGRA:
      prefix = "bgra"
    default:
      prefix = String(pixelFormat)
    }
    return "\(prefix)-\(dimensions.width)x\(dimensions.height)"
  }

  private func portableDeviceType(
    for device: AVFoundation.AVCaptureDevice
  ) -> AVFoundation.AVCaptureDevice.DeviceType {
    switch device.deviceType {
    case .external, .continuityCamera, .deskViewCamera:
      .external
    default:
      .builtInWideAngleCamera
    }
  }

  private func portablePosition(
    for device: AVFoundation.AVCaptureDevice
  ) -> CaptureDevicePosition {
    switch device.deviceType {
    case .external, .continuityCamera, .deskViewCamera:
      return .external
    default:
      break
    }

    switch device.position {
    case .front:
      return .front
    case .back:
      return .back
    case .unspecified:
      return .unspecified
    @unknown default:
      return .unspecified
    }
  }

  private func capabilityRevision(
    device: AVFoundation.AVCaptureDevice,
    dimensions: CaptureDimensions,
    nativeSubtype: FourCharCode,
    outputPixelFormats: [OSType]
  ) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037
    var components = [
      device.uniqueID,
      String(dimensions.width),
      String(dimensions.height),
      String(nativeSubtype),
    ]
    components.append(
      contentsOf: outputPixelFormats.map(String.init)
    )
    let identity = components.joined(separator: "|")
    for byte in identity.utf8 {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return value
  }
}
