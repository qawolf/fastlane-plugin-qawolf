#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Helper class for creating sample buffers from pixel buffers with proper timing
 */
@interface FrameDeliveryHelper : NSObject

+ (CMSampleBufferRef _Nullable)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                              withOriginalTiming:(CMSampleBufferRef)originalSampleBuffer;

@end

/**
 * AVCaptureVideoDataOutput category for video injection
 * This category handles intercepting and replacing video data frames
 */
@interface AVCaptureVideoDataOutput (EventDrivenVideoInjection)

@end

NS_ASSUME_NONNULL_END