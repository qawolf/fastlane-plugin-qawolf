#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Helper class for creating audio sample buffers with proper timing
 */
@interface AudioDeliveryHelper : NSObject

+ (CMSampleBufferRef _Nullable)createAudioSampleBufferFromOriginal:(CMSampleBufferRef)originalSampleBuffer
                                                 withReplacementData:(CMSampleBufferRef)replacementBuffer;

@end

/**
 * AVCaptureAudioDataOutput category for audio injection
 * This category handles intercepting and replacing audio data samples
 */
@interface AVCaptureAudioDataOutput (AudioInjection)

@end

NS_ASSUME_NONNULL_END
