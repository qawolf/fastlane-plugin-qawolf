//
//  MetadataObjectSwizzling.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "MetadataObjectDelegateContainer.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Category for swizzling AVCaptureMetadataOutput methods to enable metadata object injection
 */
@interface AVCaptureMetadataOutput (MetadataObjectSwizzling)

// Property to store weak reference container
@property (nonatomic, strong, nullable) MetadataObjectDelegateContainer *weakReferenceContainer;

// Swizzled method to intercept delegate registration
- (void)swizzled_setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate
                                      queue:(dispatch_queue_t)queue;

@end

NS_ASSUME_NONNULL_END
