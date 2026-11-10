#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "MediaInjectionConfigManager.h"

// Forward-declare UIImage so consumers that don't import UIKit still compile.
@class UIImage;

NS_ASSUME_NONNULL_BEGIN

/**
 * Protocol for objects that want to receive video frames from MockMediaSource
 */
@protocol MockMediaSourceVideoDelegate <NSObject>

@required
- (void)mockMediaSource:(id)source didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@optional
/**
 * Called when media injection state changes (enabled/disabled)
 * Delegates can implement this to respond to state changes
 */
- (void)mockMediaSource:(id)source didChangeInjectionState:(BOOL)isEnabled;

@end

/**
 * Unified mock media source that provides both video and audio from configured media files
 * Handles video frame delivery and audio sample extraction with synchronized timestamps
 * Replaces separate MockCamera and MockMicrophone implementations
 */
@interface MockMediaSource : NSObject

/**
 * Singleton instance
 */
+ (instancetype)sharedInstance;

#pragma mark - Configuration

/**
 * Reload with new configuration (called by MediaInjectionConfigManager)
 */
- (void)reloadWithConfig:(MediaInjectionConfig * _Nullable)config;

/**
 * Check if media injection is currently enabled
 */
- (BOOL)isMediaInjectionEnabled;

/**
 * Visual rotation (clockwise degrees, 0/90/180/270) to apply when rendering
 * injected frames on the preview overlay. Does NOT rotate the underlying
 * pixel data — consumers of the photo-capture path receive the raw sensor
 * orientation so dimensions stay in sync with AVCaptureResolvedPhotoSettings.
 */
- (NSInteger)previewRotation;

/**
 * The source UIImage for image-type configs in NATIVE camera-sensor
 * orientation (landscape for iPhone sensors). Used by the live preview
 * pipeline and VDO delegate so any downstream CoreML corner/blur/glare
 * gates see the document in the orientation they were trained for. Nil
 * for video / audio / no-config states. Owned by MediaInjectionConfigManager,
 * which sets it before reloadWithConfig: and clears it explicitly when
 * transitioning away from an image config. reloadWithConfig: does NOT touch it.
 */
@property (nonatomic, strong, nullable) UIImage *originalImage;

/**
 * Check if the loaded media has video tracks
 * Returns NO for audio-only media
 */
- (BOOL)hasVideo;

/**
 * Check if the loaded media has audio tracks
 * Returns NO for image-only media (should use real microphone)
 */
- (BOOL)hasAudio;

/**
 * Set to YES when the first video frame has been delivered to the app.
 * Audio push delivery is held back until this is YES.
 */
@property (atomic, assign) BOOL firstVideoFrameDelivered;

/**
 * Set to YES when the first converted audio buffer has been delivered.
 * Until this is YES, the wrapper forwards real mic audio to keep the writer fed.
 */
@property (atomic, assign) BOOL injectedAudioFlowing;

/**
 * Get the current playback timestamp (monotonic, wall-clock based).
 * Use this for both video and audio to keep them in sync.
 */
- (CMTime)getAdjustedTimestamp;

#pragma mark - Video

/**
 * Get the most recently delivered video frame (for preview layer)
 * Returns NULL if no frame has been delivered yet
 * Caller must call CVPixelBufferRelease when done
 */
- (CVPixelBufferRef _Nullable)getLatestFrame;

/**
 * Register a delegate to receive video frames.
 * Multiple delegates can register — all will receive frames.
 * Uses a proxy with a weak reference. Safe if the delegate deallocates
 * without unregistering (proxy becomes a no-op and is pruned automatically).
 * @param delegate Object conforming to MockMediaSourceVideoDelegate
 */
- (void)registerVideoDelegate:(id<MockMediaSourceVideoDelegate>)delegate;

/**
 * Register an AVCaptureVideoDataOutput delegate in push mode.
 * MockMediaSource will push frames directly to this delegate on the given queue,
 * matching how audio injection works. The wrapper just drops real camera frames.
 */
- (void)registerVideoCaptureDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                              output:(AVCaptureVideoDataOutput *)output
                       callbackQueue:(dispatch_queue_t)queue;

/**
 * Unregister a video frame delegate
 * @param delegate The delegate to unregister
 */
- (void)unregisterVideoDelegate:(id<MockMediaSourceVideoDelegate>)delegate;

/**
 * Cache the camera's intrinsic matrix, harvested from a real AVCapture sample
 * buffer (by the AVCaptureVideoDataOutput wrapper before dropping it). Injected
 * sample buffers will carry this attachment so apps that consult
 * kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix see the expected 3×3 matrix.
 * If the app never enabled intrinsic-matrix delivery on its connection, this
 * cache simply stays empty and no attachment is stamped.
 */
- (void)cacheCameraIntrinsicMatrix:(NSData *)matrixData;

/**
 * Cache the full propagating-attachments dictionary from a real AVCapture sample
 * buffer (Orientation, DPIWidth/Height, {Exif}, {TIFF}, {MakerApple}, etc.).
 * Each injected sample buffer is stamped with these attachments so consumers
 * that read them (image-orientation renderers, Vision framework, etc.) see
 * the same metadata the real camera pipeline would produce.
 */
- (void)cacheCameraSampleBufferAttachments:(NSDictionary *)attachments;

#pragma mark - Audio

/**
 * The audio format produced by the audio tap (set during tap prepare).
 * Use this to configure format conversion when consuming from the ring buffer.
 */
@property (nonatomic, assign, readonly) AudioStreamBasicDescription audioTapFormat;
@property (nonatomic, assign, readonly) BOOL audioTapFormatReady;
@property (nonatomic, assign, readonly) BOOL targetAudioFormatReady;
@property (nonatomic, assign) AudioStreamBasicDescription targetAudioFormat;

/**
 * Register audio delegate with specific audio format requirements
 * Supports multiple delegates with different formats
 */
- (void)registerAudioDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                       output:(AVCaptureAudioDataOutput *)output
                audioSettings:(NSDictionary * _Nullable)audioSettings
                callbackQueue:(dispatch_queue_t _Nullable)queue;

/**
 * Set the target audio format for conversion (e.g. mic format).
 * Audio from the tap will be converted to this format before delivery.
 */
- (void)configureTargetAudioFormat:(const AudioStreamBasicDescription *)format;


#pragma mark - Playback Control

/**
 * Start media playback and frame delivery
 * Call this when recording starts to begin injecting media
 * If media is already loaded but paused, this will start playback
 */
- (void)startMediaPlayback;

/**
 * Stop media playback and reset to beginning
 * Call this when recording stops to show placeholder frame again
 * Returns to waiting state and displays red placeholder
 */
- (void)stopMediaPlayback;

#pragma mark - Timestamp Management

/**
 * Reset timestamp tracking for new recording
 * Call this when starting a new recording to ensure timestamps start from zero
 */
- (void)resetTimestamps;

@end

/// YES while an injected frame for this output waits on the app's queue.
BOOL QAWVideoDeliveryInFlight(AVCaptureVideoDataOutput *output);

/// Calls the app's video delegate on its own queue, as AVFoundation does. Skips the
/// frame while the previous one is still queued. A nil queue drops the frame.
void QAWDeliverVideoSampleBuffer(AVCaptureVideoDataOutput *output,
                                 id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
                                 dispatch_queue_t _Nullable queue,
                                 CMSampleBufferRef sampleBuffer);

NS_ASSUME_NONNULL_END
