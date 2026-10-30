/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

#import "XRGTemperatureHardwareReader.h"
#import "XRGHIDTransport.h"

@interface XRGTemperatureHardwareReader ()
@property (nonatomic) id<XRGSMCSensorValuesProvider> smcSensors;
@end

@implementation XRGTemperatureHardwareReader

+ (id<XRGTemperatureReader>)makeTemperatureReader {
    return [[self alloc] init];
}

- (instancetype)init {
    if ((self = [super init])) {
        @try {
            _smcSensors = [[XRGSMCSensors alloc] init];
        } @catch (NSException *exception) {
            // HID discovery can still work if SMC initialization fails.
        }
    }
    return self;
}

- (NSDictionary<NSString *, id> *)temperatureValuesIncludingUnknown:(BOOL)includeUnknown {
    @try { return [self.smcSensors temperatureValuesIncludingUnknown:includeUnknown] ?: @{}; }
    @catch (NSException *exception) { return @{}; }
}

- (NSDictionary<NSString *, id> *)siliconTemperatureValues {
    @try { return [XRGAppleSiliconSensorMiner sensorData] ?: @{}; }
    @catch (NSException *exception) { return @{}; }
}

- (NSDictionary<NSString *, id> *)fanValues {
    @try { return self.smcSensors.fanValues ?: @{}; }
    @catch (NSException *exception) { return @{}; }
}

- (NSString *)humanReadableNameForKey:(NSString *)key {
    @try { return [self.smcSensors humanReadableNameForKey:key] ?: key; }
    @catch (NSException *exception) { return key; }
}

- (BOOL)isKnownKey:(NSString *)key {
    @try { return [self.smcSensors isKnownKey:key]; }
    @catch (NSException *exception) { return NO; }
}

- (NSInteger)knownTemperatureKeyCount {
    @try { return self.smcSensors.knownTemperatureKeys.count; }
    @catch (NSException *exception) { return 0; }
}
@end


// Native calls and their CF ownership stay behind Objective-C exception handlers.
@interface XRGAppleHIDTransport : NSObject <XRGHIDTemperatureTransport, XRGHIDTemperatureTransportFactory> {
    IOHIDEventSystemClientRef _client;
}
@end

@implementation XRGAppleHIDTransport
+ (id<XRGHIDTemperatureTransport>)makeHIDTransport {
#if TARGET_CPU_ARM64 || defined(XRG_SENSOR_TEST_TRANSPORTS)
    XRGAppleHIDTransport *transport = [[self alloc] init];
    @try {
        transport->_client = XRGHIDCreateClient(kCFAllocatorDefault);
        if (!transport->_client) return nil;
        XRGHIDSetMatching(transport->_client, (__bridge CFDictionaryRef)@{
            @"PrimaryUsagePage": @(XRGHIDVendorPage),
            @"PrimaryUsage": @(XRGHIDTemperatureUsage)
        });
        return transport;
    } @catch (NSException *exception) { return nil; }
#else
    return nil;
#endif
}
- (void)dealloc { if (_client) CFRelease(_client); }
- (NSArray *)services {
#if TARGET_CPU_ARM64 || defined(XRG_SENSOR_TEST_TRANSPORTS)
    @try { return CFBridgingRelease(XRGHIDCopyServices(_client)); }
    @catch (NSException *exception) { return nil; }
#else
    return nil;
#endif
}
- (id)productForService:(id)service {
#if TARGET_CPU_ARM64 || defined(XRG_SENSOR_TEST_TRANSPORTS)
    @try {
        if (CFGetTypeID((__bridge CFTypeRef)service) != XRGHIDServiceTypeID()) return nil;
        return CFBridgingRelease(XRGHIDCopyProduct((__bridge IOHIDServiceClientRef)service, CFSTR("Product")));
    } @catch (NSException *exception) { return nil; }
#else
    return nil;
#endif
}
- (NSNumber *)temperatureForService:(id)service {
#if TARGET_CPU_ARM64 || defined(XRG_SENSOR_TEST_TRANSPORTS)
    IOHIDEventRef event = NULL;
    @try {
        if (CFGetTypeID((__bridge CFTypeRef)service) != XRGHIDServiceTypeID()) return nil;
        event = XRGHIDCopyEvent((__bridge IOHIDServiceClientRef)service, XRGHIDTemperatureEvent, 0, 0);
        if (!event) return nil;
        return @(XRGHIDGetFloat(event, XRGHIDTemperatureField));
    } @catch (NSException *exception) { return nil; }
    @finally { if (event) CFRelease(event); }
#else
    return nil;
#endif
}
@end
