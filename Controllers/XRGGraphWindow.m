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
//  XRGGraphWindow.m
//

#import "XRGGraphWindow.h"
#import "definitions.h"
#import <stdio.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

// sleep/wake notifications
bool systemJustWokeUp;
io_object_t powerConnection;
void sleepNotification(void *refcon, io_service_t service, natural_t messageType, void *messageArgument);

@implementation XRGGraphWindow

///// Initialization Methods /////

+ (void)initialize {
    // first set up the defaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:[self getDefaultPrefs]];
}

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)aStyle backing:(NSBackingStoreType)bufferingType defer:(BOOL)flag {
	if (self = [super initWithContentRect:contentRect styleMask:aStyle backing:bufferingType defer:flag]) {
		// Initialize the settings class
		self.appSettings = [[XRGSettings alloc] init];
		
		// Initialize the module manager class
		self.moduleManager = [[XRGModuleManager alloc] initWithWindow:self];
		
		// Initialize the font manager
		self.fontManager = [NSFontManager sharedFontManager];
		
		// Initialize other status variables.
		systemJustWokeUp = NO;
		self.xrgCheckURL = nil;
		
		// Get the User Defaults object
		NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];    
		
		// Set variables from the user defaults
		[self setupSettingsFromDictionary:[defs dictionaryRepresentation]];

		// register for sleep/wake notifications
		CFRunLoopSourceRef rls;
		IONotificationPortRef thePortRef;
		io_object_t notifier;
        
        [self setMovable:NO];

		powerConnection = IORegisterForSystemPower(NULL, &thePortRef, sleepNotification, &notifier );

		if (powerConnection == 0) NSLog(@"Failed to register for sleep/wake events.");

		rls = IONotificationPortGetRunLoopSource(thePortRef);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
		
		if ([self.appSettings checkForUpdates]) {
			[self checkServerForUpdates];
		}
	}
	
	return self;
}

+ (NSMutableDictionary *) getDefaultPrefs {
    NSMutableDictionary *appDefs = [NSMutableDictionary dictionary];
    BOOL useMetricUnits = NO;
    if( @available( macOS 10.12, * )  ) {
        NSLocale *locale = [NSLocale currentLocale];
        useMetricUnits = locale.usesMetricSystem;
    }
    NSNumber *defaultUnitIndex = useMetricUnits ? @(1) : @(0);
    
    appDefs[XRG_backgroundTransparency] = @"0.9";
    appDefs[XRG_graphBGTransparency]    = @"0.9";
    appDefs[XRG_graphFG1Transparency]   = @"1.0";
    appDefs[XRG_graphFG2Transparency]   = @"1.0";
    appDefs[XRG_graphFG3Transparency]   = @"1.0";
    appDefs[XRG_borderTransparency]     = @"0.4";
    appDefs[XRG_textTransparency]       = @"1.0";
    
    // Cyberpunk theme - neon on dark
    NSColor *c = [NSColor colorWithDeviceRed: 0.05 green: 0.02 blue: 0.08 alpha: 0.95];
    appDefs[XRG_backgroundColor] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    c = [NSColor colorWithDeviceRed: 0.08 green: 0.04 blue: 0.12 alpha: 0.9];
    appDefs[XRG_graphBGColor] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    // Hot pink/magenta for primary data series
    c = [NSColor colorWithDeviceRed: 1.0 green: 0.0 blue: 0.6 alpha: 1.0];
    appDefs[XRG_graphFG1Color] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    // Electric cyan for secondary data series
    c = [NSColor colorWithDeviceRed: 0.0 green: 1.0 blue: 1.0 alpha: 1.0];
    appDefs[XRG_graphFG2Color] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    // Toxic green for tertiary data series
    c = [NSColor colorWithDeviceRed: 0.2 green: 1.0 blue: 0.2 alpha: 1.0];
    appDefs[XRG_graphFG3Color] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    c = [NSColor colorWithDeviceRed: 0.5 green: 0.0 blue: 0.5 alpha: 0.5];
    appDefs[XRG_borderColor] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];

    // Neon cyan text
    c = [NSColor colorWithDeviceRed: 0.6 green: 1.0 blue: 1.0 alpha: 1.0];
    appDefs[XRG_textColor] = [NSKeyedArchiver archivedDataWithRootObject:[c copy] requiringSecureCoding:NO error:nil];
    
    appDefs[XRG_graphFont] = [NSKeyedArchiver archivedDataWithRootObject:[NSFont systemFontOfSize:10.0] requiringSecureCoding:NO error:nil];
                
    appDefs[XRG_windowWidth] = @"140";
    appDefs[XRG_windowHeight] = @"700";
	
	NSScreen *mainScreen = [NSScreen mainScreen];
	NSRect screenFrame = [mainScreen frame];
	appDefs[XRG_windowOriginX] = [NSNumber numberWithInt:screenFrame.origin.x + (0.5 * screenFrame.size.width) - 70];
    appDefs[XRG_windowOriginY] = [NSNumber numberWithInt:screenFrame.origin.y + screenFrame.size.height - 50 - 700];
    
    appDefs[XRG_borderWidth] = @"4";
    appDefs[XRG_graphOrientationVertical] = @"YES";
    appDefs[XRG_antiAliasing] = @"YES";
    appDefs[XRG_graphRefresh] = @"1.0";
    appDefs[XRG_showCPUGraph] = @"YES";
    appDefs[XRG_showMemoryGraph] = @"YES";
    appDefs[XRG_showBatteryGraph] = @"YES";
    appDefs[XRG_showTemperatureGraph] = @"YES";
    appDefs[XRG_showNetworkGraph] = @"YES";
    appDefs[XRG_showDiskGraph] = @"YES";
    appDefs[XRG_showWeatherGraph] = @"YES";
    appDefs[XRG_showStockGraph] = @"YES";
	appDefs[XRG_showGPUGraph] = @"YES";
    appDefs[XRG_showAITokenGraph] = @"YES";
    appDefs[XRG_windowLevel] = @"0";
    appDefs[XRG_stickyWindow] = @"YES";
    appDefs[XRG_checkForUpdates] = @"YES";
    appDefs[XRG_dropShadow] = @"NO";
    appDefs[XRG_autoExpandGraph] = @"YES";
    appDefs[XRG_foregroundWhenExpanding] = @"NO";
    appDefs[XRG_showSummary] = @"YES";
    appDefs[XRG_minimizeUpDown] = @"";
    appDefs[XRG_isDockIconHidden] = @"NO";
    
    appDefs[XRG_showCPUBars] = @"YES";
    appDefs[XRG_separateCPUColor] = @"YES";
    appDefs[XRG_showCPUTemperature] = @"NO";
    appDefs[XRG_cpuTemperatureUnits] = defaultUnitIndex;
    appDefs[XRG_showLoadAverage] = @"YES";
    appDefs[XRG_cpuShowAverageUsage] = @"YES";
    appDefs[XRG_cpuShowUptime] = @"YES";
    
    appDefs[XRG_showMemoryPagingGraph] = @"YES";
    appDefs[XRG_memoryShowWired] = @"YES";
    appDefs[XRG_memoryShowActive] = @"YES";
    appDefs[XRG_memoryShowInactive] = @"YES";
    appDefs[XRG_memoryShowFree] = @"YES";
    appDefs[XRG_memoryShowCache] = @"YES";
    appDefs[XRG_memoryShowPage] = @"YES";
    
    appDefs[XRG_tempUnits] = defaultUnitIndex;
    appDefs[XRG_tempFG1Location] = @"0";
    appDefs[XRG_tempFG2Location] = @"1";
    appDefs[XRG_tempFG3Location] = @"2";

    appDefs[XRG_netMinGraphScale] = @"1024";
    appDefs[XRG_netGraphMode] = @"0";
    appDefs[XRG_showTotalBandwidthSinceBoot] = @"YES";
    appDefs[XRG_showTotalBandwidthSinceLoad] = @"YES";
    appDefs[XRG_networkInterface] = @"All";

    appDefs[XRG_diskGraphMode] = @"0";

    appDefs[XRG_ICAO] = @"KMOP";
    appDefs[XRG_secondaryWeatherGraph] = @"1";
    appDefs[XRG_temperatureUnits] = defaultUnitIndex;
    appDefs[XRG_distanceUnits] = defaultUnitIndex;
    appDefs[XRG_pressureUnits] = defaultUnitIndex;
    
    appDefs[XRG_stockSymbols] = @"AAPL";
    appDefs[XRG_stockGraphTimeFrame] = @"3";
    appDefs[XRG_stockShowChange] = @"YES";
    appDefs[XRG_showDJIA] = @"YES";

    // AI Token defaults are registered in XRGAIPrefController

    return appDefs;
}

- (void) setupSettingsFromDictionary:(NSDictionary *) defs {
    [self             setBorderWidth:             [defs[XRG_borderWidth] intValue]];
    [self.appSettings setAntiAliasing:            [defs[XRG_antiAliasing] boolValue]];
    [self.appSettings setGraphRefresh:            [defs[XRG_graphRefresh] floatValue]];
    [self.appSettings setStickyWindow:            [defs[XRG_stickyWindow] boolValue]];
    [self.appSettings setWindowLevel:             [defs[XRG_windowLevel] intValue]];
    [self.appSettings setCheckForUpdates:         [defs[XRG_checkForUpdates] boolValue]];
    [self.appSettings setDropShadow:              [defs[XRG_dropShadow] boolValue]];
    [self.appSettings setWindowTitle:             defs[XRG_windowTitle]];
    [self.appSettings setAutoExpandGraph:         [defs[XRG_autoExpandGraph] boolValue]];
    [self.appSettings setForegroundWhenExpanding: [defs[XRG_foregroundWhenExpanding] boolValue]];
    [self.appSettings setShowSummary:             [defs[XRG_showSummary] boolValue]];
    [self.appSettings setMinimizeUpDown:          [defs[XRG_minimizeUpDown] intValue]];
    [self.appSettings setIsDockIconHidden:        [defs[XRG_isDockIconHidden] boolValue]];

    [self.appSettings setBackgroundColor:        [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_backgroundColor] error:nil]];
    [self.appSettings setGraphBGColor:           [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_graphBGColor] error:nil]];
    [self.appSettings setGraphFG1Color:          [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_graphFG1Color] error:nil]];
    [self.appSettings setGraphFG2Color:          [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_graphFG2Color] error:nil]];
    [self.appSettings setGraphFG3Color:          [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_graphFG3Color] error:nil]];
    [self.appSettings setBorderColor:            [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_borderColor] error:nil]];
    [self.appSettings setTextColor:              [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:defs[XRG_textColor] error:nil]];
    [self.appSettings setGraphFont:              [NSKeyedUnarchiver unarchivedObjectOfClass:[NSFont class] fromData:defs[XRG_graphFont] error:nil]];
    [self.appSettings setBackgroundTransparency: [defs[XRG_backgroundTransparency] floatValue]];
    [self.appSettings setGraphBGTransparency:    [defs[XRG_graphBGTransparency] floatValue]];
    [self.appSettings setGraphFG1Transparency:   [defs[XRG_graphFG1Transparency] floatValue]];
    [self.appSettings setGraphFG2Transparency:   [defs[XRG_graphFG2Transparency] floatValue]];
    [self.appSettings setGraphFG3Transparency:   [defs[XRG_graphFG3Transparency] floatValue]];
    [self.appSettings setBorderTransparency:     [defs[XRG_borderTransparency] floatValue]];
    [self.appSettings setTextTransparency:       [defs[XRG_textTransparency] floatValue]];

    [self.appSettings setFastCPUUsage:           [defs[XRG_showCPUBars] boolValue]];
    [self.appSettings setSeparateCPUColor:       [defs[XRG_separateCPUColor] boolValue]];
    [self.appSettings setShowCPUTemperature:     [defs[XRG_showCPUTemperature] boolValue]];
    [self.appSettings setCpuTemperatureUnits:    [defs[XRG_cpuTemperatureUnits] intValue]];
    [self.appSettings setShowLoadAverage:        [defs[XRG_showLoadAverage] boolValue]];
    [self.appSettings setCpuShowAverageUsage:    [defs[XRG_cpuShowAverageUsage] boolValue]];
    [self.appSettings setCpuShowUptime:          [defs[XRG_cpuShowUptime] boolValue]];

    [self.appSettings setICAO:                   defs[XRG_ICAO]];
    [self.appSettings setSecondaryWeatherGraph:  [defs[XRG_secondaryWeatherGraph] intValue]];
    [self.appSettings setTemperatureUnits:       [defs[XRG_temperatureUnits] intValue]];
    [self.appSettings setDistanceUnits:          [defs[XRG_distanceUnits] intValue]];
    [self.appSettings setPressureUnits:          [defs[XRG_pressureUnits] intValue]];

    [self.appSettings setShowMemoryPagingGraph:  [defs[XRG_showMemoryPagingGraph] boolValue]];
    [self.appSettings setMemoryShowWired:        [defs[XRG_memoryShowWired] boolValue]];
    [self.appSettings setMemoryShowActive:       [defs[XRG_memoryShowActive] boolValue]];
    [self.appSettings setMemoryShowInactive:     [defs[XRG_memoryShowInactive] boolValue]];
    [self.appSettings setMemoryShowFree:         [defs[XRG_memoryShowFree] boolValue]];
    [self.appSettings setMemoryShowCache:        [defs[XRG_memoryShowCache] boolValue]];
    [self.appSettings setMemoryShowPage:         [defs[XRG_memoryShowPage] boolValue]];
    
    [self.appSettings setTempUnits:              [defs[XRG_tempUnits] intValue]];
    [self.appSettings setTempFG1Location:        defs[XRG_tempFG1Location]];
    [self.appSettings setTempFG2Location:        defs[XRG_tempFG2Location]];
    [self.appSettings setTempFG3Location:        defs[XRG_tempFG3Location]];

    [self.appSettings setNetMinGraphScale:            [defs[XRG_netMinGraphScale] intValue]];
    [self.appSettings setNetGraphMode:                [defs[XRG_netGraphMode] intValue]];
    [self.appSettings setShowTotalBandwidthSinceBoot: [defs[XRG_showTotalBandwidthSinceBoot] boolValue]];
    [self.appSettings setShowTotalBandwidthSinceLoad: [defs[XRG_showTotalBandwidthSinceLoad] boolValue]];
    [self.appSettings setNetworkInterface:            defs[XRG_networkInterface]];

    [self.appSettings setDiskGraphMode:          [defs[XRG_diskGraphMode] intValue]];

    [self.appSettings setStockSymbols:           defs[XRG_stockSymbols]];
    [self.appSettings setStockGraphTimeFrame:    [defs[XRG_stockGraphTimeFrame] intValue]];
    [self.appSettings setStockShowChange:        [defs[XRG_stockShowChange] boolValue]];
    [self.appSettings setShowDJIA:               [defs[XRG_showDJIA] boolValue]];
            
    //Set the background color to clear
    [self setBackgroundColor:[NSColor clearColor]];

    //set the transparency close to one.
    [self setAlphaValue:0.99];

    //turn off opaqueness
    [self setOpaque:NO];

    [self setHasShadow:self.appSettings.dropShadow];
    
    // Set these after we have initialized the parentWindow
    [self setMinSize:[self.moduleManager getMinSize]];
    [self.moduleManager windowChangedToSize:self.frame.size];
    [self setWindowLevelHelper: [defs[XRG_windowLevel] intValue]];    
        
    [self.moduleManager setGraphOrientationVertical: [defs[XRG_graphOrientationVertical] boolValue]];
    [self setMinSize:[self.moduleManager getMinSize]];
}

void sleepNotification(void *refcon, io_service_t service, natural_t messageType, void *messageArgument) {
     switch(messageType) {
        case kIOMessageSystemWillSleep: 
            IOAllowPowerChange(powerConnection, (long) messageArgument);
            break;
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(powerConnection, (long) messageArgument);
            break;
        case kIOMessageSystemHasPoweredOn:
            systemJustWokeUp = YES;
            break;
     }
} 

- (bool)systemJustWokeUp {
    return systemJustWokeUp;
}

- (void)setSystemJustWokeUp:(bool)yesNo {
    systemJustWokeUp = yesNo;
}

// This fork's update channel. The upstream endpoint (download.gauchosoft.com)
// answers for mikepj/XRG: the day upstream ships a newer version, every fork
// user would be told to download upstream over this fork's features. Same
// text protocol (a bare version string), served from the fork's own tree so
// a release is "bump latest_version.txt on main".
#define XRG_UPDATE_CHECK_URL @"https://raw.githubusercontent.com/marc-shade/XRG/main/latest_version.txt"
#define XRG_UPDATE_INFO_URL  @"https://github.com/marc-shade/XRG/releases"

- (void)checkServerForUpdates {
    self.xrgCheckURL = [[XRGURL alloc] init];
    [self.xrgCheckURL setURLString:XRG_UPDATE_CHECK_URL];
    [self.xrgCheckURL loadURLInBackground];
}

- (void)checkServerForUpdatesPostProcess {
    if (self.xrgCheckURL == nil) return;
    
    if ([self.xrgCheckURL didErrorOccur]) {
        self.xrgCheckURL = nil;
    }
    
    if ([self.xrgCheckURL isDataReady]) {
		NSString *myVersion = (NSString *)CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("CFBundleVersion"));
		NSString *s = [[NSString alloc] initWithData:[self.xrgCheckURL getData] encoding:NSASCIIStringEncoding];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		
		if ([self isVersion:s laterThanVersion:myVersion]) {
			NSString *mesg = [NSString stringWithFormat:@"XRG %@ is now available.  You are currently running XRG %@.  If you would like visit the XRG website to upgrade, click More Info.", s, myVersion];
			
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Alert"];
            [alert setInformativeText:mesg];
            [alert addButtonWithTitle:@"More Info"];
            [alert addButtonWithTitle:@"Disable Checking"];
            [alert addButtonWithTitle:@"Not Yet"];
            [alert setAlertStyle:NSAlertStyleInformational];
            
            NSModalResponse response = [alert runModal];
            
            if (response == NSAlertFirstButtonReturn) {
                // More Info
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:XRG_UPDATE_INFO_URL]];
            }
            else if (response == NSAlertSecondButtonReturn) {
                // Disable Checking
                [self.appSettings setCheckForUpdates:NO];
                // save it to the user defaults
                NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                [defs setObject: @"NO"  forKey:XRG_checkForUpdates];
                [defs synchronize];
            }
            // NSAlertThirdButtonReturn - Not Yet - don't do anything
        }
        
        self.xrgCheckURL = nil;
    }
}

- (bool)isVersion:(NSString *)latestVersion laterThanVersion:(NSString *)currentVersion {
	if ([latestVersion isEqualToString:currentVersion]) {
		return NO;
	}
	else {
		//NSLog(@"Current Version: %@   Latest Version: %@", currentVersion, latestVersion);
		NSArray *latestComponents = [latestVersion componentsSeparatedByString:@"."];
		NSArray *currentComponents = [currentVersion componentsSeparatedByString:@"."];
		
		NSInteger numLatestComponents = [latestComponents count];
		NSInteger numCurrentComponents = [currentComponents count];
		NSInteger numIterationsToDo = 0;
		
		if (numLatestComponents > numCurrentComponents) numIterationsToDo = numCurrentComponents;
		else numIterationsToDo = numLatestComponents;
		
		if (!numIterationsToDo) return NO;
		
		NSInteger i;
		for (i = 0; i < numIterationsToDo; i++) {
			NSUInteger latestBLocation = [latestComponents[i] rangeOfString:@"b"].location;
			NSUInteger currentBLocation = [currentComponents[i] rangeOfString:@"b"].location;

			int latestNumber = 0;
			int currentNumber = 0;
			int latestBetaNumber = 999999;
			int currentBetaNumber = 999999;
			
			if (latestBLocation != NSNotFound) {
				NSArray *tmpArray = [latestComponents[i] componentsSeparatedByString:@"b"];
				
				if ([tmpArray count] >= 2) {
					latestNumber = [tmpArray[0] intValue];
					latestBetaNumber = [tmpArray[1] intValue];
				}
				else if ([tmpArray count] == 1) {
					latestNumber = [tmpArray[0] intValue];
				}
				else {
					latestNumber = 0;
				}
			}
			else {
				latestNumber = [latestComponents[i] intValue];
			}
			
			if (currentBLocation != NSNotFound) {
				NSArray *tmpArray = [currentComponents[i] componentsSeparatedByString:@"b"];
				
				if ([tmpArray count] >= 2) {
					currentNumber = [tmpArray[0] intValue];
					currentBetaNumber = [tmpArray[1] intValue];
				}
				else if ([tmpArray count] == 1) {
					currentNumber = [tmpArray[0] intValue];
				}
				else {
					currentNumber = 0;
				}
			}
			else {
				currentNumber = [currentComponents[i] intValue];
			}
			
			// Error checking
			if (latestNumber == INT_MAX | latestNumber == INT_MIN) latestNumber = 0;
			if (currentNumber == INT_MAX | currentNumber == INT_MIN) currentNumber = 0;
			if (latestBetaNumber == INT_MAX | latestBetaNumber == INT_MIN) latestBetaNumber = 0;
			if (currentBetaNumber == INT_MAX | currentBetaNumber == INT_MIN) currentBetaNumber = 0;
			
			// Finally do the comparison for this revision.
			if (latestNumber > currentNumber) {
				//NSLog(@"New Version Available %d > %d (%d, %d | %d, %d)", latestNumber, currentNumber, latestNumber, latestBetaNumber, currentNumber, currentBetaNumber);
				return YES;
			}
			else if (currentNumber > latestNumber) {
				//NSLog(@"Current %d < %d (%d, %d | %d, %d)", latestNumber, currentNumber, latestNumber, latestBetaNumber, currentNumber, currentBetaNumber);
				return NO;
			}
			else if (latestNumber == currentNumber && latestBetaNumber > currentBetaNumber) {
				//NSLog(@"New Version Available %d > %d (%d, %d | %d, %d)", latestBetaNumber, currentBetaNumber, latestNumber, latestBetaNumber, currentNumber, currentBetaNumber);
				return YES;
			}
			else if (latestNumber == currentNumber && latestBetaNumber < currentBetaNumber) {
				//NSLog(@"Current %d < %d (%d, %d | %d, %d)", latestBetaNumber, currentBetaNumber, latestNumber, latestBetaNumber, currentNumber, currentBetaNumber);
				return NO;
			}
			
			// If we get here, then we need to move on to the next sub-version.
			//NSLog(@"Passed (%d, %d | %d, %d)", latestNumber, latestBetaNumber, currentNumber, currentBetaNumber);
		}
		
		if (numLatestComponents > numCurrentComponents) {
			return YES;
		}
		else {
			return NO;
		}
	}
}
///// End of Initialization Methods /////


///// Timer Methods /////

- (void)initializeAITokenView {
    if (!self.aiTokenView) {
        // Create the AI Token view programmatically
        NSRect viewFrame = NSMakeRect(0, 0, 200, 100);
        self.aiTokenView = [[XRGAITokenView alloc] initWithFrame:viewFrame];

        // Add to content view
        [[self contentView] addSubview:self.aiTokenView];

        // Manually trigger the initialization that would normally happen in awakeFromNib
        [self.aiTokenView awakeFromNib];

        // Force layout recalculation after adding the AI Token module
        // This ensures the module is positioned correctly on initial load
        [self.moduleManager windowChangedToSize:self.frame.size];
    }
}

- (void)initTimers {
    if (!self.min30Timer) {
        self.min30Timer = [NSTimer scheduledTimerWithTimeInterval:1800.0
														   target:self
														 selector:@selector(min30Update:)
														 userInfo:nil
														  repeats:YES];
    }
    if (!self.min5Timer) {
        self.min5Timer = [NSTimer scheduledTimerWithTimeInterval:300.0
														  target:self
														selector:@selector(min5Update:)
														userInfo:nil
														 repeats:YES];
    }
    if (!self.graphTimer) {
        self.graphTimer = [NSTimer scheduledTimerWithTimeInterval:self.appSettings.graphRefresh
														   target:self
														 selector:@selector(graphUpdate:)
														 userInfo:nil
														  repeats:YES];
    }
    if (!self.fastTimer) {
		self.fastTimer = [NSTimer scheduledTimerWithTimeInterval:0.125
														  target:self
														selector:@selector(fastUpdate:)
														userInfo:nil
														 repeats:YES];
    }
}

- (void)min30Update:(NSTimer *)aTimer {
    [self.moduleManager min30Update];
}

- (void)min5Update:(NSTimer *)aTimer {
    [self.moduleManager min5Update];
}

- (void)graphUpdate:(NSTimer *)aTimer {
    [self.moduleManager graphUpdate];
    [self checkServerForUpdatesPostProcess];
}

- (void)fastUpdate:(NSTimer *)aTimer {
    [self.moduleManager fastUpdate];
}

///// End of Timer Methods /////


///// Methods that set up module references /////
- (void)setBackgroundView:(id)background {
    [background setFrameSize:self.frame.size];
    [background setAutoresizesSubviews:YES];
    [background setNeedsDisplay:YES];
	_backgroundView = background;
}
///// End of methods that set up module references /////


///// Action Methods /////

- (IBAction)setShowCPUGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"CPU" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowGPUGraph:(id)sender {
	[self.backgroundView expandWindow];
	[self.moduleManager setModule:@"GPU" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
	[self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowMemoryGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Memory" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowBatteryGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Battery" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowTemperatureGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Temperature" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowAITokenGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"AI Tokens" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowNetGraph:(id)sender {    
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Network" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
   [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowDiskGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Disk" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowWeatherGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Weather" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setShowStockGraph:(id)sender {
    [self.backgroundView expandWindow];
    [self.moduleManager setModule:@"Stock" isDisplayed:([sender state] == NSControlStateValueOn)];
	[self setMinSize:[self.moduleManager getMinSize]];
	[self checkWindowSize];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setWindowTitle:(id)sender {
    [self.appSettings setWindowTitle:[sender stringValue]];
    [self.backgroundView setNeedsDisplay:YES];
}

- (IBAction)setBorderWidthAction:(id)sender {
    [self.backgroundView expandWindow];
    [self setBorderWidth: [sender intValue]];
    [self setMinSize:[self.moduleManager getMinSize]];
    [self.moduleManager windowChangedToSize:[self frame].size];
}

- (IBAction)setGraphOrientation:(id)sender {
    bool wasMinimized = [self minimized];
    if (wasMinimized) {
        [self.backgroundView expandWindow];
    }

    bool graphCurrentlyVertical = [self.moduleManager graphOrientationVertical];
	[self.moduleManager setGraphOrientationVertical:([sender indexOfSelectedItem] == 0)];	// 0 = vertical, 1 = horizontal
    
    if (graphCurrentlyVertical != [self.moduleManager graphOrientationVertical]) {        
        NSRect tmpRect = NSMakeRect(self.frame.origin.x, self.frame.origin.y + self.frame.size.height - self.frame.size.width, self.frame.size.height, self.frame.size.width);
        [self setMinSize:[self.moduleManager getMinSize]];
		[self setFrame:tmpRect display:YES animate:YES];
	}
    
    // minimize view again if it was originally.
    if (wasMinimized) {
        [self.backgroundView minimizeWindow];
    }
    
    // We need to save this parameter right away.
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	[defs setObject:([sender indexOfSelectedItem] == 0) ? @"YES" : @"NO" forKey:XRG_graphOrientationVertical];    
    [defs synchronize];
}

- (IBAction)setAntiAliasing:(id)sender {
	[self.appSettings setAntiAliasing:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setGraphRefreshActionPart2:(id)sender {
    float f = [sender floatValue];
	f = roundf(f * 5.) * 0.2;
    [self.appSettings setGraphRefresh:f];
    
    [self.graphTimer invalidate];
    self.graphTimer = [NSTimer scheduledTimerWithTimeInterval:f
													   target:self
													 selector:@selector(graphUpdate:)
													 userInfo:nil
													  repeats:YES];
}

- (IBAction)setWindowLevel:(id)sender {
    NSInteger index = [sender indexOfSelectedItem] - 1;

    [self setWindowLevelHelper: index];

    [self.appSettings setWindowLevel: index];
}


- (IBAction)setStickyWindow:(id)sender {
    [self.appSettings setStickyWindow:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setCheckForUpdates:(id)sender {
    [self.appSettings setCheckForUpdates:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setDropShadow:(id)sender {
    [self.parentWindow setHasShadow:([sender state] == NSControlStateValueOn)];
    [self.appSettings setDropShadow:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setAutoExpandGraph:(id)sender {
    [self.appSettings setAutoExpandGraph:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setForegroundWhenExpanding:(id)sender {
    [self.appSettings setForegroundWhenExpanding:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setShowSummary:(id)sender {
    [self.appSettings setShowSummary:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setMinimizeUpDown:(id)sender {
    [self.appSettings setMinimizeUpDown:[sender indexOfSelectedItem]];
}

- (IBAction)setShowTotalBandwidthSinceBoot:(id)sender {
    [self.appSettings setShowTotalBandwidthSinceBoot:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setShowTotalBandwidthSinceLoad:(id)sender {
    [self.appSettings setShowTotalBandwidthSinceLoad:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setObjectsToColor:(id)sender {
    switch ([sender tag]) {
        case 21: [self.appSettings setBackgroundColor: [sender color]]; break;
        case 22: [self.appSettings setGraphBGColor:    [sender color]]; break;
        case 23: [self.appSettings setGraphFG1Color:   [sender color]]; break;
        case 24: [self.appSettings setGraphFG2Color:   [sender color]]; break;
        case 25: [self.appSettings setGraphFG3Color:   [sender color]]; break;
        case 26: [self.appSettings setBorderColor:     [sender color]]; break;
        case 27: [self.appSettings setTextColor:       [sender color]]; break;
    }
	[[self contentView] setNeedsDisplay:YES];
}

- (void)setObjectsToTransparency:(id) sender {
    switch([sender tag]) {
        case 21: [self.appSettings setBackgroundTransparency: [sender floatValue]]; break;
        case 22: [self.appSettings setGraphBGTransparency:    [sender floatValue]]; break;
        case 23: [self.appSettings setGraphFG1Transparency:   [sender floatValue]]; break;
        case 24: [self.appSettings setGraphFG2Transparency:   [sender floatValue]]; break;
        case 25: [self.appSettings setGraphFG3Transparency:   [sender floatValue]]; break;
        case 26: [self.appSettings setBorderTransparency:     [sender floatValue]]; break;
        case 27: [self.appSettings setTextTransparency:       [sender floatValue]]; break;
    }

    for (NSView *subview in self.contentView.subviews) {
        [subview setNeedsDisplay:YES];
    }
}

- (IBAction)setGraphStyle:(id)sender {
    NSInteger selectedIndex = [sender indexOfSelectedItem];
    [self.appSettings setGraphStyle:selectedIndex];

    // Redraw all graph views to apply the new style
    for (NSView *subview in self.contentView.subviews) {
        [subview setNeedsDisplay:YES];
    }
}

- (IBAction)setFastCPUUsageCheckbox:(id)sender {
	[self.appSettings setFastCPUUsage:([sender state] == NSControlStateValueOn)];
        
    [self.cpuView setWidth:[[self.moduleManager getModuleByName:@"CPU"] currentSize].width];
    [self.cpuView setNeedsDisplay:YES];
}

- (IBAction)setSeparateCPUColor:(id)sender {
	[self.appSettings setSeparateCPUColor:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setShowCPUTemperature:(id)sender {
	[self.appSettings setShowCPUTemperature:([sender state] == NSControlStateValueOn)];
}

- (IBAction)setCPUTemperatureUnits:(id)sender {
    [self.appSettings setCpuTemperatureUnits:[sender indexOfSelectedItem]];
}

- (IBAction)setShowLoadAverage:(id)sender {
    [self.appSettings setShowLoadAverage:([sender state] == NSControlStateValueOn)];

    [self.cpuView graphUpdate:nil];
}

- (IBAction)setCPUShowAverageUsage:(id)sender {
    [self.appSettings setCpuShowAverageUsage:([sender state] == NSControlStateValueOn)];

    [self.cpuView graphUpdate:nil];
}

- (IBAction)setCPUShowUptime:(id)sender {
    [self.appSettings setCpuShowUptime:([sender state] == NSControlStateValueOn)];

    [self.cpuView graphUpdate:nil];
}

- (IBAction)setMemoryCheckbox:(id)sender {
    switch ([sender tag]) {
        case 42:
            [self.appSettings setMemoryShowWired:([sender state] == NSControlStateValueOn)];
            break;
        case 43:
            [self.appSettings setMemoryShowActive:([sender state] == NSControlStateValueOn)];
            break;
        case 44:
            [self.appSettings setMemoryShowInactive:([sender state] == NSControlStateValueOn)];
            break;
        case 45:
            [self.appSettings setMemoryShowFree:([sender state] == NSControlStateValueOn)];
            break;
        case 46:
            [self.appSettings setMemoryShowCache:([sender state] == NSControlStateValueOn)];
            break;
        case 47:
            [self.appSettings setMemoryShowPage:([sender state] == NSControlStateValueOn)];
            break;
        case 48:
            [self.appSettings setShowMemoryPagingGraph:([sender state] == NSControlStateValueOn)];
            break;
    }
    
    [self.memoryView setNeedsDisplay:YES];
}

- (IBAction)setTempUnits:(id)sender {
    [self.appSettings setTempUnits: [sender indexOfSelectedItem]];
    [self.temperatureView setNeedsDisplay:YES];
}

- (IBAction)setTempFG1Location:(NSMenuItem *)sender {
    [self.appSettings setTempFG1Location:sender.representedObject];
    [self.temperatureView setNeedsDisplay:YES];
}

- (IBAction)setTempFG2Location:(NSMenuItem *)sender {
    [self.appSettings setTempFG2Location:sender.representedObject];
    [self.temperatureView setNeedsDisplay:YES];
}

- (IBAction)setTempFG3Location:(NSMenuItem *)sender {
    [self.appSettings setTempFG3Location:sender.representedObject];
    [self.temperatureView setNeedsDisplay:YES];
}

- (IBAction)setNetGraphMode:(id)sender {
    [self.appSettings setNetGraphMode:[sender selectedRow]];
    [self.netView setNeedsDisplay:YES];
}

- (IBAction)setNetworkInterface:(id)sender {
    NSInteger selectedRow = [sender indexOfSelectedItem];
    if (selectedRow == 0) {
        [self.appSettings setNetworkInterface:@"All"];
    }
    else {
        NSArray *interfaces = [self.netView.miner networkInterfaces];
        if (selectedRow - 1 < [interfaces count])
            [self.appSettings setNetworkInterface:interfaces[(selectedRow - 1)]];
        else
            [self.appSettings setNetworkInterface:@"All"];
    }
}

- (IBAction)setDiskGraphMode:(id)sender {
    [self.appSettings setDiskGraphMode:[sender selectedRow]];
    [self.diskView setNeedsDisplay:YES];
}

- (IBAction)setICAO:(id)sender {
    [self.appSettings setICAO:[sender stringValue]];

    [self.weatherView setURL: [self.appSettings ICAO]];
    [self.weatherView min30Update:nil];
}

- (IBAction)setSecondaryWeatherGraph:(id)sender {
    [self.appSettings setSecondaryWeatherGraph: [sender indexOfSelectedItem]];
    [self.weatherView setNeedsDisplay:YES];
}

- (IBAction)setTemperatureUnits:(id)sender {
    [self.appSettings setTemperatureUnits: [sender indexOfSelectedItem]];
    [self.weatherView setNeedsDisplay:YES];
}

- (IBAction)setDistanceUnits:(id)sender {
    [self.appSettings setDistanceUnits: [sender indexOfSelectedItem]];
    [self.weatherView setNeedsDisplay:YES];
}

- (IBAction)setPressureUnits:(id)sender {
    [self.appSettings setPressureUnits: [sender indexOfSelectedItem]];
    [self.weatherView setNeedsDisplay:YES];
}

- (IBAction)setStockSymbols:(id)sender {
    [self.appSettings setStockSymbols:[sender stringValue]];
    
    [self.stockView setStockSymbolsFromString:[sender stringValue]];
}

- (IBAction)setStockGraphTimeFrame:(id)sender {
    [self.appSettings setStockGraphTimeFrame:[sender indexOfSelectedItem]];
    [self.stockView setNeedsDisplay:YES];
}

- (IBAction)setStockShowChange:(id)sender {
    [self.appSettings setStockShowChange:([sender state] == NSControlStateValueOn)];
    [self.stockView setNeedsDisplay:YES];
}

- (IBAction)setShowDJIA:(id)sender {
    [self.appSettings setShowDJIA:([sender state] == NSControlStateValueOn)];
    [self.stockView setNeedsDisplay:YES];
}


///// End of Action Methods /////


///// Action Helpers /////

- (void)setWindowLevelHelper:(NSInteger)index
{
    if (index == 0)
    {
        [self setLevel:NSNormalWindowLevel];
    }
    else if (index == 1)
    {
        [self setLevel:NSFloatingWindowLevel];
    }
    else {
        [self setLevel:kCGBackstopMenuLevel];
    }
}

- (NSColor *)colorForTag:(NSInteger)aTag {
    switch (aTag) {
        case 21:  return [self.appSettings backgroundColor];
        case 22:  return [self.appSettings graphBGColor];
        case 23:  return [self.appSettings graphFG1Color];
        case 24:  return [self.appSettings graphFG2Color];
        case 25:  return [self.appSettings graphFG3Color];
        case 26:  return [self.appSettings borderColor];
        case 27:  return [self.appSettings textColor];
    }
    
    return nil;
}

- (float)transparencyForTag:(NSInteger)aTag {
    switch (aTag) {
        case 21: return [self.appSettings backgroundTransparency];
        case 22: return [self.appSettings graphBGTransparency];
        case 23: return [self.appSettings graphFG1Transparency];
        case 24: return [self.appSettings graphFG2Transparency];
        case 25: return [self.appSettings graphFG3Transparency];
        case 26: return [self.appSettings borderTransparency];
        case 27: return [self.appSettings textTransparency];
    }
    
    return 1.0;
}

- (void)checkWindowSize {
    NSSize smallSizeLimit = [self.moduleManager getMinSize];
	NSRect newFrame = self.frame;
    if (newFrame.size.width < smallSizeLimit.width || newFrame.size.height < smallSizeLimit.height) {
        [self setMinSize:[self.moduleManager getMinSize]];
		newFrame.size.width = MAX(newFrame.size.width, smallSizeLimit.width);
		newFrame.size.height = MAX(newFrame.size.height, smallSizeLimit.height);
		[self setFrame:newFrame display:YES animate:YES];
        [self.moduleManager windowChangedToSize:self.frame.size];
    }
}

///// End of Action Helpers /////


///// Event Handlers /////

// Custom windows that use the NSBorderlessWindowMask can't become key by default.
- (BOOL) canBecomeKeyWindow {
    return YES;
}

- (void)performClose:(id)sender {
    if([[self delegate] windowShouldClose: self])
        [self close];
}

- (void)performMiniaturize:(id)sender {
    [self miniaturize: nil];
}

- (void)windowDidResize:(NSNotification *)aNotification {
    if (self.moduleManager)
        [self.moduleManager windowChangedToSize:[self frame].size];
}

- (void)cleanupBeforeExiting {
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	BOOL wasMinimized = [defs boolForKey:XRG_windowIsMinimized];
	[self.backgroundView expandWindow];
	[defs setBool:wasMinimized forKey:XRG_windowIsMinimized];
    [defs synchronize];
}


- (void)mouseDown:(NSEvent *)theEvent {
    // This is to fix a bug in Cocoa where if the mouse is double-clicked causing 
    // a window move/resize, and double clicked again, the content view does not 
    // get the mouseDown.  In the content view, there is a check so the code doesn't 
    // start looping (the content view mouseDown calls [self mouseDown])
    [self.backgroundView mouseDownAction:theEvent];
    [super mouseDown:theEvent];
}

- (BOOL)isMovableByWindowBackground {
	return YES;
}

- (void)sendEvent:(NSEvent *)theEvent {
    NSEventType type = [theEvent type];
    NSRect theEventLocationInWindowRect = NSZeroRect;
    theEventLocationInWindowRect.origin = [theEvent locationInWindow];
    
    switch (type) {
        case NSEventTypeLeftMouseDown:
        {
            // Check if the locationInWindow is around the window border.
            if (NSPointInRect([theEvent locationInWindow], NSInsetRect(self.contentView.bounds, self.borderWidth, self.borderWidth))) {
                self.draggingWindow = YES;
                self.dragStart = [self convertRectToScreen:theEventLocationInWindowRect].origin;
                self.originAtDragStart = [self frame].origin;
            }
            break;
        }

        case NSEventTypeLeftMouseDragged:
        {
            if (self.draggingWindow) {
                NSPoint dragLoc = [self convertRectToScreen:theEventLocationInWindowRect].origin;
                NSPoint newOrigin = self.originAtDragStart;
                newOrigin.x += dragLoc.x - self.dragStart.x;
                newOrigin.y += dragLoc.y - self.dragStart.y;
                
                // Snap.
                newOrigin = [self snap:newOrigin];
                
                [self setFrameOrigin:newOrigin];
            }
            break;
        }
            
        case NSEventTypeLeftMouseUp:
        {
            if (self.draggingWindow) {
                self.draggingWindow = NO;
            }
            break;
        }
            
        default:
            break;
    }
    
    [super sendEvent:theEvent];
}

// sticky window code
- (NSPoint)snap:(NSPoint)p {
    if (![self.appSettings stickyWindow]) return p;

    NSRect newRect = NSMakeRect(p.x, p.y, self.contentView.bounds.size.width, self.contentView.bounds.size.height);
    NSPoint rectCenter = NSMakePoint(NSMidX(newRect), NSMidY(newRect));
    
    NSScreen *screen = [self screen];
    for (NSScreen *s in [NSScreen screens]) {
        // Figure out which screen the new center would be on.
        if (NSPointInRect(rectCenter, [s frame])) {
            screen = s;
        }
    }
    if (!screen) return p;
    
    CGFloat snapThreshold = 20;
    
    NSRect screenFrame = screen.frame;
    
    BOOL snappedToTopOrBottom = NO;
    BOOL snappedToLeftOrRight = NO;
    
    // top
    if (screenFrame.origin.y + screenFrame.size.height - newRect.origin.y - newRect.size.height <= snapThreshold) {
        newRect.origin.y = screenFrame.origin.y + (screenFrame.size.height - newRect.size.height);
        snappedToTopOrBottom = YES;
    }
    
    // left
    if (newRect.origin.x - screenFrame.origin.x <= snapThreshold) {
        newRect.origin.x = screenFrame.origin.x;
        snappedToLeftOrRight = YES;
    }
    
    // bottom
    if (newRect.origin.y - screenFrame.origin.y <= snapThreshold) {
        newRect.origin.y = screenFrame.origin.y;
        snappedToTopOrBottom = YES;
    }
    
    // right
    if (screenFrame.origin.x + screenFrame.size.width - newRect.origin.x - newRect.size.width <= snapThreshold) {
        newRect.origin.x = screenFrame.origin.x + (screenFrame.size.width - newRect.size.width);
        snappedToLeftOrRight = YES;
    }

    // Middle top/bottom
    if (snappedToTopOrBottom) {
        if (fabs(NSMidX(newRect) - NSMidX(screenFrame)) <= snapThreshold) {
            newRect.origin.x = NSMidX(screenFrame) - 0.5 * newRect.size.width;
        }
    }
    
    if (snappedToLeftOrRight) {
        if (fabs(NSMidY(newRect) - NSMidY(screenFrame)) <= snapThreshold) {
            newRect.origin.y = NSMidY(screenFrame) - 0.5 * newRect.size.height;
        }
    }
    
    return newRect.origin;
}

///// End of Event Handlers /////

@end
