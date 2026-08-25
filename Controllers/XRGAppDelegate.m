/* 
 * XRG (X Resource Graph):  A system resource grapher for Mac OS X.
 * Copyright (C) 2002-2022 Gaucho Software, LLC.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 */

//
//  XRGAppDelegate.m
//

#import "XRGAppDelegate.h"
#import "XRGGraphWindow.h"

@implementation XRGAppDelegate

- (IBAction) showPrefs:(id)sender {
    if (!self.prefController) {
        [NSBundle.mainBundle loadNibNamed:@"Preferences" owner:self topLevelObjects:nil];
    }
	
	// Refresh the temperature settings to pick up any new sensors.
    [self.prefController setUpTemperaturePanel];
    [[self.prefController window] makeKeyAndOrderFront:sender];
}

- (void) showPrefsWithPanel:(NSString *)panelName {
    if (!self.prefController) {
        [NSBundle.mainBundle loadNibNamed:@"Preferences" owner:self topLevelObjects:nil];
    }

	// Refresh the temperature settings to pick up any new sensors.
    [self.prefController setUpTemperaturePanel];
    [[self.prefController window] makeKeyAndOrderFront:self];
    
    if ([panelName isEqualTo:@"CPU"])              [self.prefController CPU:self];
    else if ([panelName isEqualTo:@"RAM"])         [self.prefController RAM:self];
    else if ([panelName isEqualTo:@"Temperature"]) [self.prefController Temperature:self];
    else if ([panelName isEqualTo:@"Network"])     [self.prefController Network:self];
    else if ([panelName isEqualTo:@"Disk"])        [self.prefController Disk:self];
    else if ([panelName isEqualTo:@"Weather"])     [self.prefController Weather:self];
    else if ([panelName isEqualTo:@"Stocks"])      [self.prefController Stocks:self];
    else if ([panelName isEqualTo:@"General"])     [self.prefController General:self];
    else if ([panelName isEqualTo:@"Appearance"])  [self.prefController Colors:self];
}

- (IBAction)openSensorWindow:(id)sender {
    if (!self.sensorViewController) {
        [NSBundle.mainBundle loadNibNamed:@"Sensors" owner:self topLevelObjects:nil];
    }

    [self.sensorWindow setLevel:NSNormalWindowLevel];
    [self.sensorWindow makeKeyAndOrderFront:self];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:XRG_showSensorWindow];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.sensorWindow) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:XRG_showSensorWindow];
    }

    return YES;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)changeFont:(nullable id)sender {
    if (!sender) return;
    
    NSFont *oldFont = [[self.xrgGraphWindow appSettings] graphFont];
    NSFont *newFont = [sender convertFont:oldFont];
    if (oldFont == newFont || !newFont) return;
    
    [[self.xrgGraphWindow appSettings] setGraphFont:newFont];
    [[self.xrgGraphWindow moduleManager] graphFontChanged];
}
#pragma clang diagnostic pop

// Cleanup when the application exits caused by a restart or logout
- (void)NSWorkSpaceWillPowerOffNotification:(NSNotification *)aNotification {
    [self.xrgGraphWindow cleanupBeforeExiting];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[self.xrgGraphWindow.moduleManager windowChangedToSize:self.xrgGraphWindow.frame.size];

	// Initialize AI Token view programmatically
	[self.xrgGraphWindow initializeAITokenView];

	if ([[NSUserDefaults standardUserDefaults] boolForKey:XRG_windowIsMinimized]) {
		// Restore the persisted expanded frame FIRST, so minimizeWindow captures
		// real dimensions as the restore rect. Without this, a launch in the
		// minimized state captures the autosaved collapsed frame and the window
		// can never expand again (the 21px-strip trap).
		// "Expanded" means larger than the collapsed strip itself, not larger
		// than an arbitrary 300px: small windows are legitimate and must survive.
		CGFloat collapsedLimit = (2 * [self.xrgGraphWindow borderWidth]) + [self.xrgGraphWindow.appSettings textRectHeight] + 1;
		NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:XRG_unminimizedFrame];
		if (savedFrame != nil) {
			NSRect saved = NSRectFromString(savedFrame);
			if (saved.size.height > collapsedLimit && saved.size.width > collapsedLimit) {
				NSRect f = self.xrgGraphWindow.frame;
				f.size = saved.size;
				[self.xrgGraphWindow setFrame:f display:NO];
			}
		}
		// minimize the window.
		[self.xrgGraphWindow.backgroundView minimizeWindow];
		[self.xrgGraphWindow.backgroundView setClickedMinimized:YES];
	}

    if ([[NSUserDefaults standardUserDefaults] boolForKey:XRG_showSensorWindow]) {
        [self openSensorWindow:self];
    }

    // This is an ugly hack, but we were running into an issue where the menubar wouldn't be selectable at launch until switching to another app and back to XRG (issue exists as of macOS 10.15).  This will perform that programmatically, and switches to the Dock so the user doesn't notice any UI changes.
    [[[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"] firstObject] activateWithOptions:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
    });
}

// Cleanup when the application is quit by the user.
- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self.xrgGraphWindow cleanupBeforeExiting];
}

- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename {
    if ([filename length] == 0) return NO;
    
	NSData *themeData = [NSData dataWithContentsOfFile:filename];
	
	if ([themeData length] == 0) {
		NSAlert *alert1 = [[NSAlert alloc] init];
		alert1.alertStyle = NSAlertStyleInformational;
		alert1.messageText = @"Error";
		alert1.informativeText = @"The theme file dragged is not a valid theme file.";
		[alert1 addButtonWithTitle:@"OK"];
		[alert1 runModal];
	}
	
	NSError *error = nil;
	NSPropertyListFormat format;
	id plist = [NSPropertyListSerialization propertyListWithData:themeData
															   options:NSPropertyListImmutable
															    format:&format
															     error:&error];
	NSDictionary *themeDictionary = ([plist isKindOfClass:[NSDictionary class]] ? (NSDictionary *)plist : nil);
	
	if (!themeDictionary) {
		NSAlert *alert2 = [[NSAlert alloc] init];
		alert2.alertStyle = NSAlertStyleInformational;
		alert2.messageText = @"Error";
		alert2.informativeText = @"The theme file dragged is not a valid theme file.";
		[alert2 addButtonWithTitle:@"OK"];
		[alert2 runModal];
		if (error) {
			NSLog(@"Error reading theme plist: %@", error);
		}
	}
	else {
		[self.xrgGraphWindow.appSettings readXTFDictionary:themeDictionary];
		[self.xrgGraphWindow display];
	}

	[self.prefController setUpColorPanel];

	return YES;
}

- (XRGSettings *)appSettings {
    return [self.xrgGraphWindow appSettings];
}

- (XRGModuleManager *)moduleManager {
    return [self.xrgGraphWindow moduleManager];
}

@end

