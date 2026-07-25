import CoreMedia

enum AppleCameraFrameDurationBridge {
  static func frameDuration(
    for frameRate: Double
  ) -> CoreMedia.CMTime {
    CMTimeMakeWithSeconds(
      1.0 / frameRate,
      preferredTimescale: 1_000_000_000
    )
  }
}
