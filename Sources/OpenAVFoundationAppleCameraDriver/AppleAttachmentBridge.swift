import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import OpenCoreMedia
import OpenCoreVideo

enum AppleAttachmentBridge {
  static func copyImageAttachments(
    from source: CoreVideo.CVBuffer,
    to destination: OpenCoreVideo.CVBufferAttachments
  ) throws(AppleAttachmentBridgeError) {
    try copyImageAttachments(
      from: source,
      mode: .shouldNotPropagate,
      portableMode: .shouldNotPropagate,
      to: destination
    )
    try copyImageAttachments(
      from: source,
      mode: .shouldPropagate,
      portableMode: .shouldPropagate,
      to: destination
    )
  }

  static func copySampleAttachments(
    from source: CoreMedia.CMSampleBuffer,
    to destination: OpenCoreMedia.CMImageSampleBuffer
  ) throws(AppleAttachmentBridgeError) {
    try copyBearerAttachments(
      from: source,
      mode: kCMAttachmentMode_ShouldNotPropagate,
      portableMode: .shouldNotPropagate,
      to: destination.attachments
    )
    try copyBearerAttachments(
      from: source,
      mode: kCMAttachmentMode_ShouldPropagate,
      portableMode: .shouldPropagate,
      to: destination.attachments
    )
    try copyPerSampleAttachments(
      from: source,
      to: destination
    )
  }

  private static func copyImageAttachments(
    from source: CoreVideo.CVBuffer,
    mode: CoreVideo.CVAttachmentMode,
    portableMode: OpenCoreVideo.CVAttachmentMode,
    to destination: OpenCoreVideo.CVBufferAttachments
  ) throws(AppleAttachmentBridgeError) {
    guard let dictionary = CVBufferCopyAttachments(source, mode)
    else {
      return
    }
    let values = try coreVideoDictionary(dictionary)
    destination.setAttachments(values, mode: portableMode)
  }

  private static func copyBearerAttachments(
    from source: CoreMedia.CMSampleBuffer,
    mode: CoreMedia.CMAttachmentMode,
    portableMode: OpenCoreMedia.CMAttachmentMode,
    to destination: OpenCoreMedia.CMAttachmentBearerAttachments
  ) throws(AppleAttachmentBridgeError) {
    guard
      let dictionary = CMCopyDictionaryOfAttachments(
        allocator: nil,
        target: source,
        attachmentMode: mode
      )
    else {
      return
    }
    destination.merge(
      try coreMediaDictionary(dictionary),
      mode: portableMode
    )
  }

  private static func copyPerSampleAttachments(
    from source: CoreMedia.CMSampleBuffer,
    to destination: OpenCoreMedia.CMImageSampleBuffer
  ) throws(AppleAttachmentBridgeError) {
    guard
      let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(
        source,
        createIfNecessary: false
      )
    else {
      return
    }
    let sourceCount = CFArrayGetCount(sourceAttachments)
    let destinationCount: Int
    do {
      destinationCount = try destination.sampleCount()
    } catch {
      throw .portableSampleBuffer(error)
    }
    guard sourceCount == destinationCount else {
      throw .sampleAttachmentCountMismatch(
        expected: destinationCount,
        actual: sourceCount
      )
    }
    guard
      let destinationAttachments =
        destination.sampleAttachments(createIfNecessary: true)
    else {
      throw .missingPortableSampleAttachments
    }

    for index in 0..<sourceCount {
      guard let rawDictionary = CFArrayGetValueAtIndex(
        sourceAttachments,
        index
      ) else {
        throw .missingNativeSampleAttachment(index: index)
      }
      let dictionary = Unmanaged<CFDictionary>
        .fromOpaque(rawDictionary)
        .takeUnretainedValue()
      let values = try coreMediaDictionary(dictionary)
      let destinationDictionary: OpenCoreMedia.CMSampleAttachmentDictionary
      do {
        destinationDictionary = try destinationAttachments.attachment(
          at: index
        )
      } catch {
        throw .portableSampleBuffer(error)
      }
      for (key, value) in values {
        destinationDictionary[rawAttachment: key] = value
      }
    }
  }

  private static func coreVideoDictionary(
    _ dictionary: CFDictionary
  ) throws(AppleAttachmentBridgeError)
    -> [OpenCoreVideo.CVAttachmentKey: OpenCoreVideo.CVAttachmentValue]
  {
    let source = dictionary as NSDictionary
    var result:
      [OpenCoreVideo.CVAttachmentKey: OpenCoreVideo.CVAttachmentValue] = [:]
    result.reserveCapacity(source.count)
    for (rawKey, rawValue) in source {
      guard let key = rawKey as? String else {
        throw .nonStringKey
      }
      result[OpenCoreVideo.CVAttachmentKey(rawValue: key)] =
        try coreVideoValue(rawValue as CFTypeRef)
    }
    return result
  }

  private static func coreMediaDictionary(
    _ dictionary: CFDictionary
  ) throws(AppleAttachmentBridgeError)
    -> [String: OpenCoreMedia.CMAttachmentValue]
  {
    let source = dictionary as NSDictionary
    var result: [String: OpenCoreMedia.CMAttachmentValue] = [:]
    result.reserveCapacity(source.count)
    for (rawKey, rawValue) in source {
      guard let key = rawKey as? String else {
        throw .nonStringKey
      }
      result[key] = try coreMediaValue(rawValue as CFTypeRef)
    }
    return result
  }

  private static func coreVideoValue(
    _ value: CFTypeRef
  ) throws(AppleAttachmentBridgeError)
    -> OpenCoreVideo.CVAttachmentValue
  {
    switch CFGetTypeID(value) {
    case CFBooleanGetTypeID():
      return .boolean(CFBooleanGetValue((value as! CFBoolean)))
    case CFNumberGetTypeID():
      return try coreVideoNumber(value as! NSNumber)
    case CFStringGetTypeID():
      return .string(value as! String)
    case CFDataGetTypeID():
      return .binary(
        try coreVideoBinary(value as! CFData)
      )
    case CFArrayGetTypeID():
      let source = value as! NSArray
      var result: [OpenCoreVideo.CVAttachmentValue] = []
      result.reserveCapacity(source.count)
      for element in source {
        result.append(
          try coreVideoValue(element as CFTypeRef)
        )
      }
      return .array(result)
    case CFDictionaryGetTypeID():
      return .dictionary(
        try coreVideoStringDictionary(value as! CFDictionary)
      )
    default:
      throw .unsupportedValueType(CFGetTypeID(value))
    }
  }

  private static func coreMediaValue(
    _ value: CFTypeRef
  ) throws(AppleAttachmentBridgeError)
    -> OpenCoreMedia.CMAttachmentValue
  {
    switch CFGetTypeID(value) {
    case CFBooleanGetTypeID():
      return .boolean(CFBooleanGetValue((value as! CFBoolean)))
    case CFNumberGetTypeID():
      return coreMediaNumber(value as! NSNumber)
    case CFStringGetTypeID():
      return .string(value as! String)
    case CFDataGetTypeID():
      return .bytes(
        OpenCoreMedia.CMAttachmentBytes(
          try copiedBytes(value as! CFData)
        )
      )
    case CFArrayGetTypeID():
      let source = value as! NSArray
      var result: [OpenCoreMedia.CMAttachmentValue] = []
      result.reserveCapacity(source.count)
      for element in source {
        result.append(
          try coreMediaValue(element as CFTypeRef)
        )
      }
      return .array(result)
    case CFDictionaryGetTypeID():
      return .dictionary(
        try coreMediaDictionary(value as! CFDictionary)
      )
    default:
      throw .unsupportedValueType(CFGetTypeID(value))
    }
  }

  private static func coreVideoStringDictionary(
    _ dictionary: CFDictionary
  ) throws(AppleAttachmentBridgeError)
    -> [String: OpenCoreVideo.CVAttachmentValue]
  {
    let source = dictionary as NSDictionary
    var result: [String: OpenCoreVideo.CVAttachmentValue] = [:]
    result.reserveCapacity(source.count)
    for (rawKey, rawValue) in source {
      guard let key = rawKey as? String else {
        throw .nonStringKey
      }
      result[key] = try coreVideoValue(rawValue as CFTypeRef)
    }
    return result
  }

  private static func coreVideoNumber(
    _ number: NSNumber
  ) throws(AppleAttachmentBridgeError)
    -> OpenCoreVideo.CVAttachmentValue
  {
    if numberIsUnsigned(number) {
      return .unsignedInteger(number.uint64Value)
    }
    if CFNumberIsFloatType(number) {
      return .floatingPoint(number.doubleValue)
    }
    return .integer(number.int64Value)
  }

  private static func coreMediaNumber(
    _ number: NSNumber
  ) -> OpenCoreMedia.CMAttachmentValue {
    if numberIsUnsigned(number) {
      return .unsignedInteger(number.uint64Value)
    }
    if CFNumberIsFloatType(number) {
      return .floatingPoint(number.doubleValue)
    }
    return .integer(number.int64Value)
  }

  private static func numberIsUnsigned(_ number: NSNumber) -> Bool {
    switch String(cString: number.objCType) {
    case "C", "S", "I", "L", "Q":
      return true
    default:
      return false
    }
  }

  private static func copiedBytes(
    _ data: CFData
  ) throws(AppleAttachmentBridgeError) -> [UInt8] {
    let count = CFDataGetLength(data)
    guard count >= 0 else {
      throw .invalidBinaryLength(count)
    }
    var bytes = [UInt8](repeating: 0, count: count)
    guard count > 0 else {
      return bytes
    }
    guard let source = CFDataGetBytePtr(data) else {
      throw .missingBinaryStorage
    }
    bytes.withUnsafeMutableBytes { destination in
      destination.copyMemory(
        from: UnsafeRawBufferPointer(
          start: source,
          count: count
        )
      )
    }
    return bytes
  }

  private static func coreVideoBinary(
    _ data: CFData
  ) throws(AppleAttachmentBridgeError)
    -> OpenCoreVideo.CVBinaryAttachment
  {
    let count = CFDataGetLength(data)
    guard count >= 0 else {
      throw .invalidBinaryLength(count)
    }
    guard count > 0 else {
      return OpenCoreVideo.CVBinaryAttachment()
    }
    guard let source = CFDataGetBytePtr(data) else {
      throw .missingBinaryStorage
    }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: count,
      alignment: MemoryLayout<UInt8>.alignment
    )
    storage.copyMemory(from: source, byteCount: count)
    do {
      // CFData is copied once because the portable value cannot borrow a Core
      // Foundation owner's lifetime across Sendable boundaries. This metadata
      // boundary is separate from the zero-copy pixel payload. The allocation
      // has one owner; ownership transfers only after initialization succeeds,
      // and the release closure deallocates it exactly once.
      return try OpenCoreVideo.CVBinaryAttachment(
        baseAddress: storage,
        byteCount: count,
        releaseHandler: { baseAddress, _ in
          baseAddress.deallocate()
        }
      )
    } catch {
      storage.deallocate()
      throw .portableBinary(error)
    }
  }
}

enum AppleAttachmentBridgeError: Error, Sendable, Equatable {
  case nonStringKey
  case unsupportedValueType(CFTypeID)
  case invalidBinaryLength(Int)
  case missingBinaryStorage
  case portableBinary(OpenCoreVideo.CVPixelBufferError)
  case portableSampleBuffer(OpenCoreMedia.CMSampleBufferError)
  case sampleAttachmentCountMismatch(expected: Int, actual: Int)
  case missingNativeSampleAttachment(index: Int)
  case missingPortableSampleAttachments
}
