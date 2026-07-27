import CoreVideo
import OpenCoreVideo
import Synchronization

/// A zero-copy OpenCoreVideo view over one Apple Core Video pixel buffer.
///
/// The object retains the native buffer and only lends CPU addresses while the
/// matching Core Video lock is held. Packed and planar buffers share the same
/// owner, so an NV12 frame does not allocate one owner wrapper per plane.
public final class AppleCameraPixelBuffer:
  OpenCoreVideo.CVPixelBuffer,
  OpenCoreVideo.CVPlanarStorageLease
{
  public typealias AttachmentStorage =
    OpenCoreVideo.CVBufferAttachments

  private enum State: Sendable {
    case idle
    case locking
    case reading(Int)
    case unlocking
    case failed(Int32)
  }

  public let dimensions: OpenCoreVideo.CVPixelDimensions
  public let pixelFormat: OpenCoreVideo.CVPixelFormatType
  public let bytesPerRow: Int
  public let byteCount: Int
  public let isPlanar: Bool
  public let planeCount: Int
  public let attachments = OpenCoreVideo.CVBufferAttachments()
  public let accessCapabilities: OpenCoreVideo.CVPixelBufferAccessCapabilities = .read

  // This owner stores the unchanged address bits for one +1 Core Foundation
  // retain and releases it exactly once in deinit. The address is never
  // offset, rebound, or exposed. It is reconstructed only as the original
  // opaque pointer. Operations take a strong local reference under a short
  // mutex lock, then perform Core Video locking and caller callbacks after
  // releasing the owner mutex.
  private let nativeOwner: Mutex<UInt>
  private let state = Mutex(State.idle)

  init(
    pixelBuffer: consuming CoreVideo.CVPixelBuffer
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    let dimensions = try OpenCoreVideo.CVPixelDimensions(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    let pixelFormat = OpenCoreVideo.CVPixelFormatType(
      rawValue: CVPixelBufferGetPixelFormatType(pixelBuffer)
    )
    let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
    let planeCount =
      isPlanar
      ? CVPixelBufferGetPlaneCount(pixelBuffer)
      : 0

    let byteCount: Int
    let bytesPerRow: Int
    if isPlanar {
      guard planeCount > 0 else {
        throw .invalidPlaneCount(planeCount)
      }
      var totalBytes = 0
      for index in 0..<planeCount {
        let planeBytes = try Self.planeByteCount(
          pixelBuffer: pixelBuffer,
          index: index
        )
        let total = totalBytes.addingReportingOverflow(
          planeBytes
        )
        guard !total.overflow else {
          throw .layoutOverflow
        }
        totalBytes = total.partialValue
      }
      byteCount = totalBytes
      let quotient = totalBytes / dimensions.height
      let remainder = totalBytes % dimensions.height
      bytesPerRow = quotient + (remainder == 0 ? 0 : 1)
    } else {
      let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
      let result = rowBytes.multipliedReportingOverflow(
        by: dimensions.height
      )
      guard !result.overflow, result.partialValue > 0 else {
        throw .layoutOverflow
      }
      bytesPerRow = rowBytes
      byteCount = result.partialValue
    }

    self.dimensions = dimensions
    self.pixelFormat = pixelFormat
    self.isPlanar = isPlanar
    self.planeCount = planeCount
    self.bytesPerRow = bytesPerRow
    self.byteCount = byteCount
    let retainedPointer = Unmanaged
      .passRetained(pixelBuffer)
      .toOpaque()
    nativeOwner = Mutex(UInt(bitPattern: retainedPointer))
  }

  deinit {
    let retained = nativeOwner.withLock { address in
      Unmanaged<CoreVideo.CVPixelBuffer>.fromOpaque(
        UnsafeRawPointer(bitPattern: address)!
      )
    }
    retained.release()
  }

  public func withReadBytes(
    _ body: (borrowing Span<UInt8>) -> Void
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    guard !isPlanar else {
      throw .planarBufferRequiresPlaneAccess
    }
    let pixelBuffer = nativePixelBuffer()
    try withReadLock(pixelBuffer: pixelBuffer) {
      guard
        let baseAddress = CVPixelBufferGetBaseAddress(
          pixelBuffer
        )
      else {
        return .storageReleased
      }
      Self.borrow(
        baseAddress: baseAddress,
        byteCount: byteCount,
        body
      )
      return nil
    }
  }

  public func withWriteBytes(
    _ body: (inout MutableSpan<UInt8>) -> Void
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    throw .unsupportedAccess(.write)
  }

  public func dimensionsOfPlane(
    at index: Int
  ) throws(OpenCoreVideo.CVPixelBufferError)
    -> OpenCoreVideo.CVPixelDimensions
  {
    try validatePlane(index)
    let pixelBuffer = nativePixelBuffer()
    return try OpenCoreVideo.CVPixelDimensions(
      width: CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
      height: CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
    )
  }

  public func bytesPerRowOfPlane(
    at index: Int
  ) throws(OpenCoreVideo.CVPixelBufferError) -> Int {
    try validatePlane(index)
    let pixelBuffer = nativePixelBuffer()
    return CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
  }

  public func byteCount(
    ofPlane index: Int
  ) throws(OpenCoreVideo.CVPixelBufferError) -> Int {
    try validatePlane(index)
    let pixelBuffer = nativePixelBuffer()
    return try Self.planeByteCount(
      pixelBuffer: pixelBuffer,
      index: index
    )
  }

  public func withReadBytes(
    ofPlane index: Int,
    _ body: (borrowing Span<UInt8>) -> Void
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    try validatePlane(index)
    let pixelBuffer = nativePixelBuffer()
    let planeByteCount = try Self.planeByteCount(
      pixelBuffer: pixelBuffer,
      index: index
    )
    try withReadLock(pixelBuffer: pixelBuffer) {
      guard
        let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
          pixelBuffer,
          index
        )
      else {
        return .storageReleased
      }
      Self.borrow(
        baseAddress: baseAddress,
        byteCount: planeByteCount,
        body
      )
      return nil
    }
  }

  public func withWriteBytes(
    ofPlane index: Int,
    _ body: (inout MutableSpan<UInt8>) -> Void
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    try validatePlane(index)
    throw .unsupportedAccess(.write)
  }

  /// Lends the retained native buffer without exposing a CPU address.
  ///
  /// The callback must not store the reference. This projection exists for
  /// Apple GPU consumers such as Core Image and Metal texture caches.
  public func withCoreVideoPixelBuffer(
    _ body: (CoreVideo.CVPixelBuffer) -> Void
  ) {
    body(nativePixelBuffer())
  }

  private func withReadLock(
    pixelBuffer: CoreVideo.CVPixelBuffer,
    _ body: () -> OpenCoreVideo.CVPixelBufferError?
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    let needsNativeLock = try state.withLock {
      state throws(OpenCoreVideo.CVPixelBufferError) -> Bool in
      switch state {
      case .idle:
        state = .locking
        return true
      case .reading(let readerCount):
        state = .reading(readerCount + 1)
        return false
      case .locking, .unlocking:
        throw .accessConflict(.read)
      case .failed(let code):
        throw .platformAccessFailure(code: code)
      }
    }

    if needsNativeLock {
      let lockStatus = CVPixelBufferLockBaseAddress(
        pixelBuffer,
        .readOnly
      )
      guard lockStatus == CoreVideo.kCVReturnSuccess else {
        state.withLock { state in
          state = .idle
        }
        throw .platformAccessFailure(code: lockStatus)
      }
      state.withLock { state in
        state = .reading(1)
      }
    }

    let bodyError = body()
    let needsNativeUnlock = try state.withLock {
      state throws(OpenCoreVideo.CVPixelBufferError) -> Bool in
      switch state {
      case .reading(let readerCount) where readerCount > 1:
        state = .reading(readerCount - 1)
        return false
      case .reading:
        state = .unlocking
        return true
      case .idle, .locking, .unlocking, .failed:
        throw .accessConflict(.read)
      }
    }

    if needsNativeUnlock {
      let unlockStatus = CVPixelBufferUnlockBaseAddress(
        pixelBuffer,
        .readOnly
      )
      guard unlockStatus == CoreVideo.kCVReturnSuccess else {
        state.withLock { state in
          state = .failed(unlockStatus)
        }
        throw .platformAccessFailure(code: unlockStatus)
      }
      state.withLock { state in
        state = .idle
      }
    }
    if let bodyError {
      throw bodyError
    }
  }

  private func nativePixelBuffer() -> CoreVideo.CVPixelBuffer {
    nativeOwner.withLock { address in
      Unmanaged<CoreVideo.CVPixelBuffer>
        .fromOpaque(UnsafeRawPointer(bitPattern: address)!)
        .takeUnretainedValue()
    }
  }

  private func validatePlane(
    _ index: Int
  ) throws(OpenCoreVideo.CVPixelBufferError) {
    guard isPlanar, (0..<planeCount).contains(index) else {
      throw .invalidPlaneIndex(
        index: index,
        planeCount: planeCount
      )
    }
  }

  private static func planeByteCount(
    pixelBuffer: CoreVideo.CVPixelBuffer,
    index: Int
  ) throws(OpenCoreVideo.CVPixelBufferError) -> Int {
    let result = CVPixelBufferGetBytesPerRowOfPlane(
      pixelBuffer,
      index
    ).multipliedReportingOverflow(
      by: CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
    )
    guard !result.overflow, result.partialValue > 0 else {
      throw .layoutOverflow
    }
    return result.partialValue
  }

  private static func borrow(
    baseAddress: UnsafeMutableRawPointer,
    byteCount: Int,
    _ body: (borrowing Span<UInt8>) -> Void
  ) {
    // Core Video owns and initializes this storage for the validated
    // row-by-height byte count while the native read lock is held. UInt8 has
    // unit alignment and may inspect any initialized object representation.
    // The scoped Span cannot outlive the callback or cross a Sendable boundary.
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let span = Span(
      _unsafeStart: UnsafePointer(bytes),
      count: byteCount
    )
    body(span)
  }
}
