//
//  MetadataObjectFileMonitor.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import <Foundation/Foundation.h>
#import "MetadataObjectDelegateContainer.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Monitors the file system for metadata object injection commands
 */
@interface MetadataObjectFileMonitor : NSObject

@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) dispatch_source_t fileSource;
@property (nonatomic, strong) NSMutableArray *activeContainers;

+ (instancetype)sharedMonitor;

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)addContainer:(MetadataObjectDelegateContainer *)container;
- (void)simulateMetadataObjectDetection:(NSString *)type value:(NSString *)value;

@end

NS_ASSUME_NONNULL_END
