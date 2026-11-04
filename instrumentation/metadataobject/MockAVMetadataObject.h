//
//  MockAVMetadataObject.h
//  instrumentation
//
//  Created by refactor on 18.01.25.
//  Extended to support all metadata object types.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Mock implementation of AVMetadataMachineReadableCodeObject for all barcode/metadata types
 */
@interface MockAVMetadataObject : AVMetadataMachineReadableCodeObject

@property (nonatomic, strong) NSString *mockStringValue;
@property (nonatomic, strong) NSString *mockType;
@property (nonatomic, assign) CGRect mockBounds;
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *mockCorners;
@property (nonatomic, assign) CMTime mockTime;
@property (nonatomic, strong, nullable) CIBarcodeDescriptor *mockDescriptor;
@property (nonatomic, strong, nullable) NSData *mockRawValue;

// Legacy initializer for QR codes (backward compatibility)
- (instancetype)initWithStringValue:(NSString *)stringValue;

// New initializer with full control over all properties
- (instancetype)initWithStringValue:(NSString *)stringValue
                               type:(NSString *)type
                             bounds:(CGRect)bounds
                            corners:(nullable NSArray<NSDictionary *> *)corners
                           rawValue:(nullable NSData *)rawValue;

@end

NS_ASSUME_NONNULL_END
