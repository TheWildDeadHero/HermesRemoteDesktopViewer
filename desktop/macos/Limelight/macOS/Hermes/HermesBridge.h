//
//  HermesBridge.h
//  Hermes for macOS
//
//  A thin Objective-C layer between the SwiftUI interface and Moonlight's
//  Objective-C core (discovery, pairing, HTTP, streaming). Every method has an
//  explicit NS_SWIFT_NAME so the Swift side never depends on importer guesses.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryHost.h"
#import "TemporaryApp.h"

NS_ASSUME_NONNULL_BEGIN

/// Owns Moonlight's DiscoveryManager (mDNS + serverinfo polling) and the saved host list.
NS_SWIFT_NAME(HermesHostDirectory)
@interface HermesHostDirectory : NSObject

/// Called on the main queue whenever a host is added or removed.
@property (nonatomic, copy, nullable) void (^onListChanged)(void) NS_SWIFT_NAME(onListChanged);

/// Snapshot of all known hosts, sorted by name. Host objects are live and their state
/// is updated in place by the discovery workers.
@property (nonatomic, readonly) NSArray<TemporaryHost *> *hosts;

- (void)start NS_SWIFT_NAME(start());
- (void)stop NS_SWIFT_NAME(stop());
/// Stops polling and waits for in-flight polls to finish (required before pairing).
- (void)pauseBlocking NS_SWIFT_NAME(pauseBlocking());

- (void)addHostWithAddress:(NSString *)address
                completion:(void (^)(TemporaryHost * _Nullable host, NSString * _Nullable error))completion
    NS_SWIFT_NAME(addHost(address:completion:));
- (void)removeHost:(TemporaryHost *)host NS_SWIFT_NAME(remove(_:));
- (void)saveHost:(TemporaryHost *)host NS_SWIFT_NAME(save(_:));

@end

/// One-shot operations against a host. All completions run on the main queue.
NS_SWIFT_NAME(HermesHostActions)
@interface HermesHostActions : NSObject

+ (void)wakeHost:(TemporaryHost *)host NS_SWIFT_NAME(wake(_:));

+ (void)fetchAppsForHost:(TemporaryHost *)host
              completion:(void (^)(NSArray<TemporaryApp *> * _Nullable apps, NSString * _Nullable error))completion
    NS_SWIFT_NAME(fetchApps(for:completion:));

/// Ends the running session on the host (Apollo closes the virtual display).
+ (void)quitSessionOnHost:(TemporaryHost *)host
               completion:(void (^)(BOOL success))completion
    NS_SWIFT_NAME(quitSession(on:completion:));

+ (void)unpairHost:(TemporaryHost *)host
        completion:(void (^)(BOOL success, NSString * _Nullable error))completion
    NS_SWIFT_NAME(unpair(_:completion:));

/// Pairs with the host. If otpPin + passphrase are given (Apollo one-time PIN), no PIN is shown.
/// onShowPin is called with a PIN the user must type into Apollo (classic pairing only).
+ (void)pairHost:(TemporaryHost *)host
          otpPin:(nullable NSString *)otpPin
      passphrase:(nullable NSString *)passphrase
       onShowPin:(void (^)(NSString *pin))onShowPin
      completion:(void (^)(BOOL success, NSString * _Nullable error))completion
    NS_SWIFT_NAME(pair(_:otpPin:passphrase:onShowPin:completion:));

+ (void)getClipboardFromHost:(TemporaryHost *)host
                  completion:(void (^)(NSString * _Nullable text, NSString * _Nullable error))completion
    NS_SWIFT_NAME(getClipboard(from:completion:));

+ (void)sendClipboard:(NSString *)text
               toHost:(TemporaryHost *)host
           completion:(void (^)(BOOL success, NSString * _Nullable error))completion
    NS_SWIFT_NAME(sendClipboard(_:to:completion:));

/// Opens a stream window for the given app. `onSessionEnded` runs (main queue) when the
/// stream window closes or the host session ends.
+ (NSWindowController *)openStreamWindowForApp:(TemporaryApp *)app
                                onSessionEnded:(void (^)(void))onSessionEnded
    NS_SWIFT_NAME(openStreamWindow(for:onSessionEnded:));

/// Builds an app record for a host (used to resume a session that's already running).
+ (TemporaryApp *)appWithId:(NSString *)appId name:(NSString *)name host:(TemporaryHost *)host
    NS_SWIFT_NAME(makeApp(id:name:host:));

@end

NS_ASSUME_NONNULL_END
