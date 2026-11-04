//
//  AVCapturePhotoProxyInjector.h
//  ios-agent
//
//  Created by Andreas Lüdeke on 15.01.25.
//

#ifndef AVCapturePhotoProxyInjector_h
#define AVCapturePhotoProxyInjector_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "MockMediaSource.h"

// Photo capture swizzling
@interface AVCapturePhotoOutput (Swizzling)
- (void)swizzled_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate;
@end

// VideoInjectionConfig and VideoFrameProvider have been moved to CameraManager.h/m

// Frame delivery utilities
@interface FrameDeliveryHelper : NSObject
+ (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    withOriginalTiming:(CMSampleBufferRef)originalSampleBuffer;

@end

// Video data output swizzling
@interface AVCaptureVideoDataOutput (EventDrivenVideoInjection)
- (void)event_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                                queue:(dispatch_queue_t)queue;
@end

// Movie file output swizzling has been moved to AVCaptureMovieFileOutputInjector.h/m

// Capture session swizzling
@interface AVCaptureSession (EventDrivenVideoInjection)
- (void)event_addOutput:(AVCaptureOutput *)output;
@end

// Preview layer swizzling moved to VideoOverlayPreviewLayer.h/m

#endif /* AVCapturePhotoProxyInjector_h */
