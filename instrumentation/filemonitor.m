//
//  foldermonitor.m
//  ios-agent
//
//  Created by Andreas Lüdeke on 20.01.25.
//
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "filemonitor.h"
#import "utils.h"

@interface FileMonitorDelegate : NSObject

- (void)fileWasModified;

@end

@interface FileMonitor : NSObject

@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic, assign) int fileDescriptor;
@property (nonatomic, strong) FileMonitorDelegate *delegate;

- (void)startMonitoringDirectoryAtPath:(NSString *)path;
- (void)stopMonitoring;

@end

@implementation FileMonitor

static FileMonitor *sharedMonitor = nil;

+ (void)load {
    NSString *folder = [Utils getQAWolfFolder];
    
    sharedMonitor = [[FileMonitor alloc] init];
    [sharedMonitor startMonitoringDirectoryAtPath:folder];
    NSLog(@"QAWolf:FileMonitor loaded! Monitoring: %@", folder);
}

- (void) initWithDelegate:(FileMonitorDelegate *)delegate {
    self.delegate = delegate;
}

- (void)startMonitoringDirectoryAtPath:(NSString *)path {
    // Convert the path to a file descriptor
    self.fileDescriptor = open([path fileSystemRepresentation], O_EVTONLY);
    if (self.fileDescriptor < 0) {
        NSLog(@"Unable to open the path: %@", path);
        return;
    }

    // Create a dispatch source to monitor the file descriptor
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, self.fileDescriptor, DISPATCH_VNODE_WRITE, DISPATCH_TARGET_QUEUE_DEFAULT);

    if (!self.source) {
        close(self.fileDescriptor);
        NSLog(@"QAWolf:Unable to create dispatch source");
        return;
    }

    // Set the event handler
    dispatch_source_set_event_handler(self.source, ^{
        unsigned long eventTypes = dispatch_source_get_data(self.source);
        if (eventTypes & DISPATCH_VNODE_WRITE) {
            NSLog(@"QAWolf:File or directory was written to");
            
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            [center postNotificationName:kFileChangedEvent object:nil userInfo:[NSDictionary dictionaryWithObject:path forKey:@"path"]];
            [self.delegate fileWasModified];
        }
    });

    // Set the cancel handler
    dispatch_source_set_cancel_handler(self.source, ^{
        close(self.fileDescriptor);
        self.fileDescriptor = 0;
        self.source = nil;
    });

    // Start monitoring
    dispatch_resume(self.source);
}

- (void)stopMonitoring {
    if (self.source) {
        dispatch_source_cancel(self.source);
    }
}

@end
