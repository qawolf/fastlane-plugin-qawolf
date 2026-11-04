//
//  locationmanager.h
//  instrumentation
//
//  Created by Andreas Lüdeke on 20.01.25.
//

# import <CoreLocation/CoreLocation.h>

#ifndef locationmanager_h
#define locationmanager_h

@interface CLLocationManager (Swizzling)
- (CLLocationManager*)init_location_manager_swizzled;
@end

#endif /* locationmanager_h */
