#import "tb_gesture_bridge.h"
#import "tb_i18n.h"

#import <AppKit/AppKit.h>
#include <stdio.h>

@interface TBReceiverStatusView : NSView
@property(nonatomic, copy) NSString *ipText;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, copy) NSString *senderText;
@property(nonatomic, copy) NSString *panelText;
@property(nonatomic, copy) NSString *modeText;
@property(nonatomic, copy) NSString *languageText;
@property(nonatomic, copy) NSString *permissionsText;
@property(nonatomic, copy) NSString *connectingText;
@property(nonatomic, copy) NSString *waitingText;
@property(nonatomic) BOOL connecting;
@end

static NSColor *tb_rgb(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

static void tb_draw_rounded_fill(NSRect rect, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

static void tb_draw_card(NSRect rect) {
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.08];
    shadow.shadowOffset = NSMakeSize(0.0, 2.0);
    shadow.shadowBlurRadius = 10.0;
    [shadow set];
    tb_draw_rounded_fill(rect, 18.0, NSColor.whiteColor);
    [NSGraphicsContext restoreGraphicsState];

    [tb_rgb(0.87, 0.88, 0.90) setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:18.0 yRadius:18.0];
    border.lineWidth = 0.75;
    [border stroke];
}

static NSFont *tb_system_font(CGFloat size, NSFontWeight weight) {
    return [NSFont systemFontOfSize:size weight:weight];
}

static void tb_draw_text(NSString *text,
                         NSRect rect,
                         NSFont *font,
                         NSColor *color,
                         NSTextAlignment alignment) {
    if (text.length == 0) return;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect
      withAttributes:@{
          NSFontAttributeName: font,
          NSForegroundColorAttributeName: color,
          NSParagraphStyleAttributeName: paragraph
      }];
}

static void tb_draw_symbol(NSString *name, NSRect rect, NSColor *color, CGFloat point_size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!image) return;
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:point_size
                                                        weight:NSFontWeightSemibold];
    if (@available(macOS 12.0, *)) {
        NSImageSymbolConfiguration *palette =
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
        configuration = [configuration configurationByApplyingConfiguration:palette];
    }
    image = [image imageWithSymbolConfiguration:configuration];
    [image drawInRect:rect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
}

static void tb_draw_brand_icon(NSRect rect) {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:16.0 yRadius:16.0];
    [NSColor.whiteColor setFill];
    [shape fill];
    [NSGraphicsContext saveGraphicsState];
    [shape addClip];
    NSGradient *gradient = [[NSGradient alloc]
        initWithStartingColor:[NSColor.systemGreenColor colorWithAlphaComponent:0.28]
                  endingColor:[tb_rgb(0.22, 0.78, 0.86) colorWithAlphaComponent:0.12]];
    [gradient drawInRect:rect angle:-45.0];
    [NSGraphicsContext restoreGraphicsState];
    tb_draw_symbol(@"display.2", NSInsetRect(rect, 12.0, 12.0), NSColor.whiteColor, 22.0);
}

static NSString *tb_string(const char *value) {
    if (!value) return @"";
    NSString *text = [NSString stringWithUTF8String:value];
    return text ?: @"";
}

@implementation TBReceiverStatusView

- (BOOL)isFlipped {
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [tb_rgb(0.96, 0.97, 0.98) setFill];
    NSRectFill(self.bounds);

    if (self.connecting) {
        [self drawConnecting];
    } else {
        [self drawWaiting];
    }
}

- (void)drawConnecting {
    const CGFloat cardWidth = MIN(560.0, NSWidth(self.bounds) - 48.0);
    const CGFloat cardHeight = 410.0;
    NSRect card = NSMakeRect(
        (NSWidth(self.bounds) - cardWidth) / 2.0,
        MAX(24.0, (NSHeight(self.bounds) - cardHeight) / 2.0),
        cardWidth,
        cardHeight
    );
    tb_draw_card(card);

    NSRect icon = NSMakeRect(NSMidX(card) - 42.0, NSMinY(card) + 42.0, 84.0, 84.0);
    tb_draw_brand_icon(icon);
    tb_draw_text(@"TargetBridge",
                 NSMakeRect(NSMinX(card) + 24.0, NSMaxY(icon) + 24.0, cardWidth - 48.0, 38.0),
                 tb_system_font(29.0, NSFontWeightBold),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentCenter);
    tb_draw_text(@"RECEIVER",
                 NSMakeRect(NSMinX(card) + 24.0, NSMaxY(icon) + 66.0, cardWidth - 48.0, 22.0),
                 [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightSemibold],
                 tb_rgb(0.08, 0.55, 0.30),
                 NSTextAlignmentCenter);
    tb_draw_text(self.connectingText,
                 NSMakeRect(NSMinX(card) + 24.0, NSMaxY(icon) + 112.0, cardWidth - 48.0, 32.0),
                 tb_system_font(21.0, NSFontWeightSemibold),
                 tb_rgb(0.14, 0.15, 0.18),
                 NSTextAlignmentCenter);
    tb_draw_text(self.waitingText,
                 NSMakeRect(NSMinX(card) + 24.0, NSMaxY(icon) + 150.0, cardWidth - 48.0, 26.0),
                 tb_system_font(15.0, NSFontWeightRegular),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentCenter);

    NSString *identity = [NSString stringWithFormat:@"%s · build %s · commit %s",
                                                    TB_RECEIVER_VERSION,
                                                    TB_RECEIVER_BUILD,
                                                    TB_RECEIVER_COMMIT];
    tb_draw_text(identity,
                 NSMakeRect(NSMinX(card) + 20.0, NSMaxY(card) - 38.0, cardWidth - 40.0, 18.0),
                 [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                 tb_rgb(0.45, 0.47, 0.52),
                 NSTextAlignmentCenter);
}

- (void)drawWaiting {
    const CGFloat contentWidth = MIN(1000.0, NSWidth(self.bounds) - 48.0);
    const CGFloat contentHeight = 560.0;
    const CGFloat x = (NSWidth(self.bounds) - contentWidth) / 2.0;
    const CGFloat top = MAX(20.0, (NSHeight(self.bounds) - contentHeight) / 2.0);

    NSRect header = NSMakeRect(x, top, contentWidth, 86.0);
    tb_draw_card(header);
    tb_draw_brand_icon(NSMakeRect(x + 18.0, top + 17.0, 52.0, 52.0));
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.title")),
                 NSMakeRect(x + 86.0, top + 18.0, contentWidth - 250.0, 34.0),
                 tb_system_font(25.0, NSFontWeightBold),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.subtitle")),
                 NSMakeRect(x + 86.0, top + 54.0, contentWidth - 250.0, 24.0),
                 tb_system_font(15.0, NSFontWeightRegular),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);

    NSRect chip = NSMakeRect(NSMaxX(header) - 136.0, top + 27.0, 118.0, 32.0);
    tb_draw_rounded_fill(chip, 16.0, tb_rgb(0.94, 0.95, 0.96));
    tb_draw_text(self.statusText,
                 NSInsetRect(chip, 8.0, 7.0),
                 tb_system_font(13.0, NSFontWeightSemibold),
                 tb_rgb(0.34, 0.36, 0.40),
                 NSTextAlignmentCenter);

    NSRect network = NSMakeRect(x, top + 100.0, contentWidth, 72.0);
    tb_draw_rounded_fill(network, 18.0, tb_rgb(0.92, 0.98, 0.94));
    tb_draw_symbol(@"network", NSMakeRect(x + 18.0, top + 123.0, 22.0, 22.0),
                   tb_rgb(0.20, 0.48, 0.31), 17.0);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.ip_thunderbolt_bridge")),
                 NSMakeRect(x + 50.0, top + 113.0, 300.0, 22.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.30, 0.37, 0.34),
                 NSTextAlignmentLeft);
    tb_draw_text(self.ipText,
                 NSMakeRect(x + 50.0, top + 137.0, contentWidth - 68.0, 29.0),
                 [NSFont monospacedSystemFontOfSize:20.0 weight:NSFontWeightBold],
                 tb_rgb(0.08, 0.55, 0.30),
                 NSTextAlignmentLeft);

    const CGFloat gap = 14.0;
    const CGFloat cardWidth = (contentWidth - gap) / 2.0;
    NSRect statusCard = NSMakeRect(x, top + 186.0, cardWidth, 128.0);
    NSRect displayCard = NSMakeRect(x + cardWidth + gap, top + 186.0, cardWidth, 128.0);
    tb_draw_card(statusCard);
    tb_draw_card(displayCard);

    tb_draw_symbol(@"cable.connector",
                   NSMakeRect(NSMinX(statusCard) + 18.0, NSMinY(statusCard) + 18.0, 19.0, 19.0),
                   tb_rgb(0.42, 0.44, 0.49), 17.0);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.status")),
                 NSMakeRect(NSMinX(statusCard) + 46.0, NSMinY(statusCard) + 17.0, 120.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_text(self.statusText,
                 NSMakeRect(NSMinX(statusCard) + 18.0, NSMinY(statusCard) + 43.0, cardWidth - 36.0, 26.0),
                 tb_system_font(18.0, NSFontWeightSemibold),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.sender")),
                 NSMakeRect(NSMinX(statusCard) + 18.0, NSMinY(statusCard) + 78.0, 120.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_text(self.senderText,
                 NSMakeRect(NSMinX(statusCard) + 18.0, NSMinY(statusCard) + 102.0, cardWidth - 36.0, 23.0),
                 tb_system_font(16.0, NSFontWeightRegular),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);

    tb_draw_symbol(@"display",
                   NSMakeRect(NSMinX(displayCard) + 18.0, NSMinY(displayCard) + 18.0, 20.0, 20.0),
                   tb_rgb(0.42, 0.44, 0.49), 15.0);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.display")),
                 NSMakeRect(NSMinX(displayCard) + 46.0, NSMinY(displayCard) + 17.0, 120.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_text(self.panelText,
                 NSMakeRect(NSMinX(displayCard) + 18.0, NSMinY(displayCard) + 43.0, cardWidth - 36.0, 26.0),
                 tb_system_font(15.0, NSFontWeightRegular),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.stream_profile")),
                 NSMakeRect(NSMinX(displayCard) + 46.0, NSMinY(displayCard) + 78.0, 120.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_symbol(@"rectangle.on.rectangle",
                   NSMakeRect(NSMinX(displayCard) + 18.0, NSMinY(displayCard) + 79.0, 20.0, 20.0),
                   tb_rgb(0.42, 0.44, 0.49), 17.0);
    tb_draw_text(self.modeText,
                 NSMakeRect(NSMinX(displayCard) + 18.0, NSMinY(displayCard) + 102.0, cardWidth - 36.0, 23.0),
                 tb_system_font(15.0, NSFontWeightRegular),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);

    NSRect permission = NSMakeRect(x, top + 328.0, contentWidth, 88.0);
    tb_draw_card(permission);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.permissions")),
                 NSMakeRect(x + 18.0, top + 344.0, 100.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_text(self.permissionsText,
                 NSMakeRect(x + 18.0, top + 372.0, contentWidth - 270.0, 24.0),
                 tb_system_font(16.0, NSFontWeightRegular),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.language")),
                 NSMakeRect(NSMaxX(permission) - 205.0, top + 344.0, 150.0, 20.0),
                 tb_system_font(12.0, NSFontWeightSemibold),
                 tb_rgb(0.42, 0.44, 0.49),
                 NSTextAlignmentLeft);
    tb_draw_text(self.languageText,
                 NSMakeRect(NSMaxX(permission) - 205.0, top + 372.0, 185.0, 24.0),
                 tb_system_font(15.0, NSFontWeightRegular),
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);

    NSRect help = NSMakeRect(x, top + 430.0, contentWidth, 74.0);
    tb_draw_card(help);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.help_1")),
                 NSMakeRect(x + 18.0, top + 440.0, contentWidth - 36.0, 20.0),
                 tb_system_font(13.0, NSFontWeightRegular),
                 tb_rgb(0.34, 0.36, 0.41),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.help_2")),
                 NSMakeRect(x + 18.0, top + 461.0, contentWidth - 36.0, 20.0),
                 tb_system_font(13.0, NSFontWeightRegular),
                 tb_rgb(0.34, 0.36, 0.41),
                 NSTextAlignmentLeft);
    tb_draw_text(tb_string(tb_i18n_get("receiver.ui.help_4")),
                 NSMakeRect(x + 18.0, top + 482.0, contentWidth - 36.0, 20.0),
                 tb_system_font(13.0, NSFontWeightRegular),
                 tb_rgb(0.34, 0.36, 0.41),
                 NSTextAlignmentLeft);

    tb_draw_text(@"TARGETBRIDGE",
                 NSMakeRect(x, top + 532.0, 180.0, 20.0),
                 [NSFont monospacedSystemFontOfSize:13.0 weight:NSFontWeightBold],
                 tb_rgb(0.12, 0.13, 0.15),
                 NSTextAlignmentLeft);
    NSString *identity = [NSString stringWithFormat:@"%s · build %s · commit %s",
                                                    TB_RECEIVER_VERSION,
                                                    TB_RECEIVER_BUILD,
                                                    TB_RECEIVER_COMMIT];
    tb_draw_text(identity,
                 NSMakeRect(NSMaxX(header) - 430.0, top + 532.0, 430.0, 20.0),
                 [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                 tb_rgb(0.45, 0.47, 0.52),
                 NSTextAlignmentRight);
}

@end

static TBReceiverStatusView *g_status_overlay = nil;
static __weak NSWindow *g_status_window = nil;

static NSWindow *tb_find_content_window(void) {
    NSWindow *content = nil;
    CGFloat best_area = 0.0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        const CGFloat area = NSWidth(window.frame) * NSHeight(window.frame);
        if (area < 200.0 * 200.0) continue;
        if (area > best_area) {
            best_area = area;
            content = window;
        }
    }
    return content;
}

static void tb_native_status_show_main(NSString *ip,
                                       NSString *status,
                                       NSString *sender,
                                       NSString *panel,
                                       NSString *mode,
                                       NSString *language,
                                       NSString *permissions,
                                       BOOL connecting,
                                       NSString *connectingText,
                                       NSString *waitingText) {
    NSWindow *window = tb_find_content_window();
    if (!window || !window.contentView) return;

    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    closeButton.enabled = NO;
    closeButton.toolTip = @"Receiver keeps running; use Escape or Quit to exit.";

    if (!g_status_overlay || g_status_window != window) {
        [g_status_overlay removeFromSuperview];
        g_status_overlay = [[TBReceiverStatusView alloc] initWithFrame:window.contentView.bounds];
        g_status_overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [window.contentView addSubview:g_status_overlay
                            positioned:NSWindowAbove
                            relativeTo:nil];
        g_status_window = window;
    }

    BOOL changed =
        g_status_overlay.connecting != connecting ||
        ![g_status_overlay.ipText isEqualToString:ip] ||
        ![g_status_overlay.statusText isEqualToString:status] ||
        ![g_status_overlay.senderText isEqualToString:sender] ||
        ![g_status_overlay.panelText isEqualToString:panel] ||
        ![g_status_overlay.modeText isEqualToString:mode] ||
        ![g_status_overlay.languageText isEqualToString:language] ||
        ![g_status_overlay.permissionsText isEqualToString:permissions] ||
        ![g_status_overlay.connectingText isEqualToString:connectingText] ||
        ![g_status_overlay.waitingText isEqualToString:waitingText];

    g_status_overlay.ipText = ip;
    g_status_overlay.statusText = status;
    g_status_overlay.senderText = sender;
    g_status_overlay.panelText = panel;
    g_status_overlay.modeText = mode;
    g_status_overlay.languageText = language;
    g_status_overlay.permissionsText = permissions;
    g_status_overlay.connecting = connecting;
    g_status_overlay.connectingText = connectingText;
    g_status_overlay.waitingText = waitingText;
    g_status_overlay.hidden = NO;
    if (changed) [g_status_overlay setNeedsDisplay:YES];
}

void tb_native_status_show(void *sdl_window,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions,
                           int connecting,
                           const char *connecting_text,
                           const char *waiting_text) {
    (void)sdl_window;
    NSString *ipValue = tb_string(ip);
    NSString *statusValue = tb_string(status);
    NSString *senderValue = tb_string(sender);
    NSString *panelValue = tb_string(panel);
    NSString *modeValue = tb_string(mode);
    NSString *languageValue = tb_string(language);
    NSString *permissionsValue = tb_string(permissions);
    NSString *connectingValue = tb_string(connecting_text);
    NSString *waitingValue = tb_string(waiting_text);

    void (^showBlock)(void) = ^{
        tb_native_status_show_main(
            ipValue,
            statusValue,
            senderValue,
            panelValue,
            modeValue,
            languageValue,
            permissionsValue,
            connecting ? YES : NO,
            connectingValue,
            waitingValue
        );
    };
    if (NSThread.isMainThread) {
        showBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), showBlock);
    }
}

void tb_native_status_hide(void) {
    void (^hideBlock)(void) = ^{
        g_status_overlay.hidden = YES;
    };
    if (NSThread.isMainThread) {
        hideBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), hideBlock);
    }
}

void tb_native_status_destroy(void) {
    void (^destroyBlock)(void) = ^{
        [g_status_overlay removeFromSuperview];
        g_status_overlay = nil;
        g_status_window = nil;
    };
    if (NSThread.isMainThread) {
        destroyBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), destroyBlock);
    }
}

int tb_window_on_active_space(void *sdl_window) {
    /* Whether the receiver's content window is on the Space the user is
     * currently viewing. Used to gate receiverMaster forwarding so local work
     * on another (receiver-only) Space doesn't move the sender's cursor.
     *
     * We deliberately avoid SDL_GetWindowWMInfo here: it is version-gated and
     * fails when the app is compiled against newer SDL headers than the bundled
     * runtime (as happens on the Intel build), which would silently fail open.
     * Instead we find our largest visible window via NSApp and query the window
     * server directly with -[NSWindow isOnActiveSpace]. That is purely spatial,
     * so — unlike keyboard focus — it stays correct even when the receiver app
     * remains the active application on another Space. */
    (void)sdl_window;

    NSWindow *content = nil;
    CGFloat best_area = 0.0;
    NSArray<NSWindow *> *windows = [NSApp windows];
    for (NSWindow *w in windows) {
        if (!w.isVisible) continue;
        NSSize s = w.frame.size;
        CGFloat area = s.width * s.height;
        if (area < 200.0 * 200.0) continue;   /* skip tiny status/aux windows */
        if (area > best_area) { best_area = area; content = w; }
    }

    /* Fail open (forward) only when we genuinely can't find a content window. */
    int on_active = content ? (content.isOnActiveSpace ? 1 : 0) : 1;

    /* Log on decision flips only, to keep the input hot path quiet. */
    static int last = -1;
    if (on_active != last) {
        last = on_active;
        fprintf(stderr,
                "[input] forward-gate on_active_space=%d (window=%s area=%.0f "
                "collectionBehavior=0x%lx windows=%lu)\n",
                on_active, content ? "found" : "none", best_area,
                content ? (unsigned long)content.collectionBehavior : 0UL,
                (unsigned long)windows.count);
    }
    return on_active;
}

static tb_gesture_space_switch_callback g_callback = NULL;
static void *g_context = NULL;
static id g_swipe_monitor = nil;
static id g_scroll_monitor = nil;
static id g_key_down_monitor = nil;
static id g_key_up_monitor = nil;
static id g_flags_monitor = nil;
static id g_system_defined_monitor = nil;
static BOOL g_active = NO;
static NSTimeInterval g_last_horizontal_gesture_at = 0.0;
static CGFloat g_horizontal_accumulator = 0.0;
static NSTimeInterval g_last_switch_at = 0.0;

static BOOL tb_should_handle_horizontal_scroll(NSEvent *event) {
    if (!event || !g_active) return NO;
    CGFloat dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX;
    CGFloat dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY;
    if (fabs(dx) <= fabs(dy) * 1.5) return NO;
    NSEventPhase phase = event.phase;
    NSEventPhase momentum = event.momentumPhase;
    return event.hasPreciseScrollingDeltas || phase != NSEventPhaseNone || momentum != NSEventPhaseNone;
}

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context) {
    g_callback = callback;
    g_context = context;

    if (g_swipe_monitor || g_scroll_monitor || g_key_down_monitor || g_key_up_monitor || g_flags_monitor || g_system_defined_monitor) {
        return;
    }

    g_swipe_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSwipe
                                                            handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active || !g_callback) return event;
        CGFloat dx = event.deltaX;
        if (fabs(dx) < 0.01) return event;
        g_callback(dx > 0 ? 1 : -1, g_context);
        g_last_switch_at = event.timestamp;
        return nil;
    }];

    g_scroll_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                                             handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!tb_should_handle_horizontal_scroll(event)) return event;

        NSTimeInterval now = event.timestamp;
        if (now - g_last_horizontal_gesture_at > 0.25) {
            g_horizontal_accumulator = 0.0;
        }
        g_last_horizontal_gesture_at = now;

        CGFloat dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX;
        g_horizontal_accumulator += dx;

        if (fabs(g_horizontal_accumulator) >= 30.0 && now - g_last_switch_at > 0.45 && g_callback) {
            g_callback(g_horizontal_accumulator > 0 ? 1 : -1, g_context);
            g_last_switch_at = now;
            g_horizontal_accumulator = 0.0;
        }
        return nil;
    }];

    g_key_down_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_key_up_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                                             handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_flags_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                                            handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];

    g_system_defined_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                                                     handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!g_active) return event;
        return nil;
    }];
}

void tb_gesture_bridge_set_active(int active) {
    g_active = active ? YES : NO;
    if (!g_active) {
        g_horizontal_accumulator = 0.0;
        g_last_horizontal_gesture_at = 0.0;
    }
}
