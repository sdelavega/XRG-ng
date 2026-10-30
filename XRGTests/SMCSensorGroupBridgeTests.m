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
@interface SMCSensorGroupBridgeTests : XCTestCase
@end
@implementation SMCSensorGroupBridgeTests
- (void)testExistingSMCCallerConstructsTheSwiftGroupAndSeesItsNames {
    SMCSensorGroup *group = [[SMCSensorGroup alloc] initWithPattern:@"Tp0?" usingAvailableSensors:[NSSet setWithArray:@[@"Tp00", @"Tp01", @"Tp0y", @"Tp0z"]] description:@"CPU"];
    XCTAssertEqualObjects(group.sensorKeyOrder, (@[@"Tp01", @"Tp0z"]));
    XCTAssertEqualObjects(group.sensorKeyDescriptions, (@{@"Tp01": @"CPU 1", @"Tp0z": @"CPU 2"}));
    XCTAssertNil([[SMCSensorGroup alloc] initWithPattern:@"Tp0?" usingAvailableSensors:[NSSet set] description:@"CPU"]);
    SMCSensorSeries *series = [[SMCSensorSeries alloc] initWithStartingCharacter:@"0"];
    [series addCharacter:@"1"]; XCTAssertEqual(series.concurrentValues, 2);
}
@end
