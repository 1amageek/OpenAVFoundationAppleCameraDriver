import OpenAVFoundationDriver

actor AppleCameraStream: CaptureStream {
    nonisolated let deviceID: CaptureDeviceID

    private let runtime: AppleCameraRuntime

    init(
        deviceID: CaptureDeviceID,
        runtime: AppleCameraRuntime
    ) {
        self.deviceID = deviceID
        self.runtime = runtime
    }

    func start() throws(CaptureDriverError) {
        try runtime.start()
    }

    func shutdown() throws(CaptureDriverError) {
        try runtime.stop()
    }
}
