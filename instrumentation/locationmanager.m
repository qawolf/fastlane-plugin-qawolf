#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import "filemonitor.h"
#import "utils.h"

@interface CLBeaconProxy : NSProxy <NSObject>

@property (nonatomic, strong) NSUUID *UUID;
@property (nonatomic, strong) NSUUID *proximityUUID;
@property (nonatomic, strong) NSNumber *major;
@property (nonatomic, strong) NSNumber *minor;
@property (nonatomic, assign) CLProximity proximity;
@property (nonatomic, assign) NSInteger rssi;
@property (nonatomic, assign) CLLocationAccuracy accuracy;
@property (nonatomic, strong) NSDate *timestamp;

- (instancetype)initWithUUID:(NSUUID *)uuid
                      major:(NSNumber *)major
                      minor:(NSNumber *)minor
                      rssi:(NSInteger)rssi
                      accuracy:(CLLocationAccuracy)accuracy;

@end

@implementation CLBeaconProxy

- (instancetype)initWithUUID:(NSUUID *)uuid
                      major:(NSNumber *)major
                      minor:(NSNumber *)minor
                      rssi:(NSInteger)rssi
                      accuracy:(CLLocationAccuracy)accuracy{
    self.UUID = uuid;
    self.proximityUUID = uuid;
    self.major = major;
    self.minor = minor;
    self.rssi = rssi;
    self.accuracy = accuracy;
    self.timestamp = [NSDate date];
    
    // Set proximity based on RSSI
    if (rssi > -50) {
        self.proximity = CLProximityImmediate;
    } else if (rssi > -70) {
        self.proximity = CLProximityNear;
    } else {
        self.proximity = CLProximityFar;
    }
    
    return self;
}

#pragma mark - NSProxy Forwarding

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    // Return appropriate method signatures for known selectors
    if (sel == @selector(UUID)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if (sel == @selector(proximityUUID)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if (sel == @selector(major) || sel == @selector(minor)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if (sel == @selector(proximity)) {
        return [NSMethodSignature signatureWithObjCTypes:"i@:"];
    }
    if (sel == @selector(rssi)) {
        return [NSMethodSignature signatureWithObjCTypes:"l@:"];
    }
    if (sel == @selector(accuracy)) {
        return [NSMethodSignature signatureWithObjCTypes:"d@:"];
    }
    if (sel == @selector(timestamp)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if (sel == @selector(region)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    
    return [NSObject instanceMethodSignatureForSelector:sel];
}

- (void)doesNotRecognizeSelector:(SEL)selector {
    [NSException raise:NSInvalidArgumentException
                format:@"-%@ not recognized by %@", NSStringFromSelector(selector), self];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    SEL selector = invocation.selector;
    
    // Handle known selectors
    if (selector == @selector(UUID)) {
        [invocation setReturnValue:&_UUID];
    }
    if (selector == @selector(proximityUUID)) {
        [invocation setReturnValue:&_UUID];
    }
    else if (selector == @selector(major)) {
        [invocation setReturnValue:&_major];
    }
    else if (selector == @selector(minor)) {
        [invocation setReturnValue:&_minor];
    }
    else if (selector == @selector(proximity)) {
        [invocation setReturnValue:&_proximity];
    }
    else if (selector == @selector(rssi)) {
        [invocation setReturnValue:&_rssi];
    }
    else if (selector == @selector(accuracy)) {
        [invocation setReturnValue:&_accuracy];
    }
    else if (selector == @selector(timestamp)) {
        [invocation setReturnValue:&_timestamp];
    }
    else if ([self.UUID respondsToSelector:selector]) {
        [invocation invokeWithTarget:self.UUID];
    }
    else {
        [self doesNotRecognizeSelector:selector];
    }
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [NSStringFromSelector(selector) isEqualToString:@"UUID"] ||
           [NSStringFromSelector(selector) isEqualToString:@"proximityUUID"] ||
           [NSStringFromSelector(selector) isEqualToString:@"major"] ||
           [NSStringFromSelector(selector) isEqualToString:@"minor"] ||
           [NSStringFromSelector(selector) isEqualToString:@"proximity"] ||
           [NSStringFromSelector(selector) isEqualToString:@"rssi"] ||
           [NSStringFromSelector(selector) isEqualToString:@"accuracy"] ||
           [NSStringFromSelector(selector) isEqualToString:@"timestamp"] ||
           [self.UUID respondsToSelector:selector];
}

- (BOOL)isKindOfClass:(Class)aClass {
    for (Class candidate = [CLBeacon class]; candidate != Nil; candidate = class_getSuperclass(candidate)) {
        if (candidate == aClass) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isMemberOfClass:(Class)aClass {
    return aClass == [CLBeacon class];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLBeaconProxy: UUID=%@, major=%@, minor=%@, rssi=%ld>, accuracy=%f",
            self.UUID.UUIDString, self.major, self.minor, (long)self.rssi, (double)self.accuracy];
}

@end

@interface CLLocationManagerDelegateProxy : NSProxy<NSObject, CLLocationManagerDelegate>

@property (nonatomic, strong) id<CLLocationManagerDelegate> proxyObject;

@end

@implementation CLLocationManagerDelegateProxy

- (instancetype)initWithProxy:(id<CLLocationManagerDelegate>)proxy {
    if (self) {
        _proxyObject = proxy;
    }
    return self;
}

- (void) locationManager:(CLLocationManager *)manager didRangeBeacons:(nonnull NSArray<CLBeacon *> *)beacons inRegion:(nonnull CLBeaconRegion *) region
{
    NSLog(@"QAWolfInstrumentation:CLLocationManagerDelegateProxy:locationManager didRangeBeacons:%@ inRegion:%@", beacons, region);
    SEL selector = @selector(locationManager:didRangeBeacons:inRegion:);
    if([self.proxyObject respondsToSelector:selector] == false) {
        return;
    }
    
    // construct a paht of [Instrumentation getQAWolfFolder]/region.uuid.beacon and check if the file exists and read it into json
    NSString *path = [Utils getQAWolfFolder];
    NSString *filePath = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.beacon", region.UUID.UUIDString]];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:filePath]) {
        NSLog(@"QAWolfInstrumentation:LocationManager:File not found: %@", filePath);
        
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.proxyObject locationManager:manager didRangeBeacons:beacons inRegion:region];
        return;
    }
    
    NSData *data = [fileManager contentsAtPath:filePath];
    NSError *error;
    // read an array of json objects from the file
    NSArray<NSDictionary*> *jsonBeacons = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    if (error) {
        NSLog(@"QAWolfInstrumentation:LocationManager:Error reading json: %@", error);
        return;
    }
    if (![jsonBeacons isKindOfClass:[NSArray class]]) {
        NSLog(@"Expected array, got: %@", [jsonBeacons class]);
        return;
    }
    
    NSLog(@"QAWolfInstrumentation:LocationManager:didRangeBeacons jsonBeacons:%@ region:%@", jsonBeacons, region);
    
    NSMutableArray *mockBeacons = [NSMutableArray array];
    // iterate over all beacons
    for (NSDictionary *jsonBeacon in jsonBeacons) {
        NSLog(@"QAWolfInstrumentation:LocationManager:didRangeBeacons checking jsonBeacon: %@, major: %ld, minor: %ld", jsonBeacon, [region.major integerValue], [region.minor integerValue]);
        if (![jsonBeacon isKindOfClass:[NSDictionary class]]) {
            NSLog(@"Expected dictionary, got: %@", [jsonBeacon class]);
            continue;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:jsonBeacon[@"uuid"]];
        if(region.UUID != nil && [region.UUID isEqual:uuid] == false) {
            continue;
        }
        NSNumber *major = @([jsonBeacon[@"major"] intValue]);
        if(region.major != nil && [region.major isEqual:major] == false) {
            continue;
        }
        NSNumber *minor = @([jsonBeacon[@"minor"] intValue]);
        if(region.minor != nil && [region.minor isEqual:minor] == false) {
            continue;
        }
        
        CLBeaconProxy *beacon = [[CLBeaconProxy alloc] initWithUUID:uuid major:major minor:minor rssi:-50 accuracy:kCLLocationAccuracyBest];
        NSLog(@"QAWolfInstrumentation:LocationManager:didRangeBeacons adding beacon: %@", beacon);
        [mockBeacons addObject:beacon];
    }
    
    // Add debug logging before the call
    NSLog(@"Mock beacons array count: %lu", (unsigned long)mockBeacons.count);
    for (id beacon in mockBeacons) {
        NSLog(@"Beacon type: %@, value: %@", [beacon class], beacon);
    }
    
    NSLog(@"QAWolfInstrumentation:LocationManager:didRangeBeacons calling with region: %@ target: %@", region, self.proxyObject);
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    @try {
        [self.proxyObject locationManager:manager didRangeBeacons:mockBeacons inRegion:region];
    } @catch (NSException *exception) {
        NSLog(@"Exception calling delegate: %@", exception);
    }
    #pragma clang diagnostic pop
}
    

- (void)forwardInvocation:(NSInvocation *)invocation
{
    // log the method name and its passed argumets:
    NSLog(@"QAWolfInstrumentation:CLLocationManagerDelegateProxy:forwardInvocation: %@", NSStringFromSelector(invocation.selector));
    if (self.proxyObject) {
        [invocation setTarget:self.proxyObject];
        [invocation invoke];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    NSLog(@"QAWolfInstrumentation:CLLocationManagerDelegateProxy:respondsToSelector: %@", NSStringFromSelector(aSelector));
    return [self.proxyObject respondsToSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    NSLog(@"QAWolfInstrumentation:CLLocationManagerDelegateProxy:methodSignatureForSelector: %@", NSStringFromSelector(sel));
    NSMethodSignature *signature = nil;
    if ([(id)self.proxyObject methodSignatureForSelector:sel]) {
        signature = [(id)self.proxyObject methodSignatureForSelector:sel];
    }
    
    return signature;
}

@end

@implementation CLLocationManager (Swizzling)

+ (void)load
{
    NSLog(@"QAWolfInstrumentation:LocationManager:load");
    [Utils swizzleMethodInClass:self originalSelector:@selector(init) swizzledSelector:@selector(initCustom)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(startMonitoringForRegion:) swizzledSelector:@selector(swizzeld_startMonitoringForRegion:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(stopMonitoringForRegion:) swizzledSelector:@selector(swizzeld_stopMonitoringForRegion:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(startRangingBeaconsInRegion:) swizzledSelector:@selector(swizzeld_startRangingBeaconsInRegion:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(stopRangingBeaconsInRegion:) swizzledSelector:@selector(swizzeld_stopRangingBeaconsInRegion:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(startRangingBeaconsSatisfyingConstraint:) swizzledSelector:@selector(swizzeld_startRangingBeaconsSatisfyingConstraint:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(stopRangingBeaconsSatisfyingConstraint:) swizzledSelector:@selector(swizzeld_stopRangingBeaconsSatisfyingConstraint:)];
    [Utils swizzleMethodInClass:self originalSelector:@selector(setDelegate:) swizzledSelector:@selector(swizzeld_setDelegate:)];
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzled!");
}

- (instancetype) initCustom {
    NSLog(@"QAWolfInstrumentation:LocationManager:initCustom");
    
    self = [self initCustom];
    
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(onNotification:) name:kFileChangedEvent object:nil];
    
    return self;
}

- (void)onNotification:(NSNotification *)notification {
    NSLog(@"QAWolfInstrumentation:LocationManager:onNotification: %@", notification);
    
    if ([notification.name isEqualToString:kFileChangedEvent]) {
        NSString *path = notification.userInfo[@"path"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        // read all files from the diretciry at path
        NSArray *files = [fileManager contentsOfDirectoryAtPath:path error:nil];
        NSLog(@"QAWolfInstrumentation:LocationManager:Files: %@, lastChecked: %@", files, self.lastChecked);
        
        // iterate over all files and check if the last modification date is newer than the last check
        for (NSString *file in files) {
            NSString *filePath = [path stringByAppendingPathComponent:file];
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:filePath error:nil];
            NSDate *modificationDate = attributes[NSFileModificationDate];
            NSLog(@"QAWolfInstrumentation:LocationManager:file: %@, modificationDate: %@", filePath, modificationDate);
            if(self.lastChecked == nil || [self.lastChecked earlierDate:modificationDate] == self.lastChecked) {
                NSLog(@"QAWolfInstrumentation:LocationManager:File changed: %@, monitoredRegions: %@, delegate: %@", filePath, self.monitoredRegions, self.delegate);
                // read the filename and check if it ends with '.region'
                if ([filePath hasSuffix:@".region"]) {
                    NSString *regionId = [[filePath lastPathComponent] stringByDeletingPathExtension];
                    
                    // check if a region if regionId can be found in monitoredRegions
                    for (CLRegion *region in self.monitoredRegions) {
                        if ([region.identifier isEqualToString:regionId] && [self.delegate respondsToSelector:@selector(locationManager:didEnterRegion:)]) {
                            NSLog(@"QAWolfInstrumentation:LocationManager:didEnterRegion calling with %@", region);
                            // deliver on main; the file monitor fires on a background dispatch source
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self.delegate locationManager:self didEnterRegion:region];
                            });
                            break;
                        }
                    }
                    NSLog(@"QAWolfInstrumentation:LocationManager:didEnterRegion not found for %@", regionId);
                } else if ([filePath hasSuffix:@".beacon"]) {
                    // No real beacon → iOS emits no ranging tick, so synthesize one; the delegate proxy reads {uuid}.beacon and delivers the mocks.
                    NSString *uuidString = [[filePath lastPathComponent] stringByDeletingPathExtension];
                    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
                    if (uuid == nil) {
                        NSLog(@"QAWolfInstrumentation:LocationManager:invalid .beacon uuid %@", uuidString);
                        continue;
                    }
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    CLBeaconRegion *region = [[CLBeaconRegion alloc] initWithUUID:uuid identifier:uuidString];
                    if ([self.delegate respondsToSelector:@selector(locationManager:didRangeBeacons:inRegion:)]) {
                        NSLog(@"QAWolfInstrumentation:LocationManager:.beacon injected, delivering didRangeBeacons for %@", uuidString);
                        // deliver on main; the file monitor fires on a background dispatch source
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.delegate locationManager:self didRangeBeacons:@[] inRegion:region];
                        });
                    }
                    #pragma clang diagnostic pop
                }
            }
        }
        
        self.lastChecked = [NSDate date];
    }
}

- (void)swizzeld_startMonitoringForRegion:(CLRegion *)region
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_startMonitoringForRegion %@", region);

    [self swizzeld_startMonitoringForRegion:region];
}

- (void)swizzeld_stopMonitoringForRegion:(CLRegion *)region
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_stopMonitoringForRegion %@", region);

    [self swizzeld_stopMonitoringForRegion:region];
}

- (void)swizzeld_startRangingBeaconsInRegion:(CLBeaconRegion *)region
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_startRangingBeaconsInRegion %@", region);

    [self swizzeld_startRangingBeaconsInRegion:region];
}

- (void)swizzeld_stopRangingBeaconsInRegion:(CLBeaconRegion *)region
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_stopRangingBeaconsInRegion %@", region);

    [self swizzeld_stopMonitoringForRegion:region];
}

- (void) swizzeld_startRangingBeaconsSatisfyingConstraint:(CLBeaconIdentityConstraint *) constraint
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_startRangingBeaconsSatisfyingConstraint %@", constraint);

    [self swizzeld_startRangingBeaconsSatisfyingConstraint:constraint];
}

- (void) swizzeld_stopRangingBeaconsSatisfyingConstraint:(CLBeaconIdentityConstraint *) constraint
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_stopRangingBeaconsSatisfyingConstraint %@", constraint);

    [self swizzeld_stopRangingBeaconsSatisfyingConstraint:constraint];
}

- (void) swizzeld_setDelegate:(id<CLLocationManagerDelegate>) delegate
{
    NSLog(@"QAWolfInstrumentation:LocationManager:swizzeld_setDelegate %@", delegate);
    
    id<CLLocationManagerDelegate> delegateProxy = [[CLLocationManagerDelegateProxy alloc] initWithProxy:delegate];
    [self setDelegateProxy:delegateProxy];
    
    [self swizzeld_setDelegate:delegateProxy];
}


// Define a key for the associated object
static char kAssociatedLastCheckedKey;

// To set the data
- (void)setLastChecked:(id)data {
    objc_setAssociatedObject(self, &kAssociatedLastCheckedKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// To get the data
- (id)lastChecked {
    return objc_getAssociatedObject(self, &kAssociatedLastCheckedKey);
}

// Define a key for the associated object
static char kAssociateddelegateProxyKey;

// To set the data
- (void)setDelegateProxy:(id)data {
    objc_setAssociatedObject(self, &kAssociateddelegateProxyKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// To get the data
- (id)setDelegateProxy {
    return objc_getAssociatedObject(self, &kAssociateddelegateProxyKey);
}

@end
