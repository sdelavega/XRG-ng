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

#import <XCTest/XCTest.h>
#import "../Data Miners/XRGTemperatureHardwareReader.h"
#import "../Data Miners/APSL/SMCSensors.h"
#import "../Data Miners/APSL/SMCInterface.h"
#import "../Data Miners/APSL/XRGAppleSiliconSensorMiner.h"
#define XRG_SENSOR_TEST_TRANSPORTS 1
#import "../Data Miners/XRGHIDTransport.h"

// These transport stubs are linked only into the test process. The app links
// the real SMC/HID implementations; fixture tests never query physical sensors.
static BOOL throwSMCInit, throwTemperatures, throwFans, throwNames, throwKnown, throwHID;
static void readerFailure(void) {
    @throw [NSException exceptionWithName:@"XRGFixtureFailure" reason:@"Synthetic sensor failure" userInfo:nil];
}

@interface XRGFixtureSMCSensorValues : NSObject <XRGSMCSensorValuesProvider>
@end
@implementation XRGFixtureSMCSensorValues
- (instancetype)init {
    if (throwSMCInit) readerFailure();
    return [super init];
}
- (NSDictionary *)temperatureValuesIncludingUnknown:(BOOL)includeUnknown {
    if (throwTemperatures) readerFailure();
    return @{@"cpu": @50};
}
- (NSDictionary *)fanValues {
    if (throwFans) readerFailure();
    return @{@"Fan #0": @{@"F0Ac": @1200, @"F0Mx": @6000}};
}
- (NSString *)humanReadableNameForKey:(NSString *)key {
    if (throwNames) readerFailure();
    return [key isEqualToString:@"cpu"] ? @"CPU" : key;
}
- (BOOL)isKnownKey:(NSString *)key {
    if (throwKnown) readerFailure();
    return [key isEqualToString:@"cpu"];
}
- (NSSet<NSString *> *)knownTemperatureKeys {
    if (throwKnown) readerFailure();
    return [NSSet setWithObject:@"cpu"];
}
- (NSSet<NSString *> *)unknownTemperatureKeys { return [NSSet set]; }
- (NSDictionary *)allValues { return @{}; }
- (NSDictionary *)sensorValues { return @{}; }
@end

// The real Swift sensor cache uses this native-interface stub. It never opens IOKit.
static BOOL throwSMCIndex, returnSMCError;
@implementation SMCInterface
- (instancetype)init {
    if (throwSMCInit) readerFailure();
    return [super init];
}
- (NSInteger)keyCount { if (throwKnown) readerFailure(); return 1; }
- (FourCharCode)keyAtIndex:(NSInteger)index {
    if (throwSMCIndex) readerFailure();
    return index == 0 ? 0x54433050 : 0;
}
- (id)readValue:(FourCharCode)key error:(NSError **)outError {
    if (outError) *outError = nil;
    if (key == 0x54433050 && throwTemperatures) readerFailure();
    if (key == 0x46532120 && throwFans) readerFailure();
    if (returnSMCError && outError) *outError = [NSError errorWithDomain:@"XRGFixture" code:1 userInfo:nil];
    return key == 0x54433050 ? @50 : key == 0x46532120 ? @0 : nil;
}
@end

// Substitute only the C calls. Tests still execute the production Objective-C
// exception/ownership boundary and the real Swift HID collection algorithm.
static CFMutableDictionaryRef fixtureHIDClient, fixtureHIDEvent;
static NSArray *fixtureHIDServices;
static NSDictionary *capturedMatching;
static int64_t capturedEventType, capturedTimeout;
static int32_t capturedOptions, capturedField;
static BOOL throwHIDCreate, throwMatching, throwProduct, throwEvent, throwFloat;
static BOOL missingClient, missingServices, missingEvent;
IOHIDEventSystemClientRef XRGHIDCreateClient(CFAllocatorRef allocator) {
    if (throwHIDCreate) readerFailure();
    return missingClient || !fixtureHIDClient ? NULL : (IOHIDEventSystemClientRef)CFRetain(fixtureHIDClient);
}
int XRGHIDSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match) {
    capturedMatching = [(__bridge NSDictionary *)match copy];
    if (throwMatching) readerFailure();
    return 0;
}
CFArrayRef XRGHIDCopyServices(IOHIDEventSystemClientRef client) {
    if (throwHID) readerFailure();
    return missingServices ? NULL : (CFArrayRef)CFBridgingRetain(fixtureHIDServices);
}
CFTypeRef XRGHIDCopyProduct(IOHIDServiceClientRef service, CFStringRef key) {
    if (throwProduct) readerFailure();
    return CFBridgingRetain([(__bridge NSDictionary *)service objectForKey:(__bridge NSString *)key]);
}
IOHIDEventRef XRGHIDCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout) {
    capturedEventType = type; capturedOptions = options; capturedTimeout = timeout;
    if (throwEvent) readerFailure();
    return missingEvent || !fixtureHIDEvent ? NULL : (IOHIDEventRef)CFRetain(fixtureHIDEvent);
}
IOHIDFloat XRGHIDGetFloat(IOHIDEventRef event, int32_t field) {
    capturedField = field;
    if (throwFloat) readerFailure();
    return [((__bridge NSDictionary *)event)[@"temperature"] doubleValue];
}
CFTypeID XRGHIDServiceTypeID(void) { return CFDictionaryGetTypeID(); }

@interface XRGTemperatureHardwareReaderTests : XCTestCase
@end

@implementation XRGTemperatureHardwareReaderTests
- (void)setUp {
    [super setUp];
    throwSMCInit = throwTemperatures = throwFans = throwNames = throwKnown = throwHID = NO;
    throwSMCIndex = returnSMCError = NO;
    throwHIDCreate = throwMatching = throwProduct = throwEvent = throwFloat = NO;
    missingClient = missingServices = missingEvent = NO;
    capturedMatching = nil;
    fixtureHIDServices = @[@{@"Product": @"hid"}];
    fixtureHIDClient = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    fixtureHIDEvent = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(fixtureHIDEvent, CFSTR("temperature"), (__bridge const void *)@60);
}
- (void)tearDown {
    throwSMCInit = throwTemperatures = throwFans = throwNames = throwKnown = throwHID = NO;
    CFRelease(fixtureHIDClient); CFRelease(fixtureHIDEvent);
    fixtureHIDClient = fixtureHIDEvent = NULL;
    fixtureHIDServices = nil; capturedMatching = nil;
    [super tearDown];
}

- (void)testReaderMethodsContainTransportAndMetadataExceptions {
    id<XRGTemperatureReader> reader = [XRGTemperatureHardwareReader makeTemperatureReader];
    // Keep the outer reader's metadata-exception contract covered, even though
    // production metadata lookup has moved to a non-throwing Swift cache.
    [(NSObject *)reader setValue:[[XRGFixtureSMCSensorValues alloc] init] forKey:@"smcSensors"];
    XCTAssertEqualObjects([reader temperatureValuesIncludingUnknown:YES][@"cpu"], @50);
    XCTAssertEqual([reader fanValues].count, 1);
    XCTAssertEqualObjects([reader humanReadableNameForKey:@"cpu"], @"CPU");
    XCTAssertTrue([reader isKnownKey:@"cpu"]);
    XCTAssertEqual(reader.knownTemperatureKeyCount, 1);
    XCTAssertEqualObjects([reader siliconTemperatureValues][@"hid"], @60);

    throwTemperatures = throwFans = throwNames = throwKnown = throwHID = YES;
    XCTAssertNoThrow([reader temperatureValuesIncludingUnknown:YES]);
    XCTAssertEqual([reader temperatureValuesIncludingUnknown:YES].count, 0);
    XCTAssertEqual([reader fanValues].count, 0);
    XCTAssertEqualObjects([reader humanReadableNameForKey:@"cpu"], @"cpu");
    XCTAssertFalse([reader isKnownKey:@"cpu"]);
    XCTAssertEqual(reader.knownTemperatureKeyCount, 0);
    XCTAssertEqual([reader siliconTemperatureValues].count, 0);
}

- (void)testSMCInitializationFailureStillAllowsHIDReadings {
    throwSMCInit = YES;
    id<XRGTemperatureReader> reader = [XRGTemperatureHardwareReader makeTemperatureReader];
    XCTAssertNotNil(reader);
    XCTAssertEqual([reader temperatureValuesIncludingUnknown:YES].count, 0);
    XCTAssertEqual([reader fanValues].count, 0);
    XCTAssertEqualObjects([reader humanReadableNameForKey:@"hid"], @"hid");
    XCTAssertEqualObjects([reader siliconTemperatureValues][@"hid"], @60);
}

- (void)testSwiftMinerUsesTheFactoryAndDoesNotUnwindSensorExceptions {
    XCTAssertTrue(NSThread.isMainThread);
    XRGTemperatureMiner *miner = [[XRGTemperatureMiner alloc] init];
    [miner setDataSize:2];
    XCTAssertEqual(miner.knownTemperatureKeyCount, 1);
    throwTemperatures = throwFans = throwNames = YES;
    [miner updateCurrentTemperatures:YES];
    XCTAssertNil([miner sensorForLocation:@"TC0P"]);
    XRGSensorData *sensor = [miner sensorForLocation:@"hid"];
    XCTAssertNotNil(sensor);
    XCTAssertTrue(sensor.isEnabled);
    XCTAssertEqual(sensor.currentValue, 60);
    XCTAssertEqualObjects(sensor.label, @"hid");
    XCTAssertFalse([miner isFanSensor:nil]);
    XCTAssertEqual([miner maxSpeedForFan:nil], 0);
}
- (void)testNativeHIDMatchingAndEventABIAndBalancedOwnership {
    CFIndex clientsBefore = CFGetRetainCount(fixtureHIDClient), eventsBefore = CFGetRetainCount(fixtureHIDEvent);
    @autoreleasepool {
        XCTAssertEqualObjects([XRGAppleSiliconSensorMiner sensorData], (@{@"hid": @60}));
        XCTAssertEqualObjects(capturedMatching, (@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5}));
        XCTAssertEqual(capturedEventType, 15);
        XCTAssertEqual(capturedOptions, 0); XCTAssertEqual(capturedTimeout, 0);
        XCTAssertEqual(capturedField, 15 << 16);
    }
    XCTAssertEqual(CFGetRetainCount(fixtureHIDClient), clientsBefore);
    XCTAssertEqual(CFGetRetainCount(fixtureHIDEvent), eventsBefore);
}
- (void)testNativeHIDExceptionsAreContainedBeforeSwiftAndReleaseOwnedObjects {
    for (int phase = 0; phase < 6; phase++) {
        throwHIDCreate = phase == 0; throwMatching = phase == 1; throwHID = phase == 2;
        throwProduct = phase == 3; throwEvent = phase == 4; throwFloat = phase == 5;
        CFIndex clientsBefore = CFGetRetainCount(fixtureHIDClient), eventsBefore = CFGetRetainCount(fixtureHIDEvent);
        @autoreleasepool {
            NSDictionary *readings = nil;
            XCTAssertNoThrow(readings = [XRGAppleSiliconSensorMiner sensorData]);
            if (phase < 3) XCTAssertNil(readings); else XCTAssertEqualObjects(readings, @{});
        }
        XCTAssertEqual(CFGetRetainCount(fixtureHIDClient), clientsBefore);
        XCTAssertEqual(CFGetRetainCount(fixtureHIDEvent), eventsBefore);
    }
    throwHIDCreate = throwMatching = throwHID = throwProduct = throwEvent = throwFloat = NO;
    XCTAssertEqualObjects([XRGAppleSiliconSensorMiner sensorData], (@{@"hid": @60}));
}
- (void)testNativeHIDMissingClientServicesAndEventsKeepTheOldNilAndEmptyResults {
    missingClient = YES; XCTAssertNil([XRGAppleSiliconSensorMiner sensorData]); missingClient = NO;
    missingServices = YES; XCTAssertNil([XRGAppleSiliconSensorMiner sensorData]); missingServices = NO;
    missingEvent = YES; XCTAssertEqualObjects([XRGAppleSiliconSensorMiner sensorData], @{}); missingEvent = NO;
    fixtureHIDServices = @[]; XCTAssertEqualObjects([XRGAppleSiliconSensorMiner sensorData], @{});
}
- (void)testNativeSMCTransportContainsExceptionsAndRejectsNSErrorValuesBeforeSwift {
    Class<XRGSMCTransportFactory> factory = NSClassFromString(@"XRGSMCTransport");
    id<XRGSMCTransport> transport = [factory makeSMCTransport];
    XCTAssertNotNil(transport);
    XCTAssertEqual(transport.keyCount, 1);
    XCTAssertEqualObjects([transport keyAtIndex:0], @0x54433050);
    XCTAssertEqualObjects([transport readValueForKey:0x54433050], @50);
    XCTAssertNotNil(transport.descriptionsResourcePath);
    throwKnown = YES; XCTAssertEqual(transport.keyCount, 0); throwKnown = NO;
    throwSMCIndex = YES; XCTAssertNil([transport keyAtIndex:0]); throwSMCIndex = NO;
    throwTemperatures = YES; XCTAssertNil([transport readValueForKey:0x54433050]); throwTemperatures = NO;
    returnSMCError = YES; XCTAssertNil([transport readValueForKey:0x54433050]); returnSMCError = NO;
    XCTAssertEqualObjects([transport readValueForKey:0x54433050], @50);
    throwSMCInit = YES; XCTAssertNil([factory makeSMCTransport]);
}
- (void)testDefaultReaderUsesTheRealSwiftCacheAndBundledDescriptions {
    id<XRGTemperatureReader> reader = [XRGTemperatureHardwareReader makeTemperatureReader];
    XCTAssertEqual(reader.knownTemperatureKeyCount, 1);
    XCTAssertTrue([reader isKnownKey:@"TC0P"]);
    XCTAssertEqualObjects([reader humanReadableNameForKey:@"TC0P"], @"CPU Proximity");
    XCTAssertEqualObjects([reader temperatureValuesIncludingUnknown:NO], (@{@"TC0P": @50}));
    throwTemperatures = YES;
    XCTAssertEqualObjects([reader temperatureValuesIncludingUnknown:YES], @{});
    XCTAssertEqual(reader.knownTemperatureKeyCount, 1);
    XCTAssertEqualObjects([reader siliconTemperatureValues], (@{@"hid": @60}));
}
@end
