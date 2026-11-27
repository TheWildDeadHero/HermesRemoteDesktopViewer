//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import "StreamViewMac.h"
#import "AppsViewController.h"
#import "NSWindow+Moonlight.h"
#import "AlertPresenter.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"

#import "Moonlight-Swift.h"
#import "HermesBridge.h"
#import "HermesSessionActions.h"

#include "Limelight.h"

@import VideoToolbox;

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

@interface StreamViewController () <ConnectionCallbacks, KeyboardNotifiableDelegate, InputPresenceDelegate, HermesSessionActions, NSMenuItemValidation>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic) BOOL useSystemControllerDriver;
@property (nonatomic, strong) StreamManager *streamMan;
@property (nonatomic, readonly) StreamViewMac *streamView;
@property (nonatomic, strong) id windowDidExitFullScreenNotification;
@property (nonatomic, strong) id windowDidEnterFullScreenNotification;
@property (nonatomic, strong) id windowDidResignKeyNotification;
@property (nonatomic, strong) id windowDidBecomeKeyNotification;
@property (nonatomic, strong) id windowWillCloseNotification;
@property (nonatomic) int cursorHiddenCounter;

@property (nonatomic) IOPMAssertionID powerAssertionID;

// Hermes
@property (nonatomic, strong) HermesSessionPanelController *sessionPanel;
@property (nonatomic) BOOL connectionReady;
@property (nonatomic) BOOL desktopInputActive;
@property (nonatomic) int streamWidth;
@property (nonatomic) int streamHeight;
@property (nonatomic) int streamFps;
@property (nonatomic, copy) NSString *defaultSubtitle;
@property (nonatomic) HermesPointerMode sessionPointerMode;
@property (nonatomic, strong) NSScreen *targetScreen;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    
    [self prepareForStreaming];
    
    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouse];
                [weakSelf captureMouse];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf usesDesktopPointer] && [weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf.hidSupport releaseAllModifierKeys];
            [weakSelf uncaptureMouse];
            return;
        }
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if (![weakSelf isWindowInCurrentSpace] || ![weakSelf isWindowFullscreen]) {
                [weakSelf uncaptureMouse];
            }
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf usesDesktopPointer] && [weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            // Desktop pointer: input follows window focus, nothing to capture
            [weakSelf captureMouse];
            return;
        }
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        } else {
            [weakSelf uncaptureMouse];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (weakSelf.useSystemControllerDriver) {
                    [weakSelf.controllerSupport cleanup];
                }
                [weakSelf.streamMan stopStream];
            });
        }
    }];
    
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.view.window makeFirstResponder:self];
    
    self.view.window.contentAspectRatio = NSMakeSize(self.streamWidth, self.streamHeight);
    [self placeWindowOnTargetScreen];
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    if (self.sessionPanel == nil) {
        NSString *name = self.app.host.name.length > 0 ? self.app.host.name : (self.app.name ?: @"Remote desktop");
        self.sessionPanel = [[HermesSessionPanelController alloc] initWithComputerName:name actions:self];
        for (NSView *overlay in self.sessionPanel.overlayViews) {
            [self.streamView addOverlayView:overlay];
        }
        [self.sessionPanel layoutInBounds:self.streamView.bounds];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidExitFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEnterFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowWillCloseNotification];

    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
    
    if (event.modifierFlags == 786721 && !self.usesDesktopPointer) {
        [self.hidSupport releaseAllModifierKeys];
        [self uncaptureMouse];
    }
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    if (self.sessionPanel.isOpen) {
        // Clicking the picture closes the panel, like Chrome Remote Desktop
        [self.sessionPanel close];
        return;
    }
    if (self.usesDesktopPointer) {
        [self captureMouse];
        [self sendAbsolutePositionForEvent:event];
        [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
        return;
    }
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
    [self captureMouse];
}

- (void)mouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_LEFT];
}

- (void)rightMouseDown:(NSEvent *)event {
    if (self.sessionPanel.isOpen) {
        return;
    }
    [self sendAbsolutePositionForEvent:event];
    [self.hidSupport mouseDown:event withButton:BUTTON_RIGHT];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_RIGHT];
}

- (void)otherMouseDown:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)otherMouseUp:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseUp:event withButton:button];
}

- (void)mouseMoved:(NSEvent *)event {
    [self sendAbsolutePositionForEvent:event];
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self sendAbsolutePositionForEvent:event];
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self sendAbsolutePositionForEvent:event];
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self sendAbsolutePositionForEvent:event];
    [self.hidSupport mouseMoved:event];
}

#pragma mark - Hermes desktop pointer

- (BOOL)usesDesktopPointer {
    return self.sessionPointerMode == HermesPointerModeDesktop;
}

- (void)placeWindowOnTargetScreen {
    NSWindow *window = self.view.window;
    NSScreen *screen = self.targetScreen ?: window.screen ?: [NSScreen mainScreen];
    if (window == nil || screen == nil || self.streamWidth <= 0 || self.streamHeight <= 0) {
        return;
    }
    NSRect visible = screen.visibleFrame;
    CGFloat aspect = (CGFloat)self.streamWidth / (CGFloat)self.streamHeight;
    CGFloat width = NSWidth(visible) * 0.85;
    CGFloat height = width / aspect;
    if (height > NSHeight(visible) * 0.85) {
        height = NSHeight(visible) * 0.85;
        width = height * aspect;
    }
    NSRect content = NSMakeRect(0, 0, width, height);
    NSRect frame = [window frameRectForContentRect:content];
    frame.origin.x = NSMidX(visible) - NSWidth(frame) / 2;
    frame.origin.y = NSMidY(visible) - NSHeight(frame) / 2;
    [window setFrame:frame display:YES];
}

/// Where the remote picture is drawn inside `bounds` for the current Fit / Fill / Stretch mode.
- (NSRect)videoRectInBounds:(NSRect)bounds {
    if (self.streamWidth <= 0 || self.streamHeight <= 0) {
        return NSZeroRect;
    }
    HermesScaleMode mode = [HermesSettings scaleMode];
    if (mode == HermesScaleModeStretch) {
        return bounds;
    }
    CGFloat sx = NSWidth(bounds) / self.streamWidth;
    CGFloat sy = NSHeight(bounds) / self.streamHeight;
    CGFloat scale = (mode == HermesScaleModeFill) ? MAX(sx, sy) : MIN(sx, sy);
    CGFloat w = self.streamWidth * scale;
    CGFloat h = self.streamHeight * scale;
    return NSMakeRect(NSMidX(bounds) - w / 2, NSMidY(bounds) - h / 2, w, h);
}

- (void)sendAbsolutePositionForEvent:(NSEvent *)event {
    if (!self.usesDesktopPointer || !self.desktopInputActive || !self.hidSupport.shouldSendInputEvents) {
        return;
    }
    NSPoint p = [self.streamView convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, self.streamView.bounds)) {
        return;
    }
    NSRect video = [self videoRectInBounds:self.streamView.bounds];
    if (NSWidth(video) <= 0 || NSHeight(video) <= 0) {
        return;
    }
    CGFloat x = (p.x - NSMinX(video)) / NSWidth(video) * self.streamWidth;
    CGFloat y = (self.streamView.isFlipped ? (p.y - NSMinY(video)) : (NSMaxY(video) - p.y)) / NSHeight(video) * self.streamHeight;
    // Over the letterbox bars, pin to the nearest edge of the picture
    x = MAX(0, MIN(x, self.streamWidth - 1));
    y = MAX(0, MIN(y, self.streamHeight - 1));
    LiSendMousePositionEvent((short)x, (short)y, (short)self.streamWidth, (short)self.streamHeight);
}

- (void)activateDesktopInput {
    if (!self.connectionReady || self.sessionPanel.isOpen || !self.view.window.isKeyWindow) {
        return;
    }
    self.desktopInputActive = YES;
    self.hidSupport.absolutePointer = YES;
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;
    self.streamView.hidesCursor = YES;
    [self disallowDisplaySleep];
}

- (void)deactivateDesktopInput {
    if (self.desktopInputActive && self.connectionReady) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    }
    self.desktopInputActive = NO;
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.streamView.hidesCursor = NO;
    [self allowDisplaySleep];
}

- (void)scrollWheel:(NSEvent *)event {
    [self.hidSupport scrollWheel:event];
}

- (int)getMouseButtonFromEvent:(NSEvent *)event {
    int button;
    switch (event.buttonNumber) {
        case 2:
            button = BUTTON_MIDDLE;
            break;
        case 3:
            button = BUTTON_X1;
            break;
        case 4:
            button = BUTTON_X2;
            break;
        default:
            return 0;
            break;
    }
    
    return button;
}


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    const NSEventModifierFlags modifierFlags = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction;
    const NSEventModifierFlags eventModifierFlags = event.modifierFlags & modifierFlags;

    // While the session panel is open, shortcuts belong to this Mac
    if (self.sessionPanel.isOpen) {
        return NO;
    }

    // Hermes' Session menu shortcuts (⌃⌥⌘S / V / C) stay on this Mac
    if (eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)
        && (event.keyCode == kVK_ANSI_S || event.keyCode == kVK_ANSI_V || event.keyCode == kVK_ANSI_C)) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if (event.keyCode == kVK_ANSI_1 && eventModifierFlags == NSEventModifierFlagCommand) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if ((event.keyCode == kVK_ANSI_Grave && eventModifierFlags == NSEventModifierFlagCommand)
        || (event.keyCode == kVK_ANSI_H && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        if (![self isWindowFullscreen]) {
            [self.hidSupport releaseAllModifierKeys];
            return NO;
        }
    }
    
    if ((event.keyCode == kVK_ANSI_F && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_F && eventModifierFlags == NSEventModifierFlagFunction)
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagShift | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions


- (IBAction)performClose:(id)sender {
    [self uncaptureMouse];
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Disconnect from Stream, or Close and Quit App?";

    [alert addButtonWithTitle:@"Disconnect from Stream"];
    [alert addButtonWithTitle:@"Close and Quit App"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    switch (response) {
        case NSAlertFirstButtonReturn:
            [self doCommandBySelector:@selector(performCloseStreamWindow:)];
            break;
            
        case NSAlertSecondButtonReturn:
            [self doCommandBySelector:@selector(performCloseAndQuitApp:)];
            break;

        default:
            break;
    }
}

- (IBAction)performCloseStreamWindow:(id)sender {
    [self.hidSupport releaseAllModifierKeys];
    [self.nextResponder doCommandBySelector:@selector(performClose:)];
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self.delegate quitApp:self.app completion:nil];
}

- (IBAction)resizeWindowToActualResulution:(id)sender {
    CGFloat screenScale = self.view.window.backingScaleFactor > 0 ? self.view.window.backingScaleFactor : [NSScreen mainScreen].backingScaleFactor;
    CGFloat width = (CGFloat)self.streamWidth / screenScale;
    CGFloat height = (CGFloat)self.streamHeight / screenScale;
    [self.view.window setContentSize:NSMakeSize(width, height)];
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    appMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
}

- (void)captureMouse {
    if (self.sessionPanel.isOpen) {
        return;
    }
    if (self.usesDesktopPointer) {
        [self activateDesktopInput];
        return;
    }
    self.hidSupport.absolutePointer = NO;
    CGAssociateMouseAndMouseCursorPosition(NO);
    if (self.cursorHiddenCounter == 0) {
        [NSCursor hide];
        self.cursorHiddenCounter ++;
    }
    
    CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
    CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
    CGFloat screenHeight = self.view.window.screen.frame.size.height;
    CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
    CGWarpMouseCursorPosition(cursorPoint);
    
    [self enableMenuItems:NO];
    
    [self disallowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;
}

- (void)uncaptureMouse {
    if (self.usesDesktopPointer) {
        [self deactivateDesktopInput];
        return;
    }
    CGAssociateMouseAndMouseCursorPosition(YES);
    if (self.cursorHiddenCounter != 0) {
        [NSCursor unhide];
        self.cursorHiddenCounter --;
    }
    
    [self enableMenuItems:YES];
    
    [self allowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.view.window.acceptsMouseMovedEvents = NO;
}

- (BOOL)isWindowInCurrentSpace {
    BOOL found = NO;
    CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *thisWindow in (__bridge NSArray *)windowsInSpace) {
        NSNumber *thisWindowNumber = (NSNumber *)thisWindow[(__bridge NSString *)kCGWindowNumber];
        if (self.view.window.windowNumber == thisWindowNumber.integerValue) {
            found = YES;
            break;
        }
    }
    if (windowsInSpace != NULL) {
        CFRelease(windowsInSpace);
    }
    return found;
}

- (BOOL)isWindowFullscreen {
    return [self.view.window styleMask] & NSWindowStyleMaskFullScreen;
}

- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note {
    return ((NSWindow *)note.object) == self.view.window;
}

- (NSMenuItem *)itemWithMenu:(NSMenu *)menu andAction:(SEL)action {
    return [menu itemAtIndex:[menu indexOfItemWithTarget:nil andAction:action]];
}


- (void)disallowDisplaySleep {
    if (self.powerAssertionID != 0) {
        return;
    }
    
    CFStringRef reasonForActivity= CFSTR("Moonlight streaming");
    
    IOPMAssertionID assertionID;
    IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    
    if (success == kIOReturnSuccess) {
        self.powerAssertionID = assertionID;
    } else {
        self.powerAssertionID = 0;
    }
}

- (void)allowDisplaySleep {
    if (self.powerAssertionID != 0) {
        IOPMAssertionRelease(self.powerAssertionID);
        self.powerAssertionID = 0;
    }
}

- (void)closeWindowFromMainQueueWithMessage:(NSString *)message {
    [self.hidSupport releaseAllModifierKeys];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uncaptureMouse];

        [self.delegate appDidQuit:self.app];
        if (message != nil) {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Connection Failed" message:message window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                [self.view.window close];
            }];
        } else {
            [self.view.window close];
        }
    });
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.appID = self.app.id;
    streamConfig.appName = self.app.name;
    streamConfig.serverCert = self.app.host.serverCert;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    self.targetScreen = [HermesSettings preferredScreen];
    if ([HermesSettings matchDisplay]) {
        // Same HEVC decision Connection.m makes, plus whether the host can encode HEVC
        BOOL hostHevc = (self.app.host.serverCodecModeSupport & 0x0300) != 0;
        BOOL hevc = (streamSettings.useHevc || streamSettings.enableHdr) && hostHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
        CGSize size = [HermesSettings displayResolutionForScreen:self.targetScreen allowHevc:hevc];
        streamConfig.width = (int)size.width;
        streamConfig.height = (int)size.height;
    } else {
        struct Resolution resolution = [self.class getResolution];
        streamConfig.width = resolution.width;
        streamConfig.height = resolution.height;
    }
    self.streamWidth = streamConfig.width;
    self.streamHeight = streamConfig.height;

    streamConfig.frameRate = [streamSettings.framerate intValue];
    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.allowHevc = streamSettings.useHevc;
    streamConfig.enableHdr = streamSettings.useHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? streamSettings.enableHdr : NO;

    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = self.useSystemControllerDriver ? [ControllerSupport getConnectedGamepadMask:streamConfig] : 1;
    
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;

    // Apollo: give the stream its own virtual display at exactly this size. (Apollo's
    // scaleFactor multiplies the render resolution, so 100 keeps it pixel-for-pixel.)
    streamConfig.useVirtualDisplay = [HermesSettings useVirtualDisplay] && self.app.host.vDisplaySupported && self.app.host.vDisplayDriverReady;
    streamConfig.scaleFactor = 100;
    self.streamFps = streamConfig.frameRate;

    if (self.useSystemControllerDriver) {
        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.sessionPointerMode = [HermesSettings pointerMode];
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    self.hidSupport.absolutePointer = self.usesDesktopPointer;
    
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:self.streamMan];
}


#pragma mark - Resolution

+ (struct Resolution)getResolution {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution resolution;
    
    resolution.width = [streamSettings.width intValue];
    resolution.height = [streamSettings.height intValue];

    return resolution;
}


#pragma mark - ConnectionCallbacks

- (void)stageStarting:(const char *)stageName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString *titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        self.streamView.statusText = titleCase;
    });
}

- (void)stageComplete:(const char *)stageName {
}

- (void)connectionStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamView.statusText = nil;
        self.connectionReady = YES;
        
        if ([SettingsClass autoFullscreenFor:self.app.host.uuid]) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        } else {
            [self captureMouse];
        }
        if (self.usesDesktopPointer) {
            // Desktop pointer doesn't depend on full screen; start sending input right away
            [self captureMouse];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", errorCode);
    [self closeWindowFromMainQueueWithMessage:nil];
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    [self closeWindowFromMainQueueWithMessage:message];
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if ([SettingsClass rumbleFor:self.app.host.uuid]) {
        if (self.hidSupport.shouldSendInputEvents) {
            if (self.controllerSupport != nil) {
                [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            } else {
                [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            }
        }
    }
}

- (void)connectionStatusUpdate:(int)status {
}


#pragma mark - Hermes session actions

static char hermesModifierForVK(short vk) {
    switch (vk) {
        case 0xA0: case 0xA1: case 0x10: return MODIFIER_SHIFT;
        case 0xA2: case 0xA3: case 0x11: return MODIFIER_CTRL;
        case 0xA4: case 0xA5: case 0x12: return MODIFIER_ALT;
        case 0x5B: case 0x5C: return MODIFIER_META;
        default: return 0;
    }
}

- (void)hermesSendKeyCombo:(NSArray<NSNumber *> *)virtualKeys {
    if (!self.connectionReady || virtualKeys.count == 0) {
        return;
    }
    char modifiers = 0;
    for (NSNumber *key in virtualKeys) {
        short vk = key.shortValue;
        modifiers |= hermesModifierForVK(vk);
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_DOWN, modifiers);
    }
    for (NSNumber *key in [virtualKeys reverseObjectEnumerator]) {
        short vk = key.shortValue;
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_UP, modifiers);
        modifiers &= ~hermesModifierForVK(vk);
    }
}

- (void)hermesSetScaleMode:(NSInteger)mode {
    [HermesSettings setScaleMode:(HermesScaleMode)mode];
}

- (void)hermesSetPointerMode:(NSInteger)mode {
    // Fully release whichever mode is active before switching
    [self.hidSupport releaseAllModifierKeys];
    [self uncaptureMouse];
    [HermesSettings setPointerMode:(HermesPointerMode)mode];
    self.sessionPointerMode = (HermesPointerMode)mode;
    self.hidSupport.absolutePointer = self.usesDesktopPointer;
    // Desktop pointer resumes as soon as the panel closes; captured mode waits for a click
}

- (void)hermesToggleFullScreen {
    [self.view.window toggleFullScreen:self];
}

- (BOOL)hermesIsFullScreen {
    return [self isWindowFullscreen];
}

- (void)hermesResizeToActualSize {
    if ([self isWindowFullscreen]) {
        return;
    }
    [self resizeWindowToActualResulution:self];
}

- (void)hermesFlashStatus:(NSString *)message {
    if (self.sessionPanel.isOpen) {
        [self.sessionPanel showMessage:message];
        return;
    }
    NSWindow *window = self.view.window;
    window.subtitle = message;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([window.subtitle isEqualToString:message]) {
            window.subtitle = @"";
        }
    });
}

- (void)hermesSendClipboard {
    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (text.length == 0) {
        [self hermesFlashStatus:@"Your clipboard doesn't contain any text."];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [HermesHostActions sendClipboard:text toHost:self.app.host completion:^(BOOL success, NSString *error) {
        [weakSelf hermesFlashStatus:success ? @"Clipboard sent. Paste it on the computer." : error];
    }];
}

- (void)hermesGetClipboard {
    __weak typeof(self) weakSelf = self;
    [HermesHostActions getClipboardFromHost:self.app.host completion:^(NSString *text, NSString *error) {
        if (text != nil) {
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
            [weakSelf hermesFlashStatus:@"Copied the computer's clipboard to this Mac."];
        } else {
            [weakSelf hermesFlashStatus:error];
        }
    }];
}

- (void)hermesDisconnect {
    [self performCloseStreamWindow:self];
}

- (void)hermesEndSession {
    [self.hidSupport releaseAllModifierKeys];
    [self performCloseAndQuitApp:self];
}

- (NSString *)hermesStatsText {
    NSMutableString *text = [NSMutableString stringWithFormat:@"%d×%d · %d fps", self.streamWidth, self.streamHeight, self.streamFps];
    uint32_t rtt = 0, rttVariance = 0;
    if (self.connectionReady && LiGetEstimatedRttInfo(&rtt, &rttVariance)) {
        [text appendFormat:@" · %u ms", rtt];
    }
    return text;
}

- (void)hermesPanelVisibilityChanged:(BOOL)visible {
    if (visible) {
        [self.hidSupport releaseAllModifierKeys];
        [self uncaptureMouse];
    } else {
        [self.view.window makeFirstResponder:self];
        if (self.usesDesktopPointer) {
            [self captureMouse];
        }
    }
}

#pragma mark - Hermes Session menu

- (IBAction)hermesToggleSessionPanel:(id)sender {
    [self.sessionPanel toggle];
}

- (IBAction)hermesSendClipboard:(id)sender {
    [self hermesSendClipboard];
}

- (IBAction)hermesGetClipboard:(id)sender {
    [self hermesGetClipboard];
}

- (IBAction)hermesSendTaskManager:(id)sender {
    [self hermesSendKeyCombo:@[@0xA2, @0xA0, @0x1B]];
}

- (IBAction)hermesSendWindowsKey:(id)sender {
    [self hermesSendKeyCombo:@[@0x5B]];
}

- (IBAction)hermesSendAltTab:(id)sender {
    [self hermesSendKeyCombo:@[@0xA4, @0x09]];
}

- (IBAction)hermesScaleFit:(id)sender {
    [self hermesSetScaleMode:HermesScaleModeFit];
}

- (IBAction)hermesScaleFill:(id)sender {
    [self hermesSetScaleMode:HermesScaleModeFill];
}

- (IBAction)hermesScaleStretch:(id)sender {
    [self hermesSetScaleMode:HermesScaleModeStretch];
}

- (IBAction)hermesPointerDesktop:(id)sender {
    [self hermesSetPointerMode:HermesPointerModeDesktop];
    [self captureMouse];
}

- (IBAction)hermesPointerCaptured:(id)sender {
    [self hermesSetPointerMode:HermesPointerModeCaptured];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = menuItem.action;
    if (action == @selector(hermesScaleFit:)) {
        menuItem.state = [HermesSettings scaleMode] == HermesScaleModeFit ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(hermesScaleFill:)) {
        menuItem.state = [HermesSettings scaleMode] == HermesScaleModeFill ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(hermesScaleStretch:)) {
        menuItem.state = [HermesSettings scaleMode] == HermesScaleModeStretch ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(hermesPointerDesktop:)) {
        menuItem.state = self.usesDesktopPointer ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (action == @selector(hermesPointerCaptured:)) {
        menuItem.state = self.usesDesktopPointer ? NSControlStateValueOff : NSControlStateValueOn;
    } else if (action == @selector(hermesToggleSessionPanel:)) {
        menuItem.title = self.sessionPanel.isOpen ? @"Hide Session Controls" : @"Show Session Controls";
    }
    return YES;
}

#pragma mark - InputPresenceDelegate

- (void)gamepadPresenceChanged {
}

- (void)mousePresenceChanged {
}

@end
