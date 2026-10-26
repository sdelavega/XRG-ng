// Native facade and read-only IOKit boundary; modified 2026-10-26 by Stephen de la Vega.
/*
 * Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/* Modified version from IOPMLibPrivate.c - reduced to the SMC communication part. 
 Derived code follows in the bottom part
 
 */ 

#import "SMCInterface.h"
#import "SMCPacket.h"
#import <XRGCore/XRGCore-Swift.h>

#if defined(XRG_SENSOR_TEST_TRANSPORTS)
#define XRGSMCFacade XRGTestSMCInterfaceFacade
#else
#define XRGSMCFacade SMCInterface
#endif
@implementation XRGSMCFacade { XRGSMCInterface *_implementation; }
- (instancetype)init {
    if ((self = [super init])) {
        _implementation = [XRGSMCInterface openInterface];
        if (!_implementation) return nil;
    }
    return self;
}
- (id)readValue:(FourCharCode)key error:(NSError **)error { return [_implementation readValue:key error:error]; }
- (NSInteger)keyCount { return _implementation.keyCount; }
- (FourCharCode)keyAtIndex:(NSInteger)index { return [_implementation keyAtIndex:index]; }
@end

static void XRGSMCSetError(NSError **error, IOReturn status) {
    if (error) *error = [NSError errorWithDomain:NSMachErrorDomain code:status userInfo:nil];
}
static NSData *XRGSMCOperation(NSData *input, BOOL availabilityOnly, NSError **error) {
    if (error) *error = nil;
    SMCParamStruct request = {0}, output = {0};
    io_service_t service = IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    BOOL clientOpen = NO;
    @try {
    if (!availabilityOnly) {
        if (input.length != sizeof(request)) { XRGSMCSetError(error, kIOReturnBadArgument); return nil; }
        [input getBytes:&request length:sizeof(request)];
        if (!(request.data8 == 5 || request.data8 == 8 || request.data8 == 9) ||
            (request.data8 != 8 && request.key == 0) ||
            (request.data8 == 5 && (request.keyInfo.dataSize == 0 || request.keyInfo.dataSize > 32))) {
            XRGSMCSetError(error, kIOReturnBadArgument); return nil;
        }
    }
        CFMutableDictionaryRef matching = XRGSMCMatching("AppleSMC");
        if (!matching) { XRGSMCSetError(error, kIOReturnNotFound); return nil; }
        service = XRGSMCGetService(MACH_PORT_NULL, matching); // consumes matching
        if (!service) { XRGSMCSetError(error, kIOReturnNotFound); return nil; }
        IOReturn result = XRGSMCOpen(service, mach_task_self(), 1, &connection);
        if (result != kIOReturnSuccess || !connection) { XRGSMCSetError(error, result ?: kIOReturnNotFound); return nil; }
        result = XRGSMCMethod(connection, 0, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
        if (result != kIOReturnSuccess) { XRGSMCSetError(error, result); return nil; }
        clientOpen = YES;
        if (availabilityOnly) return [NSData data];
        size_t size = sizeof(output);
        result = XRGSMCStructMethod(connection, 2, &request, sizeof(request), &output, &size);
        if (result != kIOReturnSuccess) { XRGSMCSetError(error, result); return nil; }
        if (size != sizeof(output)) { XRGSMCSetError(error, kIOReturnUnderrun); return nil; }
        return [NSData dataWithBytes:&output length:size];
    } @catch (NSException *exception) { XRGSMCSetError(error, kIOReturnError); return nil; }
    @finally {
        if (connection) {
            if (clientOpen) { @try { XRGSMCMethod(connection, 1, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL); } @catch (NSException *exception) {} }
            @try { XRGSMCClose(connection); } @catch (NSException *exception) {}
        }
        if (service) { @try { XRGSMCRelease(service); } @catch (NSException *exception) {} }
    }
}
@interface XRGSMCPacketTransport : NSObject <XRGSMCPacketTransport, XRGSMCPacketTransportFactory>
@end
@implementation XRGSMCPacketTransport
+ (id<XRGSMCPacketTransport>)makeSMCPacketTransport {
    return XRGSMCOperation(nil, YES, NULL) ? [[self alloc] init] : nil;
}
- (NSData *)transactPacket:(NSData *)packet error:(NSError **)error { return XRGSMCOperation(packet, NO, error); }
@end
