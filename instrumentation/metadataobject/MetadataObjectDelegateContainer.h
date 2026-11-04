//
//  MetadataObjectDelegateContainer.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Container for managing weak references to AVCaptureMetadataOutput delegates
 */
@interface MetadataObjectDelegateContainer : NSObject

@property (nonatomic, weak) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, weak) id<AVCaptureMetadataOutputObjectsDelegate> delegate;
@property (nonatomic, weak) dispatch_queue_t queue;

- (instancetype)initWithMetadataOutput:(AVCaptureMetadataOutput *)output
                              delegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate
                                 queue:(dispatch_queue_t)queue;

- (BOOL)isValid;

- (void)forwardDelegateCall:(NSArray<AVMetadataObject *> *)metadataObjects
             fromConnection:(nullable AVCaptureConnection *)connection;

@end

NS_ASSUME_NONNULL_END
