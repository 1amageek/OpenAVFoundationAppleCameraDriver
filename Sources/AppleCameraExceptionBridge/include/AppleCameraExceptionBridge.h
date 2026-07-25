#ifndef APPLE_CAMERA_EXCEPTION_BRIDGE_H
#define APPLE_CAMERA_EXCEPTION_BRIDGE_H

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, OAVDeviceConfigurationResult) {
  OAVDeviceConfigurationResultSuccess = 0,
  OAVDeviceConfigurationResultUnsupportedFormat = 1,
  OAVDeviceConfigurationResultUnsupportedFrameDuration = 2,
  OAVDeviceConfigurationResultUnsupportedControl = 3,
  OAVDeviceConfigurationResultLockFailure = 4,
  OAVDeviceConfigurationResultException = 5,
  OAVDeviceConfigurationResultRollbackFailure = 6,
};

typedef struct {
  BOOL enabled;
  NSInteger mode;
  BOOL pointEnabled;
  double pointX;
  double pointY;
} OAVModeControlConfiguration;

FOUNDATION_EXPORT OAVDeviceConfigurationResult OAVApplyDeviceConfiguration(
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
);

NS_ASSUME_NONNULL_END

#endif
