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

// Scene hooks
+ (void)installContinueUserActivityHookIfNeeded;
+ (void)installSceneHooksIfNeeded;
+ (void)consumeExistingSceneUserActivitiesIfNeeded;

@end

static BOOL cul_continueUserActivityHookInstalled = NO;
static IMP cul_originalContinueUserActivityImp = NULL;

static BOOL cul_sceneHooksInstalled = NO;
static IMP cul_originalSceneContinueUserActivityImp = NULL;
static IMP cul_originalSceneWillConnectImp = NULL;

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
    if (plugin == nil) {
        return NO;
    }

    BOOL handled = [plugin handleUserActivity:userActivity];
    NSLog(@"[UniversalLinks] Hook handled user activity=%@", handled ? @"YES" : @"NO");
    return handled;
}

static CULPlugin *CULResolvePluginFromScene(UIScene *scene) {
    if (scene == nil || ![scene isKindOfClass:[UIWindowScene class]]) {
        return nil;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    UIWindow *window = nil;
    for (UIWindow *candidate in windowScene.windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    if (window == nil) {
        window = windowScene.windows.firstObject;
    }

    id rootViewController = window.rootViewController;
    if (![rootViewController isKindOfClass:[CDVViewController class]]) {
        return nil;
    }

    CULPlugin *plugin = [(CDVViewController *)rootViewController getCommandInstance:@"UniversalLinks"];
    return plugin;
}

static BOOL CULHandleUserActivityForScene(UIScene *scene, NSUserActivity *userActivity) {
    if (userActivity == nil || ![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || userActivity.webpageURL == nil) {
        return NO;
    }

    CULPlugin *plugin = CULResolvePluginFromScene(scene);
    if (plugin == nil) {
        return NO;
    }

    BOOL handled = [plugin handleUserActivity:userActivity];
    return handled;
}

static BOOL cul_swizzled_continueUserActivity(id selfObj, SEL _cmd, UIApplication *application, NSUserActivity *userActivity, void (^restorationHandler)(NSArray *)) {

    BOOL originalHandled = NO;
    if (cul_originalContinueUserActivityImp != NULL) {
        BOOL (*originalFunc)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) = (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))cul_originalContinueUserActivityImp;
        originalHandled = originalFunc(selfObj, _cmd, application, userActivity, restorationHandler);
    }

    BOOL pluginHandled = CULHandleUserActivityForDelegate(selfObj, userActivity);
    return originalHandled || pluginHandled;
}

static void cul_swizzled_sceneContinueUserActivity(id selfObj, SEL _cmd, UIScene *scene, NSUserActivity *userActivity) {

    if (cul_originalSceneContinueUserActivityImp != NULL) {
        void (*originalFunc)(id, SEL, UIScene *, NSUserActivity *) = (void (*)(id, SEL, UIScene *, NSUserActivity *))cul_originalSceneContinueUserActivityImp;
        originalFunc(selfObj, _cmd, scene, userActivity);
    }

    CULHandleUserActivityForScene(scene, userActivity);
}

static void cul_swizzled_sceneWillConnect(id selfObj, SEL _cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *connectionOptions) {

    if (cul_originalSceneWillConnectImp != NULL) {
        void (*originalFunc)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *) = (void (*)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *))cul_originalSceneWillConnectImp;
        originalFunc(selfObj, _cmd, scene, session, connectionOptions);
    }

    for (NSUserActivity *activity in connectionOptions.userActivities) {
        CULHandleUserActivityForScene(scene, activity);
    }
}

@implementation CULPlugin

+ (void)installContinueUserActivityHookIfNeeded {
    if (cul_continueUserActivityHookInstalled) {
        return;
    }

    id<UIApplicationDelegate> appDelegate = [UIApplication sharedApplication].delegate;
    if (appDelegate == nil) {
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
    } else {
        BOOL added = class_addMethod(delegateClass, selector, newImp, types);
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
    [[self class] installSceneHooksIfNeeded];
    [[self class] consumeExistingSceneUserActivitiesIfNeeded];
    // Can be used for testing.
    // Just uncomment, close the app and reopen it. That will simulate application launch from the link.
    // [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onResume:) name:UIApplicationWillEnterForegroundNotification object:nil];
}

// Scene hooks
+ (Class)sceneDelegateClassIfAvailable {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        id delegate = scene.delegate;
        if (delegate != nil) {
            return [delegate class];
        }
    }

    NSDictionary *sceneManifest = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
    NSDictionary *sceneConfigurations = sceneManifest[@"UISceneConfigurations"];
    NSArray *applicationConfigs = sceneConfigurations[@"UIWindowSceneSessionRoleApplication"];
    NSDictionary *firstConfig = applicationConfigs.firstObject;
    NSString *delegateClassName = firstConfig[@"UISceneDelegateClassName"];
    if (delegateClassName.length == 0) {
        return Nil;
    }

    if ([delegateClassName containsString:@"$(PRODUCT_MODULE_NAME)"]) {
        NSString *moduleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
        delegateClassName = [delegateClassName stringByReplacingOccurrencesOfString:@"$(PRODUCT_MODULE_NAME)" withString:moduleName ?: @""];
    }

    return NSClassFromString(delegateClassName);
}

+ (void)installSceneHooksIfNeeded {
    if (cul_sceneHooksInstalled) {
        return;
    }

    Class sceneDelegateClass = [self sceneDelegateClassIfAvailable];
    if (sceneDelegateClass == Nil) {
        return;
    }

    SEL continueSelector = @selector(scene:continueUserActivity:);
    Method continueMethod = class_getInstanceMethod(sceneDelegateClass, continueSelector);
    IMP continueImp = (IMP)cul_swizzled_sceneContinueUserActivity;
    const char *continueTypes = "v@:@@";

    if (continueMethod != NULL) {
        cul_originalSceneContinueUserActivityImp = method_getImplementation(continueMethod);
        method_setImplementation(continueMethod, continueImp);
    } else {
        BOOL added = class_addMethod(sceneDelegateClass, continueSelector, continueImp, continueTypes);
    }

    SEL willConnectSelector = @selector(scene:willConnectToSession:options:);
    Method willConnectMethod = class_getInstanceMethod(sceneDelegateClass, willConnectSelector);
    IMP willConnectImp = (IMP)cul_swizzled_sceneWillConnect;
    const char *willConnectTypes = "v@:@@@";

    if (willConnectMethod != NULL) {
        cul_originalSceneWillConnectImp = method_getImplementation(willConnectMethod);
        method_setImplementation(willConnectMethod, willConnectImp);
    } else {
        BOOL added = class_addMethod(sceneDelegateClass, willConnectSelector, willConnectImp, willConnectTypes);
    }

    cul_sceneHooksInstalled = YES;
}

+ (void)consumeExistingSceneUserActivitiesIfNeeded {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        NSUserActivity *userActivity = scene.userActivity;
        if (userActivity != nil) {
            CULHandleUserActivityForScene(scene, userActivity);
        }
    }
}

//- (void)onResume:(NSNotification *)notification {
//    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
//    [activity setWebpageURL:[NSURL URLWithString:@"http://site2.com/news/page?q=1&v=2#myhash"]];
//
//    [self handleUserActivity:activity];
//}

- (void)handleOpenURL:(NSNotification*)notification {
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
    CULHost *host = [self findHostByURL:launchURL];
    if (host == nil) {
        return NO;
    }

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
    if (_subscribers.count == 0 || _storedEvent == nil) {
        return;
    }

    NSString *storedEventName = [_storedEvent eventName];
    for (NSString *eventName in _subscribers) {
        if ([storedEventName isEqualToString:eventName]) {
            NSString *callbackID = _subscribers[eventName];
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
    if (eventName.length == 0) {
        return;
    }
    
    [_subscribers removeObjectForKey:eventName];
}



@end
