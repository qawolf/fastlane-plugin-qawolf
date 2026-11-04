//
//  MetadataObjectSwizzling.m
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import "MetadataObjectSwizzling.h"
#import "MetadataObjectFileMonitor.h"
#import "../utils.h"
#import <objc/runtime.h>

@implementation AVCaptureMetadataOutput (MetadataObjectSwizzling)

+ (void)load {
    NSLog(@"QAWolf:AVCaptureMetadataOutput:load");

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:AVCaptureMetadataOutput:MetadataObject Instrumentation loaded!");

        // Swizzle setMetadataObjectsDelegate:queue: to intercept delegate registration
        [Utils swizzleMethodInClass:AVCaptureMetadataOutput.class
                    originalSelector:@selector(setMetadataObjectsDelegate:queue:)
                    swizzledSelector:@selector(swizzled_setMetadataObjectsDelegate:queue:)];
        NSLog(@"QAWolf:AVCaptureMetadataOutput:setMetadataObjectsDelegate:queue: swizzled!");

        // Initialize the metadata object file monitor
        [[MetadataObjectFileMonitor sharedMonitor] startMonitoring];
    });
}

// Add property to store weak reference container
- (MetadataObjectDelegateContainer *)weakReferenceContainer {
    return objc_getAssociatedObject(self, @selector(weakReferenceContainer));
}

- (void)setWeakReferenceContainer:(MetadataObjectDelegateContainer *)container {
    objc_setAssociatedObject(self, @selector(weakReferenceContainer), container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Swizzled method to intercept delegate registration
- (void)swizzled_setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate queue:(dispatch_queue_t)queue {
    NSLog(@"QAWolf:MetadataObject:=== DELEGATE SWIZZLING TRIGGERED ===");
    NSLog(@"QAWolf:MetadataObject:setMetadataObjectsDelegate: %@", delegate);
    NSLog(@"QAWolf:MetadataObject:Delegate class: %@", [delegate class]);
    NSLog(@"QAWolf:MetadataObject:Queue: %@", queue);

    if (delegate == nil) {
        NSLog(@"QAWolf:MetadataObject:Delegate is nil, calling original method");
        [self swizzled_setMetadataObjectsDelegate:delegate queue:queue];
        return;
    }

    // Create a weak reference container to track this delegate
    MetadataObjectDelegateContainer *container = [[MetadataObjectDelegateContainer alloc]
                                                initWithMetadataOutput:self
                                                delegate:delegate
                                                queue:queue];

    // Store the container
    [self setWeakReferenceContainer:container];

    // Add to the file monitor for metadata object injection
    [[MetadataObjectFileMonitor sharedMonitor] addContainer:container];

    NSLog(@"QAWolf:MetadataObject:Created container for delegate monitoring");

    // Call original method with original delegate
    [self swizzled_setMetadataObjectsDelegate:delegate queue:queue];

    NSLog(@"QAWolf:MetadataObject:=== DELEGATE REGISTRATION COMPLETED ===");
}

@end
