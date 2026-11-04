//
//  MetadataObjectPayloadGenerator.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all barcode types.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Utility class for generating barcode/QR code payloads for various metadata object types
 */
@interface MetadataObjectPayloadGenerator : NSObject

/**
 * Creates a payload for the given barcode type and value
 * @param type The AVMetadataObjectType (e.g., org.iso.QRCode)
 * @param value The string value to encode
 * @return NSData containing the barcode payload, or nil if encoding not supported
 */
+ (nullable NSData *)createPayloadForType:(NSString *)type value:(NSString *)value;

/**
 * Legacy method: Creates a QR code payload for the given URL
 * @param url The URL to encode in the QR code
 * @return NSData containing the QR code payload
 */
+ (NSData *)createPayloadForURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END