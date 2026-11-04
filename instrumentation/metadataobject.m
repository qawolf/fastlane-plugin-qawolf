//
//  metadataobject.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 16.01.25.
//  Refactored into modular components on 18.01.25.
//  Renamed to support all metadata object types on [date].
//

#import "metadataobject/MetadataObjectInjection.h"

/**
 * This file has been refactored into modular components:
 *
 * - MetadataObjectPayloadGenerator: Handles payload creation for various barcode types
 * - MockAVMetadataObject: Mock AVMetadataObject instances for all barcode types
 * - MetadataObjectDelegateContainer: Manages delegate containers
 * - MetadataObjectFileMonitor: File system monitoring for injection
 * - MetadataObjectSwizzling: Method swizzling for interception
 *
 * All functionality is preserved but now organized into focused,
 * maintainable modules that support all AVFoundation metadata object types.
 */

// Force load all metadata object injection components
__attribute__((constructor))
static void forceLoadMetadataObjectInjection(void) {
    NSLog(@"QAWolf:MetadataObject:Loading metadata object injection system");

    // Reference classes to ensure they're linked
    [MetadataObjectPayloadGenerator class];
    [MockAVMetadataObject class];
    [MetadataObjectDelegateContainer class];
    [MetadataObjectFileMonitor class];

    NSLog(@"QAWolf:MetadataObject:Metadata object injection system loaded successfully");
}