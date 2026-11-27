//
//  HermesBridge.m
//  Hermes for macOS
//

#import "HermesBridge.h"

#import <objc/runtime.h>

#import "AppListResponse.h"
#import "AppsViewControllerDelegate.h"
#import "ConnectionHelper.h"
#import "CryptoManager.h"
#import "DataManager.h"
#import "DiscoveryManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "IdManager.h"
#import "PairManager.h"
#import "ServerInfoResponse.h"
#import "StreamViewController.h"
#import "WakeOnLanManager.h"

#pragma mark - Host directory

@interface HermesHostDirectory () <DiscoveryCallback>
@end

@implementation HermesHostDirectory {
    DiscoveryManager *_discovery;
    NSMutableArray<TemporaryHost *> *_hosts;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Discovery and pairing need our client certificate
        [CryptoManager generateKeyPairUsingSSL];

        _hosts = [NSMutableArray array];
        DataManager *dataMan = [[DataManager alloc] init];
        for (TemporaryHost *host in [dataMan getHosts]) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
            [_hosts addObject:host];
        }
        _discovery = [[DiscoveryManager alloc] initWithHosts:[_hosts copy] andCallback:self];
    }
    return self;
}

- (NSArray<TemporaryHost *> *)hosts {
    @synchronized (self) {
        return [_hosts sortedArrayUsingSelector:@selector(compareName:)];
    }
}

- (void)start {
    [_discovery startDiscovery];
}

- (void)stop {
    [_discovery stopDiscovery];
}

- (void)pauseBlocking {
    [_discovery stopDiscoveryBlocking];
}

- (void)notifyChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onListChanged) {
            self.onListChanged();
        }
    });
}

- (void)addHostWithAddress:(NSString *)address
                completion:(void (^)(TemporaryHost * _Nullable, NSString * _Nullable))completion {
    NSString *trimmed = [address stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Accept "[::1]" style IPv6 literals as well as bare ones
    if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"] && trimmed.length > 2) {
        trimmed = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self->_discovery discoverHost:trimmed withCallback:^(TemporaryHost *host, NSString *error) {
            if (host != nil) {
                DataManager *dataMan = [[DataManager alloc] init];
                [dataMan updateHost:host];
                @synchronized (self) {
                    BOOL known = NO;
                    for (TemporaryHost *existing in self->_hosts) {
                        if ([existing.uuid isEqualToString:host.uuid]) {
                            known = YES;
                            break;
                        }
                    }
                    if (!known) {
                        [self->_hosts addObject:host];
                    }
                }
                [self notifyChanged];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(host, host == nil ? (error ?: @"Couldn't add that computer.") : nil);
            });
        }];
    });
}

- (void)removeHost:(TemporaryHost *)host {
    [_discovery removeHostFromDiscovery:host];
    [[[DataManager alloc] init] removeHost:host];
    @synchronized (self) {
        [_hosts removeObject:host];
    }
    [self notifyChanged];
}

- (void)saveHost:(TemporaryHost *)host {
    [[[DataManager alloc] init] updateHost:host];
}

#pragma mark DiscoveryCallback

- (void)updateAllHosts:(NSArray *)hosts {
    // Called from discovery threads with discovery's own (mutable) array
    @synchronized (self) {
        _hosts = [hosts mutableCopy];
    }
    [self notifyChanged];
}

@end

#pragma mark - Pairing callback adapter

@interface HermesPairCallback : NSObject <PairCallback>
@property (nonatomic, copy) void (^onShowPin)(NSString *pin);
@property (nonatomic, copy) void (^completion)(BOOL success, NSString *error, NSData *serverCert);
@property (nonatomic) BOOL usesOtp;
@end

@implementation HermesPairCallback

- (void)startPairing:(NSString *)PIN {
    if (!self.usesOtp) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onShowPin(PIN);
        });
    }
}

- (void)pairSuccessful:(NSData *)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.completion(YES, nil, serverCert);
    });
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.completion(NO, message ?: @"Pairing failed.", nil);
    });
}

- (void)alreadyPaired {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.completion(YES, nil, nil);
    });
}

@end

#pragma mark - Stream window delegate adapter

@interface HermesStreamDelegate : NSObject <AppsViewControllerDelegate>
@end

@implementation HermesStreamDelegate

- (void)openApp:(TemporaryApp *)app {
}

- (void)quitApp:(TemporaryApp *)app completion:(void (^)(BOOL))completion {
    [HermesHostActions quitSessionOnHost:app.host completion:^(BOOL success) {
        if (!success) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Couldn't end the session";
            alert.informativeText = @"If the session was started from another device, end it from that device.";
            [alert runModal];
        }
        if (completion != nil) {
            completion(success);
        }
    }];
}

- (void)appDidQuit:(TemporaryApp *)app {
    // The stream window may still be open (e.g. showing a connection error); the
    // session is only over for Hermes once that window closes.
}

- (void)didOpenContextMenu:(NSMenu *)menu forApp:(TemporaryApp *)app {
}

- (void)didHover:(BOOL)hovered forApp:(TemporaryApp *)app {
}

@end

#pragma mark - Host actions

@implementation HermesHostActions

+ (HttpManager *)httpManagerForHost:(TemporaryHost *)host {
    return [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:host.serverCert];
}

+ (void)wakeHost:(TemporaryHost *)host {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [WakeOnLanManager wakeHost:host];
    });
}

+ (void)fetchAppsForHost:(TemporaryHost *)host
              completion:(void (^)(NSArray<TemporaryApp *> * _Nullable, NSString * _Nullable))completion {
    NSString *address = host.activeAddress;
    NSData *cert = host.serverCert;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (address == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"This computer can't be reached right now.");
            });
            return;
        }
        AppListResponse *resp = [ConnectionHelper getAppListForHostWithHostIP:address serverCert:cert uniqueID:[IdManager getUniqueId]];
        NSSet *list = (resp != nil && [resp isStatusOk]) ? [resp getAppList] : nil;
        NSMutableArray<TemporaryApp *> *apps = nil;
        if (list != nil) {
            apps = [NSMutableArray array];
            for (TemporaryApp *app in list) {
                app.host = host;
                [apps addObject:app];
            }
            [apps sortUsingSelector:@selector(compareName:)];
        }
        NSString *error = nil;
        if (apps == nil) {
            error = resp.statusMessage.length > 0 ? resp.statusMessage : @"The computer didn't respond.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(apps, error);
        });
    });
}

+ (void)quitSessionOnHost:(TemporaryHost *)host completion:(void (^)(BOOL))completion {
    HttpManager *hMan = [self httpManagerForHost:host];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]]];
        BOOL ok = quitResponse.statusCode == 200;
        if (ok) {
            // Newer hosts report success even when another client's session survived the request
            ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:NO] fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                ok = NO;
            } else {
                host.currentGame = @"0";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok);
        });
    });
}

+ (void)unpairHost:(TemporaryHost *)host completion:(void (^)(BOOL, NSString * _Nullable))completion {
    HttpManager *hMan = [self httpManagerForHost:host];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        HttpResponse *resp = [[HttpResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resp withUrlRequest:[hMan newUnpairRequest]]];
        BOOL ok = [resp isStatusOk];
        if (ok) {
            host.pairState = PairStateUnpaired;
            host.serverCert = nil;
            [[[DataManager alloc] init] updateHost:host];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, ok ? nil : (resp.statusMessage ?: @"The computer didn't respond."));
        });
    });
}

+ (void)pairHost:(TemporaryHost *)host
          otpPin:(NSString *)otpPin
      passphrase:(NSString *)passphrase
       onShowPin:(void (^)(NSString * _Nonnull))onShowPin
      completion:(void (^)(BOOL, NSString * _Nullable))completion {
    BOOL otp = otpPin.length > 0 && passphrase.length > 0;
    HermesPairCallback *callback = [[HermesPairCallback alloc] init];
    callback.usesOtp = otp;
    callback.onShowPin = onShowPin;
    callback.completion = ^(BOOL success, NSString *error, NSData *serverCert) {
        if (success) {
            if (serverCert != nil) {
                host.serverCert = serverCert;
            }
            host.pairState = PairStatePaired;
            [[[DataManager alloc] init] updateHost:host];
        }
        completion(success, error);
    };

    HttpManager *hMan = [self httpManagerForHost:host];
    NSData *cert = [CryptoManager readCertFromFile];
    PairManager *pMan = otp
        ? [[PairManager alloc] initWithManager:hMan clientCert:cert otpPin:otpPin passphrase:passphrase callback:callback]
        : [[PairManager alloc] initWithManager:hMan clientCert:cert callback:callback];

    // The operation keeps the callback alive until pairing finishes
    static NSOperationQueue *pairQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pairQueue = [[NSOperationQueue alloc] init];
        pairQueue.maxConcurrentOperationCount = 1;
    });
    [pairQueue addOperation:pMan];
}

+ (void)getClipboardFromHost:(TemporaryHost *)host
                  completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {
    HttpManager *hMan = [self httpManagerForHost:host];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger status = 0;
        NSData *body = [hMan executeRawRequestSynchronously:[hMan newGetClipboardRequest] statusCode:&status];
        NSString *text = nil;
        NSString *error = nil;
        if (body != nil && status == 200) {
            text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            // Hosts without clipboard support answer with a 200 and an XML error body
            NSString *head = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([head hasPrefix:@"<?xml"] || ([head hasPrefix:@"<root"] && [head containsString:@"status_code"])) {
                text = nil;
            }
        }
        if (text == nil) {
            error = (status == 401 || status == 403)
                ? @"Apollo didn't allow clipboard access. Give this device the clipboard permission in Apollo's client settings."
                : @"Couldn't read the computer's clipboard. Clipboard sync needs Apollo and an active session.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(text, error);
        });
    });
}

+ (void)sendClipboard:(NSString *)text
               toHost:(TemporaryHost *)host
           completion:(void (^)(BOOL, NSString * _Nullable))completion {
    HttpManager *hMan = [self httpManagerForHost:host];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger status = 0;
        NSData *body = [hMan executeRawRequestSynchronously:[hMan newSendClipboardRequest:text] statusCode:&status];
        // Sunshine answers unsupported endpoints with a 200 + XML 404 body; Apollo's success is an empty body
        BOOL ok = body != nil && status == 200 && body.length == 0;
        NSString *error = nil;
        if (!ok) {
            error = (status == 401 || status == 403)
                ? @"Apollo didn't allow clipboard access. Give this device the clipboard permission in Apollo's client settings."
                : @"Couldn't send the clipboard. Clipboard sync needs Apollo and an active session.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    });
}

+ (NSWindowController *)openStreamWindowForApp:(TemporaryApp *)app onSessionEnded:(void (^)(void))onSessionEnded {
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    StreamViewController *streamVC = [storyboard instantiateControllerWithIdentifier:@"streamVC"];

    HermesStreamDelegate *delegate = [[HermesStreamDelegate alloc] init];
    streamVC.app = app;
    streamVC.delegate = delegate; // weak; kept alive below

    NSWindow *window = [NSWindow windowWithContentViewController:streamVC];
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window.releasedWhenClosed = NO;
    window.title = app.host.name ?: @"Hermes";
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    NSWindowController *controller = [[NSWindowController alloc] initWithWindow:window];

    // Keep the delegate (weakly referenced by the stream VC) alive as long as the window
    static char kDelegateKey;
    objc_setAssociatedObject(window, &kDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __block id closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:window queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
        closeObserver = nil;
        if (onSessionEnded) {
            onSessionEnded();
        }
    }];

    [controller showWindow:nil];
    return controller;
}

+ (TemporaryApp *)appWithId:(NSString *)appId name:(NSString *)name host:(TemporaryHost *)host {
    TemporaryApp *app = [[TemporaryApp alloc] init];
    app.id = appId;
    app.name = name;
    app.host = host;
    return app;
}

@end
