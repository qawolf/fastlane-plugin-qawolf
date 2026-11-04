//
//  MetadataObjectDelegateContainer.m
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import "MetadataObjectDelegateContainer.h"

@implementation MetadataObjectDelegateContainer

- (instancetype)initWithMetadataOutput:(AVCaptureMetadataOutput *)output
                              delegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate
                                 queue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _metadataOutput = output;
        _delegate = delegate;
        _queue = queue;
    }
    return self;
}

- (BOOL)isValid {
    return self.metadataOutput != nil && self.delegate != nil;
}

- (void)forwardDelegateCall:(NSArray<AVMetadataObject *> *)metadataObjects
             fromConnection:(AVCaptureConnection *)connection {
    if (![self isValid]) {
        NSLog(@"QAWolf:MetadataObject:Container invalid, skipping delegate call");
        return;
    }

    if (![self.delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
        NSLog(@"QAWolf:MetadataObject:Delegate does not respond to required selector");
        return;
    }

    NSLog(@"QAWolf:MetadataObject:Forwarding %lu metadata objects to delegate", (unsigned long)metadataObjects.count);

    // Log metadata object content for debugging
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeObj = (AVMetadataMachineReadableCodeObject *)obj;
            NSLog(@"QAWolf:MetadataObject:Detected %@: %@", codeObj.type, codeObj.stringValue);
        }
    }

    if (self.queue) {
        dispatch_async(self.queue, ^{
            [self.delegate captureOutput:self.metadataOutput didOutputMetadataObjects:metadataObjects fromConnection:connection];
        });
    } else {
        [self.delegate captureOutput:self.metadataOutput didOutputMetadataObjects:metadataObjects fromConnection:connection];
    }
}

@end
