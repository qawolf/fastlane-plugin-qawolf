//
//  appgroup.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 15.01.25.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "utils.h"

@implementation NSFileManager (Swizzling)

+ (void)load {
    NSLog(@"QAWolf:NSFileManager:load");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:NSFileManager.class originalSelector:@selector(containerURLForSecurityApplicationGroupIdentifier:) swizzledSelector:@selector(swizzled_containerURLForSecurityApplicationGroupIdentifier:)];
        NSLog(@"QAWolf:NSFileManager:Instrumentation swizzled!");
    });
}

- (NSURL *)swizzled_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSLog(@"QAWolf:NSFileManager:swizzled_containerURLForSecurityApplicationGroupIdentifier groupIdentifier: %@", groupIdentifier);
    
    // If groupIdentifier is nil, call the original implementation (which safely returns nil)
    if (!groupIdentifier) {
        return [self swizzled_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }
    
    // Get the temporary directory URL
    NSURL *tmpDirectoryURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];

    // Create a subfolder URL with the app group identifier
    NSURL *appGroupSubfolderURL = [tmpDirectoryURL URLByAppendingPathComponent:groupIdentifier isDirectory:YES];

    // Create the subfolder if it doesn't exist
    NSError *error = nil;
    if (![self createDirectoryAtURL:appGroupSubfolderURL withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"QAWolf:NSFileManager:Error creating app group subfolder: %@", error);
        // Handle the error appropriately (e.g., return nil or the original temporary directory)
        return tmpDirectoryURL;
    }

    // Return a path inside the subfolder (e.g., a file named "data.txt")
    return appGroupSubfolderURL;
}

@end
