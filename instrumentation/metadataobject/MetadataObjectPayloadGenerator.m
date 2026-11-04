//
//  MetadataObjectPayloadGenerator.m
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Renamed to support all barcode types.
//

#import "MetadataObjectPayloadGenerator.h"

@implementation MetadataObjectPayloadGenerator

+ (nullable NSData *)createPayloadForType:(NSString *)type value:(NSString *)value {
    // Currently only QR code encoding is implemented
    // For most use cases, stringValue is sufficient without a payload/descriptor
    if ([type isEqualToString:@"org.iso.QRCode"]) {
        return [self createPayloadForURL:value];
    }

    // For other types, return nil (descriptor not required for injection)
    // Apps typically only care about stringValue property
    NSLog(@"QAWolf:MetadataObject:Payload encoding not implemented for type: %@", type);
    return nil;
}

+ (NSData *)createPayloadForURL:(NSString *)url {
    if (!url) return [NSData data];

    NSData* urlData = [url dataUsingEncoding:NSUTF8StringEncoding];
    if (!urlData) return [NSData data];

    NSUInteger urlLength = [urlData length];
    if (urlLength > 255) urlLength = 255; // 8-bit limit

    // QR code structure: 4 bits mode + 8 bits length + data
    NSUInteger totalBits = 4 + 8 + (urlLength * 8);
    NSUInteger totalBytes = (totalBits + 7) / 8;

    NSMutableData* payload = [NSMutableData dataWithLength:totalBytes];
    uint8_t* bytes = (uint8_t*)[payload mutableBytes];
    memset(bytes, 0, totalBytes);

    NSUInteger bitPos = 0;

    // Helper to set bits
    void (^setBits)(NSUInteger, uint32_t, NSUInteger) = ^(NSUInteger startPos, uint32_t value, NSUInteger numBits) {
        for (NSUInteger i = 0; i < numBits; i++) {
            NSUInteger byteIndex = (startPos + i) / 8;
            NSUInteger bitIndex = 7 - ((startPos + i) % 8);
            if ((value >> (numBits - 1 - i)) & 1) {
                bytes[byteIndex] |= (1 << bitIndex);
            }
        }
    };

    // Set mode (0100 = byte mode), length, and data
    setBits(bitPos, 0x4, 4); bitPos += 4;
    setBits(bitPos, (uint32_t)urlLength, 8); bitPos += 8;

    const uint8_t* urlBytes = (const uint8_t*)[urlData bytes];
    for (NSUInteger i = 0; i < urlLength; i++) {
        setBits(bitPos, urlBytes[i], 8);
        bitPos += 8;
    }

    NSLog(@"QAWolf:MetadataObject:Created QR code payload for value: %@ (length: %lu)", url, (unsigned long)totalBytes);
    return payload;
}

@end