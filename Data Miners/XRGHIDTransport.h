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

#ifndef XRGHIDTransport_h
#define XRGHIDTransport_h
#import <Foundation/Foundation.h>
#import "APSL/IOHIDEventTypes.h"
#import "APSL/AppleHIDUsageTables.h"
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#include <TargetConditionals.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
#if defined(XRG_SENSOR_TEST_TRANSPORTS)
#define XRGHIDCreateClient XRGTestHIDCreateClient
#define XRGHIDSetMatching XRGTestHIDSetMatching
#define XRGHIDCopyServices XRGTestHIDCopyServices
#define XRGHIDCopyProduct XRGTestHIDCopyProduct
#define XRGHIDCopyEvent XRGTestHIDCopyEvent
#define XRGHIDGetFloat XRGTestHIDGetFloat
#define XRGHIDServiceTypeID XRGTestHIDServiceTypeID
CFArrayRef XRGHIDCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef XRGHIDCopyProduct(IOHIDServiceClientRef service, CFStringRef key);
CFTypeID XRGHIDServiceTypeID(void);
#else
#define XRGHIDCreateClient IOHIDEventSystemClientCreate
#define XRGHIDSetMatching IOHIDEventSystemClientSetMatching
#define XRGHIDCopyServices IOHIDEventSystemClientCopyServices
#define XRGHIDCopyProduct IOHIDServiceClientCopyProperty
#define XRGHIDCopyEvent IOHIDServiceClientCopyEvent
#define XRGHIDGetFloat IOHIDEventGetFloatValue
#define XRGHIDServiceTypeID IOHIDServiceClientGetTypeID
#endif
IOHIDEventSystemClientRef XRGHIDCreateClient(CFAllocatorRef allocator);
int XRGHIDSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef XRGHIDCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
IOHIDFloat XRGHIDGetFloat(IOHIDEventRef event, int32_t field);
#endif
