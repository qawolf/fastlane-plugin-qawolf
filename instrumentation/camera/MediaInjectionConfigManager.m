#import "MediaInjectionConfigManager.h"
#import "utils.h"
#import "MockMediaSource.h"
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Configuration file name
static NSString *const kMediaConfigFileName = @"media.json";

#pragma mark - MediaInjectionConfig

@interface MediaInjectionConfig ()
// The temporary file a data URI was decoded to, and the data it came from.
@property (nonatomic, strong, nullable) NSURL *dataURIFileURL;
@property (nonatomic, strong, nullable) NSString *dataURIFileSource;
@end

@implementation MediaInjectionConfig

+ (instancetype)configFromQAWolfFolder {
    NSString *qawolfFolder = [Utils getQAWolfFolder];
    NSString *configPath = [qawolfFolder stringByAppendingPathComponent:kMediaConfigFileName];

    NSLog(@"QAWolf:MediaInjection: Looking for config at: %@", configPath);

    if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
        NSLog(@"QAWolf:MediaInjection: No config file found");
        return nil;
    }

    NSData *jsonData = [NSData dataWithContentsOfFile:configPath];
    NSError *error;
    NSDictionary *configDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                               options:kNilOptions
                                                                 error:&error];

    if (error) {
        NSLog(@"QAWolf:MediaInjection: Error parsing config: %@", error);
        return nil;
    }

    NSLog(@"QAWolf:MediaInjection: Config loaded: %@", configDict);

    MediaInjectionConfig *config = [[MediaInjectionConfig alloc] init];

    // Support both new format {"data": "...", "type": "..."} and old format {"videoPath": "..."}
    config.data = configDict[@"data"] ?: configDict[@"videoPath"];
    config.type = configDict[@"type"]; // nil defaults to "image"

    // Parse optional delaySeconds (defaults to 0.0)
    NSNumber *delayNumber = configDict[@"delaySeconds"];
    config.delaySeconds = delayNumber ? [delayNumber doubleValue] : 0.0;

    // Rotation (clockwise degrees). Normalize: only 0/90/180/270 are meaningful.
    NSNumber *rotNumber = configDict[@"rotation"];
    NSInteger rot = rotNumber ? [rotNumber integerValue] : 0;
    rot = ((rot % 360) + 360) % 360;  // normalize negatives
    if (rot != 0 && rot != 90 && rot != 180 && rot != 270) rot = 0;
    config.rotation = rot;

    // Resolve relative paths (not URLs or data URIs)
    if (config.data &&
        ![config.data hasPrefix:@"/"] &&
        ![config.data hasPrefix:@"http://"] &&
        ![config.data hasPrefix:@"https://"] &&
        ![config.data hasPrefix:@"data:"] &&
        ![config.data hasPrefix:@"file://"]) {
        config.data = [qawolfFolder stringByAppendingPathComponent:config.data];
    }

    NSLog(@"QAWolf:MediaInjection: Type: %@, Data: %@, DelaySeconds: %.2f, Rotation: %ld",
          config.type ?: @"image",
          config.data,
          config.delaySeconds,
          (long)config.rotation);

    return config;
}

- (BOOL)isImage {
    // Default to image if type is not specified
    return !self.type || [self.type isEqualToString:@"image"];
}

- (BOOL)isAudio {
    return self.type && [self.type isEqualToString:@"audio"];
}

- (NSURL *)resolvedURL {
    if (!self.data) return nil;

    // Handle data: URIs - create temporary file. isValid runs on every injection check,
    // so decode once: a multi-MB WAV decoded per call hangs the app.
    if ([self.data hasPrefix:@"data:"]) {
        @synchronized (self) {
            if (self.dataURIFileSource != self.data) {
                self.dataURIFileURL = [self writeDataURIToTemporaryFile];
                self.dataURIFileSource = self.data;
            }
            return self.dataURIFileURL;
        }
    }

    // Handle URLs
    if ([self.data hasPrefix:@"http://"] ||
        [self.data hasPrefix:@"https://"] ||
        [self.data hasPrefix:@"file://"]) {
        return [NSURL URLWithString:self.data];
    }

    // Handle file paths
    return [NSURL fileURLWithPath:self.data];
}

- (NSURL *)writeDataURIToTemporaryFile {
    NSArray *components = [self.data componentsSeparatedByString:@","];
    if (components.count != 2) {
        return nil;
    }
    NSData *mediaData = [[NSData alloc] initWithBase64EncodedString:components[1]
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!mediaData) {
        return nil;
    }

    // AVFoundation picks its parser from the extension: WAV bytes named .mp4 do not load.
    NSString *extension = @"jpg";
    if (![self isImage]) {
        NSString *mimeType = [[components[0] substringFromIndex:5] componentsSeparatedByString:@";"].firstObject;
        extension = (mimeType.length > 0 ? [UTType typeWithMIMEType:mimeType].preferredFilenameExtension : nil) ?: @"mp4";
    }
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"qawolf_media.%@", extension]];
    [mediaData writeToFile:tempPath atomically:YES];
    return [NSURL fileURLWithPath:tempPath];
}

- (BOOL)isValid {
    if (!self.data) return NO;

    // For data URIs, check if we can parse them
    if ([self.data hasPrefix:@"data:"]) {
        return [self resolvedURL] != nil;
    }

    // For remote URLs, assume valid (will fail during load if not)
    if ([self.data hasPrefix:@"http://"] || [self.data hasPrefix:@"https://"]) {
        return YES;
    }

    // For local files, check existence
    NSURL *url = [self resolvedURL];
    return url && [[NSFileManager defaultManager] fileExistsAtPath:url.path];
}

@end

#pragma mark - VideoInjectionConfig (Backward Compatibility)

@implementation VideoInjectionConfig

+ (instancetype)configFromQAWolfFolder {
    // Use parent implementation
    return [super configFromQAWolfFolder];
}

- (NSString *)videoPath {
    return self.data;
}

- (void)setVideoPath:(NSString *)videoPath {
    self.data = videoPath;
    self.type = @"video";
}

@end

#pragma mark - MediaInjectionConfigManager

@interface MediaInjectionConfigManager ()
@property (nonatomic, strong, nullable) MediaInjectionConfig *currentConfig;
@property (nonatomic, assign) CFTimeInterval configLoadTime;
@property (nonatomic, strong, nullable) NSFileManager *fileManager;
@property (nonatomic, strong, nullable) NSFileCoordinator *fileCoordinator;
@property (nonatomic, strong, nullable) NSTimer *configWatchTimer;
@property (nonatomic, strong, nullable) NSDate *lastConfigModified;
@property (nonatomic, assign) BOOL isWatching;
@end

@implementation MediaInjectionConfigManager

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:ConfigManager: +load called, will initialize after MockMediaSource");
        // Delay initialization to ensure MockMediaSource is ready
        dispatch_async(dispatch_get_main_queue(), ^{
            [MediaInjectionConfigManager shared];
        });
    });
}

+ (instancetype)shared {
    static MediaInjectionConfigManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaInjectionConfigManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.fileManager = [NSFileManager defaultManager];
        self.fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        self.isWatching = NO;
        self.configLoadTime = 0;
        // Start watching automatically
        [self startWatching];
    }
    return self;
}

- (void)startWatching {
    if (self.isWatching) {
        return;
    }

    NSLog(@"QAWolf:Coordinator: Starting config file watching");

    // Load initial config
    [self reloadConfiguration];

    // Set up file system watching for config changes
    [self setupConfigFileWatcher];

    self.isWatching = YES;
}

- (void)reloadConfiguration {
    MediaInjectionConfig *newConfig = [MediaInjectionConfig configFromQAWolfFolder];

    // Early exit if config hasn't changed
    if ([self isConfig:newConfig equalTo:self.currentConfig]) {
        return;
    }

    self.currentConfig = newConfig;
    self.configLoadTime = CACurrentMediaTime();

    // Prepare config (download remote files if needed) before passing to MockMediaSource
    [self prepareConfigForPlayback:newConfig completion:^(MediaInjectionConfig *preparedConfig) {
        if (!preparedConfig) {
            return;
        }

        [[MockMediaSource sharedInstance] reloadWithConfig:preparedConfig];
    }];
}

#pragma mark - Config Preparation

- (void)prepareConfigForPlayback:(MediaInjectionConfig *)config completion:(void (^)(MediaInjectionConfig *preparedConfig))completion {
    if (!config) {
        completion(nil);
        return;
    }

    NSURL *url = [config resolvedURL];
    if (!url) {
        completion(nil);
        return;
    }

    // Audio files don't need any conversion - use directly
    if ([config isAudio]) {
        NSLog(@"QAWolf:ConfigManager: Audio-only config, no conversion needed");
        [[MockMediaSource sharedInstance] setOriginalImage:nil];
        completion(config);
        return;
    }

    // Download remote files, then convert images to video
    if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
        [self downloadRemoteFile:url forConfig:config completion:^(MediaInjectionConfig *downloadedConfig) {
            if (!downloadedConfig) {
                completion(nil);
                return;
            }
            // Convert image to video if needed after download
            [self convertImageToVideoIfNeeded:downloadedConfig completion:completion];
        }];
        return;
    }

    // Convert image to video if needed for local files
    [self convertImageToVideoIfNeeded:config completion:completion];
}

- (void)convertImageToVideoIfNeeded:(MediaInjectionConfig *)config completion:(void (^)(MediaInjectionConfig *preparedConfig))completion {
    // If it's not an image, clear any stashed image and pass-through.
    if (![config isImage]) {
        [[MockMediaSource sharedInstance] setOriginalImage:nil];
        completion(config);
        return;
    }

    NSLog(@"QAWolf:ConfigManager: Converting image to video for playback");

    NSURL *imageURL = [config resolvedURL];
    if (!imageURL) {
        completion(nil);
        return;
    }

    // Load the image
    NSData *imageData = [NSData dataWithContentsOfURL:imageURL];
    UIImage *image = [UIImage imageWithData:imageData];
    if (!image) {
        NSLog(@"QAWolf:ConfigManager: Failed to load image from URL");
        completion(nil);
        return;
    }

    // Bake EXIF orientation into the pixel data. Source TIFFs / JPEGs
    // commonly carry an Orientation tag (e.g. tag = 6 / .right for a
    // landscape sensor capture meant to display portrait). UIImage
    // surfaces this via -imageOrientation but does NOT apply it to the
    // underlying CGImage — CGImage is always raw pixel-major. Downstream
    // we use CGImageGetWidth/Height to size the delivery CVPixelBuffer
    // and to draw into it, which means the EXIF rotation gets silently
    // dropped at the CGImage boundary unless we redraw the pixels here.
    //
    // Result of the bake: a UIImage whose imageOrientation = Up and
    // whose CGImage's pixel-major dims match what the user actually
    // sees in Photos.app / Quick Look. From this point on every consumer
    // (live VDO, SBDL preview, photo encoder) gets correctly-oriented
    // pixels without needing config.rotation to compensate.
    if (image.imageOrientation != UIImageOrientationUp) {
        CGSize bakedSize = image.size;  // already orientation-aware
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1.0;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                                             initWithSize:bakedSize format:fmt];
        UIImage *baked = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [image drawInRect:CGRectMake(0, 0, bakedSize.width, bakedSize.height)];
        }];
        if (baked) image = baked;
    }

    // Stash the EXIF-baked image on MockMediaSource. Fed in native sensor
    // orientation to: the live preview pipeline, the host app's VDO
    // delegate (so any downstream corner / blur / glare CoreML models
    // see the document in the training geometry), and the photo-capture
    // substitution path. Any visual-only rotation requested by
    // config.rotation is applied downstream — SBDL preview pre-rotates
    // via vImage; the photo encoder tags the TIFF with
    // kCGImagePropertyOrientation so review UIs auto-rotate on display.
    [[MockMediaSource sharedInstance] setOriginalImage:image];

    // Create video from image
    NSString *videoPath = [self createVideoFromImage:image];
    if (!videoPath) {
        NSLog(@"QAWolf:ConfigManager: Failed to create video from image");
        completion(nil);
        return;
    }

    // Create new config with video file. Carry every other field forward
    // from the original image config so downstream consumers (MockMediaSource,
    // SBDL preview-rotation, photo encoder) see the user's settings even
    // after the image-to-video conversion.
    MediaInjectionConfig *videoConfig = [[MediaInjectionConfig alloc] init];
    videoConfig.data = videoPath;
    videoConfig.type = @"video";
    videoConfig.rotation = config.rotation;
    videoConfig.delaySeconds = config.delaySeconds;

    NSLog(@"QAWolf:ConfigManager: Successfully converted image to video: %@ (rotation=%ld, delaySeconds=%.2f)",
          videoPath, (long)videoConfig.rotation, videoConfig.delaySeconds);
    completion(videoConfig);
}

- (NSString *)createVideoFromImage:(UIImage *)image {
    // Create a temporary video file with single frame
    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qawolf_image_video.mp4"];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

    // Remove existing file
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    NSError *error;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL
                                                      fileType:AVFileTypeQuickTimeMovie
                                                         error:&error];
    if (error) {
        NSLog(@"QAWolf:ConfigManager: Failed to create asset writer: %@", error);
        return nil;
    }

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(image.size.width),
        AVVideoHeightKey: @(image.size.height)
    };

    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                         outputSettings:videoSettings];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
                                                     assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                     sourcePixelBufferAttributes:nil];

    [writer addInput:writerInput];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    // Convert image to pixel buffer and create a short video with multiple frames
    CVPixelBufferRef pixelBuffer = [self pixelBufferFromImage:image];
    if (pixelBuffer) {
        // Create a few frames (0.5 second at 30fps) showing the same image
        int frameCount = 15;
        for (int i = 0; i < frameCount; i++) {
            CMTime frameTime = CMTimeMake(i, 30); // 30fps

            // Wait for the adaptor to be ready for more media data
            while (!writerInput.readyForMoreMediaData) {
                [NSThread sleepForTimeInterval:0.01]; // Wait 10ms
            }

            BOOL success = [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
            if (!success) {
                NSLog(@"QAWolf:ConfigManager: Failed to append pixel buffer at frame %d", i);
                break;
            }
        }
        CVPixelBufferRelease(pixelBuffer);
    }

    [writerInput markAsFinished];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (writer.status != AVAssetWriterStatusCompleted) {
        NSLog(@"QAWolf:ConfigManager: Asset writer failed: %@", writer.error);
        return nil;
    }

    return outputPath;
}

- (CVPixelBufferRef)pixelBufferFromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    CGSize frameSize = CGSizeMake(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));

    // Use the same pixel format as video output for consistency
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          frameSize.width,
                                          frameSize.height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          (__bridge CFDictionaryRef)options,
                                          &pixelBuffer);

    if (status != kCVReturnSuccess) {
        NSLog(@"QAWolf:ConfigManager: Failed to create YUV pixel buffer, falling back to RGB");
        // Fallback to RGB if YUV creation fails
        status = CVPixelBufferCreate(kCFAllocatorDefault,
                                    frameSize.width,
                                    frameSize.height,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)options,
                                    &pixelBuffer);
        if (status != kCVReturnSuccess) {
            return NULL;
        }
    }

    // For YUV pixel buffers, we need to use Core Image for proper conversion
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        // Use Core Image to convert RGB image to YUV pixel buffer
        CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
        CIContext *context = [CIContext context];

        [context render:ciImage toCVPixelBuffer:pixelBuffer];

        return pixelBuffer;
    } else {
        // RGB pixel buffer - use the original method
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pxdata,
                                                     frameSize.width,
                                                     frameSize.height,
                                                     8,
                                                     CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                     colorSpace,
                                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);

        CGContextDrawImage(context, CGRectMake(0, 0, frameSize.width, frameSize.height), cgImage);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);

        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

        return pixelBuffer;
    }
}

- (void)downloadRemoteFile:(NSURL *)remoteURL forConfig:(MediaInjectionConfig *)config completion:(void (^)(MediaInjectionConfig *preparedConfig))completion {
    NSString *extension = [config isImage] ? @"jpg" : @"mp4";
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"qawolf_downloaded_media.%@", extension]];
    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];

    // Remove existing file if present
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];

    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:remoteURL
                                                                             completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil);
            return;
        }

        if (!location) {
            completion(nil);
            return;
        }

        NSError *moveError;
        BOOL success = [[NSFileManager defaultManager] moveItemAtURL:location toURL:tempURL error:&moveError];

        if (!success || moveError) {
            completion(nil);
            return;
        }

        // Create new config with local file path. Carry rotation and
        // delaySeconds forward so remote media respects the same user
        // settings as local media — without this, equality also misfires
        // (isConfig:equalTo: compares both fields) and remote configs can
        // appear to "change" on every poll.
        MediaInjectionConfig *preparedConfig = [[MediaInjectionConfig alloc] init];
        preparedConfig.data = tempPath;
        preparedConfig.type = config.type;
        preparedConfig.rotation = config.rotation;
        preparedConfig.delaySeconds = config.delaySeconds;

        completion(preparedConfig);
    }];

    [downloadTask resume];
}

- (BOOL)isConfig:(MediaInjectionConfig *)config1 equalTo:(MediaInjectionConfig *)config2 {
    if (!config1 && !config2) return YES;
    if (!config1 || !config2) return NO;
    NSString *type1 = config1.type ?: @"image";
    NSString *type2 = config2.type ?: @"image";
    BOOL dataEqual = (config1.data == config2.data) ||
                     (config1.data && config2.data && [config1.data isEqualToString:config2.data]);
    return dataEqual &&
           [type1 isEqualToString:type2] &&
           config1.rotation == config2.rotation &&
           config1.delaySeconds == config2.delaySeconds;
}

- (CMTime)mapDeviceTime:(CMTime)deviceTime toDuration:(CMTime)duration {
    if (CMTIME_IS_INVALID(duration) || CMTimeGetSeconds(duration) <= 0) {
        return kCMTimeZero;
    }

    // Get elapsed time since config was loaded
    Float64 deviceSeconds = CMTimeGetSeconds(deviceTime);
    Float64 elapsedSinceLoad = deviceSeconds - self.configLoadTime;

    // Handle negative elapsed (shouldn't happen, but be safe)
    if (elapsedSinceLoad < 0) {
        elapsedSinceLoad = 0;
    }

    Float64 durationSeconds = CMTimeGetSeconds(duration);

    // Map to media timeline using modulo for looping
    Float64 mediaSeconds = fmod(elapsedSinceLoad, durationSeconds);

    return CMTimeMakeWithSeconds(mediaSeconds, deviceTime.timescale);
}

#pragma mark - Config File Watching

- (void)setupConfigFileWatcher {
    NSString *qawolfFolder = [Utils getQAWolfFolder];
    NSString *configPath = [qawolfFolder stringByAppendingPathComponent:kMediaConfigFileName];
    NSURL *configURL = [NSURL fileURLWithPath:configPath];

    // Create the config directory if it doesn't exist
    NSString *configDir = [configPath stringByDeletingLastPathComponent];
    [self.fileManager createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Get initial modification date
    [self updateLastModifiedDate:configURL];

    // Set up timer to check for file changes every 2 seconds
    self.configWatchTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                             target:self
                                                           selector:@selector(checkConfigFileChanges)
                                                           userInfo:nil
                                                            repeats:YES];

    NSLog(@"QAWolf:Coordinator: File watching setup for: %@", configPath);
}

- (void)updateLastModifiedDate:(NSURL *)configURL {
    NSError *error;
    NSDate *modificationDate;
    [configURL getResourceValue:&modificationDate forKey:NSURLContentModificationDateKey error:&error];
    if (!error) {
        self.lastConfigModified = modificationDate;
    }
}

- (void)checkConfigFileChanges {
    NSString *qawolfFolder = [Utils getQAWolfFolder];
    NSString *configPath = [qawolfFolder stringByAppendingPathComponent:kMediaConfigFileName];
    NSURL *configURL = [NSURL fileURLWithPath:configPath];

    // First check if file exists
    if (![self.fileManager fileExistsAtPath:configPath]) {
        // File was deleted - clean up if we had a config before
        if (self.currentConfig != nil) {
            NSLog(@"QAWolf:Coordinator: Config file deleted, stopping media injection");
            self.currentConfig = nil;
            self.lastConfigModified = nil;
            self.configLoadTime = 0;
            [[MockMediaSource sharedInstance] reloadWithConfig:nil];
        }
        return;
    }

    __block BOOL shouldReload = NO;
    NSError *coordinatorError;

    [self.fileCoordinator coordinateReadingItemAtURL:configURL
                                              options:NSFileCoordinatorReadingWithoutChanges
                                                error:&coordinatorError
                                           byAccessor:^(NSURL *readingURL) {
        NSError *error;
        NSDate *currentModified;
        [readingURL getResourceValue:&currentModified forKey:NSURLContentModificationDateKey error:&error];

        if (!error && currentModified) {
            if (!self.lastConfigModified || [currentModified compare:self.lastConfigModified] == NSOrderedDescending) {
                NSLog(@"QAWolf:Coordinator: Config file modified, will reload");
                self.lastConfigModified = currentModified;
                shouldReload = YES;
            }
        } else {
            NSLog(@"QAWolf:Coordinator: Error reading config file modification date: %@", error);
        }
    }];

    if (coordinatorError) {
        NSLog(@"QAWolf:Coordinator: Error coordinating file access: %@", coordinatorError);
    }

    if (shouldReload) {
        [self reloadConfiguration];
    }
}

- (void)stopWatching {
    if (!self.isWatching) {
        return;
    }

    NSLog(@"QAWolf:Coordinator: Stopping config file watching");

    if (self.configWatchTimer) {
        [self.configWatchTimer invalidate];
        self.configWatchTimer = nil;
    }

    self.isWatching = NO;
}

@end
