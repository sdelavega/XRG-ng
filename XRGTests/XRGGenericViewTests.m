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
#import "../Graph Views/XRGGenericView.h"

@interface XRGGenericViewTests : XCTestCase
@end
@implementation XRGGenericViewTests
- (void)testObjectiveCGraphSelectorsForwardToTheSwiftRenderer {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    @try {
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSColor.whiteColor set]; NSRectFill(NSMakeRect(0, 0, 32, 32));
        NSUInteger byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh;
        NSData *before = [NSData dataWithBytes:bitmap.bitmapData length:byteCount];
        XRGGenericView *view = [[XRGGenericView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
        XRGSettings *settings = [[XRGSettings alloc] init];
        settings.antiAliasing = NO;
        view.appSettings = settings;
        NSGraphicsContext.currentContext.shouldAntialias = YES;
        [view drawLeftText:@"CPU" centerText:nil rightText:nil inRect:view.bounds];
        XCTAssertFalse(NSGraphicsContext.currentContext.shouldAntialias);
        CGFloat missing[] = {NOVALUE, NOVALUE};
        [view drawRangedGraphWithData:missing size:2 currentIndex:1 upperBound:100 lowerBound:0 inRect:view.bounds flipped:NO filled:NO color:NSColor.redColor];
        [view drawGraphWithData:NULL size:0 currentIndex:-1 maxValue:100 inRect:view.bounds flipped:NO color:NSColor.redColor];
        XCTAssertEqualObjects(before, [NSData dataWithBytes:bitmap.bitmapData length:byteCount]);
        XRGDataSet *data = [[XRGDataSet alloc] init];
        [data resize:3]; [data setAllValues:50];
        [view drawGraphWithDataFromDataSet:data maxValue:100 inRect:view.bounds flipped:NO filled:YES color:NSColor.redColor];
        XCTAssertNotEqualObjects(before, [NSData dataWithBytes:bitmap.bitmapData length:byteCount]);
    } @finally {
        [NSGraphicsContext restoreGraphicsState];
    }
}

- (void)testObjectiveCLabelSelectorsKeepAccessibilityAndAvoidDuplicateSubviews {
    XRGSettings *settings = [[XRGSettings alloc] init];
    XRGGenericView *view = [[XRGGenericView alloc] initWithFrame:NSMakeRect(0, 0, 160, 10)];
    view.appSettings = settings;
    [view awakeFromNib]; [view awakeFromNib];
    XCTAssertEqual(view.subviews.count, 3);
    NSString *reading = @"CPU\n10 cores\nUptime 2d";
    [view drawLeftText:reading centerText:nil rightText:@"12%" inRect:view.paddedTextRect];
    XCTAssertEqualObjects(view.leftLabel.stringValue, @"CPU");
    XCTAssertEqualObjects(view.leftLabel.accessibilityValue, reading);
    XCTAssertFalse(view.centerLabel.isAccessibilityElement);
    XCTAssertNil([view.leftLabel hitTest:NSZeroPoint]);
    [view drawColumnText:reading rightText:nil inRect:view.paddedTextRect];
    XCTAssertEqual(view.rightLabel.frame.size.width, 0);
    XCTAssertEqual(view.leftLabel.frame.size.width, view.paddedTextRect.size.width);
    XCTAssertEqualObjects(view.leftLabel.accessibilityValue, reading);
}
@end
