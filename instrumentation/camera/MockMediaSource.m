#import "MockMediaSource.h"
#import "utils.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import "../QWAudioConvert.h"
#import "../audiounit/QWAudioUnitBridge.h"

// File-scope log counters — reset in stopMediaPlayback so each recording session logs diagnostics
static int sAudioDeliverWaitCount = 0;
static int sAudioDeliverVideoWaitCount = 0;
static int sAudioDeliverNoDelegateCount = 0;
static int sAudioDeliverCount = 0;
static int sAudioTapFailCount = 0;
static int sAudioTapProcessCount = 0;

// Context structure for audio tap
typedef struct {
    __unsafe_unretained MockMediaSource *source;
    AudioStreamBasicDescription processingFormat;
    AudioConverterRef converter;
    AudioStreamBasicDescription outputFormat;
    BOOL hasConverter;
} AudioTapContext;

// Audio tap callbacks
static void audioTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut);
static void audioTapFinalize(MTAudioProcessingTapRef tap);
static void audioTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat);
static void audioTapUnprepare(MTAudioProcessingTapRef tap);
static void audioTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                            MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                            CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut);

#pragma mark - Delegate Proxy

/**
 * Proxy object that MockMediaSource strongly retains.
 * Holds a __weak ref to the actual delegate. When the delegate deallocates,
 * the weak ref nils out atomically — no dangling pointers, no crashes.
 */
@interface MockMediaSourceDelegateProxy : NSObject
@property (nonatomic, weak) id<MockMediaSourceVideoDelegate> target;
@property (nonatomic, assign) NSUInteger targetIdentity;
- (instancetype)initWithTarget:(id<MockMediaSourceVideoDelegate>)target;
- (BOOL)deliverSampleBuffer:(CMSampleBufferRef)sampleBuffer fromSource:(MockMediaSource *)source;
- (BOOL)deliverStateChange:(BOOL)isEnabled fromSource:(MockMediaSource *)source;
@end

@implementation MockMediaSourceDelegateProxy

- (instancetype)initWithTarget:(id<MockMediaSourceVideoDelegate>)target {
    self = [super init];
    if (self) {
        _target = target;
        _targetIdentity = (NSUInteger)(__bridge void *)target;
    }
    return self;
}

- (BOOL)deliverSampleBuffer:(CMSampleBufferRef)sampleBuffer fromSource:(MockMediaSource *)source {
    id<MockMediaSourceVideoDelegate> strongTarget = self.target;
    if (!strongTarget) return NO;
    [strongTarget mockMediaSource:source didOutputSampleBuffer:sampleBuffer];
    return YES;
}

- (BOOL)deliverStateChange:(BOOL)isEnabled fromSource:(MockMediaSource *)source {
    id<MockMediaSourceVideoDelegate> strongTarget = self.target;
    if (!strongTarget) return NO;
    if ([strongTarget respondsToSelector:@selector(mockMediaSource:didChangeInjectionState:)]) {
        [strongTarget mockMediaSource:source didChangeInjectionState:isEnabled];
    }
    return YES;
}

@end

#pragma mark - MockMediaSource

@interface MockMediaSource ()
// Configuration
@property (nonatomic, strong, nullable) MediaInjectionConfig *currentConfig;
@property (nonatomic, strong, nullable) AVAsset *currentAsset;

// AVPlayer resources
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property (nonatomic, strong, nullable) id timeObserver;
@property (nonatomic, assign) CMTime mediaDuration;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) NSUInteger reassertGeneration; // coalescing for -reassertPlaybackIfNeeded:

// Video output resources
@property (nonatomic, strong, nullable) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, strong, nullable) dispatch_queue_t videoQueue;
@property (nonatomic, assign, nullable) CVPixelBufferRef latestVideoFrame;

// Audio tap resources
@property (nonatomic, assign) MTAudioProcessingTapRef audioTap;
@property (nonatomic, strong, nullable) AVMutableAudioMix *audioMix;
@property (nonatomic, strong, nullable) NSDictionary *requestedAudioSettings;

@property (nonatomic, assign) AudioStreamBasicDescription audioTapFormat;
@property (nonatomic, assign) BOOL audioTapFormatReady;
@property (nonatomic, assign, readwrite) BOOL targetAudioFormatReady;

// Timestamp tracking
@property (nonatomic, assign) CFAbsoluteTime playbackStartTime;

// Playback state tracking
@property (nonatomic, assign) BOOL waitingForRecordingStart;
@property (nonatomic, assign) BOOL hasVideo;
@property (nonatomic, assign) BOOL hasAudio;
@property (nonatomic, assign, nullable) CVPixelBufferRef placeholderFrame;

// Pre-rendered CVPixelBuffer for image-type configs — built lazily from
// originalImage.CGImage. Delivered on every display-link tick so any
// downstream ML gates (blur / corner / glare detectors typical in
// document-scanning SDKs) see the original crisp pixels rather than
// H.264-blurred ones.
@property (nonatomic, assign, nullable) CVPixelBufferRef originalPixelBuffer;

// Video delegates via proxy objects (strongly retained proxies with weak refs to targets)
@property (nonatomic, strong) NSMutableArray<MockMediaSourceDelegateProxy *> *videoDelegateProxies;

// Video capture delegate (push mode — like audio injection)
@property (nonatomic, weak, nullable) id<AVCaptureVideoDataOutputSampleBufferDelegate> videoCaptureDelegate;
@property (nonatomic, strong, nullable) AVCaptureVideoDataOutput *videoCaptureOutput;
@property (nonatomic, strong, nullable) dispatch_queue_t videoCaptureQueue;
@property (nonatomic, assign) CGSize videoCaptureTargetSize; // camera resolution for scaling
@property (nonatomic, strong, nullable) CIContext *videoCaptureScaleContext;
@property (nonatomic, assign, nullable) CVPixelBufferRef videoCaptureScaledBuffer;

// Camera intrinsic matrix cached from real frames — see cacheCameraIntrinsicMatrix:.
// Stamped onto delivered sample buffers so apps that consult
// kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix see the expected data.
@property (atomic, strong, nullable) NSData *cachedCameraIntrinsicMatrix;

// Full propagating-attachments dict harvested from real sample buffers
// (Orientation, DPIWidth, DPIHeight, {Exif}, {TIFF}, {MakerApple}, …).
// Applied verbatim onto injected sample buffers.
@property (atomic, strong, nullable) NSDictionary *cachedCameraSampleBufferAttachments;

// Audio delegates (weak references to avoid retain cycles)
@property (nonatomic, weak, nullable) id<AVCaptureAudioDataOutputSampleBufferDelegate> audioDelegate;
@property (nonatomic, strong, nullable) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong, nullable) dispatch_queue_t audioCallbackQueue;
@end

@implementation MockMediaSource

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:MockMediaSource: +load called, initializing singleton");
        [MockMediaSource sharedInstance];
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mediaDuration = kCMTimeZero;
        _isPlaying = NO;
        _playbackStartTime = 0;
        _waitingForRecordingStart = NO;
        _hasVideo = NO;
        _placeholderFrame = NULL;
        _videoQueue = dispatch_queue_create("com.qawolf.media.player", DISPATCH_QUEUE_SERIAL);
        _videoDelegateProxies = [NSMutableArray new];
    }
    return self;
}

+ (instancetype)sharedInstance {
    static MockMediaSource *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:MockMediaSource: Creating singleton instance");
        instance = [[MockMediaSource alloc] init];
    });
    return instance;
}

- (void)dealloc {
    [self cleanup];
}

#pragma mark - Configuration

- (void)reloadWithConfig:(MediaInjectionConfig *)config {
    BOOL wasEnabled = [self isMediaInjectionEnabled];

    [self cleanupMediaResources];
    self.currentConfig = config;

    // NOTE: Do NOT reset originalImage here. It is owned by
    // MediaInjectionConfigManager, which sets it BEFORE calling this method
    // (via prepareConfigForImagePlayback). Clearing here nulls out the
    // just-populated value. ConfigManager clears it explicitly when
    // transitioning to a non-image-type config.
    // We do release the pre-rendered pixel buffer since it's lazily
    // rebuilt on first display-link tick and caches stale dims otherwise.
    if (self.originalPixelBuffer) {
        CVPixelBufferRelease(self.originalPixelBuffer);
        self.originalPixelBuffer = NULL;
    }

    // Wait for delegate setup to start playback
    self.waitingForRecordingStart = YES;
    NSLog(@"QAWolf:MockMediaSource: Config loaded - playback will start when delegates are registered");

    // Early exit if config is invalid
    if (!config || ![config isValid]) {
        NSLog(@"QAWolf:MockMediaSource: Invalid config, media injection disabled");

        // Notify that injection was disabled (if it was previously enabled)
        if (wasEnabled) {
            [self notifyDelegateOfStateChange:NO];
        }
        return;
    }

    NSURL *mediaURL = [config resolvedURL];
    if (!mediaURL) {
        NSLog(@"QAWolf:MockMediaSource: No media URL");

        // Notify that injection was disabled (if it was previously enabled)
        if (wasEnabled) {
            [self notifyDelegateOfStateChange:NO];
        }
        return;
    }

    // MediaInjectionConfigManager already converted images to videos, so we can safely assume video
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    [self loadAsset:asset];

    // Notify that injection is now enabled (if it wasn't before)
    BOOL isNowEnabled = [self isMediaInjectionEnabled];
    if (!wasEnabled && isNowEnabled) {
        [self notifyDelegateOfStateChange:YES];

        // Kick off playback on any disabled->enabled transition. The usual
        // trigger lives in AVCaptureVideoDataOutputInjector's
        // setSampleBufferDelegate: swizzle, which only fires when the app
        // configures its capture graph AND a valid config already exists.
        // If media.json arrives AFTER the app set its capture delegate
        // (e.g. live push while the camera UI is already on-screen), that
        // trigger is long past and waitingForRecordingStart stays YES, so the display
        // link only ever ships the cached placeholder frame. Calling
        // startMediaPlayback here clears that flag and advances the
        // AVPlayer. Idempotent (returns early if already playing), so safe
        // even when the earlier trigger did fire.
        NSLog(@"QAWolf:MockMediaSource: Late reload transitioned to enabled - starting playback");
        [self startMediaPlayback];
    }
}

- (BOOL)isMediaInjectionEnabled {
    return self.currentConfig != nil && [self.currentConfig isValid];
}

- (NSInteger)previewRotation {
    return self.currentConfig ? self.currentConfig.rotation : 0;
}

#pragma mark - Asset Loading

- (void)loadAsset:(AVAsset *)asset {
    [self cleanup];

    self.currentAsset = asset;

    if (asset) {
        self.mediaDuration = asset.duration;
        NSLog(@"MockMediaSource: Asset loaded, duration: %.2fs",
              CMTimeGetSeconds(self.mediaDuration));

        // Create player item
        self.playerItem = [AVPlayerItem playerItemWithAsset:asset];

        // Create player
        self.player = [AVPlayer playerWithPlayerItem:self.playerItem];
        self.player.volume = 0.0; // Silent - audio tap will extract audio
        self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

        // Enable looping
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(playerItemDidReachEnd:)
                                                   name:AVPlayerItemDidPlayToEndTimeNotification
                                                 object:self.playerItem];

        // Observe rate changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(playerRateChanged:)
                                                   name:@"AVPlayerRateDidChangeNotification"
                                                 object:self.player];

        [self.player addObserver:self
                      forKeyPath:@"rate"
                         options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                         context:nil];

        // Observe audio session interruptions and route changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(audioSessionInterrupted:)
                                                   name:AVAudioSessionInterruptionNotification
                                                 object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(audioSessionRouteChanged:)
                                                   name:AVAudioSessionRouteChangeNotification
                                                 object:nil];

        // Also observe player item status
        [self.playerItem addObserver:self
                          forKeyPath:@"status"
                             options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                             context:nil];

        // Check if asset has video tracks before setting up video output
        [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> * _Nullable videoTracks, NSError * _Nullable videoError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL hasVideo = (!videoError && videoTracks.count > 0);
                self.hasVideo = hasVideo;

                if (hasVideo) {
                    NSLog(@"MockMediaSource: Asset has video tracks, setting up video output");
                    [self setupVideoOutput];
                } else {
                    NSLog(@"MockMediaSource: Audio-only asset detected, skipping video output setup");
                }

                // Set up audio tap (check for audio tracks)
                [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> * _Nullable audioTracks, NSError * _Nullable audioError) {
                    BOOL hasAudioTracks = (!audioError && audioTracks.count > 0);
                    self.hasAudio = hasAudioTracks;

                    if (!hasAudioTracks) {
                        NSLog(@"MockMediaSource: No audio track found: %@", audioError);
                        return;
                    }
                    NSLog(@"MockMediaSource: Audio track found, setting up audio tap");
                    [self setupAudioTapForTrack:audioTracks.firstObject];
                }];

                // Prepare player and video delivery, but don't start playback yet
                // Playback will start when startMediaPlayback is called
                [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"tracks", @"duration"] completionHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Set up video delivery (but frames will be dropped until waitingForRecordingStart = NO)
                        if (hasVideo) {
                            [self startVideoDelivery];

                            // Create red placeholder frame to show while waiting
                            // Get dimensions from first video track
                            AVAssetTrack *videoTrack = videoTracks.firstObject;
                            CGSize naturalSize = videoTrack.naturalSize;
                            size_t width = (size_t)naturalSize.width;
                            size_t height = (size_t)naturalSize.height;

                            // Cache frames from video using AVAssetImageGenerator
                            // - First frame: for photo capture
                            // - Last frame: as placeholder to show in preview before recording
                            [self cacheFramesFromAsset:asset];
                        }
                        NSLog(@"MockMediaSource: Media loaded and ready - waiting for startMediaPlayback call");
                    });
                }];
            });
        }];
    }
}

#pragma mark - Frame Extraction

- (CVPixelBufferRef)extractFrameFromAsset:(AVAsset *)asset atTime:(CMTime)time {
    // Use AVAssetImageGenerator to synchronously extract a frame
    AVAssetImageGenerator *imageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    imageGenerator.appliesPreferredTrackTransform = YES;
    imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;
    imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;

    // Extract frame
    NSError *error = nil;
    CMTime actualTime = kCMTimeZero;
    CGImageRef cgImage = [imageGenerator copyCGImageAtTime:time actualTime:&actualTime error:&error];

    if (!cgImage) {
        NSLog(@"QAWolf:MockMediaSource: Failed to extract frame at time %.2fs: %@", CMTimeGetSeconds(time), error);
        return NULL;
    }

    // Convert CGImage to CVPixelBuffer
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    NSDictionary *pixelBufferOptions = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         (__bridge CFDictionaryRef)pixelBufferOptions,
                                         &pixelBuffer);

    if (status != kCVReturnSuccess) {
        NSLog(@"QAWolf:MockMediaSource: Failed to create pixel buffer for frame");
        CGImageRelease(cgImage);
        return NULL;
    }

    // Render CGImage into pixel buffer
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Create a graphics context from the pixel buffer
    CIContext *ciContext = [CIContext contextWithOptions:nil];
    CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
    [ciContext render:ciImage toCVPixelBuffer:pixelBuffer];

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CGImageRelease(cgImage);

    return pixelBuffer; // Caller is responsible for releasing
}

- (void)cacheFramesFromAsset:(AVAsset *)asset {
    // Extract first frame - use for both photo capture AND preview placeholder
    CVPixelBufferRef firstFrame = [self extractFrameFromAsset:asset atTime:kCMTimeZero];
    if (firstFrame) {
        // Cache for photo capture
        @synchronized(self) {
            if (self.latestVideoFrame) {
                CVPixelBufferRelease(self.latestVideoFrame);
            }
            self.latestVideoFrame = firstFrame; // Already retained by extractFrameFromAsset
        }

        // Also use as placeholder for preview (retain again since we're storing in two places)
        CVPixelBufferRetain(firstFrame);
        if (self.placeholderFrame) {
            CVPixelBufferRelease(self.placeholderFrame);
        }
        self.placeholderFrame = firstFrame;

        size_t width = CVPixelBufferGetWidth(firstFrame);
        size_t height = CVPixelBufferGetHeight(firstFrame);
        NSLog(@"QAWolf:MockMediaSource: Cached first video frame (%zux%zu) for photo capture and preview", width, height);
    }
}

#pragma mark - Playback Control

- (void)startMediaPlayback {
    // Skip if player is actually playing (rate > 0). This prevents double-start
    // when video + audio injectors both call startMediaPlayback during setup.
    if (self.isPlaying && self.player.rate > 0.0) {
        NSLog(@"QAWolf:MockMediaSource: startMediaPlayback called - already playing, skipping");
        return;
    }
    NSLog(@"QAWolf:MockMediaSource: startMediaPlayback called - starting injection");

    // Clear waiting flag FIRST so frames will be delivered when they arrive
    self.waitingForRecordingStart = NO;

    // Release placeholder frame if it exists
    if (self.placeholderFrame) {
        CVPixelBufferRelease(self.placeholderFrame);
        self.placeholderFrame = NULL;
        NSLog(@"QAWolf:MockMediaSource: Released placeholder frame");
    }

    // Reset timestamps so recording starts at time zero
    self.playbackStartTime = CFAbsoluteTimeGetCurrent();

    // Always reset isPlaying flag to ensure we actually start
    self.isPlaying = NO;

    // Start player
    [self startPlayback];

    // Immediately cache a frame so getLatestFrame() has something to return
    // This fixes the issue where photo capture happens before displayLink fires
    if (self.hasVideo && !self.latestVideoFrame) {
        CVPixelBufferRef firstFrame = [self copyLatestVideoFrame];
        if (firstFrame) {
            @synchronized(self) {
                self.latestVideoFrame = firstFrame; // Already retained by copyLatestVideoFrame
            }
            NSLog(@"QAWolf:MockMediaSource: Cached first frame for immediate availability");
        }
    }

    NSLog(@"QAWolf:MockMediaSource: Media injection started - player state: %@, rate: %.2f",
          self.isPlaying ? @"playing" : @"stopped", self.player.rate);
}

- (void)stopMediaPlayback {
    NSLog(@"QAWolf:MockMediaSource: stopMediaPlayback called - stopping and resetting");

    // Stop playback
    [self stopPlayback];

    // Reset player to beginning
    if (self.player) {
        [self.player seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
            NSLog(@"QAWolf:MockMediaSource: Player reset to beginning");
        }];
    }

    // Set waiting flag to show placeholder again
    self.waitingForRecordingStart = YES;
    self.firstVideoFrameDelivered = NO;
    self.injectedAudioFlowing = NO;

    // Reset log counters so the next recording session produces diagnostic logs
    sAudioDeliverWaitCount = 0;
    sAudioDeliverVideoWaitCount = 0;
    sAudioDeliverNoDelegateCount = 0;
    sAudioDeliverCount = 0;
    sAudioTapFailCount = 0;
    sAudioTapProcessCount = 0;

    // Recreate first frame placeholder if we have video and it was previously created
    if (self.hasVideo && !self.placeholderFrame && self.currentAsset) {
        // Extract first frame from video to use as placeholder
        CVPixelBufferRef firstFrame = [self extractFrameFromAsset:self.currentAsset atTime:kCMTimeZero];
        if (firstFrame) {
            self.placeholderFrame = firstFrame;
            NSLog(@"QAWolf:MockMediaSource: Recreated first frame placeholder");
        }
    }

    NSLog(@"QAWolf:MockMediaSource: Stopped and reset - first frame placeholder will be shown");
}

- (void)startPlayback {
    if (self.isPlaying) {
        NSLog(@"MockMediaSource: Already playing (isPlaying=YES, player.rate=%.2f)", self.player.rate);
        return;
    }

    if (!self.player) {
        NSLog(@"MockMediaSource: ⚠️ No player available, cannot start playback");
        return;
    }

    NSLog(@"MockMediaSource: Starting playback (current time: %.3fs)", CMTimeGetSeconds(self.player.currentTime));
    [self qwDumpAudioSessionStateWithReason:@"startPlayback"];

    self.isPlaying = YES;
    [self.player play];

    // Verify player actually started
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.isPlaying && self.player.rate == 0.0) {
            NSLog(@"MockMediaSource: ⚠️ Player didn't start! Forcing play again...");
            [self.player play];
        } else {
            NSLog(@"MockMediaSource: ✓ Playback confirmed (rate: %.2f)", self.player.rate);
        }
    });
}

- (void)stopPlayback {
    NSLog(@"MockMediaSource: Stopping playback");
    self.isPlaying = NO;

    if (self.player) {
        [self.player pause];
    }
}

- (void)cleanup {
    [self stopPlayback];
    [self stopVideoDelivery];
    [self cleanupAudioTap];

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (self.timeObserver && self.player) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }

    @try {
        [self.player removeObserver:self forKeyPath:@"rate"];
    } @catch (NSException *exception) {
        // Observer might not be registered
    }

    if (self.videoOutput && self.playerItem) {
        [self.playerItem removeOutput:self.videoOutput];
    }
    self.videoOutput = nil;

    self.player = nil;
    self.playerItem = nil;
    self.currentAsset = nil;
    self.mediaDuration = kCMTimeZero;
}

- (void)cleanupMediaResources {
    [self cleanup];

    // Release cached frame
    @synchronized(self) {
        if (self.latestVideoFrame) {
            CVPixelBufferRelease(self.latestVideoFrame);
            self.latestVideoFrame = NULL;
        }
    }

    // Release cached scaled buffer
    if (self.videoCaptureScaledBuffer) {
        CVPixelBufferRelease(self.videoCaptureScaledBuffer);
        self.videoCaptureScaledBuffer = NULL;
    }

    // Release placeholder frame
    if (self.placeholderFrame) {
        CVPixelBufferRelease(self.placeholderFrame);
        self.placeholderFrame = NULL;
    }

    self.audioTapFormatReady = NO;

    // Discard any buffered-but-unplayed WebRTC audio so a previous clip's tail doesn't bleed
    // into whatever gets loaded/broadcast next.
    [[QWAudioUnitBridge sharedInstance] reset];
}

#pragma mark - Video

- (void)setupVideoOutput {
    if (!self.playerItem) return;

    // Configure video output for YUV pixel format (same as camera)
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBufferAttributes];
    [self.playerItem addOutput:self.videoOutput];

    NSLog(@"MockMediaSource: Video output configured");
}

- (void)startVideoDelivery {
    if (self.displayLink) {
        NSLog(@"MockMediaSource: Video delivery already active");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        self.displayLink.preferredFramesPerSecond = 30; // 30fps to reduce CPU
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

- (void)stopVideoDelivery {
    NSLog(@"MockMediaSource: Stopping video frame delivery");

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLink invalidate];
        self.displayLink = nil;
    });
}

- (void)displayLinkCallback:(CADisplayLink *)displayLink {
    if (!self.player) return;

    CMTime timestamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);

    // Image-mode lossless fast path. When originalImage is set, we skip
    // the AVPlayer + H.264 video read entirely and deliver a pre-rendered
    // CVPixelBuffer built once from the source UIImage's CGImage. Keeps
    // document edges crisp enough for any downstream live CoreML gates
    // (blur / corner detection typical in document-scanning SDKs) to
    // clear their confidence thresholds.
    if (self.isPlaying && !self.waitingForRecordingStart && self.originalImage) {
        CVPixelBufferRef pb = [self qaw_ensureOriginalPixelBuffer];
        if (pb) {
            [self handleVideoFrame:pb atTime:[self getAdjustedTimestamp]];
            return;
        }
    }

    // Check if player is playing
    if (self.isPlaying && self.videoOutput) {
        // Player is playing - try to get a new frame from AVPlayer
        CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];

        if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
            CMTime outItemTimeForDisplay = kCMTimeZero;
            CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:outputItemTime
                                                                     itemTimeForDisplay:&outItemTimeForDisplay];

            if (pixelBuffer) {
                CMTime adjustedTimestamp = [self getAdjustedTimestamp];
                [self handleVideoFrame:pixelBuffer atTime:adjustedTimestamp];
                CVPixelBufferRelease(pixelBuffer);
            }
        } else {
            // Player is starting up - deliver cached frame to preview only (not recording).
            // Recording should wait for real player frames to avoid black/stale first frames.
            @synchronized(self) {
                if (self.latestVideoFrame) {
                    CMTime adjustedTimestamp = [self getAdjustedTimestamp];
                    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:self.latestVideoFrame atTime:adjustedTimestamp];
                    if (sampleBuffer) {
                        [self deliverSampleBufferToPreviewDelegates:sampleBuffer];
                        CFRelease(sampleBuffer);
                    }
                }
            }
        }
    } else if (self.waitingForRecordingStart && self.placeholderFrame) {
        // Player not playing but injection enabled - deliver placeholder frame
        [self handleVideoFrame:self.placeholderFrame atTime:timestamp];
    }
}

- (CVPixelBufferRef)qaw_ensureOriginalPixelBuffer {
    if (self.originalPixelBuffer) return self.originalPixelBuffer;
    UIImage *img = self.originalImage;
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;

    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess || !pb) {
        NSLog(@"QAWolf:MockMediaSource: Failed to allocate originalPixelBuffer (%d)", r);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        // Without a context, the buffer was never drawn into — its memory
        // is whatever CVPixelBufferCreate left there (typically zero, but
        // not guaranteed). Don't cache or deliver an uninitialized buffer;
        // returning NULL lets callers fall back to the AVPlayer path.
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CVPixelBufferRelease(pb);
        NSLog(@"QAWolf:MockMediaSource: CGBitmapContextCreate failed for %zux%zu — falling back", w, h);
        return NULL;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    self.originalPixelBuffer = pb;
    NSLog(@"QAWolf:MockMediaSource: Built originalPixelBuffer %zux%zu (lossless preview path)", w, h);
    return pb;
}

- (void)handleVideoFrame:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)presentationTime {

    // If waiting for recording to start, deliver placeholder frames instead
    if (self.waitingForRecordingStart) {
        if (!self.placeholderFrame) {
            // No placeholder available, skip
            return;
        }

        // Deliver placeholder to all registered delegates (for preview)
        CMSampleBufferRef placeholderSampleBuffer = [self createSampleBufferFromPixelBuffer:self.placeholderFrame atTime:presentationTime];
        if (!placeholderSampleBuffer) {
            return;
        }

        [self deliverSampleBufferToDelegates:placeholderSampleBuffer];
        CFRelease(placeholderSampleBuffer);
        return;
    }

    // Cache the latest frame for legacy getLatestFrame() calls
    @synchronized(self) {
        // Release old cached frame
        if (self.latestVideoFrame) {
            CVPixelBufferRelease(self.latestVideoFrame);
        }
        // Cache new frame
        CVPixelBufferRetain(pixelBuffer);
        self.latestVideoFrame = pixelBuffer;
    }

    // Create sample buffer from pixel buffer (used by both preview and recording)
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer atTime:presentationTime];
    if (!sampleBuffer) {
        return;
    }

    // Deliver to all registered video delegates using raw pointers
    [self deliverSampleBufferToDelegates:sampleBuffer];

    CFRelease(sampleBuffer);
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)presentationTime {
    CMSampleBufferRef sampleBuffer = NULL;
    CMVideoFormatDescriptionRef formatDesc = NULL;

    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr) {
        NSLog(@"QAWolf:MockMediaSource: Failed to create format description: %d", (int)status);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    timingInfo.presentationTimeStamp = presentationTime;
    timingInfo.duration = kCMTimeInvalid;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                       pixelBuffer,
                                                       formatDesc,
                                                       &timingInfo,
                                                       &sampleBuffer);

    CFRelease(formatDesc);

    if (status != noErr) {
        NSLog(@"QAWolf:MockMediaSource: Failed to create sample buffer: %d", (int)status);
        return NULL;
    }

    return sampleBuffer;
}

- (CVPixelBufferRef)getLatestFrame {
    // First check if we have a cached video frame (used for photo capture)
    @synchronized(self) {
        if (self.latestVideoFrame) {
            CVPixelBufferRetain(self.latestVideoFrame);
            return self.latestVideoFrame;
        }
    }

    // If no cached frame, try to get from video output
    CVPixelBufferRef frameFromOutput = [self copyLatestVideoFrame];
    if (frameFromOutput) {
        return frameFromOutput;
    }

    // Last resort: return placeholder if waiting for recording
    if (self.waitingForRecordingStart && self.placeholderFrame) {
        CVPixelBufferRetain(self.placeholderFrame);
        return self.placeholderFrame;
    }

    return NULL;
}

- (CVPixelBufferRef)copyLatestVideoFrame {
    if (!self.videoOutput || !self.player) {
        return NULL;
    }

    CMTime currentTime = self.player.currentTime;

    if (![self.videoOutput hasNewPixelBufferForItemTime:currentTime]) {
        return NULL;
    }

    CMTime outItemTimeForDisplay = kCMTimeZero;
    return [self.videoOutput copyPixelBufferForItemTime:currentTime
                                     itemTimeForDisplay:&outItemTimeForDisplay];
}

- (void)registerVideoDelegate:(id<MockMediaSourceVideoDelegate>)delegate {
    if (!delegate) return;
    NSUInteger identity = (NSUInteger)(__bridge void *)delegate;
    @synchronized(self.videoDelegateProxies) {
        for (MockMediaSourceDelegateProxy *proxy in self.videoDelegateProxies) {
            if (proxy.targetIdentity == identity) return; // already registered
        }
        MockMediaSourceDelegateProxy *proxy = [[MockMediaSourceDelegateProxy alloc] initWithTarget:delegate];
        [self.videoDelegateProxies addObject:proxy];
    }
    NSLog(@"QAWolf:MockMediaSource: Registered video delegate: %p", delegate);
}

- (void)unregisterVideoDelegate:(id<MockMediaSourceVideoDelegate>)delegate {
    if (!delegate) return;
    NSUInteger identity = (NSUInteger)(__bridge void *)delegate;
    @synchronized(self.videoDelegateProxies) {
        NSUInteger idx = NSNotFound;
        for (NSUInteger i = 0; i < self.videoDelegateProxies.count; i++) {
            if (self.videoDelegateProxies[i].targetIdentity == identity) {
                idx = i;
                break;
            }
        }
        if (idx != NSNotFound) {
            [self.videoDelegateProxies removeObjectAtIndex:idx];
        }
    }
    NSLog(@"QAWolf:MockMediaSource: Unregistered video delegate: %p", delegate);
}

- (void)registerVideoCaptureDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                              output:(AVCaptureVideoDataOutput *)output
                       callbackQueue:(dispatch_queue_t)queue {
    if (delegate == nil) {
        NSLog(@"QAWolf:MockMediaSource: Unregistering video capture delegate");
        self.videoCaptureDelegate = nil;
        self.videoCaptureOutput = nil;
        self.videoCaptureQueue = nil;
        return;
    }
    NSLog(@"QAWolf:MockMediaSource: Registered video capture delegate %p (queue=%p)", delegate, queue);
    self.videoCaptureDelegate = delegate;
    self.videoCaptureOutput = output;
    self.videoCaptureQueue = queue;

    // Detect camera resolution from the capture session's active format.
    // This can return nil here if setSampleBufferDelegate: was called before
    // the capture graph finished configuring — in that case we re-detect
    // lazily inside deliverSampleBufferToDelegates: on each frame.
    AVCaptureConnection *conn = [output connectionWithMediaType:AVMediaTypeVideo];
    if (conn) {
        AVCaptureInputPort *port = conn.inputPorts.firstObject;
        CMFormatDescriptionRef portFmt = port.formatDescription;
        if (portFmt) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(portFmt);
            self.videoCaptureTargetSize = CGSizeMake(dims.width, dims.height);
            NSLog(@"QAWolf:MockMediaSource: Camera resolution detected: %dx%d", dims.width, dims.height);
        } else {
            NSLog(@"QAWolf:MockMediaSource: Camera format not yet available at delegate registration — will detect on first frame");
        }
    }
}

- (void)cacheCameraIntrinsicMatrix:(NSData *)matrixData {
    if (matrixData.length > 0) {
        // Atomic property — safe to assign from the capture-queue thread
        // that the wrapper's captureOutput:didOutputSampleBuffer: runs on.
        self.cachedCameraIntrinsicMatrix = matrixData;
    }
}

- (void)cacheCameraSampleBufferAttachments:(NSDictionary *)attachments {
    if (attachments.count > 0) {
        self.cachedCameraSampleBufferAttachments = attachments;
    }
}

/// Deliver to preview delegates only (overlay layers) — used for cached/startup frames
- (void)deliverSampleBufferToPreviewDelegates:(CMSampleBufferRef)sampleBuffer {
    NSArray<MockMediaSourceDelegateProxy *> *proxies;
    @synchronized(self.videoDelegateProxies) {
        proxies = [self.videoDelegateProxies copy];
    }
    NSMutableArray *stale = nil;
    for (MockMediaSourceDelegateProxy *proxy in proxies) {
        if (![proxy deliverSampleBuffer:sampleBuffer fromSource:self]) {
            if (!stale) stale = [NSMutableArray new];
            [stale addObject:proxy];
        }
    }
    if (stale.count > 0) {
        @synchronized(self.videoDelegateProxies) {
            [self.videoDelegateProxies removeObjectsInArray:stale];
        }
    }
}

/// Deliver to both preview and capture delegates — used for live player frames
- (void)deliverSampleBufferToDelegates:(CMSampleBufferRef)sampleBuffer {
    self.firstVideoFrameDelivered = YES;

    // Push to video capture delegate (AVCaptureVideoDataOutput push mode)
    id<AVCaptureVideoDataOutputSampleBufferDelegate> captureDelegate = self.videoCaptureDelegate;
    AVCaptureVideoDataOutput *captureOutput = self.videoCaptureOutput;
    if (captureDelegate && captureOutput) {
        CVPixelBufferRef srcPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (srcPixelBuffer) {
            // Lazy target-size detection: setSampleBufferDelegate: is often called
            // before startRunning, when the input port's formatDescription is nil.
            // Re-check on each delivery until it's populated. If none of the
            // session-side sources give us a size, default to 1280×720 — every
            // app the injection has been observed against uses that preset.
            if (self.videoCaptureTargetSize.width == 0 || self.videoCaptureTargetSize.height == 0) {
                CGSize detected = CGSizeZero;
                const char *source = "none";

                AVCaptureConnection *conn = [captureOutput connectionWithMediaType:AVMediaTypeVideo];

                // 1. Preferred: input-port format description (populated once graph is running)
                AVCaptureInputPort *port = conn.inputPorts.firstObject;
                CMFormatDescriptionRef portFmt = port.formatDescription;
                if (portFmt) {
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(portFmt);
                    detected = CGSizeMake(dims.width, dims.height);
                    source = "inputPort.formatDescription";
                }

                // 2. Fallback: walk to the AVCaptureDevice's active format.
                if (detected.width == 0) {
                    AVCaptureInput *input = port.input;
                    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
                        AVCaptureDevice *device = [(AVCaptureDeviceInput *)input device];
                        CMFormatDescriptionRef activeFmt = device.activeFormat.formatDescription;
                        if (activeFmt) {
                            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(activeFmt);
                            detected = CGSizeMake(dims.width, dims.height);
                            source = "device.activeFormat";
                        }
                    }
                }

                // 3. Fallback: parse AVCaptureSession.sessionPreset (string constants).
                //    captureOutput doesn't directly expose its session, but the connection
                //    chain lets us reach it via -[input session] (undocumented; may be nil
                //    on stricter SDK versions). Skip gracefully if unavailable.
                if (detected.width == 0) {
                    AVCaptureSession *session = [captureOutput valueForKey:@"session"];
                    AVCaptureSessionPreset preset = session.sessionPreset;
                    // Map known presets to their effective dimensions.
                    if ([preset isEqualToString:AVCaptureSessionPreset1280x720]) {
                        detected = CGSizeMake(1280, 720);
                    } else if ([preset isEqualToString:AVCaptureSessionPreset1920x1080]) {
                        detected = CGSizeMake(1920, 1080);
                    } else if ([preset isEqualToString:AVCaptureSessionPreset640x480]) {
                        detected = CGSizeMake(640, 480);
                    } else if ([preset isEqualToString:AVCaptureSessionPreset352x288]) {
                        detected = CGSizeMake(352, 288);
                    } else if ([preset isEqualToString:AVCaptureSessionPresetiFrame960x540]) {
                        detected = CGSizeMake(960, 540);
                    } else if ([preset isEqualToString:AVCaptureSessionPresetiFrame1280x720]) {
                        detected = CGSizeMake(1280, 720);
                    }
                    if (detected.width > 0) source = "sessionPreset";
                }

                // 4. Last resort: common-case default. 1280x720 is the most
                //    widely used preset for live document/face capture flows.
                if (detected.width == 0) {
                    detected = CGSizeMake(1280, 720);
                    source = "default(1280x720)";
                }

                self.videoCaptureTargetSize = detected;
                NSLog(@"QAWolf:MockMediaSource: Camera resolution detected (late): %dx%d source=%s",
                      (int)detected.width, (int)detected.height, source);
            }

            // Read the format the app actually requested on the output. AVFoundation's
            // documented default (and the behavior when videoSettings is nil or empty)
            // is kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange. Apps that want
            // direct CIImage / CoreML access typically set kCVPixelFormatType_32BGRA
            // explicitly.
            OSType destFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            NSDictionary *videoSettings = captureOutput.videoSettings;
            NSNumber *fmtNum = videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
            if (fmtNum) {
                destFormat = (OSType)fmtNum.unsignedIntValue;
            }

            size_t srcW = CVPixelBufferGetWidth(srcPixelBuffer);
            size_t srcH = CVPixelBufferGetHeight(srcPixelBuffer);
            OSType srcFormat = CVPixelBufferGetPixelFormatType(srcPixelBuffer);
            size_t dstW = self.videoCaptureTargetSize.width > 0 ? (size_t)self.videoCaptureTargetSize.width : srcW;
            size_t dstH = self.videoCaptureTargetSize.height > 0 ? (size_t)self.videoCaptureTargetSize.height : srcH;

            // Decide buffer orientation based on what the host requested:
            //
            //   - Sensor-native (angle 0 or 180) — typically ML pipelines
            //     like ID-scan that need landscape sensor-convention input.
            //     Keep dst dims as the host's videoCaptureTargetSize
            //     (landscape) and let the existing src/dst-mismatch rule
            //     rotate portrait sources 90 to fit.
            //
            //   - Display-oriented (angle 90 or 270) — typically apps that
            //     just want to show or record what's in the buffer in user-
            //     visible orientation. Override dst dims to match the
            //     source's orientation so injected media plays back in its
            //     own orientation regardless of device hold. The existing
            //     mismatch rule then no-ops (src and dst already match).
            CGFloat connAngle = 0;
            {
                AVCaptureConnection *conn = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
                if (conn) connAngle = conn.videoRotationAngle;
            }
            BOOL hostWantsSensorNative = (connAngle == 0.0 || connAngle == 180.0);
            if (!hostWantsSensorNative) {
                BOOL srcLandscape = srcW >= srcH;
                BOOL dstLandscape = dstW >= dstH;
                if (srcLandscape != dstLandscape) {
                    size_t tmp = dstW; dstW = dstH; dstH = tmp;
                }
            }

            BOOL needsConversion = (srcFormat != destFormat) || (srcW != dstW) || (srcH != dstH);

            CVPixelBufferRef deliveryPixelBuffer = srcPixelBuffer;
            CVPixelBufferRetain(deliveryPixelBuffer);

            if (needsConversion) {
                if (!self.videoCaptureScaleContext) {
                    self.videoCaptureScaleContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
                }

                // Recreate the cached buffer if format or size changed (e.g. the app
                // re-configured its output, or we late-detected a different target).
                if (self.videoCaptureScaledBuffer) {
                    size_t cachedW = CVPixelBufferGetWidth(self.videoCaptureScaledBuffer);
                    size_t cachedH = CVPixelBufferGetHeight(self.videoCaptureScaledBuffer);
                    OSType cachedF = CVPixelBufferGetPixelFormatType(self.videoCaptureScaledBuffer);
                    if (cachedW != dstW || cachedH != dstH || cachedF != destFormat) {
                        CVPixelBufferRelease(self.videoCaptureScaledBuffer);
                        self.videoCaptureScaledBuffer = NULL;
                    }
                }

                if (!self.videoCaptureScaledBuffer) {
                    // Match the real camera pool as closely as possible: IOSurface-backed,
                    // Metal-compatible, OpenGL-compatible. Some Metal/CIContext paths
                    // silently fail on buffers without these flags even when the buffer
                    // format matches, producing blank output for downstream consumers.
                    NSDictionary *attrs = @{
                        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                        (id)kCVPixelBufferPixelFormatTypeKey: @(destFormat),
                        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
                    };
                    CVPixelBufferRef buf = NULL;
                    CVReturn createStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                        dstW, dstH,
                        destFormat, (__bridge CFDictionaryRef)attrs, &buf);
                    if (createStatus == kCVReturnSuccess && buf) {
                        // Match real back-camera color tagging. The real pipeline reports
                        // Rec. 709 primaries/transfer with Rec. 601 YCbCr matrix — weird
                        // but consistent with what the device ISP actually produces.
                        // Match it exactly so any consumer comparing attachments sees the
                        // expected values.
                        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                                              kCVImageBufferColorPrimaries_ITU_R_709_2,
                                              kCVAttachmentMode_ShouldPropagate);
                        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                                              kCVImageBufferTransferFunction_ITU_R_709_2,
                                              kCVAttachmentMode_ShouldPropagate);
                        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey,
                                              kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                              kCVAttachmentMode_ShouldPropagate);
                    }
                    self.videoCaptureScaledBuffer = buf;
                    NSLog(@"QAWolf:MockMediaSource: (Re)allocated delivery buffer: %zux%zu fmt=0x%08x metal=1 openGL=1 yCbCr=601", dstW, dstH, (unsigned)destFormat);
                }

                if (self.videoCaptureScaledBuffer) {
                    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:srcPixelBuffer];

                    // Rotate the source so the delivered buffer mirrors what
                    // AVCaptureSession would have produced for the host's
                    // connection.videoRotationAngle: when src/dst orientations
                    // differ, rotate 90 CW so the content fits the buffer
                    // shape. ID-scan apps (angle=0, landscape buffer) get
                    // portrait sources rotated to landscape sensor convention;
                    // recording hosts (angle=90, portrait buffer) get landscape
                    // sources rotated to fit portrait — same rule both ways.
                    CGFloat srcW = CGRectGetWidth(ciImage.extent);
                    CGFloat srcH = CGRectGetHeight(ciImage.extent);
                    BOOL srcPortrait = srcH > srcW;
                    BOOL dstPortrait = dstH > dstW;
                    if (srcPortrait != dstPortrait) {
                        ciImage = [ciImage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                        CGRect ext = ciImage.extent;
                        if (!CGPointEqualToPoint(ext.origin, CGPointZero)) {
                            ciImage = [ciImage imageByApplyingTransform:
                                CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
                        }
                        srcW = CGRectGetWidth(ciImage.extent);
                        srcH = CGRectGetHeight(ciImage.extent);
                    }

                    // Aspect-FILL scale (preserve aspect ratio, cover the
                    // full destination). Real-camera frames never have
                    // letterbox bars; sharp black bands at fixed positions
                    // confuse downstream corner-detection models that
                    // expect edge-to-edge content. MAX(scale) makes the
                    // source overshoot one dimension, then a center crop
                    // leaves the destination filled edge-to-edge with the
                    // subject centred.
                    CGFloat scale = MAX((CGFloat)dstW / srcW, (CGFloat)dstH / srcH);
                    CGFloat scaledW = srcW * scale;
                    CGFloat scaledH = srcH * scale;
                    CGFloat tx = ((CGFloat)dstW - scaledW) * 0.5;  // <= 0
                    CGFloat ty = ((CGFloat)dstH - scaledH) * 0.5;  // <= 0
                    CIImage *transformed = [ciImage imageByApplyingTransform:
                        CGAffineTransformMake(scale, 0, 0, scale, tx, ty)];

                    // Crop to dst rect — at this point the transformed image
                    // fully covers the dst rect on at least one axis and
                    // overshoots on the other. The composite-over-black
                    // background is kept as a defensive layer in case the
                    // scale ever falls short (e.g. source extent is zero).
                    CIImage *bg = [[CIImage imageWithColor:[CIColor blackColor]]
                                   imageByCroppingToRect:CGRectMake(0, 0, dstW, dstH)];
                    CIImage *composed = [transformed imageByCompositingOverImage:bg];
                    composed = [composed imageByCroppingToRect:CGRectMake(0, 0, dstW, dstH)];

                    [self.videoCaptureScaleContext render:composed toCVPixelBuffer:self.videoCaptureScaledBuffer];
                    CVPixelBufferRelease(deliveryPixelBuffer);
                    CVPixelBufferRetain(self.videoCaptureScaledBuffer);
                    deliveryPixelBuffer = self.videoCaptureScaledBuffer;
                }
            }

            CMTime timestamp = [self getAdjustedTimestamp];
            CMSampleTimingInfo timing = {
                .presentationTimeStamp = timestamp,
                .duration = kCMTimeInvalid,
                .decodeTimeStamp = kCMTimeInvalid
            };

            CMVideoFormatDescriptionRef formatDesc = NULL;
            OSStatus fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(NULL, deliveryPixelBuffer, &formatDesc);
            if (fmtStatus == noErr && formatDesc) {
                CMSampleBufferRef captureSampleBuffer = NULL;
                fmtStatus = CMSampleBufferCreateReadyWithImageBuffer(NULL, deliveryPixelBuffer, formatDesc, &timing, &captureSampleBuffer);
                CFRelease(formatDesc);

                if (fmtStatus == noErr && captureSampleBuffer) {
                    // Stamp every propagating attachment we harvested from the real
                    // camera pipeline ({Exif}, {TIFF}, {MakerApple}, DPIWidth/Height,
                    // CameraIntrinsicMatrix if enabled, …). We SKIP the `Orientation`
                    // attachment because the real camera's sensor stores pixels in a
                    // rotated layout (typically Orientation=6, "rotate 90° CW to display
                    // correctly"), whereas our AVPlayer-sourced BGRA buffer is already
                    // in standard landscape left-to-right top-to-bottom layout. Copying
                    // Orientation verbatim would double-rotate our image and push it
                    // off-screen into black.
                    NSDictionary *attachments = self.cachedCameraSampleBufferAttachments;
                    if (attachments.count > 0) {
                        NSString *orientationKey = (__bridge NSString *)kCGImagePropertyOrientation;
                        [attachments enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                            // Skip the top-level Orientation per the comment
                            // above: real-camera frames carry the sensor's
                            // rotation tag (typically 6 = "rotate 90 CW") on
                            // pixels that are themselves laid out rotated,
                            // whereas our buffer is already oriented for the
                            // host's connection. Copying it verbatim would
                            // double-rotate downstream consumers.
                            if ([key isKindOfClass:[NSString class]] &&
                                [(NSString *)key isEqualToString:orientationKey]) {
                                return;
                            }
                            CMSetAttachment(captureSampleBuffer,
                                            (__bridge CFStringRef)key,
                                            (__bridge CFTypeRef)obj,
                                            kCMAttachmentMode_ShouldPropagate);
                        }];
                    }


                    // Legacy: if we only harvested the intrinsic matrix (e.g. via an
                    // older codepath), stamp it explicitly too. Harmless if the full
                    // attachments dict already set the key.
                    NSData *intrinsic = self.cachedCameraIntrinsicMatrix;
                    if (intrinsic) {
                        CMSetAttachment(captureSampleBuffer,
                                        kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                        (__bridge CFDataRef)intrinsic,
                                        kCMAttachmentMode_ShouldPropagate);
                    }

                    // DisplayImmediately — per-sample attachment. Matches what the real
                    // capture pipeline produces and tells display layers to render now
                    // rather than try to schedule against a future PTS.
                    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(captureSampleBuffer, true);
                    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
                        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
                        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
                    }

                    AVCaptureConnection *connection = [captureOutput connectionWithMediaType:AVMediaTypeVideo];

                    [captureDelegate captureOutput:captureOutput
                             didOutputSampleBuffer:captureSampleBuffer
                                    fromConnection:connection];
                    CFRelease(captureSampleBuffer);
                }
            }
            CVPixelBufferRelease(deliveryPixelBuffer);
        }
    }

    // Push to preview delegates (MockMediaSourceVideoDelegate)
    NSArray<MockMediaSourceDelegateProxy *> *proxies;
    @synchronized(self.videoDelegateProxies) {
        proxies = [self.videoDelegateProxies copy];
    }
    NSMutableArray *stale = nil;
    for (MockMediaSourceDelegateProxy *proxy in proxies) {
        if (![proxy deliverSampleBuffer:sampleBuffer fromSource:self]) {
            if (!stale) stale = [NSMutableArray new];
            [stale addObject:proxy];
        }
    }
    if (stale.count > 0) {
        @synchronized(self.videoDelegateProxies) {
            [self.videoDelegateProxies removeObjectsInArray:stale];
        }
    }
}

#pragma mark - Audio

- (void)setupAudioTapForTrack:(AVAssetTrack *)audioTrack {
    [self cleanupAudioTap];

    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    AVMutableAudioMixInputParameters *inputParameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge void *)self;
    callbacks.init = audioTapInit;
    callbacks.finalize = audioTapFinalize;
    callbacks.prepare = audioTapPrepare;
    callbacks.unprepare = audioTapUnprepare;
    callbacks.process = audioTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PostEffects, &tap);

    if (status != noErr || !tap) {
        NSLog(@"MockMediaSource: Failed to create audio tap: %d", (int)status);
        return;
    }

    self.audioTap = tap;
    inputParameters.audioTapProcessor = tap;
    audioMix.inputParameters = @[inputParameters];
    self.playerItem.audioMix = audioMix;
    self.audioMix = audioMix;

    NSLog(@"MockMediaSource: Audio tap configured");
}

- (void)cleanupAudioTap {
    if (self.audioTap) {
        CFRelease(self.audioTap);
        self.audioTap = NULL;
    }
    self.audioMix = nil;
}


- (void)deliverAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (self.waitingForRecordingStart) {
        if (++sAudioDeliverWaitCount <= 3) NSLog(@"QAWolf:MockMediaSource: Audio dropped - waiting for recording start");
        return;
    }
    // Only wait for video frame if we actually have video content.
    // For audio-only injection (e.g. AVAudioRecorder), there is no video.
    if (self.hasVideo && !self.firstVideoFrameDelivered) {
        if (++sAudioDeliverVideoWaitCount <= 3) NSLog(@"QAWolf:MockMediaSource: Audio dropped - waiting for first video frame");
        return;
    }

    id<AVCaptureAudioDataOutputSampleBufferDelegate> audioDelegate = self.audioDelegate;
    AVCaptureAudioDataOutput *audioOutput = self.audioOutput;
    if (!audioDelegate || !audioOutput) {
        if (++sAudioDeliverNoDelegateCount <= 3) NSLog(@"QAWolf:MockMediaSource: Audio dropped - no delegate (%p) or output (%p)", audioDelegate, audioOutput);
        return;
    }

    if (++sAudioDeliverCount <= 3) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd = fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
        CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
        if (asbd) {
            NSLog(@"QAWolf:MockMediaSource: Delivering audio #%d — %ld samples, %.0fHz %uch %ubit %s",
                  sAudioDeliverCount, (long)numSamples, asbd->mSampleRate,
                  (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBitsPerChannel,
                  (asbd->mFormatFlags & kAudioFormatFlagIsFloat) ? "float" : "int");
        } else {
            NSLog(@"QAWolf:MockMediaSource: Delivering audio #%d — %ld samples (no format desc)", sAudioDeliverCount, (long)numSamples);
        }
    }

    // Signal that injected audio is now flowing — wrapper can stop forwarding mic audio
    if (!self.injectedAudioFlowing) {
        self.injectedAudioFlowing = YES;
        NSLog(@"QAWolf:MockMediaSource: Injected audio now flowing — mic passthrough will stop");
    }

    // Retain the sample buffer for the async dispatch
    CFRetain(sampleBuffer);

    // Dispatch to the queue the app registered with setSampleBufferDelegate:queue:
    // The audio tap fires on the audio render thread, but the app expects callbacks
    // on its registered queue.
    dispatch_queue_t queue = self.audioCallbackQueue;
    void (^deliverBlock)(void) = ^{
        AVCaptureConnection *connection = nil;
        if ([audioOutput respondsToSelector:@selector(connectionWithMediaType:)]) {
            connection = [audioOutput connectionWithMediaType:AVMediaTypeAudio];
        }

        [audioDelegate captureOutput:audioOutput
                  didOutputSampleBuffer:sampleBuffer
                       fromConnection:connection];
        CFRelease(sampleBuffer);
    };

    if (queue) {
        dispatch_async(queue, deliverBlock);
    } else {
        deliverBlock();
    }
}

- (void)registerAudioDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                       output:(AVCaptureAudioDataOutput *)output
                audioSettings:(NSDictionary *)audioSettings
                callbackQueue:(dispatch_queue_t)queue {
    if (delegate == nil) {
        NSLog(@"QAWolf:MockMediaSource: Unregistering audio delegate");
        self.audioDelegate = nil;
        self.audioOutput = nil;
        self.audioCallbackQueue = nil;
        return;
    }

    NSLog(@"QAWolf:MockMediaSource: Registered audio delegate (queue=%p)", queue);
    self.audioDelegate = delegate;
    self.audioOutput = output;
    self.audioCallbackQueue = queue;

    if (audioSettings) {
        self.requestedAudioSettings = audioSettings;
    }

    NSLog(@"QAWolf:MockMediaSource: Audio delegate ready - samples will be delivered via audio tap");
}

- (void)configureTargetAudioFormat:(const AudioStreamBasicDescription *)format {
    self.targetAudioFormat = *format;
    self.targetAudioFormatReady = YES;
    NSLog(@"MockMediaSource: Target audio format set — %.0f Hz, %u ch, %u bits, formatID=%u, flags=0x%x",
          format->mSampleRate, (unsigned int)format->mChannelsPerFrame,
          (unsigned int)format->mBitsPerChannel, (unsigned int)format->mFormatID,
          (unsigned int)format->mFormatFlags);
}

#pragma mark - Timestamp Management

- (void)resetTimestamps {
    NSLog(@"MockMediaSource: Resetting timestamp tracking for new recording");
    self.playbackStartTime = CFAbsoluteTimeGetCurrent();
}

- (CMTime)getAdjustedTimestamp {
    // Use the host time clock — same timebase as AVCaptureSession.
    // This ensures our injected video/audio timestamps match the real mic's
    // timestamps (used during mic passthrough), so the AVAssetWriter accepts them.
    return CMClockGetTime(CMClockGetHostTimeClock());
}

#pragma mark - Player Notifications

// Appends the actual AVAudioSession state to a file, rather than NSLog -- syslog can silently
// drop one-time diagnostic lines under load, while a file survives and can be pulled after the
// fact to see exactly what category/mode/options the app had active at key moments.
//
// Called from -startPlayback (right before [self.player play], a timing-sensitive call site)
// and from AVAudioSession notification handlers whose delivery thread isn't guaranteed to be
// the main thread -- the actual disk I/O runs on its own serial background queue so it never
// blocks the calling thread, and the queue's serialization (instead of @synchronized) is what
// keeps concurrent appends (e.g. an interruption and a route change landing close together)
// from interleaving. Session properties are still read synchronously on the calling thread so
// the entry reflects the state at the moment being diagnosed, not whenever the queue gets to it.
- (void)qwDumpAudioSessionStateWithReason:(NSString *)reason {
    static dispatch_queue_t qwSessionLogQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        qwSessionLogQueue = dispatch_queue_create("com.qawolf.media.sessionStateLog", DISPATCH_QUEUE_SERIAL);
    });

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *entry = [NSString stringWithFormat:
        @"--- %@ (t=%f) ---\ncategory=%@\nmode=%@\noptions=0x%lx\nsampleRate=%.0f\nisOtherAudioPlaying=%d\n\n",
        reason, CFAbsoluteTimeGetCurrent(), session.category, session.mode,
        (unsigned long)session.categoryOptions, session.sampleRate, session.isOtherAudioPlaying];

    dispatch_async(qwSessionLogQueue, ^{
        NSString *dumpPath = [[Utils getQAWolfFolder] stringByAppendingPathComponent:@"session-state-log.txt"];
        NSFileManager *fm = [NSFileManager defaultManager];

        // Cap growth: this is a lightweight diagnostic aid, not a real log -- start fresh
        // instead of appending forever across the app's entire install lifetime.
        const unsigned long long kMaxLogBytes = 256 * 1024;
        NSDictionary *attrs = [fm attributesOfItemAtPath:dumpPath error:nil];
        BOOL needsFreshFile = !attrs || [attrs fileSize] > kMaxLogBytes;
        if (needsFreshFile) {
            [fm createFileAtPath:dumpPath contents:nil attributes:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:dumpPath];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } else {
            NSLog(@"QAWolf:MockMediaSource: Failed to open session state log for append");
        }
    });
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    NSLog(@"MockMediaSource: Media completed, looping...");
    [self.player seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        if (self.isPlaying) {
            [self.player play];
        }
    }];
}

- (void)playerRateChanged:(NSNotification *)notification {
    float rate = self.player.rate;
    if (rate != 1.0 && self.isPlaying) {
        NSLog(@"MockMediaSource: ⚠️ Player rate changed to %.2f", rate);
    }
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
    NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    NSLog(@"MockMediaSource: 🔊 Audio session interruption: type=%lu (%@) userInfo=%@",
          (unsigned long)type,
          type == AVAudioSessionInterruptionTypeBegan ? @"BEGAN" : @"ENDED",
          notification.userInfo);
    [self qwDumpAudioSessionStateWithReason:[NSString stringWithFormat:@"interruption:%@",
        type == AVAudioSessionInterruptionTypeBegan ? @"BEGAN" : @"ENDED"]];

    // A genuine external interruption (phone call, Siri, another app) pauses playback and the
    // rate-KVO safety net below picks it up when the player's rate actually drops. But the
    // interruption-ended edge is a reliable, explicit "the session is stable again" signal
    // worth reasserting playback on directly too, rather than only reacting to whatever rate
    // transition (if any) happened during the interruption itself.
    if (type == AVAudioSessionInterruptionTypeEnded) {
        [self reassertPlaybackIfNeeded:@"interruption ended"];
    }
}

- (void)audioSessionRouteChanged:(NSNotification *)notification {
    NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    NSString *reasonStr;
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: reasonStr = @"NewDeviceAvailable"; break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: reasonStr = @"OldDeviceUnavailable"; break;
        case AVAudioSessionRouteChangeReasonCategoryChange: reasonStr = @"CategoryChange"; break;
        case AVAudioSessionRouteChangeReasonOverride: reasonStr = @"Override"; break;
        case AVAudioSessionRouteChangeReasonWakeFromSleep: reasonStr = @"WakeFromSleep"; break;
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory: reasonStr = @"NoSuitableRoute"; break;
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange: reasonStr = @"RouteConfigChange"; break;
        default: reasonStr = @"Unknown"; break;
    }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSLog(@"MockMediaSource: 🔊 Audio route changed: reason=%@ category=%@ mode=%@ outputs=%@",
          reasonStr, session.category, session.mode, session.currentRoute.outputs);
    [self qwDumpAudioSessionStateWithReason:[NSString stringWithFormat:@"routeChanged:%@", reasonStr]];

    // Apps that only activate a recording session when the user taps record (rather than
    // eagerly at launch) fire this notification, with reason=CategoryChange, right as
    // recording starts. When that happens, our player's render pipeline can silently orphan
    // itself against the reconfigured route WITHOUT its `rate` property ever dropping to 0
    // first -- so the rate-KVO safety net in -observeValueForKeyPath:ofObject:change:context:
    // never triggers, -playerItemDidReachEnd never fires again either (the player stops
    // advancing entirely), and injected audio silently stops reaching any consumer for the
    // rest of the session. A category change is the most common trigger, but re-asserting on
    // every route change is cheap (a no-op if the player is already progressing normally) and
    // covers other reasons (e.g. device availability changes) that could plausibly cause the
    // same stall.
    [self reassertPlaybackIfNeeded:[NSString stringWithFormat:@"route changed (%@)", reasonStr]];
}

// A bare -play call (even a full -pause/-play toggle) is not enough to recover from this: after
// the app's own AVAudioSession category change, the player's `rate` KVO can report 1.0 again
// correctly, yet its underlying MTAudioProcessingTap never resumes producing samples -- as if
// the render graph feeding the tap got orphaned by the route change and pause/play doesn't
// force it to re-negotiate. Recreating the AVPlayerItem (and therefore its tap) from the same
// asset, then swapping it into the existing AVPlayer via -replaceCurrentItemWithPlayerItem:,
// forces that re-negotiation from scratch.
//
// Delayed and coalesced (not run synchronously on the first notification): the underlying
// AURemoteIO/VoiceProcessingIO unit typically cycles through several stop/restart pairs
// (visible in device syslog as repeated "Stopping AURemoteIO" / property-set / "Starting
// AURemoteIO" sequences) before settling on its final configuration when the app activates
// recording. Recreating synchronously on the first route-change/interruption-ended
// notification races that settling process -- the freshly recreated tap can get unprepared
// again within ~1s, caught by a later cycle in the same sequence. Waiting a beat, and only
// actually running once even if multiple notifications arrive in that window (each call bumps
// the generation counter, so only the last-scheduled attempt runs), avoids that race.
// May be called from AVAudioSession notification handlers, whose delivery thread isn't
// guaranteed to be the main thread -- dispatch to main before touching reassertGeneration so
// two calls landing on different threads at once can't race the read-increment-compare.
- (void)reassertPlaybackIfNeeded:(NSString *)trigger {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isPlaying || !self.currentAsset) return;

        NSUInteger generation = ++self.reassertGeneration;
        NSLog(@"MockMediaSource: 🔊 Scheduling re-assert after %@ (generation=%lu, player.rate=%.2f)",
              trigger, (unsigned long)generation, self.player.rate);

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (generation != strongSelf.reassertGeneration) {
                NSLog(@"MockMediaSource: 🔊 Skipping stale re-assert (generation=%lu, current=%lu)",
                      (unsigned long)generation, (unsigned long)strongSelf.reassertGeneration);
                return;
            }
            [strongSelf performReassert];
        });
    });
}

- (void)performReassert {
    if (!self.isPlaying || !self.currentAsset) return;

    NSLog(@"MockMediaSource: 🔊 Re-asserting playback (player.rate=%.2f) -- recreating player item + audio tap",
          self.player.rate);

    AVAsset *asset = self.currentAsset;

    // Tear down only what's specific to the old AVPlayerItem/tap -- deliberately not -cleanup
    // (which also removes the interruption/route-change observers this method itself depends
    // on being called from) and not a blanket -removeObserver:self on defaultCenter.
    [self cleanupAudioTap];
    AVPlayerItem *oldItem = self.playerItem;
    if (oldItem) {
        @try {
            [oldItem removeObserver:self forKeyPath:@"status"];
        } @catch (NSException *exception) {
            // Observer might not be registered
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                          name:AVPlayerItemDidPlayToEndTimeNotification
                                                        object:oldItem];
    }

    AVPlayerItem *newItem = [AVPlayerItem playerItemWithAsset:asset];
    self.playerItem = newItem;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:newItem];
    [newItem addObserver:self
               forKeyPath:@"status"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:nil];

    // self.player (and its volume/actionAtItemEnd/rate-KVO/rate-notification wiring) is kept
    // as-is -- replaceCurrentItemWithPlayerItem: is exactly the API meant for swapping in a
    // fresh item without disturbing any of that.
    [self.player replaceCurrentItemWithPlayerItem:newItem];

    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> * _Nullable audioTracks, NSError * _Nullable audioError) {
        if (audioError || audioTracks.count == 0) {
            NSLog(@"MockMediaSource: ⚠️ Re-assert: no audio track found: %@", audioError);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupAudioTapForTrack:audioTracks.firstObject];
            [self.player play];
            NSLog(@"MockMediaSource: 🔊 Player item + audio tap recreated, resumed playback (rate=%.2f)", self.player.rate);
        });
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"status"] && object == self.playerItem) {
        AVPlayerItemStatus newStatus = [change[NSKeyValueChangeNewKey] integerValue];
        NSLog(@"MockMediaSource: 🔊 PlayerItem status changed to %ld error=%@",
              (long)newStatus, self.playerItem.error);
    }

    if ([keyPath isEqualToString:@"rate"]) {
        float oldRate = [change[NSKeyValueChangeOldKey] floatValue];
        float newRate = [change[NSKeyValueChangeNewKey] floatValue];

        // If player stopped unexpectedly, restart it and recreate audio tap
        if (newRate == 0.0 && self.isPlaying && oldRate > 0.0) {
            AVPlayerItemStatus itemStatus = self.playerItem.status;
            NSString *waitReason = self.player.reasonForWaitingToPlay ?: @"(none)";
            AVPlayerTimeControlStatus timeStatus = self.player.timeControlStatus;
            AVAudioSession *audioSession = [AVAudioSession sharedInstance];
            NSLog(@"MockMediaSource: ⚠️ Player stopped unexpectedly!"
                  " itemStatus=%ld timeControlStatus=%ld waitReason=%@"
                  " audioSession: category=%@ mode=%@ route=%@"
                  " currentRoute.outputs=%@",
                  (long)itemStatus, (long)timeStatus, waitReason,
                  audioSession.category, audioSession.mode,
                  audioSession.currentRoute,
                  audioSession.currentRoute.outputs);
            // Resume immediately — don't wait, don't recreate the tap.
            // The tap is still valid after a pause/resume; the silence fill
            // handles any transient GetSourceAudio failures during the gap.
            [self.player play];
            NSLog(@"MockMediaSource: Immediately resumed player (rate=%.2f)", self.player.rate);
        }
    }
}

#pragma mark - Delegate Notification

- (void)notifyDelegateOfStateChange:(BOOL)isEnabled {
    NSArray<MockMediaSourceDelegateProxy *> *proxies;
    @synchronized(self.videoDelegateProxies) {
        proxies = [self.videoDelegateProxies copy];
    }
    NSMutableArray *stale = nil;
    for (MockMediaSourceDelegateProxy *proxy in proxies) {
        if (![proxy deliverStateChange:isEnabled fromSource:self]) {
            if (!stale) stale = [NSMutableArray new];
            [stale addObject:proxy];
        }
    }
    if (stale.count > 0) {
        @synchronized(self.videoDelegateProxies) {
            [self.videoDelegateProxies removeObjectsInArray:stale];
        }
    }
}

@end

#pragma mark - Audio Tap Callbacks

static void audioTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    AudioTapContext *context = calloc(1, sizeof(AudioTapContext));
    context->source = (__bridge MockMediaSource *)clientInfo;
    *tapStorageOut = context;
}

static void audioTapFinalize(MTAudioProcessingTapRef tap) {
    AudioTapContext *context = (AudioTapContext *)MTAudioProcessingTapGetStorage(tap);
    if (context->converter) {
        AudioConverterDispose(context->converter);
        context->converter = NULL;
    }
    free(context);
}

static void audioTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                           const AudioStreamBasicDescription *processingFormat) {
    AudioTapContext *context = (AudioTapContext *)MTAudioProcessingTapGetStorage(tap);
    context->processingFormat = *processingFormat;
    // Store format and try to set up converter if target format is already known
    context->source.audioTapFormat = *processingFormat;
    context->source.audioTapFormatReady = YES;
    NSLog(@"MockMediaSource: Audio tap prepared - %.0f Hz, %u channels, bitsPerChannel: %u, bytesPerFrame: %u, formatID: %u, formatFlags: 0x%x",
          processingFormat->mSampleRate, (unsigned int)processingFormat->mChannelsPerFrame,
          (unsigned int)processingFormat->mBitsPerChannel, (unsigned int)processingFormat->mBytesPerFrame,
          (unsigned int)processingFormat->mFormatID, (unsigned int)processingFormat->mFormatFlags);
}

static void audioTapUnprepare(MTAudioProcessingTapRef tap) {
    NSLog(@"MockMediaSource: Audio tap unprepared");
}

/// Convert audio from tap format to target (mic) format, via the shared QWAudioConvertBuffer
/// helper (also used by QWAudioUnitBridge's WebRTC injection path — previously each had its
/// own near-identical interleave+convert implementation).
/// Returns YES on success, populating outData (caller must free), outSize, outFrames, outFormat.
static BOOL convertAudioTapData(AudioTapContext *context,
                                AudioBufferList *bufferListInOut,
                                CMItemCount numberFramesGot,
                                void **outData, size_t *outSize,
                                CMItemCount *outFrames,
                                AudioStreamBasicDescription *outFormat) {
    *outFormat = context->outputFormat;

    AudioBufferList *converted = NULL;
    UInt32 producedFrames = 0;
    if (!QWAudioConvertBuffer(context->converter, bufferListInOut, &context->processingFormat,
                               (UInt32)numberFramesGot, outFormat, &converted, &producedFrames)) {
        static int convFailCount = 0;
        if (++convFailCount <= 3) {
            NSLog(@"MockMediaSource: QWAudioConvertBuffer failed (#%d)", convFailCount);
        }
        return NO;
    }

    // This call site's outputFormat has always been interleaved (a single mic-recording
    // target format, never non-interleaved), so `converted` has exactly one buffer — hand its
    // raw pointer back directly to match this function's existing contract (caller owns/frees
    // *outData as a bare buffer), freeing only the AudioBufferList wrapper itself.
    *outData = converted->mBuffers[0].mData;
    *outSize = converted->mBuffers[0].mDataByteSize;
    *outFrames = producedFrames; // authoritative count from the converter, not recomputed from mDataByteSize
    free(converted);
    return YES;
}

static void audioTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                           MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                           CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    AudioTapContext *context = (AudioTapContext *)MTAudioProcessingTapGetStorage(tap);
    MockMediaSource *source = context->source;

    // Get audio from player
    CMItemCount numberFramesGot = 0;
    CMTimeRange timeRange = kCMTimeRangeZero;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                         flagsOut, &timeRange, &numberFramesGot);

    BOOL gotSourceAudio = (status == noErr);

    if (!gotSourceAudio) {
        if (++sAudioTapFailCount <= 5) {
            NSLog(@"MockMediaSource: Audio tap GetSourceAudio failed: %d (#%d)"
                  " flags=0x%x numberFrames=%ld playerRate=%.2f",
                  (int)status, sAudioTapFailCount, (unsigned int)flags,
                  (long)numberFrames, source.player.rate);
        }
        // Fill buffers with silence instead of dropping — keeps the writer fed
        for (UInt32 i = 0; i < bufferListInOut->mNumberBuffers; i++) {
            memset(bufferListInOut->mBuffers[i].mData, 0, bufferListInOut->mBuffers[i].mDataByteSize);
        }
        numberFramesGot = numberFrames;
    }

    *numberFramesOut = numberFramesGot;

    // Independent WebRTC injection path: pushes real source audio (before any of the
    // conversion/delivery below, which is gated on an AVCaptureAudioDataOutput/AVAudioRecorder
    // delegate being registered — WebRTC apps like Citizen never register one, since Agora
    // bypasses those APIs entirely) into the ring buffer audiounit.m's AudioUnitRender hook
    // reads from. No-ops until a WebRTC mic-capture Audio Unit has been identified and its
    // format configured via QWAudioUnitBridge -configureTargetFormat:. Only pushes real
    // (non-silence) audio — no point feeding injected silence into the ring buffer underrun
    // path when the render hook's own underrun fallback already does the equivalent thing
    // (passes real mic audio through).
    if (gotSourceAudio) {
        [[QWAudioUnitBridge sharedInstance] pushSourceBuffer:bufferListInOut
                                                    sourceFormat:context->processingFormat
                                                      frameCount:(UInt32)numberFramesGot];
    }

    if (++sAudioTapProcessCount <= 3) {
        NSLog(@"MockMediaSource: Audio tap process #%d — got %ld frames (silence=%d)",
              sAudioTapProcessCount, (long)numberFramesGot, !gotSourceAudio);
    }

    // Lazily create the AudioConverter when the target (mic) format is known
    if (!context->hasConverter && source.targetAudioFormatReady) {
        // Build an interleaved version of the tap format for the converter input
        AudioStreamBasicDescription srcFormat = context->processingFormat;
        // AudioConverter needs interleaved input — adjust if tap is non-interleaved
        srcFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
        srcFormat.mBytesPerFrame = srcFormat.mBytesPerPacket =
            (srcFormat.mBitsPerChannel / 8) * srcFormat.mChannelsPerFrame;

        AudioStreamBasicDescription dstFormat = source.targetAudioFormat;
        OSStatus convStatus = AudioConverterNew(&srcFormat, &dstFormat, &context->converter);
        if (convStatus == noErr) {
            context->hasConverter = YES;
            context->outputFormat = dstFormat;
            NSLog(@"MockMediaSource: Audio converter created — %.0fHz %uch → %.0fHz %uch",
                  context->processingFormat.mSampleRate, (unsigned)context->processingFormat.mChannelsPerFrame,
                  dstFormat.mSampleRate, (unsigned)dstFormat.mChannelsPerFrame);
        } else {
            NSLog(@"MockMediaSource: ⚠️ AudioConverterNew failed: %d", (int)convStatus);
        }
    }

    // Determine output format and data
    AudioStreamBasicDescription deliveryFormat;
    void *deliveryData = NULL;
    size_t deliverySize = 0;
    CMItemCount deliveryFrames = numberFramesGot;
    void *convertedBuffer = NULL;

    BOOL converted = NO;
    if (context->hasConverter && gotSourceAudio) {
        converted = convertAudioTapData(context, bufferListInOut, numberFramesGot,
                                        &deliveryData, &deliverySize, &deliveryFrames, &deliveryFormat);
        if (converted) {
            convertedBuffer = deliveryData;
        }
    }

    if (!converted) {
        // No converter, silence mode, or conversion failed — deliver in target format if possible
        if (context->hasConverter && source.targetAudioFormatReady) {
            // Deliver silence in the target (mic) format
            deliveryFormat = context->outputFormat;
            double rateRatio = deliveryFormat.mSampleRate / context->processingFormat.mSampleRate;
            deliveryFrames = (CMItemCount)(numberFramesGot * rateRatio);
            deliverySize = deliveryFrames * deliveryFormat.mBytesPerFrame;
            convertedBuffer = calloc(1, deliverySize); // zeroed = silence
            deliveryData = convertedBuffer;
        } else {
            // Raw tap format fallback
            deliveryFormat = context->processingFormat;
            deliverySize = 0;
            for (UInt32 i = 0; i < bufferListInOut->mNumberBuffers; i++) {
                deliverySize += bufferListInOut->mBuffers[i].mDataByteSize;
            }
        }
    }

    // Create CMSampleBuffer and deliver to the app
    CMAudioFormatDescriptionRef formatDesc = NULL;
    status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &deliveryFormat, 0, NULL, 0, NULL, NULL, &formatDesc);
    if (status == noErr && formatDesc) {
        CMBlockBufferRef blockBuffer = NULL;
        status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, deliverySize,
                                                     kCFAllocatorDefault, NULL, 0, deliverySize, 0, &blockBuffer);
        if (status == noErr && blockBuffer) {
            if (deliveryData) {
                CMBlockBufferReplaceDataBytes(deliveryData, blockBuffer, 0, deliverySize);
            } else {
                // Original tap data — may be in multiple buffers
                size_t offset = 0;
                for (UInt32 i = 0; i < bufferListInOut->mNumberBuffers; i++) {
                    if (bufferListInOut->mBuffers[i].mData) {
                        CMBlockBufferReplaceDataBytes(bufferListInOut->mBuffers[i].mData, blockBuffer, offset, bufferListInOut->mBuffers[i].mDataByteSize);
                    }
                    offset += bufferListInOut->mBuffers[i].mDataByteSize;
                }
            }

            CMTime adjustedTimestamp = [source getAdjustedTimestamp];
            CMSampleBufferRef sampleBuffer = NULL;
            status = CMAudioSampleBufferCreateWithPacketDescriptions(
                kCFAllocatorDefault, blockBuffer, true, NULL, NULL,
                formatDesc, deliveryFrames, adjustedTimestamp, NULL, &sampleBuffer);

            if (status == noErr && sampleBuffer) {
                [source deliverAudioSampleBuffer:sampleBuffer];
                CFRelease(sampleBuffer);
            }
            CFRelease(blockBuffer);
        }
        CFRelease(formatDesc);
    }

    if (convertedBuffer) free(convertedBuffer);

    // Zero out buffer to silence the speaker (AVPlayer audio output)
    for (UInt32 i = 0; i < bufferListInOut->mNumberBuffers; i++) {
        memset(bufferListInOut->mBuffers[i].mData, 0, bufferListInOut->mBuffers[i].mDataByteSize);
    }
}
