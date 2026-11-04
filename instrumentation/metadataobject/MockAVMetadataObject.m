//
//  MockAVMetadataObject.m
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Extended to support all metadata object types.
//

#import "MockAVMetadataObject.h"
#import "MetadataObjectPayloadGenerator.h"

@implementation MockAVMetadataObject

// Legacy initializer for QR codes (backward compatibility)
- (instancetype)initWithStringValue:(NSString *)stringValue {
    return [self initWithStringValue:stringValue
                                type:@"org.iso.QRCode"
                              bounds:CGRectMake(0.38, 0.27, 0.32, 0.57)
                             corners:nil
                            rawValue:nil];
}

// New initializer with full control
- (instancetype)initWithStringValue:(NSString *)stringValue
                               type:(NSString *)type
                             bounds:(CGRect)bounds
                            corners:(nullable NSArray<NSDictionary *> *)corners
                           rawValue:(nullable NSData *)rawValue {
    if (self) {
        _mockStringValue = stringValue;
        _mockType = type;
        _mockBounds = bounds;
        _mockTime = CMTimeMakeWithSeconds([[NSDate date] timeIntervalSince1970], 1000);

        // Calculate corners from bounds if not provided
        if (corners) {
            _mockCorners = corners;
        } else {
            // Calculate 4 corner points from bounds
            CGFloat x = bounds.origin.x;
            CGFloat y = bounds.origin.y;
            CGFloat w = bounds.size.width;
            CGFloat h = bounds.size.height;

            CGPoint topLeft = CGPointMake(x, y);
            CGPoint topRight = CGPointMake(x + w, y);
            CGPoint bottomRight = CGPointMake(x + w, y + h);
            CGPoint bottomLeft = CGPointMake(x, y + h);

            _mockCorners = @[
                (__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(topLeft),
                (__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(topRight),
                (__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(bottomRight),
                (__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(bottomLeft)
            ];
        }

        // Set raw value or default to UTF-8 encoding
        if (rawValue) {
            _mockRawValue = rawValue;
        } else {
            _mockRawValue = [stringValue dataUsingEncoding:NSUTF8StringEncoding];
        }

        // Create descriptor based on type
        _mockDescriptor = [self createDescriptorForType:type value:stringValue];
    }
    return self;
}

- (nullable CIBarcodeDescriptor *)createDescriptorForType:(NSString *)type value:(NSString *)value {
    // Only create descriptors for supported types
    if ([type isEqualToString:@"org.iso.QRCode"]) {
        if (@available(iOS 11.0, *)) {
            NSData *payloadData = [MetadataObjectPayloadGenerator createPayloadForURL:value];
            if (payloadData) {
                CIQRCodeDescriptor *descriptor = [CIQRCodeDescriptor descriptorWithPayload:payloadData
                                                                               symbolVersion:5
                                                                                maskPattern:0
                                                                           errorCorrectionLevel:CIQRCodeErrorCorrectionLevelM];
                if (!descriptor) {
                    NSLog(@"QAWolf:MockAVMetadata:Failed to create QR code descriptor");
                }
                return descriptor;
            }
        }
    }
    // TODO: Add support for other descriptor types (Aztec, PDF417, DataMatrix) when needed
    // For most barcode types (EAN, Code128, etc.), no descriptor is available
    return nil;
}

// Override AVMetadataMachineReadableCodeObject properties
- (NSString *)stringValue {
    return _mockStringValue;
}

- (NSString *)type {
    return _mockType;
}

- (CGRect)bounds {
    return _mockBounds;
}

- (NSArray<NSDictionary *> *)corners {
    return _mockCorners;
}

- (CMTime)time {
    return _mockTime;
}

- (CIBarcodeDescriptor *)descriptor {
    return _mockDescriptor;
}

- (CMTime)duration {
    return CMTimeMakeWithSeconds(0.1, 1000);
}

// iOS 13+ rawValue support
- (NSData *)rawValue API_AVAILABLE(ios(13.0)) {
    return _mockRawValue;
}

@end
