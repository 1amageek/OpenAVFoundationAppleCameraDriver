#import "AppleCameraExceptionBridge.h"

static const int64_t OAVDeviceConfigurationExceptionCode = -3;
static const int64_t OAVDeviceConfigurationRollbackExceptionCode = -4;
static const int64_t OAVFocusControlCode = 1;
static const int64_t OAVExposureControlCode = 2;
static const int64_t OAVWhiteBalanceControlCode = 3;

static BOOL OAVDurationIsSupported(
    AVCaptureDevice *device,
    CMTime duration
) {
  for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
    if (CMTimeCompare(duration, range.minFrameDuration) >= 0
        && CMTimeCompare(duration, range.maxFrameDuration) <= 0) {
      return YES;
    }
  }
  return NO;
}

OAVDeviceConfigurationResult OAVApplyDeviceConfiguration(
    AVCaptureDevice *device,
    AVCaptureDeviceInput *input,
    AVCaptureDeviceFormat *format,
    CMTime duration,
    BOOL durationEnabled,
    BOOL restoreAutoFrameRate,
    OAVModeControlConfiguration focus,
    OAVModeControlConfiguration exposure,
    OAVModeControlConfiguration whiteBalance,
    int64_t *errorCode
) {
  if (errorCode != NULL) {
    *errorCode = 0;
  }

  NSError *lockError = nil;
  if (![device lockForConfiguration:&lockError]) {
    if (errorCode != NULL) {
      *errorCode = lockError.code;
    }
    return OAVDeviceConfigurationResultLockFailure;
  }

  OAVDeviceConfigurationResult result =
      OAVDeviceConfigurationResultSuccess;
  BOOL stateCaptured = NO;
  AVCaptureDeviceFormat *originalFormat = nil;
  BOOL originalAutoFrameRateSupported = NO;
  BOOL targetAutoFrameRateSupported = NO;
  BOOL originalAutoFrameRateEnabled = NO;
  CMTime originalLockedDuration = kCMTimeInvalid;
  CMTime originalMinimumDuration = kCMTimeInvalid;
  CMTime originalMaximumDuration = kCMTimeInvalid;
  AVCaptureFocusMode originalFocusMode = AVCaptureFocusModeLocked;
  CGPoint originalFocusPoint = CGPointZero;
  AVCaptureExposureMode originalExposureMode =
      AVCaptureExposureModeLocked;
  CGPoint originalExposurePoint = CGPointZero;
  AVCaptureWhiteBalanceMode originalWhiteBalanceMode =
      AVCaptureWhiteBalanceModeLocked;

  @try {
    @try {
      originalFormat = device.activeFormat;
      if (@available(macOS 15.0, *)) {
        originalAutoFrameRateSupported =
            device.activeFormat.autoVideoFrameRateSupported;
        if (originalAutoFrameRateSupported) {
          originalAutoFrameRateEnabled =
              device.isAutoVideoFrameRateEnabled;
        }
      }
      if (@available(macOS 26.0, *)) {
        originalLockedDuration = input.activeLockedVideoFrameDuration;
      } else {
        originalMinimumDuration = device.activeVideoMinFrameDuration;
        originalMaximumDuration = device.activeVideoMaxFrameDuration;
      }
      originalFocusMode = device.focusMode;
      originalFocusPoint = device.focusPointOfInterest;
      originalExposureMode = device.exposureMode;
      originalExposurePoint = device.exposurePointOfInterest;
      originalWhiteBalanceMode = device.whiteBalanceMode;
      stateCaptured = YES;

      if (![device.formats containsObject:format]) {
        result = OAVDeviceConfigurationResultUnsupportedFormat;
      } else {
        device.activeFormat = format;
        if (@available(macOS 15.0, *)) {
          targetAutoFrameRateSupported =
              device.activeFormat.autoVideoFrameRateSupported;
        }
      }

      BOOL hasExplicitDuration;
      if (@available(macOS 26.0, *)) {
        hasExplicitDuration = CMTIME_IS_VALID(originalLockedDuration);
      } else {
        hasExplicitDuration =
            CMTIME_IS_VALID(originalMinimumDuration)
            || CMTIME_IS_VALID(originalMaximumDuration);
      }

      if (result == OAVDeviceConfigurationResultSuccess
          && targetAutoFrameRateSupported
          && device.isAutoVideoFrameRateEnabled
          && (durationEnabled || hasExplicitDuration)) {
        device.autoVideoFrameRateEnabled = NO;
      }

      if (result == OAVDeviceConfigurationResultSuccess) {
        if (@available(macOS 26.0, *)) {
          if (durationEnabled) {
            CMTime minimumDuration =
                device.minSupportedLockedVideoFrameDuration;
            if (!input.isLockedVideoFrameDurationSupported
                || !CMTIME_IS_VALID(minimumDuration)
                || !OAVDurationIsSupported(device, duration)
                || CMTimeCompare(duration, minimumDuration) < 0) {
              result =
                  OAVDeviceConfigurationResultUnsupportedFrameDuration;
            } else {
              input.activeLockedVideoFrameDuration = duration;
            }
          } else if (CMTIME_IS_VALID(originalLockedDuration)) {
            if (!input.isLockedVideoFrameDurationSupported) {
              result =
                  OAVDeviceConfigurationResultUnsupportedFrameDuration;
            } else {
              input.activeLockedVideoFrameDuration = kCMTimeInvalid;
            }
          }
        } else if (durationEnabled
                   && !OAVDurationIsSupported(device, duration)) {
          result =
              OAVDeviceConfigurationResultUnsupportedFrameDuration;
        } else if (durationEnabled || hasExplicitDuration) {
          CMTime appliedDuration =
              durationEnabled ? duration : kCMTimeInvalid;
          device.activeVideoMinFrameDuration = appliedDuration;
          device.activeVideoMaxFrameDuration = appliedDuration;
        }
      }

      if (result == OAVDeviceConfigurationResultSuccess
          && !durationEnabled
          && restoreAutoFrameRate
          && targetAutoFrameRateSupported
          && !device.isAutoVideoFrameRateEnabled) {
        device.autoVideoFrameRateEnabled = YES;
      }

      if (result == OAVDeviceConfigurationResultSuccess && focus.enabled) {
        AVCaptureFocusMode mode = (AVCaptureFocusMode)focus.mode;
        if (![device isFocusModeSupported:mode]
            || (focus.pointEnabled
                && !device.isFocusPointOfInterestSupported)) {
          if (errorCode != NULL) {
            *errorCode = OAVFocusControlCode;
          }
          result = OAVDeviceConfigurationResultUnsupportedControl;
        } else {
          if (focus.pointEnabled) {
            device.focusPointOfInterest =
                CGPointMake(focus.pointX, focus.pointY);
          }
          device.focusMode = mode;
        }
      }

      if (result == OAVDeviceConfigurationResultSuccess
          && exposure.enabled) {
        AVCaptureExposureMode mode =
            (AVCaptureExposureMode)exposure.mode;
        if (![device isExposureModeSupported:mode]
            || (exposure.pointEnabled
                && !device.isExposurePointOfInterestSupported)) {
          if (errorCode != NULL) {
            *errorCode = OAVExposureControlCode;
          }
          result = OAVDeviceConfigurationResultUnsupportedControl;
        } else {
          if (exposure.pointEnabled) {
            device.exposurePointOfInterest =
                CGPointMake(exposure.pointX, exposure.pointY);
          }
          device.exposureMode = mode;
        }
      }

      if (result == OAVDeviceConfigurationResultSuccess
          && whiteBalance.enabled) {
        AVCaptureWhiteBalanceMode mode =
            (AVCaptureWhiteBalanceMode)whiteBalance.mode;
        if (![device isWhiteBalanceModeSupported:mode]) {
          if (errorCode != NULL) {
            *errorCode = OAVWhiteBalanceControlCode;
          }
          result = OAVDeviceConfigurationResultUnsupportedControl;
        } else {
          device.whiteBalanceMode = mode;
        }
      }
    } @catch (NSException *exception) {
      if (errorCode != NULL) {
        *errorCode = OAVDeviceConfigurationExceptionCode;
      }
      result = OAVDeviceConfigurationResultException;
    }

    if (result != OAVDeviceConfigurationResultSuccess && stateCaptured) {
      BOOL rollbackFailed = NO;
      @try {
        device.activeFormat = originalFormat;
        if (@available(macOS 26.0, *)) {
          if (input.isLockedVideoFrameDurationSupported) {
            input.activeLockedVideoFrameDuration =
                originalLockedDuration;
          } else if (CMTIME_IS_VALID(originalLockedDuration)) {
            rollbackFailed = YES;
          }
        } else {
          device.activeVideoMinFrameDuration = originalMinimumDuration;
          device.activeVideoMaxFrameDuration = originalMaximumDuration;
        }
        if (device.isFocusPointOfInterestSupported) {
          device.focusPointOfInterest = originalFocusPoint;
        }
        if ([device isFocusModeSupported:originalFocusMode]) {
          device.focusMode = originalFocusMode;
        }
        if (device.isExposurePointOfInterestSupported) {
          device.exposurePointOfInterest = originalExposurePoint;
        }
        if ([device isExposureModeSupported:originalExposureMode]) {
          device.exposureMode = originalExposureMode;
        }
        if ([device isWhiteBalanceModeSupported:originalWhiteBalanceMode]) {
          device.whiteBalanceMode = originalWhiteBalanceMode;
        }
        if (originalAutoFrameRateSupported
            && device.isAutoVideoFrameRateEnabled
                != originalAutoFrameRateEnabled) {
          device.autoVideoFrameRateEnabled =
              originalAutoFrameRateEnabled;
        }
      } @catch (NSException *exception) {
        rollbackFailed = YES;
      }
      if (rollbackFailed) {
        if (errorCode != NULL) {
          *errorCode = OAVDeviceConfigurationRollbackExceptionCode;
        }
        result = OAVDeviceConfigurationResultRollbackFailure;
      }
    }
  } @finally {
    [device unlockForConfiguration];
  }

  return result;
}
