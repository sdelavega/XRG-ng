// Packet definitions retained from SMCInterface.m; modified 2026-10-26 by Stephen de la Vega.
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

#ifndef XRGSMCPacket_h
#define XRGSMCPacket_h
#include <stdint.h>
#include <stddef.h>
#include <IOKit/IOKitLib.h>
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;
_Static_assert(sizeof(SMCParamStruct) == 80, "SMC packet size");
_Static_assert(offsetof(SMCParamStruct, keyInfo) == 28, "SMC key info offset");
_Static_assert(offsetof(SMCParamStruct, result) == 40, "SMC result offset");
_Static_assert(offsetof(SMCParamStruct, data8) == 42, "SMC command offset");
_Static_assert(offsetof(SMCParamStruct, data32) == 44, "SMC index offset");
_Static_assert(offsetof(SMCParamStruct, bytes) == 48, "SMC payload offset");
#if defined(XRG_SENSOR_TEST_TRANSPORTS) && defined(__OBJC__)
#import <Foundation/Foundation.h>
// The test target compiles the same facade under another runtime name, retaining
// the older higher-level interface fixture used by the reader exception tests.
@interface XRGTestSMCInterfaceFacade : NSObject
- (id)readValue:(uint32_t)key error:(NSError **)error;
- (NSInteger)keyCount;
- (uint32_t)keyAtIndex:(NSInteger)index;
@end
#endif
#if defined(XRG_SENSOR_TEST_TRANSPORTS)
#define XRGSMCMatching XRGTestSMCMatching
#define XRGSMCGetService XRGTestSMCGetService
#define XRGSMCOpen XRGTestSMCOpen
#define XRGSMCMethod XRGTestSMCMethod
#define XRGSMCStructMethod XRGTestSMCStructMethod
#define XRGSMCClose XRGTestSMCClose
#define XRGSMCRelease XRGTestSMCRelease
CFMutableDictionaryRef XRGSMCMatching(const char *name);
io_service_t XRGSMCGetService(mach_port_t port, CFDictionaryRef matching);
IOReturn XRGSMCOpen(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection);
kern_return_t XRGSMCMethod(mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCount, const void *inputStruct, size_t inputSize, uint64_t *output, uint32_t *outputCount, void *outputStruct, size_t *outputSize);
kern_return_t XRGSMCStructMethod(mach_port_t connection, uint32_t selector, const void *input, size_t inputSize, void *output, size_t *outputSize);
IOReturn XRGSMCClose(io_connect_t connection);
IOReturn XRGSMCRelease(io_object_t object);
#else
#define XRGSMCMatching IOServiceMatching
#define XRGSMCGetService IOServiceGetMatchingService
#define XRGSMCOpen IOServiceOpen
#define XRGSMCMethod IOConnectCallMethod
#define XRGSMCStructMethod IOConnectCallStructMethod
#define XRGSMCClose IOServiceClose
#define XRGSMCRelease IOObjectRelease
#endif
#endif
