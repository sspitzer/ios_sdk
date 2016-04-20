//
//  ADJActivityHandler.m
//  Adjust
//
//  Created by Christian Wellenbrock on 2013-07-01.
//  Copyright (c) 2013 adjust GmbH. All rights reserved.
//

#import "ADJActivityPackage.h"
#import "ADJActivityHandler.h"
#import "ADJActivityState.h"
#import "ADJPackageBuilder.h"
#import "ADJPackageHandler.h"
#import "ADJLogger.h"
#import "ADJTimerCycle.h"
#import "ADJTimerOnce.h"
#import "ADJUtil.h"
#import "UIDevice+ADJAdditions.h"
#import "ADJAdjustFactory.h"
#import "ADJAttributionHandler.h"
#import "NSString+ADJAdditions.h"

static NSString   * const kActivityStateFilename = @"AdjustIoActivityState";
static NSString   * const kAttributionFilename   = @"AdjustIoAttribution";
static NSString   * const kAdjustPrefix          = @"adjust_";
static const char * const kInternalQueueName     = "io.adjust.ActivityQueue";
static NSString   * const kForegroundTimerName   = @"Foreground timer";
static NSString   * const kBackgroundTimerName   = @"Background timer";

static NSTimeInterval kForegroundTimerInterval;
static NSTimeInterval kForegroundTimerStart;
static NSTimeInterval kBackgroundTimerInterval;
static double kSessionInterval;
static double kSubSessionInterval;

// number of tries
static const int kTryIadV3                       = 2;
static const uint64_t kDelayRetryIad   =  2 * NSEC_PER_SEC; // 1 second

@interface ADJInternalState : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL offline;
@property (nonatomic, assign) BOOL background;

- (id)init;

- (BOOL)isEnabled;
- (BOOL)isDisabled;
- (BOOL)isOffline;
- (BOOL)isOnline;
- (BOOL)isBackground;
- (BOOL)isForeground;

@end

@implementation ADJInternalState

- (id)init {
    self = [super init];
    if (self == nil) return nil;

    return self;
}

- (BOOL)isEnabled { return self.enabled; }
- (BOOL)isDisabled { return !self.enabled; }
- (BOOL)isOffline { return self.offline; }
- (BOOL)isOnline { return !self.offline; }
- (BOOL)isBackground { return self.background; }
- (BOOL)isForeground { return !self.background; }

@end

#pragma mark -
@interface ADJActivityHandler()

@property (nonatomic) dispatch_queue_t internalQueue;
@property (nonatomic, retain) id<ADJPackageHandler> packageHandler;
@property (nonatomic, retain) id<ADJAttributionHandler> attributionHandler;
@property (nonatomic, retain) ADJActivityState *activityState;
@property (nonatomic, retain) ADJTimerCycle *foregroundTimer;
@property (nonatomic, retain) ADJTimerOnce *backgroundTimer;
@property (nonatomic, retain) id<ADJLogger> logger;
@property (nonatomic, weak) NSObject<AdjustDelegate> *adjustDelegate;
@property (nonatomic, copy) ADJAttribution *attribution;
@property (nonatomic, copy) ADJConfig *adjustConfig;
@property (nonatomic, retain) ADJInternalState *internalState;

@property (nonatomic, copy) ADJDeviceInfo* deviceInfo;

@end

// copy from ADClientError
typedef NS_ENUM(NSInteger, AdjADClientError) {
    AdjADClientErrorUnknown = 0,
    AdjADClientErrorLimitAdTracking = 1,
};

#pragma mark -
@implementation ADJActivityHandler

+ (id<ADJActivityHandler>)handlerWithConfig:(ADJConfig *)adjustConfig {
    return [[ADJActivityHandler alloc] initWithConfig:adjustConfig];
}

- (id)initWithConfig:(ADJConfig *)adjustConfig {
    self = [super init];
    if (self == nil) return nil;

    if (adjustConfig == nil) {
        [ADJAdjustFactory.logger error:@"AdjustConfig missing"];
        return nil;
    }

    if (![adjustConfig isValid]) {
        [ADJAdjustFactory.logger error:@"AdjustConfig not initialized correctly"];
        return nil;
    }

    // init logger to be available everywhere
    self.logger = ADJAdjustFactory.logger;
    if ([self.adjustConfig.environment isEqualToString:ADJEnvironmentProduction]) {
        [self.logger setLogLevel:ADJLogLevelAssert];
    } else {
        [self.logger setLogLevel:self.adjustConfig.logLevel];
    }

    self.adjustConfig = adjustConfig;
    self.adjustDelegate = adjustConfig.delegate;

    // read files to have sync values available
    [self readAttribution];
    [self readActivityState];

    self.internalState = [[ADJInternalState alloc] init];

    // enabled by default
    if (self.activityState == nil) {
        self.internalState.enabled = YES;
    } else {
        self.internalState.enabled = self.activityState.enabled;
    }

    // online by default
    self.internalState.offline = NO;
    // in the background by default
    self.internalState.background = YES;

    self.internalQueue = dispatch_queue_create(kInternalQueueName, DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.internalQueue, ^{
        [self initInternal];
    });

    // get timer values
    kForegroundTimerStart = ADJAdjustFactory.timerStart;
    kForegroundTimerInterval = ADJAdjustFactory.timerInterval;
    kBackgroundTimerInterval = ADJAdjustFactory.timerInterval;

    // initialize timers to be available in applicationDidBecomeActive/WillResignActive
    // after initInternal so that the handlers are initialized
    self.foregroundTimer = [ADJTimerCycle timerWithBlock:^{ [self foregroundTimerFired]; }
                                                   queue:self.internalQueue
                                               startTime:kForegroundTimerStart
                                            intervalTime:kForegroundTimerInterval
                                                    name:kForegroundTimerName];

    self.backgroundTimer = [ADJTimerOnce timerWithBlock:^{ [self backgroundTimerFired]; }
                                                  queue:self.internalQueue
                                                   name:kBackgroundTimerName];

    [self addNotificationObserver];

    return self;
}

- (void)applicationDidBecomeActive {
    self.internalState.background = NO;

    [self stopBackgroundTimer];

    [self startForegroundTimer];

    [self trackSubsessionStart];
}

- (void)trackSubsessionStart {
    [self.logger verbose:@"Subsession start"];
    dispatch_async(self.internalQueue, ^{
        [self startInternal];
    });
}

- (void)applicationWillResignActive {
    self.internalState.background = YES;

    [self stopForegroundTimer];

    [self startBackgroundTimer];

    [self trackSubsessionEnd];
}

- (void)trackSubsessionEnd {
    [self.logger verbose:@"Subsession end"];
    dispatch_async(self.internalQueue, ^{
        [self endInternal];
    });
}

- (void)trackEvent:(ADJEvent *)event {
    dispatch_async(self.internalQueue, ^{
        [self eventInternal:event];
    });
}

- (void)finishedTracking:(ADJResponseData *)responseData {
    // redirect session responses to attribution handler to check for attribution information
    if ([responseData isKindOfClass:[ADJSessionResponseData class]]) {
        [self.attributionHandler checkSessionResponse:(ADJSessionResponseData*)responseData];
        return;
    }

    // check if it's an event response
    if ([responseData isKindOfClass:[ADJEventResponseData class]]) {
        [self launchEventResponseTasks:(ADJEventResponseData*)responseData];
        return;
    }
}

- (void)launchEventResponseTasks:(ADJEventResponseData *)eventResponseData {
    dispatch_async(self.internalQueue, ^{
        [self launchEventResponseTasksInternal:eventResponseData];
    });
}

- (void)launchSessionResponseTasks:(ADJSessionResponseData *)sessionResponseData {
    dispatch_async(self.internalQueue, ^{
        [self launchSessionResponseTasksInternal:sessionResponseData];
    });
}

- (void)launchAttributionResponseTasks:(ADJAttributionResponseData *)attributionResponseData {
    dispatch_async(self.internalQueue, ^{
        [self launchAttributionResponseTasksInternal:attributionResponseData];
    });
}

- (void)launchDeepLink:(NSString *)deepLink{
    if (deepLink == nil) return;

    NSURL* deepLinkUrl = [NSURL URLWithString:deepLink];

    BOOL success = [[UIApplication sharedApplication] openURL:deepLinkUrl];

    if (!success) {
        [self.logger error:@"Unable to open deep link (%@)", deepLink];
    }
}

- (void)setEnabled:(BOOL)enabled {
    // compare with the saved or internal state
    if (![self hasChangedState:[self isEnabled]
                     nextState:enabled
                   trueMessage:@"Adjust already enabled"
                  falseMessage:@"Adjust already disabled"])
    {
        return;
    }

    // save new enabled state in internal state
    self.internalState.enabled = enabled;

    if (self.activityState == nil) {
        [self updateState:!enabled
           pausingMessage:@"Package handler and attribution handler will start as paused due to the SDK being disabled"
     remainsPausedMessage:@"Package and attribution handler will still start as paused due to the SDK being offline"
         unPausingMessage:@"Package handler and attribution handler will start as active due to the SDK being enabled"];
        return;
    }

    // save new enabled state in activity state
    self.activityState.enabled = enabled;
    [self writeActivityState];

    [self updateState:!enabled
       pausingMessage:@"Pausing package handler and attribution handler due to SDK being disabled"
 remainsPausedMessage:@"Package and attribution handler remain paused due to SDK being offline"
     unPausingMessage:@"Resuming package handler and attribution handler due to SDK being enabled"];
}

- (void)setOfflineMode:(BOOL)offline {
    // compare with the internal state
    if (![self hasChangedState:[self.internalState isOffline]
                     nextState:offline
                   trueMessage:@"Adjust already in offline mode"
                  falseMessage:@"Adjust already in online mode"])
    {
        return;
    }

    // save new offline state in internal state
    self.internalState.offline = offline;

    if (self.activityState == nil) {
        [self updateState:offline
           pausingMessage:@"Package handler and attribution handler will start paused due to SDK being offline"
     remainsPausedMessage:@"Package and attribution handler will still start as paused due to SDK being disabled"
         unPausingMessage:@"Package handler and attribution handler will start as active due to SDK being online"];
        return;
    }

    [self updateState:offline
       pausingMessage:@"Pausing package and attribution handler to put SDK offline mode"
 remainsPausedMessage:@"Package and attribution handler remain paused due to SDK being disabled"
     unPausingMessage:@"Resuming package handler and attribution handler to put SDK in online mode"];
}

- (BOOL)isEnabled {
    if (self.activityState != nil) {
        return self.activityState.enabled;
    } else {
        return [self.internalState isEnabled];
    }
}

- (BOOL)hasChangedState:(BOOL)previousState
              nextState:(BOOL)nextState
            trueMessage:(NSString *)trueMessage
           falseMessage:(NSString *)falseMessage
{
    if (previousState != nextState) {
        return YES;
    }

    if (previousState) {
        [self.logger debug:trueMessage];
    } else {
        [self.logger debug:falseMessage];
    }

    return NO;
}

- (void)updateState:(BOOL)pausingState
     pausingMessage:(NSString *)pausingMessage
remainsPausedMessage:(NSString *)remainsPausedMessage
   unPausingMessage:(NSString *)unPausingMessage
{
    // it is changing from an active state to a pause state
    if (pausingState) {
        [self.logger info:pausingMessage];
        [self updateHandlersStatusAndSend];
        return;
    }

    // it is remaining in a pause state
    if ([self paused]) {
        [self.logger info:remainsPausedMessage];
        return;
    }

    // it is changing from a pause state to an active state
    [self.logger info:unPausingMessage];
    [self updateHandlersStatusAndSend];
}

- (void)appWillOpenUrl:(NSURL*)url {
    dispatch_async(self.internalQueue, ^{
        [self appWillOpenUrlInternal:url];
    });
}

- (void)setDeviceToken:(NSData *)deviceToken {
    dispatch_async(self.internalQueue, ^{
        [self setDeviceTokenInternal:deviceToken];
    });
}

- (void)setIadDate:(NSDate *)iAdImpressionDate withPurchaseDate:(NSDate *)appPurchaseDate {
    if (iAdImpressionDate == nil) {
        [self.logger debug:@"iAdImpressionDate not received"];
        return;
    }

    [self.logger debug:@"iAdImpressionDate received: %@", iAdImpressionDate];


    double now = [NSDate.date timeIntervalSince1970];
    ADJPackageBuilder *clickBuilder = [[ADJPackageBuilder alloc]
                                       initWithDeviceInfo:self.deviceInfo
                                       activityState:self.activityState
                                       config:self.adjustConfig
                                       createdAt:now];

    clickBuilder.purchaseTime = appPurchaseDate;
    clickBuilder.clickTime = iAdImpressionDate;

    ADJActivityPackage *clickPackage = [clickBuilder buildClickPackage:@"iad"];
    [self.packageHandler addPackage:clickPackage];
    [self.packageHandler sendFirstPackage];
}

- (void)setIadDetails:(NSDictionary *)attributionDetails
                error:(NSError *)error
          retriesLeft:(int)retriesLeft
{
    if (![ADJUtil isNull:error]) {
        [self.logger warn:@"Unable to read iAd details"];

        if (retriesLeft < 0) {
            [self.logger warn:@"Limit number of retry for iAd v3 surpassed"];
            return;
        }

        if (error.code == AdjADClientErrorUnknown) {
            dispatch_time_t retryTime = dispatch_time(DISPATCH_TIME_NOW, kDelayRetryIad);
            dispatch_after(retryTime, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[UIDevice currentDevice] adjSetIad:self triesV3Left:retriesLeft];
            });
        }
        return;
    }

    if ([ADJUtil isNull:attributionDetails]) {
        return;
    }

    double now = [NSDate.date timeIntervalSince1970];
    ADJPackageBuilder *clickBuilder = [[ADJPackageBuilder alloc]
                                       initWithDeviceInfo:self.deviceInfo
                                       activityState:self.activityState
                                       config:self.adjustConfig
                                       createdAt:now];

    clickBuilder.iadDetails = attributionDetails;

    ADJActivityPackage *clickPackage = [clickBuilder buildClickPackage:@"iad3"];
    [self.packageHandler addPackage:clickPackage];
    [self.packageHandler sendFirstPackage];
}

- (void)setAskingAttribution:(BOOL)askingAttribution {
    self.activityState.askingAttribution = askingAttribution;
    [self writeActivityState];
}

- (void)updateHandlersStatusAndSend {
    dispatch_async(self.internalQueue, ^{
        [self updateHandlersStatusAndSendInternal];
    });
}

- (void)foregroundTimerFired {
    dispatch_async(self.internalQueue, ^{
        [self foregroundTimerFiredInternal];
    });
}

- (void)backgroundTimerFired {
    dispatch_async(self.internalQueue, ^{
        [self backgroundTimerFiredInternal];
    });
}

#pragma mark - internal
- (void)initInternal {
    kSessionInterval = ADJAdjustFactory.sessionInterval;
    kSubSessionInterval = ADJAdjustFactory.subsessionInterval;

    self.deviceInfo = [ADJDeviceInfo deviceInfoWithSdkPrefix:self.adjustConfig.sdkPrefix];

    if (self.adjustConfig.eventBufferingEnabled)  {
        [self.logger info:@"Event buffering is enabled"];
    }

    if (self.adjustConfig.defaultTracker != nil) {
        [self.logger info:@"Default tracker: %@", self.adjustConfig.defaultTracker];
    }

    self.packageHandler = [ADJAdjustFactory packageHandlerForActivityHandler:self
                                                               startsSending:[self toSend]];

    double now = [NSDate.date timeIntervalSince1970];
    ADJPackageBuilder *attributionBuilder = [[ADJPackageBuilder alloc]
                                             initWithDeviceInfo:self.deviceInfo
                                             activityState:self.activityState
                                             config:self.adjustConfig
                                             createdAt:now];
    ADJActivityPackage *attributionPackage = [attributionBuilder buildAttributionPackage];
    self.attributionHandler = [ADJAdjustFactory attributionHandlerForActivityHandler:self
                                                              withAttributionPackage:attributionPackage
                                                                       startsSending:[self toSend]
                                                       hasAttributionChangedDelegate:self.adjustConfig.hasAttributionChangedDelegate];

    [[UIDevice currentDevice] adjSetIad:self triesV3Left:kTryIadV3];

    [self startInternal];
}

- (void)startInternal {
    // it shouldn't start if it was disabled after a first session
    if (self.activityState != nil
        && !self.activityState.enabled) {
        return;
    }

    [self updateHandlersStatusAndSendInternal];

    [self processSession];

    [self checkAttributionState];
}

- (void)processSession {
    double now = [NSDate.date timeIntervalSince1970];

    // very first session
    if (self.activityState == nil) {
        self.activityState = [[ADJActivityState alloc] init];
        self.activityState.sessionCount = 1; // this is the first session

        [self transferSessionPackage:now];
        [self.activityState resetSessionAttributes:now];
        self.activityState.enabled = [self.internalState isEnabled];
        [self writeActivityState];
        return;
    }

    double lastInterval = now - self.activityState.lastActivity;
    if (lastInterval < 0) {
        [self.logger error:@"Time travel!"];
        self.activityState.lastActivity = now;
        [self writeActivityState];
        return;
    }

    // new session
    if (lastInterval > kSessionInterval) {
        self.activityState.sessionCount++;
        self.activityState.lastInterval = lastInterval;

        [self transferSessionPackage:now];
        [self.activityState resetSessionAttributes:now];
        [self writeActivityState];
        return;
    }

    // new subsession
    if (lastInterval > kSubSessionInterval) {
        self.activityState.subsessionCount++;
        self.activityState.sessionLength += lastInterval;
        self.activityState.lastActivity = now;
        [self.logger verbose:@"Started subsession %d of session %d",
         self.activityState.subsessionCount,
         self.activityState.sessionCount];
        [self writeActivityState];
        return;
    }

    [self.logger verbose:@"Time span since last activity too short for a new subsession"];
}

- (void)checkAttributionState {
    if (![self checkActivityState]) return;

    // if it' a new session
    if (self.activityState.subsessionCount <= 1) {
        return;
    }

    // if there is already an attribution saved and there was no attribution being asked
    if (self.attribution != nil && !self.activityState.askingAttribution) {
        return;
    }

    [self.attributionHandler getAttribution];
}

- (void)endInternal {
    // pause sending if it's not allowed to send
    if (![self toSend]) {
        [self pauseSending];
    }

    double now = [NSDate.date timeIntervalSince1970];
    if ([self updateActivityState:now]) {
        [self writeActivityState];
    }
}

- (void)eventInternal:(ADJEvent *)event {
    if (![self checkActivityState]) return;
    if (![self isEnabled]) return;
    if (![self checkEvent:event]) return;
    if (![self checkTransactionId:event.transactionId]) return;

    double now = [NSDate.date timeIntervalSince1970];

    self.activityState.eventCount++;
    [self updateActivityState:now];

    // create and populate event package
    ADJPackageBuilder *eventBuilder = [[ADJPackageBuilder alloc]
                                       initWithDeviceInfo:self.deviceInfo
                                       activityState:self.activityState
                                       config:self.adjustConfig
                                       createdAt:now];
    ADJActivityPackage *eventPackage = [eventBuilder buildEventPackage:event];
    [self.packageHandler addPackage:eventPackage];

    if (self.adjustConfig.eventBufferingEnabled) {
        [self.logger info:@"Buffered event %@", eventPackage.suffix];
    } else {
        [self.packageHandler sendFirstPackage];
    }

    // if it is in the background and it can send, start the background timer
    if (self.adjustConfig.sendInBackground && [self.internalState isBackground]) {
        [self startBackgroundTimer];
    }

    [self writeActivityState];
}

- (void) launchEventResponseTasksInternal:(ADJEventResponseData *)eventResponseData {
    // event success callback
    if (eventResponseData.success
        && [self.adjustDelegate respondsToSelector:@selector(adjustEventTrackingSucceeded:)])
    {
        [self.logger debug:@"Launching success event tracking delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustEventTrackingSucceeded:)
                                              withObject:[eventResponseData successResponseData]
                                           waitUntilDone:NO]; // non-blocking
        return;
    }
    // event failure callback
    if (!eventResponseData.success
        && [self.adjustDelegate respondsToSelector:@selector(adjustEventTrackingFailed:)])
    {
        [self.logger debug:@"Launching failed event tracking delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustEventTrackingFailed:)
                                              withObject:[eventResponseData failureResponseData]
                                           waitUntilDone:NO]; // non-blocking
        return;
    }
}

- (void) launchSessionResponseTasksInternal:(ADJSessionResponseData *)sessionResponseData {
    BOOL toLaunchAttributionDelegate = [self updateAttribution:sessionResponseData.attribution];

    // session success callback
    if (sessionResponseData.success
        && [self.adjustDelegate respondsToSelector:@selector(adjustSessionTrackingSucceeded:)])
    {
        [self.logger debug:@"Launching success session tracking delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustSessionTrackingSucceeded:)
                                              withObject:[sessionResponseData successResponseData]
                                           waitUntilDone:NO]; // non-blocking
    }
    // session failure callback
    if (!sessionResponseData.success
        && [self.adjustDelegate respondsToSelector:@selector(adjustSessionTrackingFailed:)])
    {
        [self.logger debug:@"Launching failed session tracking delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustSessionTrackingFailed:)
                                              withObject:[sessionResponseData failureResponseData]
                                           waitUntilDone:NO]; // non-blocking
    }

    // try to update and launch the attribution changed delegate blocking
    if (toLaunchAttributionDelegate) {
        [self.logger debug:@"Launching attribution changed delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustAttributionChanged:)
                                              withObject:sessionResponseData.attribution
                                           waitUntilDone:NO]; // non-blocking
    }

    if ([ADJUtil isNull:sessionResponseData.jsonResponse]) {
        return;
    }

    NSString *deepLink = [sessionResponseData.jsonResponse objectForKey:@"deeplink"];
    if (deepLink == nil) {
        return;
    }

    [self.logger info:@"Trying to open deep link (%@)", deepLink];

    [self performSelectorOnMainThread:@selector(launchDeepLink:)
                           withObject:deepLink
                        waitUntilDone:NO]; // non-blocking
}

- (void) launchAttributionResponseTasksInternal:(ADJAttributionResponseData *)attributionResponseData {
    BOOL toLaunchAttributionDelegate = [self updateAttribution:attributionResponseData.attribution];

    // try to update and launch the attribution changed delegate non-blocking
    if (toLaunchAttributionDelegate) {
        [self.logger debug:@"Launching attribution changed delegate"];
        [self.adjustDelegate performSelectorOnMainThread:@selector(adjustAttributionChanged:)
                                              withObject:attributionResponseData.attribution
                                           waitUntilDone:NO]; // non-blocking
    }
}

- (BOOL)updateAttribution:(ADJAttribution *)attribution {
    if (attribution == nil) {
        return NO;
    }
    if ([attribution isEqual:self.attribution]) {
        return NO;
    }
    self.attribution = attribution;
    [self writeAttribution];

    if (self.adjustDelegate == nil) {
        return NO;
    }

    if (![self.adjustDelegate respondsToSelector:@selector(adjustAttributionChanged:)]) {
        return NO;
    }

    return YES;
}

- (void) appWillOpenUrlInternal:(NSURL *)url {
    if ([ADJUtil isNull:url]) {
        return;
    }

    NSArray* queryArray = [url.query componentsSeparatedByString:@"&"];
    if (queryArray == nil) {
        return;
    }

    NSMutableDictionary* adjustDeepLinks = [NSMutableDictionary dictionary];
    ADJAttribution *deeplinkAttribution = [[ADJAttribution alloc] init];
    BOOL hasDeepLink = NO;

    for (NSString* fieldValuePair in queryArray) {
        if([self readDeeplinkQueryString:fieldValuePair adjustDeepLinks:adjustDeepLinks attribution:deeplinkAttribution]) {
            hasDeepLink = YES;
        }
    }

    if (!hasDeepLink) {
        return;
    }

    double now = [NSDate.date timeIntervalSince1970];
    ADJPackageBuilder *clickBuilder = [[ADJPackageBuilder alloc]
                                       initWithDeviceInfo:self.deviceInfo
                                       activityState:self.activityState
                                       config:self.adjustConfig
                                       createdAt:now];
    clickBuilder.deeplinkParameters = adjustDeepLinks;
    clickBuilder.attribution = deeplinkAttribution;
    clickBuilder.clickTime = [NSDate date];

    ADJActivityPackage *clickPackage = [clickBuilder buildClickPackage:@"deeplink"];
    [self.packageHandler addPackage:clickPackage];
    [self.packageHandler sendFirstPackage];
}

- (BOOL) readDeeplinkQueryString:(NSString *)queryString
                 adjustDeepLinks:(NSMutableDictionary*)adjustDeepLinks
                     attribution:(ADJAttribution *)deeplinkAttribution
{
    NSArray* pairComponents = [queryString componentsSeparatedByString:@"="];
    if (pairComponents.count != 2) return NO;

    NSString* key = [pairComponents objectAtIndex:0];
    if (![key hasPrefix:kAdjustPrefix]) return NO;

    NSString* keyDecoded = [key adjUrlDecode];

    NSString* value = [pairComponents objectAtIndex:1];
    if (value.length == 0) return NO;

    NSString* valueDecoded = [value adjUrlDecode];

    NSString* keyWOutPrefix = [keyDecoded substringFromIndex:kAdjustPrefix.length];
    if (keyWOutPrefix.length == 0) return NO;

    if (![self trySetAttributionDeeplink:deeplinkAttribution withKey:keyWOutPrefix withValue:valueDecoded]) {
        [adjustDeepLinks setObject:valueDecoded forKey:keyWOutPrefix];
    }

    return YES;
}

- (BOOL) trySetAttributionDeeplink:(ADJAttribution *)deeplinkAttribution
                           withKey:(NSString *)key
                         withValue:(NSString*)value {

    if ([key isEqualToString:@"tracker"]) {
        deeplinkAttribution.trackerName = value;
        return YES;
    }

    if ([key isEqualToString:@"campaign"]) {
        deeplinkAttribution.campaign = value;
        return YES;
    }

    if ([key isEqualToString:@"adgroup"]) {
        deeplinkAttribution.adgroup = value;
        return YES;
    }

    if ([key isEqualToString:@"creative"]) {
        deeplinkAttribution.creative = value;
        return YES;
    }

    return NO;
}

- (void) setDeviceTokenInternal:(NSData *)deviceToken {
    if (deviceToken == nil) {
        return;
    }

    NSString *token = [deviceToken.description stringByTrimmingCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"<>"]];
    token = [token stringByReplacingOccurrencesOfString:@" " withString:@""];

    self.deviceInfo.pushToken = token;
}

#pragma mark - private

// returns whether or not the activity state should be written
- (BOOL)updateActivityState:(double)now {
    if (![self checkActivityState]) return NO;

    double lastInterval = now - self.activityState.lastActivity;

    // ignore late updates
    if (lastInterval > kSessionInterval) return NO;

    self.activityState.lastActivity = now;

    if (lastInterval < 0) {
        [self.logger error:@"Time travel!"];
        return YES;
    } else {
        self.activityState.sessionLength += lastInterval;
        self.activityState.timeSpent += lastInterval;
    }

    return YES;
}

- (void)writeActivityState {
    [ADJUtil writeObject:self.activityState filename:kActivityStateFilename objectName:@"Activity state"];
}

- (void)writeAttribution {
    [ADJUtil writeObject:self.attribution filename:kAttributionFilename objectName:@"Attribution"];
}

- (void)readActivityState {
    [NSKeyedUnarchiver setClass:[ADJActivityState class] forClassName:@"AIActivityState"];
    self.activityState = [ADJUtil readObject:kActivityStateFilename
                                  objectName:@"Activity state"
                                       class:[ADJActivityState class]];
}

- (void)readAttribution {
    self.attribution = [ADJUtil readObject:kAttributionFilename
                                objectName:@"Attribution"
                                     class:[ADJAttribution class]];
}

- (void)transferSessionPackage:(double)now {
    ADJPackageBuilder *sessionBuilder = [[ADJPackageBuilder alloc]
                                         initWithDeviceInfo:self.deviceInfo
                                         activityState:self.activityState
                                         config:self.adjustConfig
                                         createdAt:now];
    ADJActivityPackage *sessionPackage = [sessionBuilder buildSessionPackage];
    [self.packageHandler addPackage:sessionPackage];
    [self.packageHandler sendFirstPackage];
}

# pragma mark - handlers status
- (void)updateHandlersStatusAndSendInternal {
    // check if it should stop sending

    if (![self toSend]) {
        [self pauseSending];
        return;
    }

    [self resumeSending];

    // try to send
    if (!self.adjustConfig.eventBufferingEnabled) {
        [self.packageHandler sendFirstPackage];
    }
}

- (void)pauseSending {
    [self.attributionHandler pauseSending];
    [self.packageHandler pauseSending];
}

- (void)resumeSending {
    [self.attributionHandler resumeSending];
    [self.packageHandler resumeSending];
}

// offline or disabled pauses the sdk
- (BOOL)paused {
    return [self.internalState isOffline] || ![self isEnabled];
}

- (BOOL)toSend {
    // if it's offline, disabled -> don't send
    if ([self paused]) {
        return NO;
    }

    // has the option to send in the background -> is to send
    if (self.adjustConfig.sendInBackground) {
        return YES;
    }

    // doesn't have the option -> depends on being on the background/foreground
    return [self.internalState isForeground];
}

# pragma mark - timer
- (void)startForegroundTimer {
    // don't start the timer if it's disabled/offline
    if ([self paused]) {
        return;
    }

    [self.foregroundTimer resume];
}

- (void)stopForegroundTimer {
    [self.foregroundTimer suspend];
}

- (void)foregroundTimerFiredInternal {
    if ([self paused]) {
        // stop the timer cycle if it's disabled/offline
        [self stopForegroundTimer];
        return;
    }
    [self.packageHandler sendFirstPackage];
    double now = [NSDate.date timeIntervalSince1970];
    if ([self updateActivityState:now]) {
        [self writeActivityState];
    }
}

- (void)startBackgroundTimer {
    // check if it can send in the background
    if (![self toSend]) {
        return;
    }

    // background timer already started
    if ([self.backgroundTimer fireIn] > 0) {
        return;
    }

    [self.backgroundTimer startIn:kBackgroundTimerInterval];
}

- (void)stopBackgroundTimer {
    [self.backgroundTimer cancel];
}

-(void)backgroundTimerFiredInternal {
    [self.packageHandler sendFirstPackage];
}

#pragma mark - notifications
- (void)addNotificationObserver {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center removeObserver:self];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(applicationWillResignActive)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(removeNotificationObserver)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
}

- (void)removeNotificationObserver {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - checks

- (BOOL)checkTransactionId:(NSString *)transactionId {
    if (transactionId == nil || transactionId.length == 0) {
        return YES; // no transaction ID given
    }

    if ([self.activityState findTransactionId:transactionId]) {
        [self.logger info:@"Skipping duplicate transaction ID '%@'", transactionId];
        [self.logger verbose:@"Found transaction ID in %@", self.activityState.transactionIds];
        return NO; // transaction ID found -> used already
    }
    
    [self.activityState addTransactionId:transactionId];
    [self.logger verbose:@"Added transaction ID %@", self.activityState.transactionIds];
    // activity state will get written by caller
    return YES;
}

- (BOOL)checkEvent:(ADJEvent *)event {
    if (event == nil) {
        [self.logger error:@"Event missing"];
        return NO;
    }

    if (![event isValid]) {
        [self.logger error:@"Event not initialized correctly"];
        return NO;
    }

    return YES;
}

- (BOOL)checkActivityState {
    if (self.activityState == nil) {
        [self.logger error:@"Missing activity state"];
        return NO;
    }
    return YES;
}
@end
