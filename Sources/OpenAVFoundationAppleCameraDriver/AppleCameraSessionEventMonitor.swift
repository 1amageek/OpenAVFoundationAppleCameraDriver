@preconcurrency import AVFoundation
import Foundation
import OpenAVFoundationDriver

final class AppleCameraSessionEventMonitor {
  private let notificationCenter: NotificationCenter
  private let observationTokens: [NSObjectProtocol]

  init(
    driverID: CaptureDriverID,
    deviceID: CaptureDeviceID,
    session: AVFoundation.AVCaptureSession,
    relay: AppleCameraStreamEventRelay,
    notificationCenter: NotificationCenter = .default
  ) {
    self.notificationCenter = notificationCenter
    observationTokens = [
      notificationCenter.addObserver(
        forName:
          AVFoundation.AVCaptureSession.wasInterruptedNotification,
        object: session,
        queue: nil
      ) { _ in
        // macOS posts the interruption notification but does not expose
        // AVCaptureSessionInterruptionReasonKey. Preserve that unknown native
        // reason explicitly instead of inventing a portable cause.
        relay.offer(.interrupted(.platform(code: 0)))
      },
      notificationCenter.addObserver(
        forName:
          AVFoundation.AVCaptureSession.interruptionEndedNotification,
        object: session,
        queue: nil
      ) { _ in
        relay.offer(.resumed)
      },
      notificationCenter.addObserver(
        forName:
          AVFoundation.AVCaptureSession.runtimeErrorNotification,
        object: session,
        queue: nil
      ) { notification in
        let nativeError = notification.userInfo?[
          AVFoundation.AVCaptureSessionErrorKey
        ] as? NSError
        relay.offer(
          .failed(
            .backendFailure(
              driverID: driverID,
              deviceID: deviceID,
              operation: .streaming,
              code: Int64(nativeError?.code ?? -1)
            )
          )
        )
      },
    ]
  }

  deinit {
    for token in observationTokens {
      notificationCenter.removeObserver(token)
    }
  }
}
