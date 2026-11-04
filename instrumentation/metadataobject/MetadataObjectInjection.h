//
//  MetadataObjectInjection.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all metadata object types.
//

#import <Foundation/Foundation.h>

// Main umbrella header for metadata object injection functionality
#import "MetadataObjectPayloadGenerator.h"
#import "MockAVMetadataObject.h"
#import "MetadataObjectDelegateContainer.h"
#import "MetadataObjectFileMonitor.h"
#import "MetadataObjectSwizzling.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * AVMetadataObject Injection System
 *
 * This system provides the ability to inject AVMetadataObject instances (barcodes, QR codes, etc.)
 * into AVFoundation-based scanners by:
 *
 * 1. Intercepting delegate registration (MetadataObjectSwizzling)
 * 2. Monitoring file system for injection commands (MetadataObjectFileMonitor)
 * 3. Creating mock metadata objects (MockAVMetadataObject)
 * 4. Managing delegate containers (MetadataObjectDelegateContainer)
 * 5. Generating barcode payloads (MetadataObjectPayloadGenerator)
 *
 * Supported Types:
 * - QR codes, Aztec, PDF417, DataMatrix (2D codes)
 * - EAN, UPC, Code128, Code39, Code93 (1D barcodes)
 * - And all other AVMetadataObjectType constants
 *
 * Usage:
 * - Include this header in your instrumentation
 * - The system automatically activates via +load methods
 * - Write JSON file to trigger injection:
 *   - .qawolf/metadataobject.json with {"metadataObjects": [...]}
 */

NS_ASSUME_NONNULL_END