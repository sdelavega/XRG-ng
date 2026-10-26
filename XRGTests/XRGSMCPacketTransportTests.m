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
#import <XRGCore/XRGCore-Swift.h>
#define XRG_SENSOR_TEST_TRANSPORTS 1
#import "../Data Miners/APSL/SMCPacket.h"

static int failPhase, throwPhase;
static NSUInteger matchingCreated, matchingConsumed, servicesAcquired, servicesReleased;
static NSUInteger connectionsOpened, connectionsClosed, clientOpens, clientCloses, structCalls;
static BOOL abiMatches;
static void packetFailure(void) { @throw [NSException exceptionWithName:@"XRGPacketFixture" reason:@"Synthetic native failure" userInfo:nil]; }
static void resetCalls(void) {
    matchingCreated = matchingConsumed = servicesAcquired = servicesReleased = 0;
    connectionsOpened = connectionsClosed = clientOpens = clientCloses = structCalls = 0;
    abiMatches = YES;
}
CFMutableDictionaryRef XRGSMCMatching(const char *name) {
    if (throwPhase == 1) packetFailure();
    if (failPhase == 1) return NULL;
    abiMatches &= strcmp(name, "AppleSMC") == 0;
    matchingCreated++;
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
io_service_t XRGSMCGetService(mach_port_t port, CFDictionaryRef matching) {
    matchingConsumed++; CFRelease(matching);
    if (throwPhase == 2) packetFailure();
    if (failPhase == 2) return 0;
    abiMatches &= port == MACH_PORT_NULL; servicesAcquired++; return 41;
}
IOReturn XRGSMCOpen(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection) {
    abiMatches &= service == 41 && task == mach_task_self() && type == 1;
    if (failPhase == 7) { *connection = 0; return kIOReturnSuccess; }
    *connection = 83; connectionsOpened++;
    if (throwPhase == 3) packetFailure();
    return failPhase == 3 ? kIOReturnError : kIOReturnSuccess;
}
kern_return_t XRGSMCMethod(mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCount, const void *inputStruct, size_t inputSize, uint64_t *output, uint32_t *outputCount, void *outputStruct, size_t *outputSize) {
    abiMatches &= connection == 83 && inputCount == 0 && inputSize == 0;
    if (selector == 0) {
        if (throwPhase == 4) packetFailure();
        if (failPhase == 4) return kIOReturnError;
        clientOpens++;
    } else { clientCloses++; if (throwPhase == 6) packetFailure(); }
    return kIOReturnSuccess;
}
kern_return_t XRGSMCStructMethod(mach_port_t connection, uint32_t selector, const void *input, size_t inputSize, void *output, size_t *outputSize) {
    structCalls++; abiMatches &= connection == 83 && selector == 2 && inputSize == 80 && *outputSize == 80;
    if (throwPhase == 5) packetFailure();
    if (failPhase == 5) return kIOReturnError;
    const SMCParamStruct *request = input; SMCParamStruct *reply = output;
    memset(reply, 0, sizeof(*reply));
    if (request->data8 == 9) {
        reply->keyInfo.dataSize = request->key == 0x234b4559 ? 4 : 2;
        reply->keyInfo.dataType = request->key == 0x234b4559 ? 0x75693332 : 0x73703738;
    } else if (request->data8 == 5) {
        if (request->key == 0x234b4559) reply->bytes[3] = 1;
        else { abiMatches &= request->keyInfo.dataSize == 2 && request->keyInfo.dataType == 0x73703738; reply->bytes[0] = 50; }
    } else if (request->data8 == 8) reply->key = 0x54433050;
    else abiMatches = NO;
    *outputSize = failPhase == 6 ? 79 : 80;
    return kIOReturnSuccess;
}
IOReturn XRGSMCClose(io_connect_t connection) { connectionsClosed++; if (throwPhase == 7) packetFailure(); return kIOReturnSuccess; }
IOReturn XRGSMCRelease(io_object_t object) { servicesReleased++; if (throwPhase == 8) packetFailure(); return kIOReturnSuccess; }

@interface XRGThrowingPacket : NSData
@end
@implementation XRGThrowingPacket
- (NSUInteger)length { packetFailure(); return 0; }
- (const void *)bytes { return NULL; }
@end
@interface XRGSMCPacketTransportTests : XCTestCase
@end
@implementation XRGSMCPacketTransportTests
- (void)setUp { [super setUp]; failPhase = throwPhase = 0; resetCalls(); }
- (id<XRGSMCPacketTransport>)transport {
    Class<XRGSMCPacketTransportFactory> factory = NSClassFromString(@"XRGSMCPacketTransport");
    return [factory makeSMCPacketTransport];
}
- (NSData *)infoPacket {
    SMCParamStruct packet = {0}; packet.key = 0x54433050; packet.data8 = 9;
    return [NSData dataWithBytes:&packet length:sizeof(packet)];
}
- (void)assertBalanced {
    XCTAssertEqual(matchingCreated, matchingConsumed);
    XCTAssertEqual(servicesAcquired, servicesReleased);
    XCTAssertEqual(connectionsOpened, connectionsClosed);
    XCTAssertEqual(clientOpens, clientCloses);
    XCTAssertTrue(abiMatches);
}
- (void)testSwiftInterfaceAndLegacyFacadeUseTheRealCLayoutAndCacheMetadata {
    XRGSMCInterface *interface = [XRGSMCInterface openInterface]; XCTAssertNotNil(interface); resetCalls();
    NSError *error = [NSError errorWithDomain:@"stale" code:1 userInfo:nil];
    XCTAssertEqualObjects([interface readValue:0x54433050 error:&error], @50); XCTAssertNil(error);
    XCTAssertEqualObjects([interface readValue:0x54433050 error:&error], @50);
    XCTAssertEqual(structCalls, 3); [self assertBalanced];
    XRGTestSMCInterfaceFacade *legacy = [[XRGTestSMCInterfaceFacade alloc] init]; XCTAssertNotNil(legacy);
    XCTAssertEqual(legacy.keyCount, 1); XCTAssertEqual([legacy keyAtIndex:0], (uint32_t)0x54433050);
    XCTAssertEqualObjects([legacy readValue:0x54433050 error:&error], @50); XCTAssertNil(error);
    [self assertBalanced];
    failPhase = 2; XCTAssertNil([[XRGTestSMCInterfaceFacade alloc] init]); [self assertBalanced];
}
- (void)testNativeFailuresAndTruncatedRepliesCleanUpEveryAcquiredHandle {
    id<XRGSMCPacketTransport> transport = [self transport]; XCTAssertNotNil(transport);
    for (int phase = 1; phase <= 7; phase++) {
        resetCalls(); failPhase = phase; NSError *error = nil;
        XCTAssertNil([transport transactPacket:self.infoPacket error:&error]); XCTAssertNotNil(error);
        [self assertBalanced];
    }
    failPhase = 0;
    NSError *error = nil; XCTAssertNotNil([transport transactPacket:self.infoPacket error:&error]); XCTAssertNil(error); [self assertBalanced];
}
- (void)testNativeExceptionsDoNotCrossSwiftAndCleanupContinuesWhenCleanupThrows {
    id<XRGSMCPacketTransport> transport = [self transport]; XCTAssertNotNil(transport);
    for (int phase = 1; phase <= 8; phase++) {
        resetCalls(); throwPhase = phase; NSError *error = nil; NSData *reply = nil;
        XCTAssertNoThrow(reply = [transport transactPacket:self.infoPacket error:&error]);
        if (phase <= 5) { XCTAssertNil(reply); XCTAssertNotNil(error); }
        else { XCTAssertNotNil(reply); XCTAssertNil(error); }
        [self assertBalanced];
    }
}
- (void)testInvalidOrWritePacketsNeverReachIOKit {
    id<XRGSMCPacketTransport> transport = [self transport]; XCTAssertNotNil(transport);
    resetCalls(); NSError *error = nil;
    XCTAssertNil([transport transactPacket:[NSData data] error:&error]);
    SMCParamStruct packet = {0}; packet.key = 0x54433050; packet.data8 = 6;
    XCTAssertNil([transport transactPacket:[NSData dataWithBytes:&packet length:sizeof(packet)] error:&error]);
    packet.data8 = 5; packet.keyInfo.dataSize = 33;
    XCTAssertNil([transport transactPacket:[NSData dataWithBytes:&packet length:sizeof(packet)] error:&error]);
    XCTAssertNoThrow([transport transactPacket:[[XRGThrowingPacket alloc] init] error:&error]);
    XCTAssertEqual(matchingCreated, 0); XCTAssertEqual(structCalls, 0); XCTAssertNotNil(error);
}
@end
