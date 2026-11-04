//
//  appgroup.h
//  instrumentation
//
//  Created by Andreas Lüdeke on 15.01.25.
//

#ifndef appgroup_h
#define appgroup_h

@interface NSFileManager (Swizzling)

- (NSURL *)swizzled_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;

@end

#endif /* appgroup_h */
