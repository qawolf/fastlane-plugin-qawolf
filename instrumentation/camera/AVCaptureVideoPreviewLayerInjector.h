//
//  AVCaptureVideoPreviewLayerInjector.h
//  ios-agent
//
//  Created by Andreas Lüdeke on 22.01.25.
//

#ifndef AVCaptureVideoPreviewLayerInjector_h
#define AVCaptureVideoPreviewLayerInjector_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "MockMediaSource.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * AVCaptureVideoPreviewLayer category for video injection
 * This category handles all preview layer video overlay functionality
 * without requiring a separate manager singleton
 */
@interface AVCaptureVideoPreviewLayer (VideoOverlay)

@end


NS_ASSUME_NONNULL_END

#endif /* AVCaptureVideoPreviewLayerInjector_h */