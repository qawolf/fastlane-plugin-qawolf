//
//  AVCapturePhotoProxyInjector.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 15.01.25.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import "utils.h"
#import "AVCapturePhotoProxyInjector.h"
#import "MockMediaSource.h"

#pragma mark - AVCaptureResolvedPhotoSettingsProxy

// Wraps the real AVCaptureResolvedPhotoSettings reported to the photo delegate
// during will-begin / will-capture / did-capture / did-finish-capture
// callbacks AND returned by photo.resolvedSettings, so consumers see
// dimensions consistent with our injected pixel data instead of the
// real-camera sensor's native output size. uniqueID, isFlashEnabled, and the
// rest forward to the real settings unchanged.
@interface AVCaptureResolvedPhotoSettingsProxy : NSProxy
@property (nonatomic, strong) id realSettings;
@property (nonatomic, assign) CMVideoDimensions photoDimensions;
@property (nonatomic, assign) CMVideoDimensions previewDimensions;
@end

@implementation AVCaptureResolvedPhotoSettingsProxy

- (instancetype)initWithRealSettings:(id)real
                     photoDimensions:(CMVideoDimensions)photoDims
                   previewDimensions:(CMVideoDimensions)previewDims {
    self->_realSettings = real;
    self->_photoDimensions = photoDims;
    self->_previewDimensions = previewDims;
    return self;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    SEL sel = invocation.selector;
    if (sel_isEqual(sel, @selector(photoDimensions))) {
        CMVideoDimensions dims = self.photoDimensions;
        [invocation setReturnValue:&dims];
        return;
    }
    if (sel_isEqual(sel, @selector(previewDimensions))) {
        CMVideoDimensions dims = self.previewDimensions;
        [invocation setReturnValue:&dims];
        return;
    }
    if (self.realSettings) {
        [invocation setTarget:self.realSettings];
        [invocation invoke];
    }
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [self.realSettings methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [self.realSettings respondsToSelector:sel];
}

@end


#pragma mark - AVCapturePhotoProxy

// Wraps the real AVCapturePhoto delivered by AVCapturePhotoOutput. Substitutes
// the four accessors a consumer might read for image data + metadata:
//   - fileDataRepresentation / fileDataRepresentationWithCustomizer:
//       returns the bytes we already encoded for the format requested
//       (TIFF / JPEG / HEIF). The customizer protocol is honored: we call
//       the customizer's replacement* methods to give it a chance to
//       transform metadata, then re-encode the output via CGImageDestination
//       so the new metadata makes it into the file.
//   - processedFileType: returns the AVFileType matching our encoded bytes
//       so a consumer that reads both file-type-and-bytes sees consistent
//       values instead of the real-camera 'BGRA' on a TIFF payload.
//   - metadata: returns a synthetic minimal CGImageProperties dict so
//       real-camera ISO / exposure / lens position / GPS / timestamp /
//       MakerApple don't leak through onto our injected pixels.
//   - resolvedSettings: returns a proxy reporting our injected dimensions.
//
// Everything else (depthData, isRawPhoto, sourceDeviceType, photoCount,
// timestamp, ...) forwards to the real AVCapturePhoto unchanged because the
// real value is the safest default for any consumer we haven't enumerated.
@interface AVCapturePhotoProxy : NSProxy
@property (nonatomic, strong) AVCapturePhoto *realPhoto;
@property (nonatomic, strong) NSData *imageBytes;
@property (nonatomic, strong) UIImage *sourceImage;        // for lazy pixelBuffer build
@property (nonatomic, copy) NSString *processedFileType;
@property (nonatomic, assign) CMVideoDimensions photoDimensions;
@property (nonatomic, assign) int exifOrientation;          // matches the orientation tag stamped on imageBytes
@property (nonatomic, strong) AVCaptureResolvedPhotoSettingsProxy *resolvedSettingsProxy;
@property (nonatomic, assign) CVPixelBufferRef cachedPixelBuffer;  // released in dealloc
@end

@implementation AVCapturePhotoProxy

- (instancetype)initWithRealPhoto:(AVCapturePhoto *)real
                       imageBytes:(NSData *)imageBytes
                      sourceImage:(UIImage *)sourceImage
                processedFileType:(NSString *)fileType
                  photoDimensions:(CMVideoDimensions)dims
                  exifOrientation:(int)exifOrientation {
    self->_realPhoto = real;
    self->_imageBytes = imageBytes;
    self->_sourceImage = sourceImage;
    self->_processedFileType = [fileType copy];
    self->_photoDimensions = dims;
    self->_exifOrientation = exifOrientation;
    return self;
}

- (void)dealloc {
    if (_cachedPixelBuffer) {
        CVPixelBufferRelease(_cachedPixelBuffer);
        _cachedPixelBuffer = NULL;
    }
}

// Build a BGRA CVPixelBuffer from the source UIImage on demand. Cached so
// repeated -[AVCapturePhoto pixelBuffer] calls return the same instance the
// way Apple's real implementation does. Caller does NOT own the returned
// buffer — the proxy owns it for its lifetime, matching Apple's contract
// for pixelBuffer (which is documented as returning an unowned reference).
- (CVPixelBufferRef)qaw_pixelBuffer {
    if (_cachedPixelBuffer) return _cachedPixelBuffer;
    CGImageRef cg = self.sourceImage.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    NSDictionary *opts = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)opts, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        return NULL;
    }
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    _cachedPixelBuffer = pb;   // owned by the proxy
    return _cachedPixelBuffer;
}

- (NSString *)qaw_exifDateNow {
    static NSDateFormatter *fmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy:MM:dd HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

- (NSDictionary *)qaw_syntheticMetadata {
    NSString *now = [self qaw_exifDateNow];
    // Reflect the same EXIF orientation that the encoded bytes carry. A
    // host that consults photo.metadata for orientation/dimensions must
    // see values consistent with fileDataRepresentation; otherwise consumers
    // that combine the two (e.g. building a UIImage with metadata-driven
    // orientation) end up rotated wrong.
    int orientation = self.exifOrientation > 0 ? self.exifOrientation : 1;
    return @{
        (NSString *)kCGImagePropertyOrientation: @(orientation),
        (NSString *)kCGImagePropertyPixelWidth: @(self.photoDimensions.width),
        (NSString *)kCGImagePropertyPixelHeight: @(self.photoDimensions.height),
        (NSString *)kCGImagePropertyTIFFDictionary: @{
            (NSString *)kCGImagePropertyTIFFOrientation: @(orientation),
            (NSString *)kCGImagePropertyTIFFSoftware: @"QAWolf",
            (NSString *)kCGImagePropertyTIFFDateTime: now,
        },
        (NSString *)kCGImagePropertyExifDictionary: @{
            (NSString *)kCGImagePropertyExifPixelXDimension: @(self.photoDimensions.width),
            (NSString *)kCGImagePropertyExifPixelYDimension: @(self.photoDimensions.height),
            (NSString *)kCGImagePropertyExifDateTimeOriginal: now,
            (NSString *)kCGImagePropertyExifDateTimeDigitized: now,
        },
    };
}

- (NSData *)qaw_dataForCustomizer:(id)customizer {
    if (!customizer) return self.imageBytes;

    NSDictionary *baseMeta = [self qaw_syntheticMetadata];
    NSDictionary *finalMeta = baseMeta;

    // Honor the customizer protocol's metadata replacement. The other
    // replacements (embedded-thumbnail-pixel-buffer, depth-data, portrait-
    // effects-matte, semantic-segmentation-matte) take complex out-pointer
    // signatures and only matter when we have a thumbnail / depth / matte
    // to embed - which we don't for injected images. Skip them silently;
    // apps that depend on those replacements are using a feature we don't
    // simulate.
    if ([customizer respondsToSelector:@selector(replacementMetadataForPhoto:)]) {
        NSDictionary *override = [customizer replacementMetadataForPhoto:(id)self];
        if (override) finalMeta = override;
    }

    if ([finalMeta isEqual:baseMeta]) return self.imageBytes;

    // Re-encode bytes with the overridden metadata: decode existing payload
    // via CGImageSource, re-emit through CGImageDestination using the
    // original UTI so the format stays the same (TIFF stays TIFF, JPEG stays
    // JPEG, etc.).
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)self.imageBytes, NULL);
    if (!src) return self.imageBytes;

    CFStringRef uti = CGImageSourceGetType(src);
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, uti ?: CFSTR("public.tiff"), 1, NULL);
    if (!dst) {
        CFRelease(src);
        return self.imageBytes;
    }
    CGImageDestinationAddImageFromSource(dst, src, 0, (__bridge CFDictionaryRef)finalMeta);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CFRelease(src);
    return (ok && out.length > 0) ? out : self.imageBytes;
}

// NSInvocation's setReturnValue: copies pointer bytes only - it does not retain
// the returned object, and the ARC autoreleased-return-value optimization does
// not apply to messages dispatched through forwardInvocation:. A caller using
// the canonical objc_msgSend + objc_retainAutoreleasedReturnValue sequence
// (which ARC compiles every [photo fileDataRepresentation] call to) ends up
// retaining a pointer that may point to a deallocated object. Adding an
// explicit retain+autorelease ensures the returned object lives at least
// until the next pool drain, satisfying the +0/autoreleased-return contract.
static inline void QAWolfReturnAutoreleased(NSInvocation *invocation, id value) {
    if (value) {
        CFRetain((__bridge CFTypeRef)value);
        CFAutorelease((__bridge CFTypeRef)value);
    }
    [invocation setReturnValue:&value];
}

// Encode CGImage with explicit EXIF Orientation stamped. Matches real
// iPhone JPEG/HEIF output (sensor-landscape pixels + rotate-for-display
// tag); UIImageJPEGRepresentation / UIImageHEICRepresentation drop the
// tag, which makes consumers render our pixels rotated.
static NSData *QAWolfEncodeWithOrientation(CGImageRef cg, CFStringRef uti, int orientation) {
    if (!cg || !uti) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, uti, 1, NULL);
    if (!dest) return nil;
    NSDictionary *props = @{
        (id)kCGImagePropertyOrientation: @(orientation),
        (id)kCGImagePropertyTIFFDictionary: @{
            (id)kCGImagePropertyTIFFOrientation: @(orientation),
        },
        (id)kCGImageDestinationLossyCompressionQuality: @(1.0),
    };
    CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return (ok && out.length > 0) ? out : nil;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    SEL sel = invocation.selector;

    if (sel_isEqual(sel, @selector(fileDataRepresentation))) {
        NSLog(@"QAWolf:CameraInjection:substituting fileDataRepresentation (%lu bytes, %@)",
              (unsigned long)self.imageBytes.length, self.processedFileType);
        QAWolfReturnAutoreleased(invocation, self.imageBytes);
        return;
    }
    if (sel_isEqual(sel, @selector(fileDataRepresentationWithCustomizer:))) {
        id customizer = nil;
        [invocation getArgument:&customizer atIndex:2];
        NSData *bytes = [self qaw_dataForCustomizer:customizer];
        NSLog(@"QAWolf:CameraInjection:substituting fileDataRepresentationWithCustomizer: (%lu bytes)",
              (unsigned long)bytes.length);
        QAWolfReturnAutoreleased(invocation, bytes);
        return;
    }
    if (sel_isEqual(sel, @selector(processedFileType))) {
        NSLog(@"QAWolf:CameraInjection:substituting processedFileType=%@", self.processedFileType);
        QAWolfReturnAutoreleased(invocation, self.processedFileType);
        return;
    }
    if (sel_isEqual(sel, @selector(metadata))) {
        NSDictionary *meta = [self qaw_syntheticMetadata];
        NSLog(@"QAWolf:CameraInjection:substituting metadata (synthetic, %lu top-level keys)",
              (unsigned long)meta.count);
        QAWolfReturnAutoreleased(invocation, meta);
        return;
    }
    if (sel_isEqual(sel, @selector(pixelBuffer))) {
        // When a host requests settings.format = {kCVPixelBufferPixelFormatTypeKey: BGRA},
        // AVCapturePhoto.pixelBuffer is non-nil and consumers may use it
        // INSTEAD of fileDataRepresentation. Substitute here too so both
        // accessors return content consistent with each other; otherwise
        // the real-camera pixel buffer leaks through and a consumer that
        // reads it sees the actual camera (typically covered/dark during
        // injection testing).
        CVPixelBufferRef pb = [self qaw_pixelBuffer];
        NSLog(@"QAWolf:CameraInjection:substituting pixelBuffer (%p, %zux%zu)",
              pb, pb ? CVPixelBufferGetWidth(pb) : 0, pb ? CVPixelBufferGetHeight(pb) : 0);
        [invocation setReturnValue:&pb];
        return;
    }
    if (sel_isEqual(sel, @selector(resolvedSettings))) {
        if (!self.resolvedSettingsProxy) {
            CMVideoDimensions prev = self.photoDimensions;
            self.resolvedSettingsProxy = (AVCaptureResolvedPhotoSettingsProxy *)
                [[AVCaptureResolvedPhotoSettingsProxy alloc]
                    initWithRealSettings:self.realPhoto.resolvedSettings
                         photoDimensions:self.photoDimensions
                       previewDimensions:prev];
            NSLog(@"QAWolf:CameraInjection:substituting photo.resolvedSettings (photo=%dx%d)",
                  self.photoDimensions.width, self.photoDimensions.height);
        }
        QAWolfReturnAutoreleased(invocation, self.resolvedSettingsProxy);
        return;
    }

    if (self.realPhoto) {
        [invocation setTarget:self.realPhoto];
        [invocation invoke];
    }
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [self.realPhoto methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [self.realPhoto respondsToSelector:sel];
}

@end


#pragma mark - PhotoCaptureDelegateProxy (injection mode)

// Wraps the host app's AVCapturePhotoCaptureDelegate during media injection.
// Forwards every callback (so the app sees the full lifecycle, including
// will-capture / did-capture / did-finish-capture used for shutter sound and
// "capture done" signals), and intercepts:
//   - didFinishProcessingPhoto:error: -> wraps the photo with AVCapturePhotoProxy
//   - the resolvedSettings parameter on the four other callbacks -> wraps with
//     AVCaptureResolvedPhotoSettingsProxy reporting our injected dimensions
//
// Multiple in-flight captures are retained via a shared NSMutableArray on the
// AVCapturePhotoOutput so concurrent triggers don't stomp each other (some
// hosts fire back-to-back captures with different uniqueIDs and a legacy
// single-slot setAssociatedObject pattern would lose proxies). Self-removal
// in didFinishCapture keeps the array bounded over long sessions.
@interface PhotoCaptureDelegateProxy : NSObject<AVCapturePhotoCaptureDelegate>
@property (nonatomic, weak) id<AVCapturePhotoCaptureDelegate> delegate;
@property (nonatomic, strong) NSData *imageBytes;
@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, copy) NSString *processedFileType;
@property (nonatomic, assign) CMVideoDimensions photoDimensions;
@property (nonatomic, assign) int exifOrientation;
@property (nonatomic, weak) NSMutableArray *pendingQueue;
@end

@implementation PhotoCaptureDelegateProxy

- (instancetype)initWithDelegate:(id<AVCapturePhotoCaptureDelegate>)delegate
                      imageBytes:(NSData *)imageBytes
                     sourceImage:(UIImage *)sourceImage
               processedFileType:(NSString *)fileType
                 photoDimensions:(CMVideoDimensions)dims
                 exifOrientation:(int)exifOrientation {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _imageBytes = imageBytes;
        _sourceImage = sourceImage;
        _processedFileType = [fileType copy];
        _photoDimensions = dims;
        _exifOrientation = exifOrientation;
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    return [self.delegate respondsToSelector:sel];
}

// Delegate callbacks we don't intercept (e.g. iOS 26 CameraUI's
// readyForResponsiveRequestAfterResolvedSettings:) go straight to the host.
- (id)forwardingTargetForSelector:(SEL)sel {
    id<AVCapturePhotoCaptureDelegate> delegate = self.delegate;
    return [delegate respondsToSelector:sel] ? delegate : nil;
}

- (AVCaptureResolvedPhotoSettings *)qaw_wrapSettings:(AVCaptureResolvedPhotoSettings *)real {
    if (!real) return real;
    AVCaptureResolvedPhotoSettingsProxy *proxy = (AVCaptureResolvedPhotoSettingsProxy *)
        [[AVCaptureResolvedPhotoSettingsProxy alloc]
            initWithRealSettings:real
                 photoDimensions:_photoDimensions
               previewDimensions:_photoDimensions];
    return (AVCaptureResolvedPhotoSettings *)proxy;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings {
    if ([self.delegate respondsToSelector:_cmd]) {
        [self.delegate captureOutput:output
willBeginCaptureForResolvedSettings:[self qaw_wrapSettings:settings]];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
willCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings {
    if ([self.delegate respondsToSelector:_cmd]) {
        [self.delegate captureOutput:output
willCapturePhotoForResolvedSettings:[self qaw_wrapSettings:settings]];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings {
    if ([self.delegate respondsToSelector:_cmd]) {
        [self.delegate captureOutput:output
didCapturePhotoForResolvedSettings:[self qaw_wrapSettings:settings]];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
    NSLog(@"QAWolf:CameraInjection:didFinishProcessingPhoto error=%@", error);

    // Nil-photo guard: real-camera failures (session interruption, hardware
    // error, permission revocation mid-capture) deliver a nil photo with
    // non-nil error. Wrapping nil in NSProxy crashes the host on the first
    // forwarded selector since every selector dispatches to a nil target.
    // Forward the failure through unchanged so the host sees the real
    // error mode.
    if (!photo) {
        if ([self.delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            [self.delegate captureOutput:output didFinishProcessingPhoto:nil error:error];
        }
        return;
    }

    AVCapturePhotoProxy *proxy = [[AVCapturePhotoProxy alloc]
        initWithRealPhoto:photo
               imageBytes:self.imageBytes
              sourceImage:self.sourceImage
        processedFileType:self.processedFileType
          photoDimensions:self.photoDimensions
          exifOrientation:self.exifOrientation];

    if ([self.delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [self.delegate captureOutput:output
            didFinishProcessingPhoto:(AVCapturePhoto *)proxy
                               error:error];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings
                error:(NSError *)error {
    NSLog(@"QAWolf:CameraInjection: didFinishCapture forwarding error=%@", error);
    if ([self.delegate respondsToSelector:_cmd]) {
        [self.delegate captureOutput:output
didFinishCaptureForResolvedSettings:[self qaw_wrapSettings:settings]
                               error:error];
    }

    NSMutableArray *q = self.pendingQueue;
    if (q) {
        @synchronized (q) {
            [q removeObject:self];
        }
    }
}

@end


#pragma mark - AVCapturePhotoOutput swizzling

@implementation AVCapturePhotoOutput (Swizzling)

// Single shared associated-object key for both injection-mode and capture-mode
// pending-proxies arrays. We can use one key because the array contains
// arbitrary delegate proxies; the type is uniform.
static const char kQAWolfPendingProxyKey;

+ (void)load {
    NSLog(@"QAWolf:AVCapturePhotoOutput:load");

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:AVCapturePhotoOutput.class
                   originalSelector:@selector(capturePhotoWithSettings:delegate:)
                   swizzledSelector:@selector(swizzled_capturePhotoWithSettings:delegate:)];
        NSLog(@"QAWolf:AVCapturePhotoOutput:Instrumentation swizzled!");
    });
}

- (void)swizzled_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                                  delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    NSLog(@"QAWolf:CameraInjection:swizzled_capturePhotoWithSettings: %@", settings);

    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    if (![mediaSource isMediaInjectionEnabled]) {
        NSLog(@"QAWolf:CameraInjection:No media injection configured");
        [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
        return;
    }

    NSLog(@"QAWolf:CameraInjection:Media injection is enabled");

    // Pick the source UIImage. Image-type configs set MockMediaSource's
    // originalImage at config-load. Video-type configs don't, so for those
    // we grab the most recent decoded frame from the running playback.
    UIImage *uiimage = [mediaSource originalImage];
    if (uiimage && uiimage.CGImage) {
        NSLog(@"QAWolf:CameraInjection:Using cached originalImage %.0fx%.0f",
              uiimage.size.width, uiimage.size.height);
    } else {
        CVPixelBufferRef latest = [mediaSource getLatestFrame];
        if (latest) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:latest];
            static CIContext *sFrameCtx = nil;
            static dispatch_once_t sFrameOnce;
            dispatch_once(&sFrameOnce, ^{ sFrameCtx = [CIContext context]; });
            CGImageRef cg = [sFrameCtx createCGImage:ci fromRect:ci.extent];
            CVPixelBufferRelease(latest);
            if (cg) {
                uiimage = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
                NSLog(@"QAWolf:CameraInjection:Using latest video frame %.0fx%.0f",
                      uiimage.size.width, uiimage.size.height);
            }
        }
    }
    if (!uiimage || !uiimage.CGImage) {
        NSLog(@"QAWolf:CameraInjection:No usable image - passthrough");
        [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
        return;
    }

    // Decide rotation + EXIF Orientation from the host's connection rotation.
    // Mirrors what real iPhone captures produce in the same configuration:
    //
    //   - Sensor-native (angle 0 or 180): rotate portrait sources 90 CCW
    //     into landscape sensor convention; stamp Orientation=6 so consumers
    //     that auto-apply EXIF rotation get the source's portrait
    //     orientation back, while raw-pixel consumers see the same landscape
    //     sensor geometry as the VDO frame stream.
    //
    //   - Display-oriented (angle 90 or 270): no rotation; pixels are
    //     already display-oriented. Orientation=1.
    BOOL hostWantsSensorNative = YES;
    if ([self respondsToSelector:@selector(connectionWithMediaType:)]) {
        AVCaptureConnection *photoConn = [self connectionWithMediaType:AVMediaTypeVideo];
        CGFloat angle = photoConn ? photoConn.videoRotationAngle : 90.0;
        hostWantsSensorNative = (angle == 0 || angle == 180);
        NSLog(@"QAWolf:CameraInjection:photo connection.videoRotationAngle=%.0f sensorNative=%d",
              angle, hostWantsSensorNative);
    }
    int exifOrientation = 1;

    if (hostWantsSensorNative && uiimage.size.height > uiimage.size.width) {
        exifOrientation = 6;
        CIImage *src = [CIImage imageWithCGImage:uiimage.CGImage];
        // EXIF orientation 8 (Left) tells CIImage "source is left-oriented,
        // rotate 90° CW to make it upright". For a portrait image whose
        // visual "up" is at the top, that lands in landscape with the
        // image's original right edge becoming the new top edge — i.e.
        // sensor orientation when the device was held portrait.
        src = [src imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
        // Re-anchor to (0,0) before rendering — imageByApplyingCGOrientation
        // can shift extent.origin off the origin.
        CGRect ext = src.extent;
        if (!CGPointEqualToPoint(ext.origin, CGPointZero)) {
            src = [src imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
            ext = src.extent;
        }
        static CIContext *sCtx = nil;
        static dispatch_once_t sOnce;
        dispatch_once(&sOnce, ^{ sCtx = [CIContext context]; });
        CGImageRef rotatedCG = [sCtx createCGImage:src fromRect:ext];
        if (rotatedCG) {
            uiimage = [UIImage imageWithCGImage:rotatedCG];
            CGImageRelease(rotatedCG);
            NSLog(@"QAWolf:CameraInjection:Rotated source 90 CCW to landscape sensor orientation %.0fx%.0f",
                  uiimage.size.width, uiimage.size.height);
        }
    } else {
        NSLog(@"QAWolf:CameraInjection:Source already landscape (%.0fx%.0f) — no rotation",
              uiimage.size.width, uiimage.size.height);
    }

    // Encode bytes per settings.format AND track which file type we wrote so
    // AVCapturePhotoProxy can substitute photo.processedFileType consistently.
    NSData *output = nil;
    NSString *processedFileType = nil;
    NSDictionary *formats = settings.format;
    NSLog(@"QAWolf:CameraInjection:Photo settings format: %@", formats);

    if (formats[(id)kCVPixelBufferPixelFormatTypeKey] != nil) {
        // Uncompressed pixel-format request. We only synthesize BGRA TIFF
        // (SamplesPerPixel=4 / BitsPerSample=8 8 8 8, matching real iPhone
        // BGRA captures). For other uncompressed formats (e.g. 420f / 420v)
        // we don't have an encoder, so passthrough lets the real camera
        // bytes flow rather than handing the host a mismatched payload.
        OSType pixelFormat = [formats[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
        if (pixelFormat != kCVPixelFormatType_32BGRA) {
            NSLog(@"QAWolf:CameraInjection:Unsupported uncompressed pixel format %u — passthrough", pixelFormat);
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
        const size_t kTargetW = CGImageGetWidth(uiimage.CGImage);
        const size_t kTargetH = CGImageGetHeight(uiimage.CGImage);
        NSLog(@"QAWolf:CameraInjection:Pixel buffer format: BGRA (wrapping as %zux%zu BGRA TIFF)",
              kTargetW, kTargetH);

        // Render via CGBitmapContextCreate with explicit BGRA byte layout
        // (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little).
        // CIContext.createCGImage with kCIFormatBGRA8 alone produces a
        // CGImage whose alphaInfo the TIFF encoder still treats as no-
        // alpha (verified empirically: output was 3-channel). The
        // bitmap-context path forces 4-channel output.
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bctx = CGBitmapContextCreate(NULL,
                                                  kTargetW, kTargetH,
                                                  8,
                                                  kTargetW * 4,
                                                  cs,
                                                  kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (!bctx) {
            NSLog(@"QAWolf:CameraInjection:Failed to create BGRA bitmap context");
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
        CGContextDrawImage(bctx, CGRectMake(0, 0, kTargetW, kTargetH), uiimage.CGImage);
        CGImageRef resizedCG = CGBitmapContextCreateImage(bctx);
        CGContextRelease(bctx);
        if (!resizedCG) {
            NSLog(@"QAWolf:CameraInjection:BGRA bitmap snapshot failed for %zux%zu", kTargetW, kTargetH);
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
        // Replace uiimage with the BGRA-formatted version so photoDimensions
        // and the pixelBuffer-substitution path use the same pixels.
        uiimage = [UIImage imageWithCGImage:resizedCG];
        CGImageRelease(resizedCG);

        NSMutableData *tiffData = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)tiffData, CFSTR("public.tiff"), 1, NULL);
        if (!dest) {
            NSLog(@"QAWolf:CameraInjection:Failed to create TIFF destination");
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
        NSDictionary *props = @{
            (id)kCGImagePropertyOrientation: @(exifOrientation),
            (id)kCGImagePropertyTIFFDictionary: @{
                (id)kCGImagePropertyTIFFOrientation: @(exifOrientation),
                (id)kCGImagePropertyTIFFCompression: @(1),  // Uncompressed
            },
        };
        CGImageDestinationAddImage(dest, uiimage.CGImage, (__bridge CFDictionaryRef)props);
        BOOL ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        if (!ok || tiffData.length == 0) {
            NSLog(@"QAWolf:CameraInjection:TIFF finalize failed");
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
        output = tiffData;
        processedFileType = AVFileTypeTIFF;
        NSLog(@"QAWolf:CameraInjection:Generated %zux%zu uncompressed TIFF %lu bytes (Orientation=%d)",
              kTargetW, kTargetH, (unsigned long)output.length, exifOrientation);
    } else if (formats[(id)AVVideoCodecKey] != nil) {
        id codec = formats[(id)AVVideoCodecKey];
        NSLog(@"QAWolf:CameraInjection:Video codec: %@", codec);
        if (codec == AVVideoCodecTypeJPEG || codec == AVVideoCodecJPEG) {
            output = QAWolfEncodeWithOrientation(uiimage.CGImage, CFSTR("public.jpeg"), exifOrientation);
            processedFileType = AVFileTypeJPEG;
        } else if (codec == AVVideoCodecTypeHEVC || codec == AVVideoCodecHEVC) {
            output = QAWolfEncodeWithOrientation(uiimage.CGImage, CFSTR("public.heic"), exifOrientation);
            processedFileType = AVFileTypeHEIF;
        } else {
            NSLog(@"QAWolf:CameraInjection:Unknown codec: %@ - passthrough", codec);
            [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
            return;
        }
    } else {
        // Default to JPEG when no format hint is provided.
        output = QAWolfEncodeWithOrientation(uiimage.CGImage, CFSTR("public.jpeg"), exifOrientation);
        processedFileType = AVFileTypeJPEG;
        NSLog(@"QAWolf:CameraInjection:No format specified, defaulting to JPEG");
    }

    if (!output || output.length == 0) {
        NSLog(@"QAWolf:CameraInjection:Failed to encode injection bytes - passthrough");
        [self swizzled_capturePhotoWithSettings:settings delegate:delegate];
        return;
    }

    CMVideoDimensions photoDims = {
        (int32_t)CGImageGetWidth(uiimage.CGImage),
        (int32_t)CGImageGetHeight(uiimage.CGImage),
    };

    PhotoCaptureDelegateProxy *proxy = [[PhotoCaptureDelegateProxy alloc]
        initWithDelegate:delegate
              imageBytes:output
             sourceImage:uiimage
       processedFileType:processedFileType
         photoDimensions:photoDims
         exifOrientation:exifOrientation];

    NSMutableArray *pending = objc_getAssociatedObject(self, &kQAWolfPendingProxyKey);
    if (!pending) {
        pending = [NSMutableArray new];
        objc_setAssociatedObject(self, &kQAWolfPendingProxyKey, pending,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @synchronized (pending) { [pending addObject:proxy]; }
    proxy.pendingQueue = pending;

    [self swizzled_capturePhotoWithSettings:settings delegate:proxy];
    NSLog(@"QAWolf:CameraInjection:Image injection completed (file type %@, %dx%d)",
          processedFileType, photoDims.width, photoDims.height);
}

@end
