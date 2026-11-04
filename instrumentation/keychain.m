//
//  keychain.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 11.02.25.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "fishhook.h"
#import "utils.h"

// Original function pointers
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query);

// Helper function to remove access group from dictionary
static NSMutableDictionary* removeAccessGroup(CFDictionaryRef dict) {
    NSMutableDictionary *mutableDict = CFBridgingRelease(CFDictionaryCreateMutableCopy(NULL, 0, dict));
    [mutableDict removeObjectForKey:(__bridge NSString *)kSecAttrAccessGroup];
    return mutableDict;
}

// Swizzled implementations
OSStatus my_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSLog(@"QAWolf:keychain:SecItemAdd was called");
    NSMutableDictionary *mutableAttributes = removeAccessGroup(attributes);
    return original_SecItemAdd((__bridge CFDictionaryRef)mutableAttributes, result);
}

OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSLog(@"QAWolf:keychain:SecItemCopyMatching was called");
    NSMutableDictionary *mutableQuery = removeAccessGroup(query);
    return original_SecItemCopyMatching((__bridge CFDictionaryRef)mutableQuery, result);
}

OSStatus my_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSLog(@"QAWolf:keychain:SecItemUpdate was called");
    NSMutableDictionary *mutableQuery = removeAccessGroup(query);
    NSMutableDictionary *mutableAttributes = removeAccessGroup(attributesToUpdate);
    return original_SecItemUpdate((__bridge CFDictionaryRef)mutableQuery, 
                                (__bridge CFDictionaryRef)mutableAttributes);
}

OSStatus my_SecItemDelete(CFDictionaryRef query) {
    NSLog(@"QAWolf:keychain:SecItemDelete was called");
    NSMutableDictionary *mutableQuery = removeAccessGroup(query);
    return original_SecItemDelete((__bridge CFDictionaryRef)mutableQuery);
}

// Helper function to clear all items of a specific keychain class
static void clearKeychainClass(CFTypeRef keychainClass, NSString *className) {
    NSLog(@"QAWolf:keychain:clearKeychainClass: Clearing %@", className);

    // Query all items of this class
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)keychainClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

    if (status == errSecSuccess && result != NULL) {
        NSArray *items = (__bridge_transfer NSArray *)result;
        NSLog(@"QAWolf:keychain:clearKeychainClass: Found %lu items in %@", (unsigned long)items.count, className);

        // Delete all items of this class
        NSDictionary *deleteQuery = @{
            (__bridge id)kSecClass: (__bridge id)keychainClass
        };
        OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

        if (deleteStatus == errSecSuccess) {
            NSLog(@"QAWolf:keychain:clearKeychainClass: Successfully deleted all items from %@", className);
        } else if (deleteStatus == errSecItemNotFound) {
            NSLog(@"QAWolf:keychain:clearKeychainClass: No items found in %@ (errSecItemNotFound)", className);
        } else {
            NSLog(@"QAWolf:keychain:clearKeychainClass: Failed to delete items from %@, status: %d", className, (int)deleteStatus);
        }
    } else if (status == errSecItemNotFound) {
        NSLog(@"QAWolf:keychain:clearKeychainClass: No items found in %@ (errSecItemNotFound)", className);
    } else {
        NSLog(@"QAWolf:keychain:clearKeychainClass: Failed to query %@, status: %d", className, (int)status);
    }
}

// Clear all keychain data on first launch after install
static void clearKeychainOnFirstLaunch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: Checking first launch status");

        // Get .qawolf folder path
        NSString *qawolfFolder = [Utils getQAWolfFolder];
        NSString *markerPath = [qawolfFolder stringByAppendingPathComponent:@"keychain_initialized"];

        NSFileManager *fileManager = [NSFileManager defaultManager];

        // Check if marker file exists
        if ([fileManager fileExistsAtPath:markerPath]) {
            NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: Marker file exists, not first launch");
            return;
        }

        NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: First launch detected, clearing keychain");

        // Clear all keychain classes
        clearKeychainClass(kSecClassGenericPassword, @"GenericPassword");
        clearKeychainClass(kSecClassInternetPassword, @"InternetPassword");
        clearKeychainClass(kSecClassCertificate, @"Certificate");
        clearKeychainClass(kSecClassKey, @"Key");
        clearKeychainClass(kSecClassIdentity, @"Identity");

        // Create marker file to prevent re-clearing
        NSError *error = nil;
        [@"cleared" writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:&error];

        if (error) {
            NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: Failed to create marker file: %@", error.localizedDescription);
        } else {
            NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: Marker file created successfully");
        }

        NSLog(@"QAWolf:keychain:clearKeychainOnFirstLaunch: Keychain clearing completed");
    });
}

__attribute__((constructor))
static void initializeSwizzling(void) {
    NSLog(@"QAWolf:keychain:initializeSwizzling was called");

    // Clear keychain on first launch
    clearKeychainOnFirstLaunch();

    rebind_single_symbol("SecItemAdd", (void *)my_SecItemAdd, (void **)&original_SecItemAdd);
    rebind_single_symbol("SecItemCopyMatching", (void *)my_SecItemCopyMatching, (void **)&original_SecItemCopyMatching);
    rebind_single_symbol("SecItemUpdate", (void *)my_SecItemUpdate, (void **)&original_SecItemUpdate);
    rebind_single_symbol("SecItemDelete", (void *)my_SecItemDelete, (void **)&original_SecItemDelete);
}
