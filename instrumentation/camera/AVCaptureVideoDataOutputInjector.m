#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "AVCaptureVideoDataOutputInjector.h"
#import "MockMediaSource.h"
#import "utils.h"
#import <CoreImage/CoreImage.h>

#pragma mark - Diagnostics helpers

/// Render a FourCC OSType as its four ASCII chars if printable, otherwise hex.
static inline NSString *QAWolf_FourCCString(OSType fourcc) {
    char cc[5];
    cc[0] = (char)((fourcc >> 24) & 0xff);
    cc[1] = (char)((fourcc >> 16) & 0xff);
    cc[2] = (char)((fourcc >> 8) & 0xff);
    cc[3] = (char)(fourcc & 0xff);
    cc[4] = 0;
    for (int i = 0; i < 4; i++) {
        if (cc[i] < 32 || cc[i] > 126) {
            return [NSString stringWithFormat:@"0x%08x", (unsigned)fourcc];
        }
    }
    return [NSString stringWithFormat:@"'%s'(0x%08x)", cc, (unsigned)fourcc];
}

#pragma mark - WeakDelegateBox

/** Weak box to safely store delegate references as associated objects. */
@interface WeakDelegateBox : NSObject
@property (nonatomic, weak) id delegate;
@end
@implementation WeakDelegateBox
@end

#pragma mark - VideoDataOutputDelegateWrapper

@interface VideoDataOutputDelegateWrapper : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
@end

@implementation VideoDataOutputDelegateWrapper

- (instancetype)initWithOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    self = [super init];
    if (self) {
        _originalDelegate = delegate;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // Harvest the FULL propagating attachments dictionary from the real sample
    // buffer (Orientation, DPIWidth/Height, {Exif}, {TIFF}, {MakerApple},
    // CameraIntrinsicMatrix if enabled, …). MockMediaSource stamps these
    // attachments onto every injected sample buffer so downstream consumers
    // see identical metadata to real camera output.
    CFDictionaryRef propagating = CMCopyDictionaryOfAttachments(NULL,
                                                                sampleBuffer,
                                                                kCMAttachmentMode_ShouldPropagate);
    if (propagating) {
        NSDictionary *dict = (__bridge_transfer NSDictionary *)propagating;
        [[MockMediaSource sharedInstance] cacheCameraSampleBufferAttachments:dict];
    }

    // Keep the intrinsic-matrix cache too for backward compatibility with code
    // paths that only need that one attachment.
    CFTypeRef raw = CMGetAttachment(sampleBuffer,
                                    kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                    NULL);
    if (raw && CFGetTypeID(raw) == CFDataGetTypeID()) {
        [[MockMediaSource sharedInstance] cacheCameraIntrinsicMatrix:(__bridge NSData *)(CFDataRef)raw];
    }

    // Drop the real camera frame — MockMediaSource pushes injected video directly
    // to the app's delegate via deliverSampleBufferToDelegates (display link driven).
    // This matches the audio injection pattern: wrapper drops, MockMediaSource pushes.
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if (delegate && [delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [delegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

#pragma mark - Transparent forwarding

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id delegate = self.originalDelegate;
    return delegate ? [delegate respondsToSelector:aSelector] : NO;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id delegate = self.originalDelegate;
    if (delegate && [delegate respondsToSelector:aSelector]) return delegate;
    return [super forwardingTargetForSelector:aSelector];
}

@end

#pragma mark - FrameDeliveryHelper

@implementation FrameDeliveryHelper

+ (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    withOriginalTiming:(CMSampleBufferRef)originalSampleBuffer {
    if (!pixelBuffer || !originalSampleBuffer) return NULL;

    // Extract timing information from the original camera sample buffer
    CMSampleTimingInfo timingInfo;
    OSStatus status = CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, 0, &timingInfo);
    if (status != noErr) {
        NSLog(@"QAWolf:VideoInjection: Failed to get timing info from original buffer: %d", status);
        return NULL;
    }

    // Create format description from pixel buffer
    CMVideoFormatDescriptionRef formatDesc = NULL;
    status = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &formatDesc);
    if (status != noErr) {
        NSLog(@"QAWolf:VideoInjection: Failed to create format description: %d", status);
        return NULL;
    }

    // Create sample buffer with original timing
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(NULL,
                                                     pixelBuffer,
                                                     formatDesc,
                                                     &timingInfo,
                                                     &sampleBuffer);

    CFRelease(formatDesc);

    if (status != noErr) {
        NSLog(@"QAWolf:VideoInjection: Failed to create sample buffer with original timing: %d", status);
        return NULL;
    }

    return sampleBuffer;
}

@end

#pragma mark - AVCaptureVideoDataOutput Event-Driven Injection

@interface AVCaptureVideoDataOutput (EventDrivenVideoInjection) <MockMediaSourceVideoDelegate>
@end

@implementation AVCaptureVideoDataOutput (EventDrivenVideoInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(setSampleBufferDelegate:queue:)
                   swizzledSelector:@selector(event_setSampleBufferDelegate:queue:)];

        // Swizzle dealloc to ensure proper cleanup
        [Utils swizzleMethodInClass:self
                   originalSelector:NSSelectorFromString(@"dealloc")
                   swizzledSelector:@selector(videoDataOutput_dealloc)];

        NSLog(@"QAWolf:VideoDataOutput: Swizzling complete");
    });
}

- (void)event_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                                queue:(dispatch_queue_t)queue {

    NSLog(@"QAWolf:VideoDataOutput: setSampleBufferDelegate called with delegate=%p, queue=%p", delegate, queue);

    // Guard: if the delegate IS our wrapper, pass through to avoid re-wrapping
    if ([delegate isKindOfClass:[VideoDataOutputDelegateWrapper class]]) {
        [self event_setSampleBufferDelegate:delegate queue:queue];
        return;
    }

    // Dump what the app is configuring — useful for diagnosing why injection
    // doesn't match a host's expectations. Only logged for non-nil delegates
    // (the interesting case); teardown has nothing new.
    if (delegate != nil) {
        // 1. videoSettings — what pixel format / attrs the app requested
        NSDictionary *vs = self.videoSettings;
        NSLog(@"QAWolf:CaptureConfig: videoSettings=%@", vs ?: @"(nil/default 420v)");

        // 2. What formats the output supports
        NSArray *avail = self.availableVideoCVPixelFormatTypes;
        NSMutableArray *availStr = [NSMutableArray array];
        for (NSNumber *n in avail) {
            [availStr addObject:QAWolf_FourCCString((OSType)n.unsignedIntValue)];
        }
        NSLog(@"QAWolf:CaptureConfig: availableVideoCVPixelFormatTypes=[%@]", [availStr componentsJoinedByString:@", "]);

        // 3. alwaysDiscardsLateVideoFrames — tells us if the host wants real-time only
        NSLog(@"QAWolf:CaptureConfig: alwaysDiscardsLateVideoFrames=%d", self.alwaysDiscardsLateVideoFrames);

        // 4. Connection properties — orientation, intrinsic delivery, mirroring, data-stabilization
        AVCaptureConnection *conn = [self connectionWithMediaType:AVMediaTypeVideo];
        if (conn) {
            NSLog(@"QAWolf:CaptureConfig: connection active=%d enabled=%d videoOrientation=%ld videoMirrored=%d intrinsicMatrixDelivery=%d preferredStab=%ld",
                  conn.active, conn.enabled, (long)conn.videoOrientation, conn.videoMirrored,
                  conn.isCameraIntrinsicMatrixDeliveryEnabled, (long)conn.preferredVideoStabilizationMode);

            // Input port format at delegate-install time — we care whether this is nil
            // (pre-startRunning) or populated already.
            AVCaptureInputPort *port = conn.inputPorts.firstObject;
            CMFormatDescriptionRef portFmt = port.formatDescription;
            if (portFmt) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(portFmt);
                FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(portFmt);
                NSLog(@"QAWolf:CaptureConfig: inputPort format=%@ %dx%d (populated at delegate-install time)",
                      QAWolf_FourCCString(mediaSubType), dims.width, dims.height);
            } else {
                NSLog(@"QAWolf:CaptureConfig: inputPort format=nil (capture graph not yet configured — late-detect in delivery path)");
            }
        } else {
            NSLog(@"QAWolf:CaptureConfig: no AVMediaTypeVideo connection on output");
        }

        // 5. How many connections are bound to this output (usually 1 — the video one)
        NSLog(@"QAWolf:CaptureConfig: outputs_connected=%lu", (unsigned long)self.connections.count);
    }

    // Store the original delegate and queue for potential state changes
    [self setOriginalDelegate:delegate];
    objc_setAssociatedObject(self, @selector(delegateQueue), queue, OBJC_ASSOCIATION_RETAIN);

    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    // Check if we have video to inject
    BOOL hasVideo = [mediaSource hasVideo];
    BOOL hasAudio = [mediaSource hasAudio];

    if (hasVideo) {
        // Video injection (push mode): MockMediaSource pushes frames via display link
        if (delegate != nil) {
            NSLog(@"QAWolf:VideoDataOutput: Delegate set - starting video injection (push mode)");

            // Register delegate so MockMediaSource pushes frames directly
            [mediaSource registerVideoCaptureDelegate:delegate output:self callbackQueue:queue];

            // Install wrapper that drops real camera frames
            VideoDataOutputDelegateWrapper *wrapper = [[VideoDataOutputDelegateWrapper alloc] initWithOriginalDelegate:delegate];
            objc_setAssociatedObject(self, @selector(delegateWrapper), wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self event_setSampleBufferDelegate:wrapper queue:queue];

            // Start playback — display link will push frames to delegate
            [mediaSource startMediaPlayback];

            NSLog(@"QAWolf:VideoDataOutput: Video injection started (delegate=%p)", delegate);
        } else {
            // Delegate being cleared = recording stopped
            NSLog(@"QAWolf:VideoDataOutput: Delegate cleared - stopping video injection");

            // Unregister capture delegate
            [mediaSource registerVideoCaptureDelegate:nil output:self callbackQueue:nil];

            // Stop playback
            [mediaSource stopMediaPlayback];

            // Clear wrapper
            objc_setAssociatedObject(self, @selector(delegateWrapper), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self event_setSampleBufferDelegate:nil queue:queue];

            NSLog(@"QAWolf:VideoDataOutput: Video injection stopped");
        }
        return;
    } else if (hasAudio) {
        // Audio-only injection: block camera frames, only deliver audio
        if (delegate != nil) {
            NSLog(@"QAWolf:VideoDataOutput: Audio-only injection - blocking camera frames, starting audio playback");

            // Don't set the delegate - this prevents camera frames from being delivered
            // Audio will be delivered via AVCaptureAudioDataOutput

            // Start audio playback
            [mediaSource startMediaPlayback];
            NSLog(@"QAWolf:VideoDataOutput: Audio playback started, camera frames blocked");
        } else {
            NSLog(@"QAWolf:VideoDataOutput: Stopping audio playback");
            [mediaSource stopMediaPlayback];
        }
        return;
    }

    NSLog(@"QAWolf:VideoDataOutput: No video/audio to inject - using real camera");
    // Fall back to original implementation - use real camera
    [self event_setSampleBufferDelegate:delegate queue:queue];
}

#pragma mark - MockMediaSourceVideoDelegate

- (void)mockMediaSource:(id)source didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // captureDelegate is stored with OBJC_ASSOCIATION_ASSIGN — it's a raw pointer
    // that may dangle if the app's delegate was freed. Use the same proxy pattern:
    // store it as a weak reference instead.
    id<AVCaptureVideoDataOutputSampleBufferDelegate> captureDelegate = self.captureDelegate;
    if (!captureDelegate) return;

    QAWDeliverVideoSampleBuffer(self, captureDelegate, self.delegateQueue, sampleBuffer);
}

- (void)mockMediaSource:(id)source didChangeInjectionState:(BOOL)isEnabled {
    NSLog(@"QAWolf:VideoDataOutput: Injection state changed to %@", isEnabled ? @"ENABLED" : @"DISABLED");

    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleInjectionStateChange:isEnabled];
    });
}

- (void)handleInjectionStateChange:(BOOL)injectionEnabled {
    // Get stored delegate and queue
    id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate = self.originalDelegate;
    dispatch_queue_t queue = self.delegateQueue;

    if (!originalDelegate || !queue) {
        NSLog(@"QAWolf:VideoDataOutput: No delegate configured, state change ignored");
        return;
    }

    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    if (injectionEnabled) {
        // Check if we have video - if audio-only, don't switch from real camera
        if (![mediaSource hasVideo]) {
            NSLog(@"QAWolf:VideoDataOutput: Audio-only injection - keeping real camera for video");
            return;
        }

        // Switch FROM real camera TO injected video
        NSLog(@"QAWolf:VideoDataOutput: Switching from real camera to injected video");

        // Remove real camera delegate
        [self event_setSampleBufferDelegate:nil queue:queue];

        // Store the capture delegate for frame forwarding
        [self setCaptureDelegate:originalDelegate];

        // Register with MockMediaSource to receive injected frames
        [mediaSource registerVideoDelegate:self];

        // Start media playback now that delegate is registered
        [mediaSource startMediaPlayback];
        NSLog(@"QAWolf:VideoDataOutput: Media playback started for state change");

        NSLog(@"QAWolf:VideoDataOutput: Now using injected video");

    } else {
        // Switch FROM injected video TO real camera
        NSLog(@"QAWolf:VideoDataOutput: Switching from injected video to real camera");

        // Unregister from MockMediaSource
        [mediaSource unregisterVideoDelegate:self];

        // Stop and reset media playback to show placeholder
        [mediaSource stopMediaPlayback];

        // Clear capture delegate
        [self setCaptureDelegate:nil];

        // Re-enable real camera delegate
        [self event_setSampleBufferDelegate:originalDelegate queue:queue];

        NSLog(@"QAWolf:VideoDataOutput: Now using real camera");
    }
}

- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)captureDelegate {
    WeakDelegateBox *box = objc_getAssociatedObject(self, @selector(captureDelegate));
    return box.delegate;
}

- (void)setCaptureDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    if (delegate) {
        WeakDelegateBox *box = [[WeakDelegateBox alloc] init];
        box.delegate = delegate;
        objc_setAssociatedObject(self, @selector(captureDelegate), box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(self, @selector(captureDelegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)originalDelegate {
    WeakDelegateBox *box = objc_getAssociatedObject(self, @selector(originalDelegate));
    return box.delegate;
}

- (void)setOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    if (delegate) {
        WeakDelegateBox *box = [[WeakDelegateBox alloc] init];
        box.delegate = delegate;
        objc_setAssociatedObject(self, @selector(originalDelegate), box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(self, @selector(originalDelegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (dispatch_queue_t)delegateQueue {
    return objc_getAssociatedObject(self, @selector(delegateQueue));
}

#pragma mark - Cleanup

- (void)videoDataOutput_dealloc {
    NSLog(@"QAWolf:VideoDataOutput: Cleaning up before dealloc %p", self);

    // Unregister from MockMediaSource - this is our responsibility!
    // Even though MockMediaSource uses weak references, we must explicitly unregister
    // to avoid race conditions during deallocation
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    [mediaSource unregisterVideoDelegate:self];
    [mediaSource registerVideoCaptureDelegate:nil output:self callbackQueue:nil];

    // Stop and reset media playback on cleanup
    [mediaSource stopMediaPlayback];

    // Clear associated objects (not strictly necessary, but good hygiene)
    [self setCaptureDelegate:nil];
    [self setOriginalDelegate:nil];
    objc_setAssociatedObject(self, @selector(delegateQueue), nil, OBJC_ASSOCIATION_RETAIN);

    // Call original dealloc (swizzling makes this call the real dealloc)
    [self videoDataOutput_dealloc];
}

@end
