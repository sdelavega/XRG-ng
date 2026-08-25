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
//  XRGBackgroundView.m
//

#import "XRGBackgroundView.h"
#import "XRGGraphWindow.h"
#import "XRGGenericView.h"
#import "XRGAppDelegate.h"
#import "XRGPrefController.h"
#import <sys/sysctl.h>

@implementation XRGBackgroundView

- (void)awakeFromNib {
    [super awakeFromNib];
    
    parentWindow = (XRGGraphWindow *)[self window]; 
    
    appSettings = [parentWindow appSettings];
    moduleManager = [parentWindow moduleManager];
    
	self.hostname = @"XRG";
	[self getHostname];
	
    // Find out whether or not the App's UI is being displayed.
    uiIsHidden = [[NSUserDefaults standardUserDefaults] boolForKey:XRG_isDockIconHidden];
    if (!uiIsHidden) {
        [self showUI:nil];
    }
    
    isVertical = YES;
    inInner = inOuter = inHeader = NO;
    self.clickedMinimized = NO;
    lastWidth = [self frame].size.width;
    
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    
    [parentWindow setBackgroundView: self];
}

- (void)setFrame:(NSRect)frame {
	[super setFrame:frame];
	[parentWindow.moduleManager windowChangedToSize:self.frame.size];
}

- (void)offsetDrawingOrigin:(NSSize)offset {
    [self translateOriginToPoint: NSMakePoint(offset.width, offset.height)];
}

- (NSBezierPath *)outerPath {
    int borderWidth = [parentWindow borderWidth];

    return [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:borderWidth yRadius:borderWidth];
}

- (NSBezierPath *)innerPath {
    int borderWidth = [parentWindow borderWidth];
    NSRect tmpRect = [self bounds];
    tmpRect.origin.x += borderWidth;
    tmpRect.origin.y = tmpRect.size.height - borderWidth - [appSettings textRectHeight];
    tmpRect.size.width -= borderWidth * 2;
    tmpRect.size.height = [appSettings textRectHeight];

    return [NSBezierPath bezierPathWithRoundedRect:tmpRect xRadius:borderWidth yRadius:borderWidth];
}

- (void)drawRect:(NSRect)rect{
    // Rotate the coordinate system if necessary
    if (![moduleManager graphOrientationVertical] && isVertical) {
        // first update our size:
        NSRect f = [parentWindow frame];
        f.origin = [self frame].origin;
        [self setFrame:f];
        // switch from vertical to horizontal
        [self setBoundsRotation: 90];
        [self translateOriginToPoint: NSMakePoint(0, 0 - [self frame].size.width)];
        isVertical = NO;
        lastWidth = [self frame].size.width;
    }
    if ([moduleManager graphOrientationVertical] && !isVertical) {
        // first update our size:
        NSRect f = [parentWindow frame];
        f.origin = [self frame].origin;
        [self setFrame:f];
        // switch from horizontal to vertical
        [self translateOriginToPoint: NSMakePoint(0, lastWidth)];
        [self setBoundsRotation: 0];
        [self setAutoresizesSubviews:YES];
        isVertical = YES;
    }
    
    if (!isVertical) {
        if (lastWidth != [self frame].size.width) {
            [self translateOriginToPoint:NSMakePoint(0, 0 - ([self frame].size.width - lastWidth))];
            lastWidth = [self frame].size.width;
        }
    }
	
    NSGraphicsContext *gc = [NSGraphicsContext currentContext]; 
    
    // Draw the border
    [[appSettings borderColor] set];
    NSBezierPath *borderPath = [self outerPath];
    
    NSBezierPath *excludePath = [NSBezierPath bezierPath];
    for (XRGModule *module in parentWindow.moduleManager.displayList) {
        NSRect graphRect = module.reference.frame;
        graphRect = [self convertRect:module.reference.bounds fromView:module.reference];
        [excludePath appendBezierPath:[NSBezierPath bezierPathWithRect:graphRect]];
    }

    [borderPath appendBezierPath:[excludePath bezierPathByReversingPath]];
    [borderPath fill];

    // Draw the title background
    [[appSettings backgroundColor] set];
    [[self innerPath] fill];
    
    // Draw the title
    int borderWidth = [parentWindow borderWidth];
    NSRect titleRect = NSMakeRect(borderWidth,
                                  [self bounds].size.height - borderWidth - [appSettings textRectHeight],
                                  [self bounds].size.width - 2 * borderWidth,
                                  [appSettings textRectHeight]);
    NSRectFill(titleRect);
    
    [gc setShouldAntialias:YES];

    NSString *title = [appSettings windowTitle];
    if (!title || [title isEqualToString:@""]) {
		[self.hostname drawInRect:titleRect withAttributes:[appSettings alignCenterAttributes]];
    }
    else {
        [title drawInRect:titleRect withAttributes:[appSettings alignCenterAttributes]];
    }
    
    [gc setShouldAntialias:YES];
}

- (void)getHostname {
	// Run this in a background thread because it might take a little bit of time.
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSProcessInfo *proc = [NSProcessInfo processInfo];
		NSString *s = [proc hostName];
		NSRange r = [s rangeOfString:@"."];
		
		NSString *newHostname = @"XRG";
		if (r.location == NSNotFound) {
			if ([s length] > 0)	newHostname = s;
		}
		else {
			if (r.location != 0) newHostname = [s substringToIndex:r.location];
		}
		self.hostname = newHostname;

		dispatch_async(dispatch_get_main_queue(), ^{
			[self setNeedsDisplay:YES];
		});
	});

	@autoreleasepool {
	}
}

- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)theEvent {       
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent {       
    return YES;
}

- (BOOL)acceptsMouseMovedEvents {       
    return YES;
}

- (void)mouseDownAction:(NSEvent *)theEvent { 
    if ([appSettings windowLevel] == kCGDesktopWindowLevel) [NSApp preventWindowOrdering];
 	NSInteger originalWindowLevel = [parentWindow level];
	viewPointClicked = [self convertPoint:[theEvent locationInWindow] fromView:nil];

    // if it's a double click in the title bar, minimize the window
    if ([theEvent clickCount] == 2) { 
		NSRect frame    = [self bounds];
		int borderWidth = [parentWindow borderWidth];
		NSRect headerRect = NSMakeRect(frame.origin.x + borderWidth, frame.origin.y + frame.size.height - borderWidth - [appSettings textRectHeight], frame.size.width, [appSettings textRectHeight]);
        if (NSPointInRect(viewPointClicked, headerRect)) {
            if ([parentWindow minimized]) {
                self.clickedMinimized = NO;
                [self expandWindow];
            }
            else {
                if (self.clickedMinimized == NO) {
                    self.clickedMinimized = YES;
                    [self minimizeWindow];
                }
                else {
                    self.clickedMinimized = NO;
                    
                    // If the window was brought to the front when expanding, we need to put it back.
                    [parentWindow setLevel:originalWindowLevel];
                }
            }
        }
    }
}

- (void)mouseDragged:(NSEvent *)theEvent {
    [parentWindow mouseDragged:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent {
    [parentWindow mouseUp:theEvent];
}

- (void)minimizeWindow {
    if ([parentWindow minimized]) return;

    int i;
    NSRect windowFrame;
    // The collapsed strip is exactly this tall (or, horizontally, this wide).
    // A captured frame is "already minimized" when it IS that strip, give or
    // take a pixel of autosave rounding, not merely when it is small: a user
    // who runs a 200px graph must get their 200px back, not a synthesized 600.
    CGFloat minimizedDim = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight];
    CGFloat collapsedLimit = minimizedDim + 1;

    // Figure out what the new rect should be and save the old rect.
    // Never capture an already-minimized frame as the restore rect (happens
    // when minimizing at launch from an autosaved collapsed frame). Both
    // dimensions are checked regardless of orientation: a frame collapsed in
    // the OTHER axis (a vertical-layout strip inherited by a horizontal
    // layout, or vice versa) is just as useless as a restore rect, and
    // measured on a horizontal layout it was persisted as an 809x21
    // "expanded" frame. Prefer the persisted expanded rect when it is sane
    // in that axis; otherwise synthesize 600.
    // By the time this runs at launch, windowChangedToSize/checkWindowSize has
    // usually already regrown the autosaved strip to the module-minimum size
    // (measured: 21 -> 107 tall on a vertical layout, 21 -> 809 wide on a
    // horizontal one), so "is it the bare strip?" alone misses the trap. A
    // frame at or below the module minimum in an axis is not a restore rect
    // either: nobody chose it, the regrowth did.
    windowFrame = [parentWindow frame];
    unminimizedRect = windowFrame;
    {
        NSSize minSize = [moduleManager getMinSize];
        CGFloat trapHeight = MAX(collapsedLimit, minSize.height);
        CGFloat trapWidth  = MAX(collapsedLimit, minSize.width);
        NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:XRG_unminimizedFrame];
        NSRect saved = savedFrame ? NSRectFromString(savedFrame) : NSZeroRect;
        if (unminimizedRect.size.height <= trapHeight) {
            unminimizedRect.size.height = (saved.size.height > trapHeight) ? saved.size.height : MAX(600, trapHeight);
        }
        if (unminimizedRect.size.width <= trapWidth) {
            unminimizedRect.size.width = (saved.size.width > trapWidth) ? saved.size.width : MAX(600, trapWidth);
        }
    }

    if ([moduleManager graphOrientationVertical]) {
        if ([appSettings minimizeUpDown] == 0) { // minimize up
            windowFrame.origin.y = windowFrame.origin.y + windowFrame.size.height - minimizedDim;
            windowFrame.size.height = minimizedDim;
        }
        else { // minimize down
            windowFrame.size.height = minimizedDim;
        }

        [parentWindow setMinimized:YES];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
    else {
        if ([appSettings minimizeUpDown] == 0) { // minimize left
            windowFrame.size.width = minimizedDim;
        }
        else { // minimize right
            windowFrame.origin.x = windowFrame.origin.x + windowFrame.size.width - minimizedDim;
            windowFrame.size.width = minimizedDim;
        }
        
        [parentWindow setMinimized:YES];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }

    // Hide the modules.
    NSArray *a = [moduleManager displayList];
    for (i = 0; i < [a count]; i++) {
        XRGGenericView *ref = [a[i] reference];
        if (ref != nil) {
            [ref setHidden:YES];
        }
    }
    
    // Resize the window.
	[parentWindow setFrame:windowFrame display:YES animate:YES];
    
    // Put the window level back where it was.
    if ([appSettings foregroundWhenExpanding]) {
        if ([appSettings windowLevel] == 0)
        {
            [parentWindow setLevel:NSNormalWindowLevel];
        }
        else if ([appSettings windowLevel] == 1)
        {
            [parentWindow setLevel:NSFloatingWindowLevel];
        }
        else {
            [parentWindow setLevel:kCGDesktopWindowLevel];
        }
    }
	
	// Save in the preferences, including the expanded frame so a relaunch
	// in the minimized state can always restore to real dimensions.
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:XRG_windowIsMinimized];
	[[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(unminimizedRect) forKey:XRG_unminimizedFrame];
}

- (void)expandWindow {
    if (![parentWindow minimized]) return;

    int i;
    NSRect windowFrame;
    
    // Figure out what our new rect should be. The cross axis is restored too
    // whenever it is collapsed: a frame inherited from the other layout (or a
    // module-minimum regrowth) leaves the window a strip in the axis this
    // orientation never touches, and nothing else would ever fix it.
    CGFloat collapsedLimit = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight] + 1;
    if ([moduleManager graphOrientationVertical]) {
        windowFrame = [parentWindow frame];
		if ([appSettings minimizeUpDown] == 0) { // maximize down
			windowFrame.origin.y -= unminimizedRect.size.height - windowFrame.size.height;
		}
		else { // maximize up
			// windowFrame.origin.y is fine as-is
		}
        windowFrame.size.height = unminimizedRect.size.height;
        if (windowFrame.size.width <= collapsedLimit && unminimizedRect.size.width > collapsedLimit) {
            windowFrame.size.width = unminimizedRect.size.width;
        }
        [parentWindow setMinimized:NO];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
    else {
        windowFrame = [parentWindow frame];
		if ([appSettings minimizeUpDown] == 0) { // maximize right
			// windowFrame.origin.x is fine as-is
		}
		else { // maximize left
			windowFrame.origin.x -= unminimizedRect.size.width - windowFrame.size.width;
		}
        windowFrame.size.width = unminimizedRect.size.width;
        if (windowFrame.size.height <= collapsedLimit && unminimizedRect.size.height > collapsedLimit) {
            windowFrame.size.height = unminimizedRect.size.height;
        }
        [parentWindow setMinimized:NO];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
        
    if ([appSettings foregroundWhenExpanding] && [appSettings autoExpandGraph]) 
        [parentWindow setLevel:NSFloatingWindowLevel];

    // Finally, resize the window.
	[parentWindow setFrame:windowFrame display:YES animate:YES];
	
	// Show the modules again.
    NSArray *a = [moduleManager displayList];
    for (i = 0; i < [a count]; i++) {
        XRGGenericView *ref = [a[i] reference];
        if (ref != nil) {
            [ref setHidden:NO];
            [ref setNeedsDisplay:YES];
        }
    }
    	
	// Save in the preferences.
	[[NSUserDefaults standardUserDefaults] setBool:NO forKey:XRG_windowIsMinimized];
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent {
    NSMenu *myMenu = [[NSMenu alloc] initWithTitle:@"Background View"];
    NSMenuItem *tMI;

    tMI = [[NSMenuItem alloc] initWithTitle:@"About XRG" action:@selector(openAboutBox:) keyEquivalent:@""];
    [myMenu addItem:tMI];

    tMI = [[NSMenuItem alloc] initWithTitle:@"Preferences..." action:@selector(openPreferences:) keyEquivalent:@""];
    [myMenu addItem:tMI];

    tMI = [[NSMenuItem alloc] initWithTitle:@"XRG Help" action:@selector(openHelp:) keyEquivalent:@""];
    [myMenu addItem:tMI];
    
    [myMenu addItem:[NSMenuItem separatorItem]];

    if (uiIsHidden) {
        tMI = [[NSMenuItem alloc] initWithTitle:@"Show XRG Dock Icon" action:@selector(showUI:) keyEquivalent:@""];
        [myMenu addItem:tMI];
    }
    else {
        tMI = [[NSMenuItem alloc] initWithTitle:@"Hide XRG Dock Icon (After Restart)" action:@selector(hideUI:) keyEquivalent:@""];
        [myMenu addItem:tMI];
    }

    [myMenu addItem:[NSMenuItem separatorItem]];
    
    tMI = [[NSMenuItem alloc] initWithTitle:@"Quit XRG" action:@selector(quit:) keyEquivalent:@""];
    [myMenu addItem:tMI];
    
    return myMenu;
}

- (void)openAboutBox:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] orderFrontStandardAboutPanel:self];
}

- (void)openHelp:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] showHelp:self];
}

- (void)openPreferences:(NSEvent *)theEvent {
    [[parentWindow controller] showPrefsWithPanel:@"General"];
}

- (void)hideUI:(NSEvent *)theEvent {
    uiIsHidden = YES;
    
    [[NSUserDefaults standardUserDefaults] setBool:uiIsHidden forKey:XRG_isDockIconHidden];
    
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Hiding the XRG Dock Icon";
    alert.informativeText = @"Please re-launch XRG for changes to take effect.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showUI:(NSEvent *)theEvent {
    [NSApp setActivationPolicy: NSApplicationActivationPolicyRegular];
    uiIsHidden = NO;
    
    [[NSUserDefaults standardUserDefaults] setBool:uiIsHidden forKey:XRG_isDockIconHidden];
}

- (void)quit:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] terminate:self];
} 

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender {
    NSPasteboard *pasteBoard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];

    if (sourceDragMask & NSDragOperationCopy) {
        NSArray<NSURL *> *urls = [pasteBoard readObjectsForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
        if (urls.count == 1 && [[urls.firstObject path] hasSuffix:@".xtf"]) {
            return NSDragOperationCopy;
        }
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
    NSPasteboard *pasteBoard = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pasteBoard readObjectsForClasses:@[[NSURL class]] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (urls.count == 1 && [[urls.firstObject path] hasSuffix:@".xtf"]) {
        NSURL *url = urls.firstObject;
        NSData *themeData = [NSData dataWithContentsOfURL:url];
        if (themeData.length == 0) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Error";
            alert.informativeText = @"The theme file dragged is not a valid theme file.";
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
            return YES;
        }

        NSError *plistError = nil;
        NSPropertyListFormat format;
        id plist = [NSPropertyListSerialization propertyListWithData:themeData options:NSPropertyListImmutable format:&format error:&plistError];
        if (![plist isKindOfClass:[NSDictionary class]] || plistError) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Error";
            alert.informativeText = @"The theme file dragged is not a valid theme file.";
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        } else {
            NSDictionary *themeDictionary = (NSDictionary *)plist;
            [appSettings readXTFDictionary:themeDictionary];
            [self setNeedsDisplay:YES];
        }

        [[(XRGAppDelegate *)[NSApp delegate] prefController] setUpColorPanel];
        return YES;
    }

    return NO;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
        self.trackingArea = nil;
    }

    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)theEvent {
	//    NSLog(@"mouseEntered start\n");
	if (self.clickedMinimized && [appSettings autoExpandGraph]) {
		[self expandWindow];
	}
}

- (void)mouseExited:(NSEvent *)theEvent {
	//    NSLog(@"mouseEntered start\n");
	if (self.clickedMinimized && [appSettings autoExpandGraph]) {
		[self minimizeWindow];
	}
}

@end
