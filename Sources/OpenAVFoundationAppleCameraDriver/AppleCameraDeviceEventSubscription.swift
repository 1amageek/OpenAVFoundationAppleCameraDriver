@preconcurrency import AVFoundation
import Foundation
import OpenAVFoundationDriver

actor AppleCameraDeviceEventSubscription:
  CaptureDeviceEventSubscription
{
  private enum Phase {
    case idle
    case running
    case stopped
  }

  nonisolated let driverID: CaptureDriverID

  private let sink: any CaptureDeviceEventSink
  private let failureHandler: @Sendable (CaptureDriverError) -> Void
  private let snapshot:
    @Sendable () throws(CaptureDriverError)
      -> [CaptureDeviceDescriptor]
  private let notificationCenter: NotificationCenter
  private let connectedNotification: Notification.Name
  private let disconnectedNotification: Notification.Name
  private var phase = Phase.idle
  private var descriptors: [CaptureDeviceID: CaptureDeviceDescriptor] = [:]
  private var observerTokens: [NSObjectProtocol] = []

  init(
    driverID: CaptureDriverID,
    sink: any CaptureDeviceEventSink,
    failureHandler: @escaping @Sendable (CaptureDriverError) -> Void,
    snapshot:
      @escaping @Sendable () throws(CaptureDriverError)
        -> [CaptureDeviceDescriptor],
    notificationCenter: NotificationCenter = .default,
    connectedNotification: Notification.Name =
      AVFoundation.AVCaptureDevice.wasConnectedNotification,
    disconnectedNotification: Notification.Name =
      AVFoundation.AVCaptureDevice.wasDisconnectedNotification
  ) {
    self.driverID = driverID
    self.sink = sink
    self.failureHandler = failureHandler
    self.snapshot = snapshot
    self.notificationCenter = notificationCenter
    self.connectedNotification = connectedNotification
    self.disconnectedNotification = disconnectedNotification
  }

  deinit {
    for token in observerTokens {
      notificationCenter.removeObserver(token)
    }
  }

  func start() throws(CaptureDriverError) {
    switch phase {
    case .running:
      return
    case .stopped:
      throw .backendFailure(
        driverID: driverID,
        deviceID: nil,
        operation: .observation,
        code: 1
      )
    case .idle:
      break
    }

    installObservers()
    let initial: [CaptureDeviceDescriptor]
    do {
      initial = try snapshot()
    } catch {
      removeObservers()
      phase = .stopped
      throw error
    }

    do {
      descriptors = try Self.dictionary(
        initial,
        driverID: driverID
      )
    } catch {
      removeObservers()
      phase = .stopped
      throw error
    }
    phase = .running
    if sink.offer(.snapshot(initial)) == .stop {
      shutdown()
    }
  }

  func shutdown() {
    guard phase != .stopped else {
      return
    }
    phase = .stopped
    descriptors.removeAll(keepingCapacity: false)
    removeObservers()
  }

  private func installObservers() {
    observerTokens = [
      notificationCenter.addObserver(
        forName: connectedNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        Task {
          await self?.refresh()
        }
      },
      notificationCenter.addObserver(
        forName: disconnectedNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        Task {
          await self?.refresh()
        }
      },
    ]
  }

  private func removeObservers() {
    let tokens = observerTokens
    observerTokens.removeAll(keepingCapacity: false)
    for token in tokens {
      notificationCenter.removeObserver(token)
    }
  }

  func refresh() {
    guard phase == .running else {
      return
    }

    let latest: [CaptureDeviceDescriptor]
    let latestByID: [CaptureDeviceID: CaptureDeviceDescriptor]
    do {
      latest = try snapshot()
      latestByID = try Self.dictionary(
        latest,
        driverID: driverID
      )
    } catch {
      failureHandler(error)
      shutdown()
      return
    }

    var events: [CaptureDeviceEvent] = []
    for deviceID in descriptors.keys
    where latestByID[deviceID] == nil {
      events.append(.disconnected(deviceID))
    }
    for descriptor in latest {
      guard let previous = descriptors[descriptor.deviceID] else {
        events.append(.connected(descriptor))
        continue
      }
      if previous != descriptor {
        events.append(.updated(descriptor))
      }
    }
    descriptors = latestByID

    for event in events {
      if sink.offer(event) == .stop {
        shutdown()
        return
      }
    }
  }

  private static func dictionary(
    _ descriptors: [CaptureDeviceDescriptor],
    driverID: CaptureDriverID
  ) throws(CaptureDriverError)
    -> [CaptureDeviceID: CaptureDeviceDescriptor]
  {
    var result: [CaptureDeviceID: CaptureDeviceDescriptor] = [:]
    result.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      guard result[descriptor.deviceID] == nil else {
        throw .backendFailure(
          driverID: driverID,
          deviceID: descriptor.deviceID,
          operation: .observation,
          code: 2
        )
      }
      result[descriptor.deviceID] = descriptor
    }
    return result
  }
}
