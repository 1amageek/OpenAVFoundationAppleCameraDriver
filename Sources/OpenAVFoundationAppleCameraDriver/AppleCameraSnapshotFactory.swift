@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import OpenAVFoundationDriver

struct AppleCameraSnapshotFactory: Sendable {
  let driverID: CaptureDriverID

  func snapshot(
    for device: AVFoundation.AVCaptureDevice
  ) throws(CaptureDriverError) -> CaptureDeviceSnapshot {
    let deviceID: CaptureDeviceID
    let deviceTypeID: CaptureDeviceTypeID
    do {
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

    let records = try formatRecords(for: device)
    guard !records.isEmpty else {
      throw .unsupportedConfiguration(deviceID)
    }
    let formats: [CaptureDeviceFormatDescriptor]
    let controls: CaptureDeviceControlCapabilities
    do {
      formats = try Self.formatDescriptors(from: records)
      controls = try AppleCameraControlCapabilitiesFactory.capabilities(
        for: device
      )
    } catch {
      throw .contractViolation(driverID: driverID, error: error)
    }
    guard let preferredFormatIndex = Self.preferredFormatIndex(
      in: records
    ) else {
      throw .unsupportedConfiguration(deviceID)
    }
    let preferredFormatID = formats[preferredFormatIndex].formatID

    let revision = capabilityRevision(
      device: device,
      records: records,
      controls: controls
    )

    do {
      return try makeSnapshot(
        device: device,
        deviceID: deviceID,
        deviceTypeID: deviceTypeID,
        revision: revision,
        formats: formats,
        preferredFormatID: preferredFormatID,
        controls: controls
      )
    } catch {
      throw .contractViolation(driverID: driverID, error: error)
    }
  }

  private func makeSnapshot(
    device: AVFoundation.AVCaptureDevice,
    deviceID: CaptureDeviceID,
    deviceTypeID: CaptureDeviceTypeID,
    revision: UInt64,
    formats: [CaptureDeviceFormatDescriptor],
    preferredFormatID: CaptureDeviceFormatID,
    controls: CaptureDeviceControlCapabilities
  ) throws(CaptureContractError) -> CaptureDeviceSnapshot {
    let videoStreamID = try CaptureStreamID("video")
    let videoStream = try CaptureStreamDescriptor(
      streamID: videoStreamID,
      mediaType: .video,
      formatIDs: formats.map(\.formatID),
      eventCapabilities: [
        .interruptions,
        .sourceDrops,
        .terminalFailures,
      ],
      videoConnectionCapabilities:
        try AppleCameraVideoConnectionBridge.capabilities()
    )
    let videoStreamCombination = try CaptureStreamCombination(
      streamIDs: [videoStreamID]
    )
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
    let capabilities = try CaptureDeviceCapabilities(
      deviceID: deviceID,
      revision: revision,
      formats: formats,
      preferredFormatID: preferredFormatID,
      controls: controls,
      streams: [videoStream],
      supportedStreamCombinations: [videoStreamCombination]
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
      // The provider capability boundary is intentionally native NV12/BGRA.
      // Unsupported native formats are not advertised because this driver
      // does not perform an implicit pixel conversion or payload copy.
      return []
    }
  }

  static func supports(
    frameRate: Double,
    ranges: [CaptureFrameRateRange]
  ) -> Bool {
    ranges.contains { range in
      range.minimum <= frameRate && frameRate <= range.maximum
    }
  }

  static func formatDescriptors(
    from records: [AppleCameraFormatRecord]
  ) throws(CaptureContractError)
    -> [CaptureDeviceFormatDescriptor]
  {
    var descriptors: [CaptureDeviceFormatDescriptor] = []
    descriptors.reserveCapacity(records.count)
    for record in records {
      descriptors.append(
        try CaptureDeviceFormatDescriptor(
          formatID: formatID(for: record),
          mediaType: .video,
          mediaSubtype: CaptureMediaSubtype(
            rawValue: record.mediaSubtype
          ),
          dimensions: record.dimensions,
          frameRateRanges: record.frameRateRanges
        )
      )
    }
    return descriptors
  }

  static func formatID(
    for record: AppleCameraFormatRecord
  ) throws(CaptureContractError) -> CaptureDeviceFormatID {
    let prefix: String
    switch OSType(record.mediaSubtype) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      prefix = "nv12-full"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      prefix = "nv12-video"
    case kCVPixelFormatType_32BGRA:
      prefix = "bgra"
    default:
      prefix = String(record.mediaSubtype)
    }
    return try CaptureDeviceFormatID(
      "\(prefix)-\(record.dimensions.width)x"
        + "\(record.dimensions.height)-native-\(record.nativeIndex)"
    )
  }

  static func preferredFormatIndex(
    in records: [AppleCameraFormatRecord]
  ) -> Int? {
    guard !records.isEmpty else {
      return nil
    }
    return records.firstIndex(where: \.isActive) ?? records.startIndex
  }

  func nativeFormat(
    identifiedBy formatID: CaptureDeviceFormatID,
    on device: AVFoundation.AVCaptureDevice,
    deviceID: CaptureDeviceID
  ) throws(CaptureDriverError) -> AVFoundation.AVCaptureDevice.Format {
    for (index, format) in device.formats.enumerated() {
      let record: AppleCameraFormatRecord
      do {
        record = try Self.formatRecord(
          nativeIndex: index,
          format: format,
          isActive: format === device.activeFormat
        )
      } catch {
        throw .contractViolation(driverID: driverID, error: error)
      }
      guard
        Self.supportedPixelFormats(
          nativeSubtype: OSType(record.mediaSubtype)
        ).isEmpty == false
      else {
        continue
      }
      do {
        if try Self.formatID(for: record) == formatID {
          return format
        }
      } catch {
        throw .contractViolation(driverID: driverID, error: error)
      }
    }
    throw .unsupportedFormat(
      deviceID: deviceID,
      formatID: formatID
    )
  }

  private func formatRecords(
    for device: AVFoundation.AVCaptureDevice
  ) throws(CaptureDriverError) -> [AppleCameraFormatRecord] {
    var records: [AppleCameraFormatRecord] = []
    records.reserveCapacity(device.formats.count)
    for (index, format) in device.formats.enumerated() {
      let subtype = CMFormatDescriptionGetMediaSubType(
        format.formatDescription
      )
      guard
        !Self.supportedPixelFormats(
          nativeSubtype: subtype
        ).isEmpty
      else {
        continue
      }
      do {
        records.append(
          try Self.formatRecord(
            nativeIndex: index,
            format: format,
            isActive: format === device.activeFormat
          )
        )
      } catch {
        throw .contractViolation(driverID: driverID, error: error)
      }
    }
    return records
  }

  private static func formatRecord(
    nativeIndex: Int,
    format: AVFoundation.AVCaptureDevice.Format,
    isActive: Bool
  ) throws(CaptureContractError) -> AppleCameraFormatRecord {
    let description = format.formatDescription
    let nativeDimensions = CMVideoFormatDescriptionGetDimensions(
      description
    )
    let dimensions = try CaptureDimensions(
      width: Int(nativeDimensions.width),
      height: Int(nativeDimensions.height)
    )
    var ranges: [CaptureFrameRateRange] = []
    ranges.reserveCapacity(format.videoSupportedFrameRateRanges.count)
    for range in format.videoSupportedFrameRateRanges {
      ranges.append(
        try CaptureFrameRateRange(
          minimum: range.minFrameRate,
          maximum: range.maxFrameRate
        )
      )
    }
    return AppleCameraFormatRecord(
      nativeIndex: nativeIndex,
      mediaSubtype: UInt32(
        CMFormatDescriptionGetMediaSubType(description)
      ),
      dimensions: dimensions,
      frameRateRanges: ranges,
      isActive: isActive
    )
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
    records: [AppleCameraFormatRecord],
    controls: CaptureDeviceControlCapabilities
  ) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037
    var components = [
      device.uniqueID,
    ]
    for record in records {
      components.append(String(record.nativeIndex))
      components.append(String(record.mediaSubtype))
      components.append(String(record.dimensions.width))
      components.append(String(record.dimensions.height))
      for range in record.frameRateRanges {
        components.append(String(range.minimum))
        components.append(String(range.maximum))
      }
    }
    components.append(String(describing: controls))
    let identity = components.joined(separator: "|")
    for byte in identity.utf8 {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return value
  }
}
