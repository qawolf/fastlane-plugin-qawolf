//
//  utils.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 30.01.25.
//

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import "utils.h"

@implementation Utils: NSObject

+ (NSString*) getQAWolfFolder {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *qawolfFolder = [documentsDirectory stringByAppendingPathComponent:@".qawolf"];
    // create directory if it doesn't exist
    if (![[NSFileManager defaultManager] fileExistsAtPath:qawolfFolder]) {
        NSError *error = nil;

        [[NSFileManager defaultManager] createDirectoryAtPath:qawolfFolder withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"QAWolf:Error creating directory: %@", error);
        }
    }

    return qawolfFolder;
}

// implement a static swizzle method which takes call original selector and swizzled selector as paramaters
+ (void)swizzleMethodInClass:(Class)class originalSelector:(SEL)originalSelector swizzledSelector:(SEL)swizzledSelector {
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);

    BOOL didAddMethod =
        class_addMethod(class,
                        originalSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod));

    if (didAddMethod) {
        class_replaceMethod(class,
                            swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

@end

#ifndef GIT_SHA
#define GIT_SHA "dev"
#endif

__attribute__((constructor))
static void QAWolfInstrumentationVersion(void) {
    NSLog(@"[QA_WOLF] [INFO] instrumentation commit: %@", @GIT_SHA);
}
