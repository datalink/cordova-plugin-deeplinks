//
//  CULPlugin.m
//
//  Created by Nikolay Demyankov on 14.09.15.
//

#import "CULPlugin.h"
#import "CULConfigXmlParser.h"
#import "CULPath.h"
#import "CULHost.h"
#import "CDVPluginResult+CULPlugin.h"
#import "CDVInvokedUrlCommand+CULPlugin.h"
#import "CULConfigJsonParser.h"
#import <Cordova/CDVViewController.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface CULPlugin() {
    NSArray *_supportedHosts;
    CDVPluginResult *_storedEvent;
    NSMutableDictionary<NSString *, NSString *> *_subscribers;
}

+ (void)installContinueUserActivityHookIfNeeded;

@end

static BOOL cul_continueUserActivityHookInstalled = NO;
static IMP cul_originalContinueUserActivityImp = NULL;

static BOOL CULHandleUserActivityForDelegate(id delegate, NSUserActivity *userActivity) {
    if (userActivity == nil || ![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || userActivity.webpageURL == nil) {
        return NO;
    }

    id viewController = nil;
    @try {
        viewController = [delegate valueForKey:@"viewController"];
    } @catch (NSException *exception) {
        NSLog(@"[UniversalLinks] Failed to read app delegate viewController: %@", exception);
        return NO;
    }

    if (![viewController isKindOfClass:[CDVViewController class]]) {
        NSLog(@"[UniversalLinks] App delegate viewController is not CDVViewController: %@", viewController);
        return NO;
    }

    CULPlugin *plugin = [(CDVViewController *)viewController getCommandInstance:@"UniversalLinks"];
    NSLog(@"[UniversalLinks] Hook resolved plugin instance=%@", plugin);
    if (plugin == nil) {
        return NO;
    }

    BOOL handled = [plugin handleUserActivity:userActivity];
    NSLog(@"[UniversalLinks] Hook handled user activity=%@", handled ? @"YES" : @"NO");
    return handled;
}

static BOOL cul_swizzled_continueUserActivity(id selfObj, SEL _cmd, UIApplication *application, NSUserActivity *userActivity, void (^restorationHandler)(NSArray *)) {
    NSLog(@"[UniversalLinks] Swizzled continueUserActivity activityType=%@ url=%@", userActivity.activityType, userActivity.webpageURL);

    BOOL originalHandled = NO;
    if (cul_originalContinueUserActivityImp != NULL) {
        BOOL (*originalFunc)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) = (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))cul_originalContinueUserActivityImp;
        originalHandled = originalFunc(selfObj, _cmd, application, userActivity, restorationHandler);
        NSLog(@"[UniversalLinks] Original continueUserActivity handled=%@", originalHandled ? @"YES" : @"NO");
    }

    BOOL pluginHandled = CULHandleUserActivityForDelegate(selfObj, userActivity);
    return originalHandled || pluginHandled;
}

@implementation CULPlugin

+ (void)installContinueUserActivityHookIfNeeded {
    if (cul_continueUserActivityHookInstalled) {
        return;
    }

    id<UIApplicationDelegate> appDelegate = [UIApplication sharedApplication].delegate;
    if (appDelegate == nil) {
        NSLog(@"[UniversalLinks] Cannot install continueUserActivity hook because UIApplication delegate is nil");
        return;
    }

    Class delegateClass = [appDelegate class];
    SEL selector = @selector(application:continueUserActivity:restorationHandler:);
    Method method = class_getInstanceMethod(delegateClass, selector);
    IMP newImp = (IMP)cul_swizzled_continueUserActivity;
    const char *types = "B@:@@?";

    if (method != NULL) {
        cul_originalContinueUserActivityImp = method_getImplementation(method);
        method_setImplementation(method, newImp);
        NSLog(@"[UniversalLinks] Installed swizzled continueUserActivity hook on %@ (existing implementation)", NSStringFromClass(delegateClass));
    } else {
        BOOL added = class_addMethod(delegateClass, selector, newImp, types);
        NSLog(@"[UniversalLinks] Installed swizzled continueUserActivity hook on %@ (added=%@)", NSStringFromClass(delegateClass), added ? @"YES" : @"NO");
        if (!added) {
            return;
        }
    }

    cul_continueUserActivityHookInstalled = YES;
}

#pragma mark Public API

- (void)pluginInitialize {
    [self localInit];
    [[self class] installContinueUserActivityHookIfNeeded];
    NSLog(@"[UniversalLinks] pluginInitialize supportedHosts=%@", _supportedHosts);
    // Can be used for testing.
    // Just uncomment, close the app and reopen it. That will simulate application launch from the link.
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onResume:) name:UIApplicationWillEnterForegroundNotification object:nil];
}

//- (void)onResume:(NSNotification *)notification {
//    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
//    [activity setWebpageURL:[NSURL URLWithString:@"http://site2.com/news/page?q=1&v=2#myhash"]];
//
//    [self handleUserActivity:activity];
//}

- (void)handleOpenURL:(NSNotification*)notification {
    NSLog(@"[UniversalLinks] handleOpenURL notification=%@", notification.object);
    id url = notification.object;
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }

    CULHost *host = [self findHostByURL:url];
    if (host) {
        [self storeEventWithHost:host originalURL:url];
    }
}

- (BOOL)handleUserActivity:(NSUserActivity *)userActivity {
    [self localInit];

    NSURL *launchURL = userActivity.webpageURL;
    NSLog(@"[UniversalLinks] handleUserActivity url=%@ supportedHosts=%@", launchURL, _supportedHosts);
    CULHost *host = [self findHostByURL:launchURL];
    if (host == nil) {
        NSLog(@"[UniversalLinks] handleUserActivity no matching host for url=%@", launchURL);
        return NO;
    }

    NSLog(@"[UniversalLinks] handleUserActivity matched host=%@", host.name);
    [self storeEventWithHost:host originalURL:launchURL];

    return YES;
}

- (void)onAppTerminate {
    _supportedHosts = nil;
    _subscribers = nil;
    _storedEvent = nil;

    [super onAppTerminate];
}

#pragma mark Private API

- (void)localInit {
    if (_supportedHosts) {
        return;
    }

    _subscribers = [[NSMutableDictionary alloc] init];

    // Get supported hosts from the config.xml or www/ul.json.
    // For now priority goes to json config.
    _supportedHosts = [self getSupportedHostsFromPreferences];
}

- (NSArray<CULHost *> *)getSupportedHostsFromPreferences {
    NSString *jsonConfigPath = [[NSBundle mainBundle] pathForResource:@"ul" ofType:@"json" inDirectory:@"www"];
    if (jsonConfigPath) {
        return [CULConfigJsonParser parseConfig:jsonConfigPath];
    }

    return [CULConfigXmlParser parse];
}

/**
 *  Store event data for future use.
 *  If we are resuming the app - try to consume it.
 *
 *  @param host        host that matches the launch url
 *  @param originalUrl launch url
 */
- (void)storeEventWithHost:(CULHost *)host originalURL:(NSURL *)originalUrl {
    NSLog(@"[UniversalLinks] storeEventWithHost host=%@ url=%@", host.name, originalUrl);
    _storedEvent = [CDVPluginResult resultWithHost:host originalURL:originalUrl];
    [self tryToConsumeEvent];
}

/**
 *  Find host entry that corresponds to launch url.
 *
 *  @param  launchURL url that launched the app
 *  @return host entry; <code>nil</code> if none is found
 */
- (CULHost *)findHostByURL:(NSURL *)launchURL {
    NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:launchURL resolvingAgainstBaseURL:YES];
    NSLog(@"[UniversalLinks] findHostByURL host=%@ path=%@ query=%@", urlComponents.host, urlComponents.path, urlComponents.query);
    CULHost *host = nil;
    for (CULHost *supportedHost in _supportedHosts) {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"self LIKE[c] %@", supportedHost.name];
        if ([pred evaluateWithObject:urlComponents.host]) {
            host = supportedHost;
            break;
        }
    }

    return host;
}

#pragma mark Methods to send data to JavaScript

/**
 *  Try to send event to the web page.
 *  If there is a subscriber for the event - it will be consumed.
 *  If not - it will stay until someone subscribes to it.
 */
- (void)tryToConsumeEvent {
    NSLog(@"[UniversalLinks] tryToConsumeEvent subscribers=%@ storedEvent=%@", _subscribers, _storedEvent);
    if (_subscribers.count == 0 || _storedEvent == nil) {
        return;
    }

    NSString *storedEventName = [_storedEvent eventName];
    for (NSString *eventName in _subscribers) {
        if ([storedEventName isEqualToString:eventName]) {
            NSString *callbackID = _subscribers[eventName];
            NSLog(@"[UniversalLinks] Consuming stored event %@ with callbackId=%@", storedEventName, callbackID);
            [_storedEvent setKeepCallbackAsBool:YES];
            [self.commandDelegate sendPluginResult:_storedEvent callbackId:callbackID];
            _storedEvent = nil;
            break;
        }
    }
}

#pragma mark Methods, available from JavaScript side

- (void)jsSubscribeForEvent:(CDVInvokedUrlCommand *)command {
    [self localInit];
    NSString *eventName = [command eventName];
    NSLog(@"[UniversalLinks] jsSubscribeForEvent eventName=%@ callbackId=%@", eventName, command.callbackId);
    if (eventName.length == 0) {
        return;
    }

    _subscribers[eventName] = command.callbackId;
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    [self tryToConsumeEvent];
}

- (void)jsUnsubscribeFromEvent:(CDVInvokedUrlCommand *)command {
    NSString *eventName = [command eventName];
    NSLog(@"[UniversalLinks] jsUnsubscribeFromEvent eventName=%@", eventName);
    if (eventName.length == 0) {
        return;
    }
    
    [_subscribers removeObjectForKey:eventName];
}



@end
