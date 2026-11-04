//
//  AVCaptureVideoPreviewLayerInjector.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 22.01.25.
//

#import "AVCaptureVideoPreviewLayerInjector.h"
#import "utils.h"
#import "MockMediaSource.h"
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Accelerate/Accelerate.h>


#pragma mark - AVCaptureVideoPreviewLayer (VideoOverlay)

// Generic preview-layer instrumentation. Approach: leave the real capture
// session connected so the preview layer keeps rendering the live camera;
// install an AVSampleBufferDisplayLayer as a sublayer with zPosition=FLT_MAX
// and push synthesized frames into it whenever injection is enabled. The
// overlay's .hidden flag toggles with the injection state — when injection
// is off the overlay hides and the real camera preview shows through.
//
// This avoids two problems from the previous design:
//   1. Disconnecting the session broke the real-camera fallback path.
//   2. Creating the overlay lazily on first delivered frame raced with view
//      lifecycle events that tore the delegate registration down before any
//      frame arrived (observed with apps that present the camera UI inside
//      a sheet that re-creates its view tree on rotation).

@interface AVCaptureVideoPreviewLayer (VideoOverlay) <MockMediaSourceVideoDelegate>
@end

@implementation AVCaptureVideoPreviewLayer (VideoOverlay)

#pragma mark - Swizzling

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(setSession:)
                   swizzledSelector:@selector(videoOverlay_setSession:)];

        // dealloc is the only lifecycle hook we need — the overlay is a
        // sublayer, so Core Animation tears it down automatically when the
        // preview layer is destroyed. We only swizzle dealloc to unregister
        // the MockMediaSource delegate.
        [Utils swizzleMethodInClass:self
                   originalSelector:NSSelectorFromString(@"dealloc")
                   swizzledSelector:@selector(videoOverlay_dealloc)];

        NSLog(@"QAWolf:PreviewOverlay: Preview layer swizzling complete");
    });
}

#pragma mark - setSession: interception

- (void)videoOverlay_setSession:(AVCaptureSession *)session {
    // Call through to the real setter so the preview layer continues to
    // render the live camera as usual. We never disconnect the session.
    [self videoOverlay_setSession:session];

    // Nothing to overlay on if the app cleared the session.
    if (!session) return;

    [self qaw_installOverlayIfNeeded];
    [self qaw_registerAsVideoDelegateIfNeeded];
}

#pragma mark - Overlay installation

- (void)qaw_installOverlayIfNeeded {
    AVSampleBufferDisplayLayer *existing = objc_getAssociatedObject(self, @selector(qaw_sbdlOverlay));
    if (existing) return;

    AVSampleBufferDisplayLayer *overlay = [AVSampleBufferDisplayLayer layer];
    overlay.frame = self.bounds;
    overlay.videoGravity = self.videoGravity ?: AVLayerVideoGravityResizeAspect;
    overlay.masksToBounds = YES;
    overlay.zPosition = FLT_MAX;
    overlay.hidden = YES;  // flipped on first successful enqueue / state change

    [self addSublayer:overlay];
    objc_setAssociatedObject(self,
                             @selector(qaw_sbdlOverlay),
                             overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"QAWolf:PreviewOverlay: installed SBDL overlay %p on preview layer %p gravity=%@ bounds=%.0fx%.0f",
          overlay, self, overlay.videoGravity,
          overlay.frame.size.width, overlay.frame.size.height);
}

- (void)qaw_registerAsVideoDelegateIfNeeded {
    NSNumber *registered = objc_getAssociatedObject(self, @selector(qaw_registerAsVideoDelegateIfNeeded));
    if ([registered boolValue]) return;

    [[MockMediaSource sharedInstance] registerVideoDelegate:self];
    objc_setAssociatedObject(self,
                             @selector(qaw_registerAsVideoDelegateIfNeeded),
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - MockMediaSourceVideoDelegate

- (void)mockMediaSource:(id)source didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    AVSampleBufferDisplayLayer *overlay = objc_getAssociatedObject(self, @selector(qaw_sbdlOverlay));
    if (!overlay || !sampleBuffer) return;

    // Keep overlay frame aligned with preview layer bounds on every delivery
    // — covers device rotation and auto-layout passes.
    if (!CGRectEqualToRect(overlay.frame, self.bounds)) {
        overlay.frame = self.bounds;
    }

    // Visual rotation: when MockMediaSource feeds landscape-sensor-native
    // pixels but the preview layer is portrait (typical when an app
    // requests landscape video orientation while presenting a portrait
    // preview), pre-rotate the CMSampleBuffer's underlying pixel buffer
    // before enqueueing. CATransform3D on AVSampleBufferDisplayLayer does
    // not visually rotate the SBDL's CMVideoFormat-driven rendering — the
    // pixels themselves have to be rotated in the buffer for the visual
    // change to land. previewRotation is config.rotation in degrees CW.
    NSInteger rotDeg = [[MockMediaSource sharedInstance] previewRotation];
    CMSampleBufferRef bufferToEnqueue = sampleBuffer;
    CMSampleBufferRef rotatedBuffer = NULL;
    if (rotDeg != 0) {
        rotatedBuffer = [self qaw_sampleBufferByRotating:sampleBuffer degreesCW:rotDeg];
        if (rotatedBuffer) bufferToEnqueue = rotatedBuffer;
    }

    // Track videoGravity changes. Apps commonly call setVideoGravity: after
    // setSession:, so the gravity captured at install time is often the
    // default (AspectFit) rather than the value the app actually wants
    // (AspectFill is typical for camera previews). Without this, the overlay
    // content is letterboxed inside the full preview-layer bounds even
    // though our overlay layer itself fills the bounds.
    AVLayerVideoGravity desiredGravity = self.videoGravity ?: AVLayerVideoGravityResizeAspect;
    if (![overlay.videoGravity isEqualToString:desiredGravity]) {
        overlay.videoGravity = desiredGravity;
    }


    // Stamp DisplayImmediately so the SBDL renders without a driven
    // timebase. MockMediaSource usually sets this, re-stamp defensively.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(bufferToEnqueue, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    if (overlay.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"QAWolf:PreviewOverlay: SBDL %p in failed state, flushing before enqueue", overlay);
        [overlay flush];
    }

    [overlay enqueueSampleBuffer:bufferToEnqueue];

    if (rotatedBuffer) {
        CFRelease(rotatedBuffer);
    }

    // First successful enqueue: reveal the overlay if injection is on.
    // This avoids a one-frame black flash between install and the first
    // buffer arriving.
    NSNumber *firstEnqueueDone = objc_getAssociatedObject(self, @selector(qaw_firstEnqueueDone));
    if (![firstEnqueueDone boolValue]) {
        BOOL injectionEnabled = [[MockMediaSource sharedInstance] isMediaInjectionEnabled];
        overlay.hidden = !injectionEnabled;
        objc_setAssociatedObject(self,
                                 @selector(qaw_firstEnqueueDone),
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Rotate a CMSampleBuffer's underlying pixel buffer by 90/180/270 degrees
// clockwise, returning a NEW retained CMSampleBufferRef that the caller
// owns (CFRelease after enqueue). Returns NULL on any failure path so
// callers can fall back to the original buffer.
- (CMSampleBufferRef)qaw_sampleBufferByRotating:(CMSampleBufferRef)src degreesCW:(NSInteger)deg {
    if (!src || (deg != 90 && deg != 180 && deg != 270)) return NULL;
    CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(src);
    if (!inPB) return NULL;

    OSType fmt4cc = CVPixelBufferGetPixelFormatType(inPB);
    if (fmt4cc != kCVPixelFormatType_32BGRA) return NULL;

    size_t srcW = CVPixelBufferGetWidth(inPB);
    size_t srcH = CVPixelBufferGetHeight(inPB);
    size_t outW = (deg == 180) ? srcW : srcH;
    size_t outH = (deg == 180) ? srcH : srcW;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    CVPixelBufferRef outPB = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &outPB) != kCVReturnSuccess
        || !outPB) {
        return NULL;
    }

    if (CVPixelBufferLockBaseAddress(inPB, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(outPB);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(outPB, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(inPB, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(outPB);
        return NULL;
    }

    vImage_Buffer srcBuf = {
        .data = CVPixelBufferGetBaseAddress(inPB),
        .height = srcH,
        .width = srcW,
        .rowBytes = CVPixelBufferGetBytesPerRow(inPB),
    };
    vImage_Buffer dstBuf = {
        .data = CVPixelBufferGetBaseAddress(outPB),
        .height = outH,
        .width = outW,
        .rowBytes = CVPixelBufferGetBytesPerRow(outPB),
    };

    // vImageRotate90_ARGB8888 rotation constants are deterministic and
    // direction-explicit, unlike CGImagePropertyOrientation which expresses
    // "where the source is oriented". The function operates on any 4-channel
    // 8-bit interleaved format (BGRA bytes pass through unchanged).
    uint8_t rotConst;
    switch (deg) {
        case 90:  rotConst = kRotate90DegreesClockwise;  break;
        case 180: rotConst = kRotate180DegreesClockwise; break;
        case 270: rotConst = kRotate270DegreesClockwise; break;
        default:  rotConst = kRotate0DegreesClockwise;   break;
    }
    uint8_t bgcolor[4] = {0, 0, 0, 0};
    vImage_Error vErr = vImageRotate90_ARGB8888(&srcBuf, &dstBuf, rotConst, bgcolor, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(outPB, 0);
    CVPixelBufferUnlockBaseAddress(inPB, kCVPixelBufferLock_ReadOnly);

    if (vErr != kvImageNoError) {
        NSLog(@"QAWolf:PreviewOverlay: vImageRotate90 failed err=%ld", (long)vErr);
        CVPixelBufferRelease(outPB);
        return NULL;
    }

    // Build a new CMSampleBuffer wrapping the rotated pixel buffer with the
    // same timing as the source buffer. The format description has to
    // match the rotated dimensions, so we synthesize a fresh one rather
    // than reusing the source's.
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, outPB, &fmt);
    if (s != noErr || !fmt) {
        CVPixelBufferRelease(outPB);
        return NULL;
    }

    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(src, 0, &timing);

    CMSampleBufferRef out = NULL;
    s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, outPB, true, NULL, NULL,
                                           fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(outPB);
    if (s != noErr || !out) return NULL;

    return out;
}

- (void)mockMediaSource:(id)source didChangeInjectionState:(BOOL)isEnabled {
    // Layer mutation must happen on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        AVSampleBufferDisplayLayer *overlay = objc_getAssociatedObject(self, @selector(qaw_sbdlOverlay));
        if (!overlay) return;

        overlay.hidden = !isEnabled;

        // When flipping to disabled, flush any queued injected frames so
        // they don't replay briefly on the next enable.
        if (!isEnabled) {
            [overlay flush];
        }

        NSLog(@"QAWolf:PreviewOverlay: visibility toggled enabled=%d layer=%p hidden=%d",
              isEnabled, overlay, overlay.hidden);
    });
}

#pragma mark - Cleanup

- (void)videoOverlay_dealloc {
    [[MockMediaSource sharedInstance] unregisterVideoDelegate:self];

    // Associated objects are released automatically on dealloc; the
    // SBDL sublayer is torn down by Core Animation with its superlayer.
    // Explicitly drop our markers in case some retain cycle keeps them
    // alive through a dealloc simulation.
    objc_setAssociatedObject(self, @selector(qaw_sbdlOverlay), nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @selector(qaw_registerAsVideoDelegateIfNeeded), nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @selector(qaw_firstEnqueueDone), nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Call original dealloc (now pointed at videoOverlay_dealloc via swizzle)
    [self videoOverlay_dealloc];
}

@end


#pragma mark - AVSampleBufferDisplayLayer (VideoOverlay)

// Many camera-preview UIs (custom capture, ARKit passthrough, document-
// scanning SDKs, …) don't use AVCaptureVideoPreviewLayer at all. They pull
// CMSampleBuffers out of an AVCaptureVideoDataOutput themselves and push
// them to an AVSampleBufferDisplayLayer (or a descendant). That render
// path completely bypasses the AVCaptureSession↔AVCaptureVideoPreviewLayer
// pipe, which is why our injection (which drops capture frames and removes
// the preview session) leaves the on-screen preview black.
//
// This category intercepts enqueueSampleBuffer: so that, when injection is
// enabled, we substitute our injected CMSampleBuffer instead of the host
// app's real-camera buffer. When injection is disabled, we pass through.

@interface AVSampleBufferDisplayLayer (VideoOverlay) <MockMediaSourceVideoDelegate>
@end

@implementation AVSampleBufferDisplayLayer (VideoOverlay)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(enqueueSampleBuffer:)
                   swizzledSelector:@selector(qaw_enqueueSampleBuffer:)];

        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(flush)
                   swizzledSelector:@selector(qaw_flush)];

        NSLog(@"QAWolf:SBDL: AVSampleBufferDisplayLayer swizzling complete");
    });
}

- (void)qaw_registerIfNeeded {
    NSNumber *registered = objc_getAssociatedObject(self, @selector(qaw_registerIfNeeded));
    if ([registered boolValue]) return;

    [[MockMediaSource sharedInstance] registerVideoDelegate:self];
    objc_setAssociatedObject(self, @selector(qaw_registerIfNeeded), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"QAWolf:SBDL: Registered display layer %p as video delegate", self);
}

- (void)qaw_enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // On first use, register with MockMediaSource so we get push-delivered
    // injected frames.
    [self qaw_registerIfNeeded];

    BOOL injectionEnabled = [[MockMediaSource sharedInstance] isMediaInjectionEnabled];

    // One-shot log so we know this render path is live
    NSNumber *logged = objc_getAssociatedObject(self, @selector(qaw_enqueueSampleBuffer:));
    if (![logged boolValue]) {
        NSLog(@"QAWolf:SBDL: enqueueSampleBuffer: FIRST CALL on %p %@ injection=%d parent=%@ %p",
              self, NSStringFromClass([self class]), injectionEnabled,
              NSStringFromClass([self.superlayer class]), self.superlayer);
        objc_setAssociatedObject(self, @selector(qaw_enqueueSampleBuffer:), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (injectionEnabled) {
        // Drop the real camera buffer. Our MockMediaSource delegate callback
        // (mockMediaSource:didOutputSampleBuffer:) will enqueue the injected
        // buffer on the display-link tick instead.
        return;
    }

    // Not injecting — pass through.
    [self qaw_enqueueSampleBuffer:sampleBuffer];
}

- (void)qaw_flush {
    // Don't let flush() wipe our injected frame while injection is enabled.
    BOOL injectionEnabled = [[MockMediaSource sharedInstance] isMediaInjectionEnabled];
    if (injectionEnabled) {
        NSLog(@"QAWolf:SBDL: flush suppressed on %p during injection", self);
        return;
    }
    [self qaw_flush];
}

#pragma mark - MockMediaSourceVideoDelegate

- (void)mockMediaSource:(id)source didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (![[MockMediaSource sharedInstance] isMediaInjectionEnabled]) return;
    if (!sampleBuffer) return;

    // AVSampleBufferDisplayLayer requires the DisplayImmediately attachment
    // on sample buffers delivered without a timebase (we don't drive one).
    // MockMediaSource already sets this, but re-stamp defensively.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    if (self.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"QAWolf:SBDL: layer %p in failed state, flushing", self);
        [self qaw_flush]; // bypass our injection-guarded flush
    }

    [self qaw_enqueueSampleBuffer:sampleBuffer]; // call swizzled name → real impl
}

- (void)mockMediaSource:(id)source didChangeInjectionState:(BOOL)isEnabled {
    NSLog(@"QAWolf:SBDL: injection state change -> %d on layer %p", isEnabled, self);
    if (!isEnabled) {
        // Clear stale injected frame when switching back to live camera
        [self qaw_flush];
    }
}

@end
