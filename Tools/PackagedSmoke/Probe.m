// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <unistd.h>

int main(void) {
    @autoreleasepool {
        int (*ready)(void) = dlsym(RTLD_DEFAULT, "XRGPackagedSmokeInstalled");
        if (!ready || ready() != 1) { fprintf(stderr, "Injection preflight failed\n"); return 2; }
        if (NSApplication.sharedApplication.activationPolicy != NSApplicationActivationPolicyProhibited) return 3;
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].count) return 9;
        [NSApp activate];
        int (*attempts)(void) = dlsym(RTLD_DEFAULT, "XRGPackagedSmokeActivations");
        if (!attempts || attempts() < 2) return 10;
        NSString *domain = NSProcessInfo.processInfo.environment[@"XRG_PACKAGED_SMOKE_DOMAIN"];
        if (![[NSUserDefaults.standardUserDefaults stringForKey:@"packagedSmokeMarker"] isEqual:domain] ||
            [NSUserDefaults.standardUserDefaults boolForKey:@"checkForUpdates"]) {
            CFTypeRef value = CFPreferencesCopyAppValue(CFSTR("packagedSmokeMarker"), (__bridge CFStringRef)domain);
            fprintf(stderr, "Private preferences preflight failed (standard marker: %d; explicit marker: %d)\n",
                    [NSUserDefaults.standardUserDefaults stringForKey:@"packagedSmokeMarker"] != nil, value != NULL);
            if (value) CFRelease(value);
            return 4;
        }
        int file = open(getenv("XRG_PACKAGED_SMOKE_FORBIDDEN_FILE"), O_RDONLY);
        if (file >= 0) { close(file); fprintf(stderr, "Home read was not denied\n"); return 5; }
        if (errno != EPERM && errno != EACCES) return 6;
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock >= 0) {
            struct sockaddr_in address = {.sin_family=AF_INET, .sin_port=htons(9), .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
            int result = connect(sock, (void *)&address, sizeof(address)), saved = errno;
            close(sock);
            if (result == 0 || (saved != EPERM && saved != EACCES)) { fprintf(stderr, "Network was not denied\n"); return 7; }
        } else if (errno != EPERM && errno != EACCES) return 8;
        puts("PASS: injection, prohibited activation, private preferences, denied home read and denied network");
        return 0;
    }
}
