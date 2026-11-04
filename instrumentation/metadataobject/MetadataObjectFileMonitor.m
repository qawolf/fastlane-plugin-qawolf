//
//  MetadataObjectFileMonitor.m
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Monitors metadataobject.json for barcode injection.
//

#import "MetadataObjectFileMonitor.h"
#import "MockAVMetadataObject.h"
#import "../utils.h"

@implementation MetadataObjectFileMonitor

+ (instancetype)sharedMonitor {
    static MetadataObjectFileMonitor *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[MetadataObjectFileMonitor alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *qawolfFolder = [Utils getQAWolfFolder];
        _filePath = [qawolfFolder stringByAppendingPathComponent:@"metadataobject.json"];
        _activeContainers = [[NSMutableArray alloc] init];

        [self startMonitoring];
    }
    return self;
}

- (void)startMonitoring {
    NSLog(@"QAWolf:MetadataObject:Starting file monitoring: %@", self.filePath);

    // Create the QAWolf folder if it doesn't exist
    NSString *qawolfFolder = [self.filePath stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:qawolfFolder]) {
        [fileManager createDirectoryAtPath:qawolfFolder withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Monitor the QAWolf folder for any changes
    dispatch_queue_t queue = dispatch_queue_create("com.qawolf.metadataobject.monitor", DISPATCH_QUEUE_SERIAL);

    int fileDescriptor = open([qawolfFolder UTF8String], O_EVTONLY);
    if (fileDescriptor == -1) {
        NSLog(@"QAWolf:MetadataObject:Error opening folder for monitoring: %@", qawolfFolder);
        return;
    }

    self.fileSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fileDescriptor,
                                              DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND,
                                              queue);

    dispatch_source_set_event_handler(self.fileSource, ^{
        [self checkForFile];
    });

    dispatch_source_set_cancel_handler(self.fileSource, ^{
        close(fileDescriptor);
    });

    dispatch_resume(self.fileSource);

    // Also check immediately in case file already exists
    [self checkForFile];
}

- (void)checkForFile {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:self.filePath]) {
        NSLog(@"QAWolf:MetadataObject:File detected!");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self processFileWithRetry:3];
        });
    }
}

- (void)processFileWithRetry:(int)remainingRetries {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager fileExistsAtPath:self.filePath]) {
        return;
    }

    // Check file size
    NSError *error = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:self.filePath error:&error];
    if (error || [attributes[NSFileSize] integerValue] == 0) {
        if (remainingRetries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self processFileWithRetry:remainingRetries - 1];
            });
        }
        return;
    }

    NSDictionary *config = [self readJsonFile:self.filePath];
    if (!config) {
        if (remainingRetries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self processFileWithRetry:remainingRetries - 1];
            });
        }
        return;
    }

    NSArray *metadataObjects = config[@"metadataObjects"];
    if (metadataObjects && [metadataObjects isKindOfClass:[NSArray class]]) {
        NSLog(@"QAWolf:MetadataObject:Processing %lu metadata objects", (unsigned long)metadataObjects.count);

        NSMutableArray *mockObjects = [[NSMutableArray alloc] init];

        for (NSDictionary *obj in metadataObjects) {
            if (![obj isKindOfClass:[NSDictionary class]]) continue;

            NSString *type = obj[@"type"] ?: @"org.iso.QRCode";
            NSString *value = obj[@"value"];
            if (!value) continue;

            // Parse bounds if provided
            CGRect bounds = CGRectMake(0.38, 0.27, 0.32, 0.57);
            NSDictionary *boundsDict = obj[@"bounds"];
            if (boundsDict && [boundsDict isKindOfClass:[NSDictionary class]]) {
                bounds = CGRectMake([boundsDict[@"x"] doubleValue], [boundsDict[@"y"] doubleValue],
                                   [boundsDict[@"width"] doubleValue], [boundsDict[@"height"] doubleValue]);
            }

            // Parse corners if provided
            NSArray *corners = nil;
            NSArray *cornersArray = obj[@"corners"];
            if (cornersArray && [cornersArray isKindOfClass:[NSArray class]] && cornersArray.count >= 4) {
                NSMutableArray *cornerValues = [[NSMutableArray alloc] init];
                for (NSUInteger i = 0; i < cornersArray.count; i++) {
                    NSDictionary *corner = cornersArray[i];
                    CGPoint pt = CGPointMake([corner[@"x"] doubleValue], [corner[@"y"] doubleValue]);
                    [cornerValues addObject:(__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(pt)];
                }
                corners = cornerValues;
            }

            // Parse rawValue if provided
            NSData *rawValue = nil;
            NSString *rawValueBase64 = obj[@"rawValue"];
            if (rawValueBase64) {
                rawValue = [[NSData alloc] initWithBase64EncodedString:rawValueBase64 options:0];
            }

            // Create mock object
            MockAVMetadataObject *mockObj = [[MockAVMetadataObject alloc] initWithStringValue:value
                                                                                          type:type
                                                                                        bounds:bounds
                                                                                       corners:corners
                                                                                      rawValue:rawValue];
            [mockObjects addObject:mockObj];
        }

        if (mockObjects.count > 0) {
            [self sendMetadataObjectsToDelegate:mockObjects];
        }

        [fileManager removeItemAtPath:self.filePath error:nil];
    }
}

- (void)addContainer:(MetadataObjectDelegateContainer *)container {
    [self.activeContainers addObject:container];
    NSLog(@"QAWolf:MetadataObject:Added container, total: %lu", (unsigned long)self.activeContainers.count);
}

- (void)simulateMetadataObjectDetection:(NSString *)type value:(NSString *)value {
    NSLog(@"QAWolf:MetadataObject:Simulating detection of %@ for %lu containers", type, (unsigned long)self.activeContainers.count);

    // Create mock metadata object
    MockAVMetadataObject *mockObject = [[MockAVMetadataObject alloc] initWithStringValue:value
                                                                                     type:type
                                                                                   bounds:CGRectMake(0.38, 0.27, 0.32, 0.57)
                                                                                  corners:nil
                                                                                 rawValue:nil];
    NSArray *metadataObjects = @[(AVMetadataObject *)mockObject];
    [self sendMetadataObjectsToDelegate:metadataObjects];
}

- (void)sendMetadataObjectsToDelegate:(NSArray<AVMetadataObject *> *)metadataObjects {
    // Clean up invalid containers
    NSMutableArray *validContainers = [[NSMutableArray alloc] init];
    for (MetadataObjectDelegateContainer *container in self.activeContainers) {
        if ([container isValid]) {
            [validContainers addObject:container];
        }
    }

    self.activeContainers = validContainers;

    // Send to all valid containers
    for (MetadataObjectDelegateContainer *container in self.activeContainers) {
        [container forwardDelegateCall:metadataObjects fromConnection:nil];
    }
}

- (NSDictionary *)readJsonFile:(NSString *)filePath {
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    if (error) {
        NSLog(@"QAWolf:MetadataObject:Error reading JSON file: %@", error);
        return nil;
    }
    return json;
}

- (void)stopMonitoring {
    if (self.fileSource) {
        dispatch_source_cancel(self.fileSource);
        self.fileSource = nil;
    }
}

- (void)dealloc {
    [self stopMonitoring];
}

@end