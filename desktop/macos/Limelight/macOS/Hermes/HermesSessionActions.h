//
//  HermesSessionActions.h
//  Hermes for macOS
//
//  What the in-session panel (SwiftUI) can ask the stream (StreamViewController) to do.
//  Modes are passed as NSInteger raw values of HermesScaleMode / HermesPointerMode.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol HermesSessionActions <NSObject>

/// Presses the Windows virtual-key codes in order, then releases them in reverse.
- (void)hermesSendKeyCombo:(NSArray<NSNumber *> *)virtualKeys NS_SWIFT_NAME(sendKeyCombo(_:));

- (void)hermesSetScaleMode:(NSInteger)mode NS_SWIFT_NAME(setScaleMode(_:));
- (void)hermesSetPointerMode:(NSInteger)mode NS_SWIFT_NAME(setPointerMode(_:));

- (void)hermesToggleFullScreen NS_SWIFT_NAME(toggleFullScreen());
- (BOOL)hermesIsFullScreen NS_SWIFT_NAME(isFullScreen());
- (void)hermesResizeToActualSize NS_SWIFT_NAME(resizeToActualSize());

- (void)hermesSendClipboard NS_SWIFT_NAME(sendClipboard());
- (void)hermesGetClipboard NS_SWIFT_NAME(getClipboard());

- (void)hermesDisconnect NS_SWIFT_NAME(disconnect());
- (void)hermesEndSession NS_SWIFT_NAME(endSession());

/// One-line connection summary, e.g. "2560×1600 · 60 fps · 4 ms round trip".
- (NSString *)hermesStatsText NS_SWIFT_NAME(statsText());

/// Called when the panel opens or closes, so input can be paused while it's open.
- (void)hermesPanelVisibilityChanged:(BOOL)visible NS_SWIFT_NAME(panelVisibilityChanged(_:));

@end

NS_ASSUME_NONNULL_END
