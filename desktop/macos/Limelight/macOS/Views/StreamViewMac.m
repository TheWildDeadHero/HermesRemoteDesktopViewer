//
//  StreamViewMac.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewMac.h"

@interface StreamViewMac ()
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSMutableArray<NSView *> *overlayViews;
@property (nonatomic) BOOL reorderingOverlays;

@end

@implementation StreamViewMac

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.spinner = [[NSProgressIndicator alloc] init];
        self.spinner.style = NSProgressIndicatorStyleSpinning;
        [self.spinner startAnimation:self];
        [self addSubview:self.spinner];
        self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        [self.spinner.widthAnchor constraintEqualToConstant:32].active = YES;
        [self.spinner.heightAnchor constraintEqualToConstant:32].active = YES;
    }
    return self;
}

- (void)setStatusText:(NSString *)statusText {
    if (statusText == nil) {
        [self.spinner stopAnimation:self];
        self.spinner.hidden = YES;
        self.window.title = self.appName;
    } else {
        self.window.title = [[self.appName stringByAppendingString:@" - "] stringByAppendingString:statusText];
    }
}

- (void)addOverlayView:(NSView *)view {
    if (self.overlayViews == nil) {
        self.overlayViews = [NSMutableArray array];
    }
    self.wantsLayer = YES;
    [self.overlayViews addObject:view];
    [self addSubview:view positioned:NSWindowAbove relativeTo:nil];
}

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    // The renderer adds (and re-creates) its video layer view at any time; keep overlays on top.
    if (self.reorderingOverlays || self.overlayViews.count == 0 || [self.overlayViews containsObject:subview]) {
        return;
    }
    self.reorderingOverlays = YES;
    for (NSView *overlay in self.overlayViews) {
        [self addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    }
    self.reorderingOverlays = NO;
}

- (void)setHidesCursor:(BOOL)hidesCursor {
    if (_hidesCursor == hidesCursor) {
        return;
    }
    _hidesCursor = hidesCursor;
    [self.window invalidateCursorRectsForView:self];
}

+ (NSCursor *)blankCursor {
    static NSCursor *cursor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    });
    return cursor;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.hidesCursor) {
        [self addCursorRect:self.bounds cursor:[StreamViewMac blankCursor]];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return [self.keyboardNotifiable onKeyboardEquivalent:event];
}

@end
