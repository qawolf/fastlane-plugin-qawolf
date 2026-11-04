//
//  utils.h
//  instrumentation
//
//  Created by Andreas Lüdeke on 30.01.25.
//

@interface Utils : NSObject

+ (NSString*)getQAWolfFolder;
+ (void)swizzleMethodInClass:(Class)class originalSelector:(SEL)originalSelector swizzledSelector:(SEL)swizzledSelector;

@end
