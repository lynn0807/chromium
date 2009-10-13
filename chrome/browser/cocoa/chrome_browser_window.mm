// Copyright (c) 2009 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/cocoa/chrome_browser_window.h"

#include "base/logging.h"
#import "chrome/browser/cocoa/browser_window_controller.h"
#import "chrome/browser/cocoa/browser_frame_view.h"
#import "chrome/browser/cocoa/tab_strip_controller.h"
#import "chrome/browser/renderer_host/render_widget_host_view_mac.h"
#include "chrome/browser/global_keyboard_shortcuts_mac.h"

// Our browser window does some interesting things to get the behaviors that
// we want. We replace the standard window controls (zoom, close, miniaturize)
// with our own versions, so that we can position them slightly differently than
// the default window has them. To do this, we hide the ones that Apple provides
// us with, and create our own. This requires us to handle tracking for the
// buttons (so that they highlight and activate correctly) as well as implement
// the private method _mouseInGroup in our frame view class which is required
// to get the rollover highlight drawing to draw correctly.
@interface ChromeBrowserWindow(ChromeBrowserWindowPrivateMethods)
// Return the view that does the "frame" drawing.
- (NSView*)frameView;
@end

typedef int (*KeyToCommandMapper)(bool, bool, bool, int);

@implementation ChromeBrowserWindow
- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

- (void)setWindowController:(NSWindowController*)controller {
  if (controller == [self windowController]) {
    return;
  }
  // Clean up our old stuff.
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [closeButton_ removeFromSuperview];
  closeButton_ = nil;
  [miniaturizeButton_ removeFromSuperview];
  miniaturizeButton_ = nil;
  [zoomButton_ removeFromSuperview];
  zoomButton_ = nil;

  [super setWindowController:controller];

  BrowserWindowController* browserController
      = static_cast<BrowserWindowController*>(controller);
  if ([browserController isKindOfClass:[BrowserWindowController class]]) {
    NSNotificationCenter* defaultCenter = [NSNotificationCenter defaultCenter];
    [defaultCenter addObserver:self
                      selector:@selector(themeDidChangeNotification:)
                          name:kGTMThemeDidChangeNotification
                        object:nil];

    // Hook ourselves up to get notified if the user changes the system
    // theme on us.
    NSDistributedNotificationCenter* distCenter =
        [NSDistributedNotificationCenter defaultCenter];
    [distCenter addObserver:self
                   selector:@selector(systemThemeDidChangeNotification:)
                       name:@"AppleAquaColorVariantChanged"
                     object:nil];
    // Set up our buttons how we like them.
    NSView* frameView = [self frameView];
    NSRect frameViewBounds = [frameView bounds];

    // Find all the "original" buttons, and hide them. We can't use the original
    // buttons because the OS likes to move them around when we resize windows
    // and will put them back in what it considers to be their "preferred"
    // locations.
    NSButton* oldButton = [self standardWindowButton:NSWindowCloseButton];
    [oldButton setHidden:YES];
    oldButton = [self standardWindowButton:NSWindowMiniaturizeButton];
    [oldButton setHidden:YES];
    oldButton = [self standardWindowButton:NSWindowZoomButton];
    [oldButton setHidden:YES];

    // Create and position our new buttons.
    NSUInteger aStyle = [self styleMask];
    closeButton_ = [NSWindow standardWindowButton:NSWindowCloseButton
                                     forStyleMask:aStyle];
    NSRect closeButtonFrame = [closeButton_ frame];
    CGFloat yOffset = [browserController isNormalWindow] ?
        kChromeWindowButtonsWithTabStripOffsetFromTop :
        kChromeWindowButtonsWithoutTabStripOffsetFromTop;
    closeButtonFrame.origin =
        NSMakePoint(kChromeWindowButtonsOffsetFromLeft,
                    (NSHeight(frameViewBounds) -
                     NSHeight(closeButtonFrame) - yOffset));

    [closeButton_ setFrame:closeButtonFrame];
    [closeButton_ setTarget:self];
    [closeButton_ setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
    [frameView addSubview:closeButton_];

    miniaturizeButton_ =
        [NSWindow standardWindowButton:NSWindowMiniaturizeButton
                          forStyleMask:aStyle];
    NSRect miniaturizeButtonFrame = [miniaturizeButton_ frame];
    miniaturizeButtonFrame.origin =
        NSMakePoint((NSMaxX(closeButtonFrame) +
                     kChromeWindowButtonsInterButtonSpacing),
                    NSMinY(closeButtonFrame));
    [miniaturizeButton_ setFrame:miniaturizeButtonFrame];
    [miniaturizeButton_ setTarget:self];
    [miniaturizeButton_ setAutoresizingMask:(NSViewMaxXMargin |
                                             NSViewMinYMargin)];
    [frameView addSubview:miniaturizeButton_];

    zoomButton_ = [NSWindow standardWindowButton:NSWindowZoomButton
                                    forStyleMask:aStyle];
    NSRect zoomButtonFrame = [zoomButton_ frame];
    zoomButtonFrame.origin =
        NSMakePoint((NSMaxX(miniaturizeButtonFrame) +
                     kChromeWindowButtonsInterButtonSpacing),
                    NSMinY(miniaturizeButtonFrame));
    [zoomButton_ setFrame:zoomButtonFrame];
    [zoomButton_ setTarget:self];
    [zoomButton_ setAutoresizingMask:(NSViewMaxXMargin |
                                      NSViewMinYMargin)];

    [frameView addSubview:zoomButton_];
  }

  // Update our tracking areas. We want to update them even if we haven't
  // added buttons above as we need to remove the old tracking area. If the
  // buttons aren't to be shown, updateTrackingAreas won't add new ones.
  [self updateTrackingAreas];
}

- (NSView*)frameView {
  return [[self contentView] superview];
}

// The tab strip view covers our window buttons. So we add hit testing here
// to find them properly and return them to the accessibility system.
- (id)accessibilityHitTest:(NSPoint)point {
  NSPoint windowPoint = [self convertScreenToBase:point];
  NSControl* controls[] = { closeButton_, zoomButton_, miniaturizeButton_ };
  id value = nil;
  for (size_t i = 0; i < sizeof(controls) / sizeof(controls[0]); ++i) {
    if (NSPointInRect(windowPoint, [controls[i] frame])) {
      value = [controls[i] accessibilityHitTest:point];
      break;
    }
  }
  if (!value) {
    value = [super accessibilityHitTest:point];
  }
  return value;
}

// Map our custom buttons into the accessibility hierarchy correctly.
- (id)accessibilityAttributeValue:(NSString*)attribute {
  id value = nil;
  struct {
    NSString* attribute_;
    id value_;
  } attributeMap[] = {
    { NSAccessibilityCloseButtonAttribute, [closeButton_ cell]},
    { NSAccessibilityZoomButtonAttribute, [zoomButton_ cell]},
    { NSAccessibilityMinimizeButtonAttribute, [miniaturizeButton_ cell]},
  };

  for (size_t i = 0; i < sizeof(attributeMap) / sizeof(attributeMap[0]); ++i) {
    if ([attributeMap[i].attribute_ isEqualToString:attribute]) {
      value = attributeMap[i].value_;
      break;
    }
  }
  if (!value) {
    value = [super accessibilityAttributeValue:attribute];
  }
  return value;
}

- (void)updateTrackingAreas {
  NSView* frameView = [self frameView];
  if (widgetTrackingArea_) {
    [frameView removeTrackingArea:widgetTrackingArea_];
  }
  if (closeButton_) {
    NSRect trackingRect = [closeButton_ frame];
    trackingRect.size.width = NSMaxX([zoomButton_ frame]) -
        NSMinX(trackingRect);
    widgetTrackingArea_.reset(
        [[NSTrackingArea alloc] initWithRect:trackingRect
                                     options:(NSTrackingMouseEnteredAndExited |
                                              NSTrackingActiveAlways)
                                       owner:self
                                    userInfo:nil]);
    [frameView addTrackingArea:widgetTrackingArea_];
  }
}

- (void)windowMainStatusChanged {
  [closeButton_ setNeedsDisplay];
  [zoomButton_ setNeedsDisplay];
  [miniaturizeButton_ setNeedsDisplay];
  NSView* frameView = [self frameView];
  NSView* contentView = [self contentView];
  NSRect updateRect = [frameView frame];
  NSRect contentRect = [contentView frame];
  CGFloat tabStripHeight = [TabStripController defaultTabHeight];
  updateRect.size.height -= NSHeight(contentRect) - tabStripHeight;
  updateRect.origin.y = NSMaxY(contentRect) - tabStripHeight;
  [[self frameView] setNeedsDisplayInRect:updateRect];
}

- (void)becomeMainWindow {
  [self windowMainStatusChanged];
  [super becomeMainWindow];
}

- (void)resignMainWindow {
  [self windowMainStatusChanged];
  [super resignMainWindow];
}

- (void)themeDidChangeNotification:(NSNotification*)aNotification {
  GTMTheme* theme = [aNotification object];
  if ([theme isEqual:[self gtm_theme]]) {
    [[self frameView] setNeedsDisplay:YES];
  }
}

- (void)systemThemeDidChangeNotification:(NSNotification*)aNotification {
  [closeButton_ setNeedsDisplay];
  [zoomButton_ setNeedsDisplay];
  [miniaturizeButton_ setNeedsDisplay];
}

- (void)sendEvent:(NSEvent*)event {
  // For cocoa windows, clicking on the close and the miniaturize (but not the
  // zoom buttons) while a window is in the background does NOT bring that
  // window to the front. We don't get that behavior for free, so we handle
  // it here. Zoom buttons do bring the window to the front. Note that
  // Finder windows (in Leopard) behave differently in this regard in that
  // zoom buttons don't bring the window to the foreground.
  BOOL eventHandled = NO;
  if (![self isMainWindow]) {
    if ([event type] == NSLeftMouseDown) {
      NSView* frameView = [self frameView];
      NSPoint mouse = [frameView convertPointFromBase:[event locationInWindow]];
      if (NSPointInRect(mouse, [closeButton_ frame])) {
        [closeButton_ mouseDown:event];
        eventHandled = YES;
      } else if (NSPointInRect(mouse, [miniaturizeButton_ frame])) {
        [miniaturizeButton_ mouseDown:event];
        eventHandled = YES;
      }
    }
  }
  if (!eventHandled) {
    [super sendEvent:event];
  }
}

// Update our buttons so that they highlight correctly.
- (void)mouseEntered:(NSEvent*)event {
  entered_ = YES;
  [closeButton_ setNeedsDisplay];
  [zoomButton_ setNeedsDisplay];
  [miniaturizeButton_ setNeedsDisplay];
}

// Update our buttons so that they highlight correctly.
- (void)mouseExited:(NSEvent*)event {
  entered_ = NO;
  [closeButton_ setNeedsDisplay];
  [zoomButton_ setNeedsDisplay];
  [miniaturizeButton_ setNeedsDisplay];
}

- (BOOL)mouseInGroup:(NSButton*)widget {
  return entered_;
}

- (BOOL)handleExtraKeyboardShortcut:(NSEvent*)event fromTable:
    (KeyToCommandMapper)commandForKeyboardShortcut {
  // Extract info from |event|.
  NSUInteger modifers = [event modifierFlags];
  const bool cmdKey = modifers & NSCommandKeyMask;
  const bool shiftKey = modifers & NSShiftKeyMask;
  const bool cntrlKey = modifers & NSControlKeyMask;
  const int keyCode = [event keyCode];

  int cmdNum = commandForKeyboardShortcut(cmdKey, shiftKey, cntrlKey,
      keyCode);

  BrowserWindowController* controller =
      (BrowserWindowController*)[self delegate];
  // A bit of sanity.
  DCHECK([controller isKindOfClass:[BrowserWindowController class]]);
  DCHECK([controller respondsToSelector:@selector(executeCommand:)]);

  if (cmdNum != -1) {
    [controller executeCommand:cmdNum];
    return YES;
  }
  return NO;
}

- (BOOL)handleExtraWindowKeyboardShortcut:(NSEvent*)event {
  return [self handleExtraKeyboardShortcut:event
                                 fromTable:CommandForWindowKeyboardShortcut];
}

- (BOOL)handleExtraBrowserKeyboardShortcut:(NSEvent*)event {
  return [self handleExtraKeyboardShortcut:event
                                 fromTable:CommandForBrowserKeyboardShortcut];
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
  // Give the web site a chance to handle the event. If it doesn't want to
  // handle it, it will call us back with one of the |handle*| methods above.
  NSResponder* r = [self firstResponder];
  if ([r isKindOfClass:[RenderWidgetHostViewCocoa class]])
    return [r performKeyEquivalent:event];

  // Handle per-window shortcuts like cmd-1, but do not handle browser-level
  // shortcuts like cmd-left (else, cmd-left would do history navigation even
  // if e.g. the Omnibox has focus).
  if ([self handleExtraWindowKeyboardShortcut:event])
    return YES;
  return [super performKeyEquivalent:event];
}

- (void)setShouldHideTitle:(BOOL)flag {
  shouldHideTitle_ = flag;
}

-(BOOL)_isTitleHidden {
  return shouldHideTitle_;
}

@end
