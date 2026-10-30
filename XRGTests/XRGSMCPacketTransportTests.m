// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#import <XCTest/XCTest.h>
#import <XRGCore/XRGCore-Swift.h>
#define XRG_SENSOR_TEST_TRANSPORTS 1
#import "../Data Miners/XRGSMCNative.h"
static int failStage,throwStage,opened,closed,started,stopped,released,calls;
static void fault(int stage) {if(throwStage==stage) @throw [NSException exceptionWithName:@"fixture" reason:@"native failure" userInfo:nil];}
CFMutableDictionaryRef XRGSMCMatching(const char *name) {fault(1);return failStage==1 ? NULL : CFDictionaryCreateMutable(NULL,0,NULL,NULL);}
io_service_t XRGSMCGetService(mach_port_t port,CFDictionaryRef match) {CFRelease(match);fault(2);return failStage==2 ? 0 : 7;}
kern_return_t XRGSMCOpen(io_service_t service,task_port_t task,uint32_t type,io_connect_t *connection) {
    fault(3);if(failStage==3)return kIOReturnError;*connection=9;opened++;return KERN_SUCCESS;
}
kern_return_t XRGSMCMethod(mach_port_t c,uint32_t selector,const uint64_t *a,uint32_t b,const void *d,size_t e,uint64_t *f,uint32_t *g,void *h,size_t *i) {
    if(selector==0){fault(4);if(failStage==4)return kIOReturnError;started++;}else{stopped++;fault(6);}return KERN_SUCCESS;
}
kern_return_t XRGSMCStructMethod(mach_port_t c,uint32_t selector,const void *input,size_t size,void *output,size_t *outSize) {
    calls++;fault(5);if(failStage==5)return kIOReturnError;if(failStage==9)return kIOReturnNoDevice;
    const uint8_t *request=input;uint8_t *reply=output;memset(reply,0,80);
    if(request[42]==9){reply[28]=2;uint32_t type=CFSwapInt32HostToLittle(0x73703738);memcpy(reply+32,&type,4);}
    else if(request[42]==5){reply[48]=25;reply[49]=128;}
    if(failStage==7)*outSize=79;
    return KERN_SUCCESS;
}
IOReturn XRGSMCClose(io_connect_t c) {closed++;fault(7);return KERN_SUCCESS;}
IOReturn XRGSMCRelease(io_object_t c) {released++;fault(8);return KERN_SUCCESS;}
@interface XRGSMCPacketTransportTests:XCTestCase @end
@implementation XRGSMCPacketTransportTests
- (void)setUp {[super setUp];failStage=throwStage=opened=closed=started=stopped=released=calls=0;}
- (id<XRGSMCPacketTransport>)channel {return [(Class<XRGSMCPacketTransportFactory>)NSClassFromString(@"XRGSMCPacketTransport") makeSMCPacketTransport];}
- (NSData *)message:(uint8_t)command {NSMutableData *data=[NSMutableData dataWithLength:80];uint8_t *p=data.mutableBytes;p[0]=1;p[28]=2;p[42]=command;return data;}
- (void)testOneConnectionIsOwnedForItsLifetimeAndClosesAfterTheLastRead {
    @autoreleasepool {
        id<XRGSMCPacketTransport> c=[self channel];XCTAssertNotNil(c);XCTAssertEqual(opened,1);XCTAssertEqual(released,1);
        for(int i=0;i<3;i++){NSError *error=nil;XCTAssertNotNil([c transactPacket:[self message:9] error:&error]);XCTAssertNil(error);}
        XCTAssertEqual(calls,3);XCTAssertEqual(opened,1);XCTAssertEqual(closed,0);
    }
    XCTAssertEqual(closed,1);XCTAssertEqual(started,stopped);
}
- (void)testSwiftReaderUsesTheNativeChannelAndContainsNativeExceptions {
    @autoreleasepool {
        XRGSMCReader *reader=[XRGSMCReader openReader];XCTAssertNotNil(reader);
        XCTAssertEqualObjects([reader readValueForKey:0x54433050],@25.5);
        XCTAssertEqualObjects([reader readValueForKey:0x54433050],@25.5);XCTAssertEqual(calls,3);
        throwStage=5;
        XCTAssertNoThrow([reader readValueForKey:0x54433050]);
        XCTAssertNil([reader readValueForKey:0x54433050]);
        throwStage=0;XCTAssertEqualObjects([reader readValueForKey:0x54433050],@25.5);
    }
    XCTAssertEqual(opened,closed);XCTAssertEqual(started,stopped);
}
- (void)testOpenFailuresAndExceptionsReleaseAcquiredResources {
    for(int mode=0;mode<2;mode++)for(int stage=1;stage<=4;stage++){
        failStage=mode==0?stage:0;throwStage=mode==1?stage:0;
        int oldOpen=opened,oldClose=closed;
        @autoreleasepool {XCTAssertNil([self channel]);}
        XCTAssertEqual(opened-oldOpen,closed-oldClose);
    }
}
- (void)testWriteCommandsAndInvalidSizesNeverEnterTheDriver {
    id<XRGSMCPacketTransport> c=[self channel];NSError *error=nil;
    for(int command=0;command<16;command++)if(command!=5&&command!=8&&command!=9){
        XCTAssertNil([c transactPacket:[self message:command] error:&error]);XCTAssertNotNil(error);
    }
    XCTAssertNil([c transactPacket:[NSData data] error:&error]);XCTAssertEqual(calls,0);
    NSMutableData *invalid=[[self message:5] mutableCopy];((uint8_t *)invalid.mutableBytes)[28]=33;
    XCTAssertNil([c transactPacket:invalid error:&error]);XCTAssertEqual(calls,0);
}
- (void)testReadFailuresAndNativeExceptionsNeverPublishAPartialPacket {
    id<XRGSMCPacketTransport> c=[self channel];NSError *error=nil;
    failStage=5;XCTAssertNil([c transactPacket:[self message:9] error:&error]);XCTAssertNotNil(error);
    failStage=7;XCTAssertNil([c transactPacket:[self message:9] error:&error]);XCTAssertEqual(error.code,kIOReturnUnderrun);
    failStage=0;throwStage=5;XCTAssertNoThrow([c transactPacket:[self message:9] error:&error]);XCTAssertNotNil(error);
    throwStage=0;XCTAssertNotNil([c transactPacket:[self message:9] error:&error]);XCTAssertNil(error);
}
- (void)testDisconnectedDevicesCanReopenOnTheNextRead {
    id<XRGSMCPacketTransport> c=[self channel];NSError *error=nil;
    failStage=9;XCTAssertNil([c transactPacket:[self message:9] error:&error]);XCTAssertEqual(opened,closed);
    failStage=0;XCTAssertNotNil([c transactPacket:[self message:9] error:&error]);XCTAssertNil(error);XCTAssertEqual(opened,2);
}
- (void)testCleanupContinuesIfClosingTheClientThrows {
    @autoreleasepool {id<XRGSMCPacketTransport> c=[self channel];XCTAssertNotNil(c);throwStage=6;}
    XCTAssertEqual(closed,1);XCTAssertEqual(stopped,1);
}
@end
