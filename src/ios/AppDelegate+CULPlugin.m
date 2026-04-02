//
//  AppDelegate+CULPlugin.m
//
//  Created by Nikolay Demyankov on 15.09.15.
//

#import "AppDelegate+CULPlugin.h"
#import "CULPlugin.h"
#import <Cordova/CDVViewController.h>

/**
 *  Plugin name in config.xml
 */
static NSString *const PLUGIN_NAME = @"UniversalLinks";

@implementation AppDelegate (CULPlugin)

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray *))restorationHandler {
    NSLog(@"[UniversalLinks] AppDelegate category continueUserActivity activityType=%@ url=%@", userActivity.activityType, userActivity.webpageURL);

    // ignore activities that are not for Universal Links
    if (![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || userActivity.webpageURL == nil) {
        NSLog(@"[UniversalLinks] AppDelegate category ignoring non-web activity");
        return NO;
    }

    id viewController = self.viewController;
    if (![viewController isKindOfClass:[CDVViewController class]]) {
        NSLog(@"[UniversalLinks] AppDelegate category viewController is not CDVViewController: %@", viewController);
        return NO;
    }

    // get instance of the plugin and let it handle the userActivity object
    CULPlugin *plugin = [(CDVViewController *)viewController getCommandInstance:PLUGIN_NAME];
    NSLog(@"[UniversalLinks] AppDelegate category plugin instance=%@", plugin);
    if (plugin == nil) {
        return NO;
    }

    BOOL handled = [plugin handleUserActivity:userActivity];
    NSLog(@"[UniversalLinks] AppDelegate category handled=%@", handled ? @"YES" : @"NO");
    return handled;
}

@end
