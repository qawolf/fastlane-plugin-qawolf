#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Media injection configuration model
 */
@interface MediaInjectionConfig : NSObject

@property (nonatomic, strong, nullable) NSString *data;  // URL, file path, or data URI
@property (nonatomic, strong, nullable) NSString *type;  // "image", "video", or "audio" (defaults to "image" if nil)
@property (nonatomic, assign) NSTimeInterval delaySeconds;  // Delay before starting playback (default 0.0)

// Clockwise rotation applied to image-type sources before injection. Accepts
// 0 / 90 / 180 / 270. Needed because iPhone photos captured via the
// AVCapturePhotoOutput BGRA(TIFF) path land on disk in sensor-native
// orientation (landscape pixels even when the phone was held portrait) with
// no EXIF Orientation tag, so when replayed through a portrait preview the
// subject appears on its side.
@property (nonatomic, assign) NSInteger rotation;

+ (instancetype _Nullable)configFromQAWolfFolder;
- (BOOL)isValid;
- (BOOL)isImage;
- (BOOL)isAudio;
- (NSURL * _Nullable)resolvedURL;

@end

// Keep VideoInjectionConfig for backward compatibility
@interface VideoInjectionConfig : MediaInjectionConfig
@property (nonatomic, strong, nullable) NSString *videoPath;
@end

/**
 * Singleton manager that manages media injection configuration and timing
 * Watches config file and notifies MockCamera and MockMicrophone of changes
 */
@interface MediaInjectionConfigManager : NSObject

/**
 * Singleton instance
 */
+ (instancetype)shared;

/**
 * Current configuration
 */
@property (nonatomic, readonly, nullable) MediaInjectionConfig *currentConfig;

/**
 * Timestamp when the current config was loaded (used as time zero for playback)
 */
@property (nonatomic, readonly) CFTimeInterval configLoadTime;

/**
 * Map device time to media timeline time with looping
 * deviceTime: monotonically increasing device timestamp
 * duration: media duration for looping calculation
 * Returns: time within the media timeline [0, duration)
 */
- (CMTime)mapDeviceTime:(CMTime)deviceTime toDuration:(CMTime)duration;

/**
 * Start watching config file for changes
 */
- (void)startWatching;

/**
 * Stop watching config file
 */
- (void)stopWatching;

/**
 * Reload now if media.json changed since the last check (the timer checks every 2 s)
 */
- (void)checkConfigFileChanges;

@end

NS_ASSUME_NONNULL_END
