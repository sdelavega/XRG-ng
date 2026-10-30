// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#import "XRGSMCNative.h"
#import <XRGCore/XRGCore-Swift.h>

// Own a persistent channel. This boundary is Objective-C solely to contain
// native exceptions; the driver protocol/decoding belongs to the Swift reader.
@interface XRGSMCPacketTransport : NSObject <XRGSMCPacketTransport, XRGSMCPacketTransportFactory> {
    io_connect_t _handle;
    BOOL _started;
}
- (BOOL)connect;
- (void)disconnect;
@end
@implementation XRGSMCPacketTransport
+ (id<XRGSMCPacketTransport>)makeSMCPacketTransport {
    XRGSMCPacketTransport *channel = [[self alloc] init];
    return [channel connect] ? channel : nil;
}
- (BOOL)connect {
    [self disconnect];
    io_service_t service = 0;
    @try {
        CFMutableDictionaryRef match = XRGSMCMatching("AppleSMC");
        if (!match) return NO;
        service = XRGSMCGetService(kIOMainPortDefault, match);
        if (!service || XRGSMCOpen(service, mach_task_self(), 1, &_handle) != KERN_SUCCESS || !_handle) return NO;
        if (XRGSMCMethod(_handle, 0, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL) != KERN_SUCCESS) return NO;
        _started = YES;
        return YES;
    } @catch (NSException *exception) { return NO; }
    @finally { if (service) { @try { XRGSMCRelease(service); } @catch (NSException *exception) {} } }
}
- (void)disconnect {
    if (_handle) {
        if (_started) { @try { XRGSMCMethod(_handle, 1, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL); } @catch (NSException *exception) {} }
        @try { XRGSMCClose(_handle); } @catch (NSException *exception) {}
    }
    _started = NO; _handle = 0;
}
- (void)dealloc { [self disconnect]; }
- (NSData *)transactPacket:(NSData *)packet error:(NSError **)error {
    if (error) *error = nil;
    IOReturn status = kIOReturnBadArgument;
    @synchronized(self) {
        @try {
            if (packet.length == 80) {
                uint8_t request[80]; [packet getBytes:request length:80];
                uint32_t key = 0, width = 0;
                memcpy(&key, request, 4); memcpy(&width, request + 28, 4);
                key = CFSwapInt32LittleToHost(key); width = CFSwapInt32LittleToHost(width);
                BOOL read = request[42] == 5 && key && width && width <= 32;
                BOOL info = request[42] == 9 && key;
                BOOL enumerate = request[42] == 8;
                if ((read || info || enumerate) && (_started || [self connect])) {
                    uint8_t response[80] = {0}; size_t size = sizeof(response);
                    status = XRGSMCStructMethod(_handle, 2, request, sizeof(request), response, &size);
                    if (status == KERN_SUCCESS && size == sizeof(response)) return [NSData dataWithBytes:response length:size];
                    if (status == KERN_SUCCESS) status = kIOReturnUnderrun;
                    if (status == kIOReturnNoDevice || status == kIOReturnNotOpen) [self disconnect];
                }
            }
        } @catch (NSException *exception) { status = kIOReturnError; }
    }
    if (error) *error = [NSError errorWithDomain:NSMachErrorDomain code:status userInfo:nil];
    return nil;
}
@end
