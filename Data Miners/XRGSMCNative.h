// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#pragma once
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
// Test substitution of system calls; the application imports their SDK declarations.
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
kern_return_t XRGSMCOpen(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection);
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
