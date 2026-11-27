//
//  StreamViewMac.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "StreamViewController.h"

@interface StreamViewMac : NSView
@property (nonatomic, strong) NSString *statusText;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, weak) id<KeyboardNotifiableDelegate> keyboardNotifiable;

// Hermes: hide the Mac's cursor over the stream (the host draws its own pointer in the video)
@property (nonatomic) BOOL hidesCursor;

// Hermes: views that must stay above the video layer (session panel and its handle)
- (void)addOverlayView:(NSView *)view;

@end
