import OpenAVFoundationDriver
import OpenCoreMedia
import Synchronization

final class AppleCameraStreamEventRelay: Sendable {
  private enum OfferAction {
    case none
    case drain
    case terminate
  }

  private enum Phase: Sendable {
    case stopped
    case running
    case shutdown
  }

  private struct State: Sendable {
    var phase = Phase.stopped
    var sink: (any CaptureStreamEventSink)?
    var pending: [CaptureStreamEvent] = []
    var pendingIndex = 0
    var isDraining = false
    var terminalEventQueued = false
    var cumulativeDropCount: UInt64 = 0
  }

  private static let maximumPendingEventCount = 256

  let capabilities: CaptureStreamEventCapabilities = [
    .interruptions,
    .sourceDrops,
    .terminalFailures,
  ]

  private let deviceID: CaptureDeviceID
  private let terminalHandler: @Sendable () -> Void
  private let state = Mutex(State())

  init(
    deviceID: CaptureDeviceID,
    terminalHandler: @escaping @Sendable () -> Void
  ) {
    self.deviceID = deviceID
    self.terminalHandler = terminalHandler
  }

  func setSink(
    _ sink: (any CaptureStreamEventSink)?
  ) throws(CaptureDriverError) {
    try state.withLock { state throws(CaptureDriverError) in
      switch state.phase {
      case .stopped:
        state.sink = sink
      case .running:
        throw .deviceBusy(deviceID)
      case .shutdown:
        throw .deviceDisconnected(deviceID)
      }
    }
  }

  func beginStart() throws(CaptureDriverError) {
    try state.withLock { state throws(CaptureDriverError) in
      switch state.phase {
      case .stopped:
        state.phase = .running
      case .running:
        throw .deviceBusy(deviceID)
      case .shutdown:
        throw .deviceDisconnected(deviceID)
      }
    }
  }

  func cancelStart() {
    state.withLock { state in
      guard state.phase == .running else {
        return
      }
      state.phase = .stopped
      state.pending.removeAll(keepingCapacity: true)
      state.pendingIndex = 0
      state.terminalEventQueued = false
    }
  }

  func shutdown() {
    state.withLock { state in
      state.phase = .shutdown
      state.sink = nil
      state.pending.removeAll(keepingCapacity: false)
      state.pendingIndex = 0
      state.terminalEventQueued = false
    }
  }

  func requestStop() {
    let shouldTerminate = state.withLock { state -> Bool in
      guard state.phase != .shutdown else {
        return false
      }
      state.phase = .shutdown
      state.sink = nil
      state.pending.removeAll(keepingCapacity: false)
      state.pendingIndex = 0
      state.isDraining = false
      state.terminalEventQueued = false
      return true
    }
    if shouldTerminate {
      terminalHandler()
    }
  }

  func offer(_ event: CaptureStreamEvent) {
    let action = state.withLock { state -> OfferAction in
      let isTerminalFailure: Bool
      if case .failed = event {
        isTerminalFailure = true
      } else {
        isTerminalFailure = false
      }
      guard state.phase != .shutdown else {
        return .none
      }
      guard state.phase == .running, state.sink != nil else {
        guard isTerminalFailure else {
          return .none
        }
        state.phase = .shutdown
        state.sink = nil
        state.pending.removeAll(keepingCapacity: false)
        state.pendingIndex = 0
        state.isDraining = false
        state.terminalEventQueued = false
        return .terminate
      }
      guard !state.terminalEventQueued else {
        return .none
      }
      let activeCount = state.pending.count - state.pendingIndex
      if activeCount >= Self.maximumPendingEventCount {
        state.pending.append(
          .failed(
            .backendFailure(
              driverID: deviceID.driverID,
              deviceID: deviceID,
              operation: .streaming,
              code: -2
            )
          )
        )
        state.terminalEventQueued = true
      } else {
        state.pending.append(event)
        if case .failed = event {
          state.terminalEventQueued = true
        }
      }
      guard !state.isDraining else {
        return .none
      }
      state.isDraining = true
      return .drain
    }
    switch action {
    case .none:
      break
    case .drain:
      drain()
    case .terminate:
      terminalHandler()
    }
  }

  func offerDrop(
    presentationTimeStamp: OpenCoreMedia.CMTime,
    reason: CaptureStreamDropReason
  ) {
    let event = state.withLock {
      state -> CaptureStreamEvent? in
      guard state.phase == .running, state.sink != nil else {
        return nil
      }
      let next = state.cumulativeDropCount.addingReportingOverflow(1)
      guard !next.overflow else {
        return .failed(
          .backendFailure(
            driverID: deviceID.driverID,
            deviceID: deviceID,
            operation: .streaming,
            code: -1
          )
        )
      }
      state.cumulativeDropCount = next.partialValue
      return .dropped(
        CaptureStreamDropEvent(
          presentationTimeStamp: presentationTimeStamp,
          cumulativeCount: next.partialValue,
          reason: reason
        )
      )
    }
    if let event {
      offer(event)
    }
  }

  private func drain() {
    while true {
      let next = state.withLock {
        state -> (
          (any CaptureStreamEventSink),
          CaptureStreamEvent
        )? in
        guard state.phase == .running,
          let sink = state.sink,
          state.pendingIndex < state.pending.count
        else {
          state.pending.removeAll(keepingCapacity: true)
          state.pendingIndex = 0
          state.isDraining = false
          state.terminalEventQueued = false
          return nil
        }
        let event = state.pending[state.pendingIndex]
        state.pendingIndex += 1
        if state.pendingIndex >= 128,
          state.pendingIndex * 2 >= state.pending.count
        {
          state.pending.removeFirst(state.pendingIndex)
          state.pendingIndex = 0
        }
        return (sink, event)
      }
      guard let (sink, event) = next else {
        return
      }

      let disposition = sink.offer(event)
      let isTerminalFailure: Bool
      if case .failed = event {
        isTerminalFailure = true
      } else {
        isTerminalFailure = false
      }
      guard disposition == .continueStreaming, !isTerminalFailure else {
        let shouldStop = state.withLock { state -> Bool in
          guard state.phase == .running else {
            return false
          }
          state.phase = .shutdown
          state.sink = nil
          state.pending.removeAll(keepingCapacity: false)
          state.pendingIndex = 0
          state.isDraining = false
          state.terminalEventQueued = false
          return true
        }
        if shouldStop {
          terminalHandler()
        }
        return
      }
    }
  }
}
