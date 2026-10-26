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
#import "../Resources/XRGAITokensNotifications.h"
#import "../Graph Views/XRGAITokensNotifications.h"

@interface XRGAITokensNotificationBridgeTests : XCTestCase
@end

@implementation XRGAITokensNotificationBridgeTests
- (void)testLegacyHeadersDeliverSwiftNamesToExistingObservers {
    NSNotificationCenter *center = [[NSNotificationCenter alloc] init];
    NSObject *sender = [[NSObject alloc] init];
    NSArray<NSString *> *expected = @[@"XRGAITokensDidResetSession", @"XRGAITokensDidResetDaily", @"XRGAITokensBudgetThresholdReached"];
    NSArray<NSString *> *names = @[XRGAITokensDidResetSessionNotification, XRGAITokensDidResetDailyNotification, XRGAITokensBudgetThresholdReachedNotification];
    NSMutableArray *tokens = [NSMutableArray array];
    NSMutableArray<NSString *> *received = [NSMutableArray array];
    for (NSString *name in expected) {
        id token = [center addObserverForName:name object:sender queue:nil usingBlock:^(NSNotification *note) {
            XCTAssertEqual(note.object, sender);
            XCTAssertEqualObjects(note.userInfo[@"progress"], @0.8);
            [received addObject:note.name];
        }];
        [tokens addObject:token];
    }
    for (NSString *name in names) {
        [center postNotificationName:name object:sender userInfo:@{@"progress": @0.8}];
    }
    for (id token in tokens) [center removeObserver:token];
    XCTAssertEqualObjects(received, expected);
}
@end
