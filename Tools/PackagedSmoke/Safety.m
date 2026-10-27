// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only, process-local presentation guards. Never linked into the shipped app.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/sysctl.h>
#import <errno.h>
#import "Safety.h"

extern void XRGPackagedSmokeStart(void);
extern void XRGPackagedSmokeFinished(void);
static atomic_int installed, activations, ordering;
static BOOL (*setPolicy)(id, SEL, NSApplicationActivationPolicy);
static void (*orderWindow)(id, SEL, NSWindowOrderingMode, NSInteger);
static id (*sharedApplication)(id, SEL);
static id (*lookupApplications)(id, SEL, NSString *);
static void (*terminateDelegate)(id, SEL, NSNotification *);

static void fail(const char *message) { fprintf(stderr, "Packaged smoke protection failed: %s\n", message); _exit(2); }
static void uncaught(NSException *exception) {
    fprintf(stderr, "Packaged smoke uncaught exception: %s\n", exception.name.UTF8String);
    _exit(2);
}
static IMP replace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) fail(sel_getName(selector));
    return method_setImplementation(method, replacement);
}
static BOOL prohibitPolicy(id object, SEL selector, NSApplicationActivationPolicy policy) {
    return setPolicy(object, selector, NSApplicationActivationPolicyProhibited);
}
static id protectedApplication(id object, SEL selector) {
    id application = sharedApplication(object, selector);
    setPolicy(application, @selector(setActivationPolicy:), NSApplicationActivationPolicyProhibited);
    return application;
}
static void preventActivation(id object, SEL selector) { atomic_fetch_add(&activations, 1); }
static void preventIgnoringActivation(id object, SEL selector, BOOL ignore) { atomic_fetch_add(&activations, 1); }
static BOOL preventRunningActivation(id object, SEL selector, NSApplicationActivationOptions options) {
    atomic_fetch_add(&activations, 1); return NO;
}
static id protectedApplicationLookup(id object, SEL selector, NSString *identifier) {
    if ([identifier isEqualToString:@"com.apple.dock"]) { atomic_fetch_add(&activations, 1); return @[]; }
    return lookupApplications(object, selector, identifier);
}
static void preventPresentation(id object, SEL selector, id sender) { atomic_fetch_add(&ordering, 1); }
static void preventFrontRegardless(id object, SEL selector) { atomic_fetch_add(&ordering, 1); }
static void preventOrdering(id object, SEL selector, NSWindowOrderingMode mode, NSInteger relative) {
    if (mode == NSWindowOut) orderWindow(object, selector, mode, relative);
    else atomic_fetch_add(&ordering, 1);
}
static NSModalResponse preventAlert(id object, SEL selector) { fail("unexpected modal alert"); return NSModalResponseAbort; }

int XRGPackagedSmokeInstalled(void) { return atomic_load(&installed); }
int XRGPackagedSmokeActivations(void) { return atomic_load(&activations); }
int XRGPackagedSmokeOrdering(void) { return atomic_load(&ordering); }
const char *XRGPackagedSmokeArchitecture(void) {
#if defined(__arm64__)
    return "arm64";
#elif defined(__x86_64__)
    return "x86_64";
#else
    return "unsupported";
#endif
}
int XRGPackagedSmokeTranslated(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0)) return errno == ENOENT ? 0 : -1;
    return size == sizeof(translated) && (translated == 0 || translated == 1) ? translated : -1;
}
static void finishedTermination(id object, SEL selector, NSNotification *notification) {
    terminateDelegate(object, selector, notification);
    XRGPackagedSmokeFinished();
}
void XRGPackagedInstallTerminationHook(NSObject *delegate) {
    terminateDelegate = (void *)replace(object_getClass(delegate), @selector(applicationWillTerminate:), (IMP)finishedTermination);
}

__attribute__((constructor)) static void install(void) {
    @autoreleasepool {
        NSString *domain = NSProcessInfo.processInfo.environment[@"XRG_PACKAGED_SMOKE_DOMAIN"];
        NSString *root = NSProcessInfo.processInfo.environment[@"XRG_PACKAGED_SMOKE_ROOT"];
        NSString *prefix = @"com.sdelavega.XRG-ng.PackagedSmoke.";
        if (!root.length || ![domain hasPrefix:prefix]) fail("private environment");
        if (![[NSUUID alloc] initWithUUIDString:[domain substringFromIndex:prefix.length]]) fail("private UUID");
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:domain]) fail("bundle identifier does not match private domain");
        NSString *architecture = NSProcessInfo.processInfo.environment[@"XRG_PACKAGED_SMOKE_ARCH"];
        NSString *translated = NSProcessInfo.processInfo.environment[@"XRG_PACKAGED_SMOKE_TRANSLATED"];
        if (![architecture isEqualToString:@(XRGPackagedSmokeArchitecture())]) fail("unexpected process architecture");
        if (![@[@"0", @"1"] containsObject:translated] || XRGPackagedSmokeTranslated() != translated.intValue) fail("unexpected translation status");
        char image[PATH_MAX], resolvedImage[PATH_MAX], resolvedRoot[PATH_MAX];
        uint32_t imageSize = sizeof(image);
        if (_NSGetExecutablePath(image, &imageSize) || !realpath(image, resolvedImage) || !realpath(root.fileSystemRepresentation, resolvedRoot) ||
            strncmp(resolvedImage, resolvedRoot, strlen(resolvedRoot)) || resolvedImage[strlen(resolvedRoot)] != '/') fail("executable is outside private output root");
        NSSetUncaughtExceptionHandler(uncaught);
        setPolicy = (void *)replace(NSApplication.class, @selector(setActivationPolicy:), (IMP)prohibitPolicy);
        Method shared = class_getClassMethod(NSApplication.class, @selector(sharedApplication));
        if (!shared) fail("missing shared application method");
        sharedApplication = (void *)method_setImplementation(shared, (IMP)protectedApplication);
        Method lookup = class_getClassMethod(NSRunningApplication.class, @selector(runningApplicationsWithBundleIdentifier:));
        if (!lookup) fail("missing application lookup method");
        lookupApplications = (void *)method_setImplementation(lookup, (IMP)protectedApplicationLookup);
        replace(NSApplication.class, @selector(activate), (IMP)preventActivation);
        replace(NSApplication.class, @selector(activateIgnoringOtherApps:), (IMP)preventIgnoringActivation);
        replace(NSRunningApplication.class, @selector(activateWithOptions:), (IMP)preventRunningActivation);
        orderWindow = (void *)replace(NSWindow.class, @selector(orderWindow:relativeTo:), (IMP)preventOrdering);
        replace(NSWindow.class, @selector(makeKeyAndOrderFront:), (IMP)preventPresentation);
        replace(NSWindow.class, @selector(orderFront:), (IMP)preventPresentation);
        replace(NSWindow.class, @selector(orderFrontRegardless), (IMP)preventFrontRegardless);
        replace(NSAlert.class, @selector(runModal), (IMP)preventAlert);
        XRGPackagedSmokeStart();
        atomic_store(&installed, 1);
    }
}
