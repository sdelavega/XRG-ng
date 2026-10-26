#import "XRGGraphWindow+AITokens.h"
#import "XRG-Swift.h"
#import "XRGSettings.h"

@implementation XRGGraphWindow (AITokens)

- (IBAction)setShowAITokenGraph:(id)sender {
    BOOL enabled = NO;
    if ([sender isKindOfClass:[NSButton class]]) {
        enabled = ([sender state] == NSControlStateValueOn);
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:@"showAITokenGraph"];
    [defaults synchronize];

    if ([self respondsToSelector:@selector(moduleManager)]) {
        id moduleManager = [self performSelector:@selector(moduleManager)];
        if ([moduleManager respondsToSelector:@selector(redisplayModules)]) {
            [moduleManager performSelector:@selector(redisplayModules)];
            return;
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"XRGShowAITokenGraphDidChange" object:self];
}

@end
