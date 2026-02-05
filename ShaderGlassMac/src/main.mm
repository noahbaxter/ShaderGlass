/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#import <Cocoa/Cocoa.h>
#import "AppWindow.h"
#import "MetalRenderer.h"
#import "ScreenCapture.h"

static const int SHADER_COUNT = 63;

static NSString* const kShaderType = @"shaderType";
static NSString* const kClickThrough = @"clickThrough";
static NSString* const kCaptureUnderneath = @"captureUnderneath";
static NSString* const kFullscreen = @"fullscreen";
static NSString* const kWindowFrame = @"windowFrame";

static const int PARAM_COUNT = 5;
static NSString* const kParamNames[] = {
    @"Intensity", @"Curvature", @"Scanline Weight", @"Blur/Glow", @"Color Bleed"
};
static NSString* const kParamKeys[] = {
    @"paramIntensity", @"paramCurvature", @"paramScanline", @"paramBlur", @"paramColorBleed"
};

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, assign) AppWindow* window;
@property (nonatomic, assign) MetalRenderer* renderer;
@property (nonatomic, assign) ScreenCapture* capture;
@property (nonatomic, assign) BOOL captureUnderneath;
@property (nonatomic, assign) BOOL clickThrough;
@property (nonatomic, assign) BOOL isFullscreen;
@property (nonatomic, assign) NSRect savedWindowFrame;
@property (nonatomic, strong) NSMenuItem* captureUnderneathItem;
@property (nonatomic, strong) NSMenuItem* clickThroughItem;
@property (nonatomic, strong) NSMenuItem* fullscreenItem;
@property (nonatomic, strong) NSArray<NSMenuItem*>* shaderItems;
@property (nonatomic, strong) NSArray<NSMenuItem*>* paramItems;
@property (nonatomic, strong) id localMonitor;
@property (nonatomic, strong) id globalMonitor;
@property (nonatomic, strong) id flagsMonitor;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Register defaults for first launch
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kShaderType: @1,
        kClickThrough: @YES,
        kCaptureUnderneath: @YES,
        kFullscreen: @YES,
        @"paramIntensity": @0.5,
        @"paramCurvature": @0.5,
        @"paramScanline": @0.5,
        @"paramBlur": @0.5,
        @"paramColorBleed": @0.5,
    }];

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    _captureUnderneath = [defaults boolForKey:kCaptureUnderneath];
    _clickThrough = [defaults boolForKey:kClickThrough];
    _isFullscreen = NO;
    _savedWindowFrame = NSZeroRect;

    // Create window
    _window = new AppWindow();
    if (!_window->create(800, 600, "ShaderGlass")) {
        NSLog(@"Failed to create window");
        [NSApp terminate:nil];
        return;
    }

    // Set window delegate for move/resize tracking
    NSWindow* nsWindow = (__bridge NSWindow*)_window->getNSWindow();
    nsWindow.delegate = self;

    // Restore saved window frame
    NSString* savedFrame = [defaults stringForKey:kWindowFrame];
    if (savedFrame) {
        [nsWindow setFrameFromString:savedFrame];
    }

    // Create renderer
    _renderer = new MetalRenderer();
    if (!_renderer->initialize(_window->getMTKView())) {
        NSLog(@"Failed to initialize renderer");
        [NSApp terminate:nil];
        return;
    }

    // Restore saved shader
    int savedShader = (int)[defaults integerForKey:kShaderType];
    if (savedShader >= 0 && savedShader < SHADER_COUNT) {
        _renderer->setShaderType(savedShader);
    }

    // Restore saved parameters
    for (int i = 0; i < PARAM_COUNT; i++) {
        id saved = [defaults objectForKey:kParamKeys[i]];
        if (saved) {
            _renderer->setParam(i, [saved floatValue]);
        }
    }

    // Create screen capture
    _capture = new ScreenCapture();
    _capture->setExcludedWindow(_window->getNSWindow());
    _capture->setErrorCallback([self]() {
        [self showScreenRecordingDeniedAlert];
    });

    // Apply click-through
    _window->setClickThrough(_clickThrough);

    _window->show();

    // Enter fullscreen if saved (or first launch default)
    if ([defaults boolForKey:kFullscreen]) {
        [self toggleFullScreen:nil];
    } else {
        [self startCapture];
    }

    // Add local key monitor for R key (randomize) and Escape (exit fullscreen)
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
        if ([event.charactersIgnoringModifiers isEqualToString:@"r"] && !(event.modifierFlags & NSEventModifierFlagCommand)) {
            [self randomizeShader:nil];
            return nil;
        }
        // Escape exits fullscreen
        if (event.keyCode == 53 && self->_isFullscreen) {
            [self toggleFullScreen:nil];
            return nil;
        }
        return event;
    }];

    // Global monitor for Cmd+Q to always work
    _globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent* event) {
        if ([event.charactersIgnoringModifiers isEqualToString:@"q"] &&
            (event.modifierFlags & NSEventModifierFlagCommand)) {
            [NSApp terminate:nil];
        }
    }];

    // Monitor for Option key to temporarily allow dragging when click-through is on
    _flagsMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent*(NSEvent* event) {
        if (self->_clickThrough) {
            NSWindow* win = (__bridge NSWindow*)self->_window->getNSWindow();
            BOOL optionHeld = (event.modifierFlags & NSEventModifierFlagOption) != 0;
            win.ignoresMouseEvents = !optionHeld;
        }
        return event;
    }];
}

- (void)startCapture {
    _capture->stop();

    MetalRenderer* renderer = _renderer;
    NSWindow* nsWindow = (__bridge NSWindow*)_window->getNSWindow();

    if (_captureUnderneath) {
        // Use content view frame (excludes titlebar) in screen coordinates
        NSView* contentView = nsWindow.contentView;
        NSRect contentFrame = [contentView convertRect:contentView.bounds toView:nil];
        NSRect contentScreenFrame = [nsWindow convertRectToScreen:contentFrame];

        NSScreen* screen = nsWindow.screen ?: [NSScreen mainScreen];
        CGFloat scale = screen.backingScaleFactor;
        NSRect screenFrame = screen.frame;

        // Convert from bottom-left origin (NSWindow) to top-left origin (ScreenCaptureKit)
        CGRect captureRect = CGRectMake(
            contentScreenFrame.origin.x - screenFrame.origin.x,
            screenFrame.size.height - contentScreenFrame.origin.y - contentScreenFrame.size.height + screenFrame.origin.y,
            contentScreenFrame.size.width,
            contentScreenFrame.size.height
        );

        _capture->setSourceRect(captureRect, scale);
    } else {
        _capture->setSourceRect(CGRectNull, 0);
    }

    _capture->start([renderer](CVPixelBufferRef pixelBuffer, size_t width, size_t height) {
        renderer->updateTexture(pixelBuffer, width, height);
    });
}

- (void)saveWindowFrame {
    if (_window && !_isFullscreen) {
        NSWindow* nsWindow = (__bridge NSWindow*)_window->getNSWindow();
        [[NSUserDefaults standardUserDefaults] setObject:[nsWindow stringWithSavedFrame] forKey:kWindowFrame];
    }
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [self saveWindowFrame];
    if (_localMonitor) {
        [NSEvent removeMonitor:_localMonitor];
    }
    if (_globalMonitor) {
        [NSEvent removeMonitor:_globalMonitor];
    }
    if (_flagsMonitor) {
        [NSEvent removeMonitor:_flagsMonitor];
    }
    if (_capture) {
        _capture->stop();
        delete _capture;
    }
    if (_renderer) {
        delete _renderer;
    }
    if (_window) {
        delete _window;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

#pragma mark - Menu Actions

- (void)toggleFullScreen:(id)sender {
    NSWindow* nsWindow = (__bridge NSWindow*)_window->getNSWindow();

    if (!_isFullscreen) {
        // Save current frame
        _savedWindowFrame = nsWindow.frame;

        // Get screen frame (including menu bar area)
        NSScreen* screen = nsWindow.screen ?: [NSScreen mainScreen];
        NSRect screenFrame = screen.frame;

        // Go borderless fullscreen - use floating level so menu bar/dock can appear
        nsWindow.styleMask = NSWindowStyleMaskBorderless;
        nsWindow.level = NSFloatingWindowLevel;
        [nsWindow setFrame:screenFrame display:YES animate:NO];
        [nsWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                        NSWindowCollectionBehaviorStationary |
                                        NSWindowCollectionBehaviorIgnoresCycle];
        [nsWindow makeKeyAndOrderFront:nil];

        _isFullscreen = YES;
        _fullscreenItem.title = @"Exit Full Screen";
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFullscreen];
    } else {
        // Restore window
        nsWindow.styleMask = NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable;
        nsWindow.titlebarAppearsTransparent = YES;
        nsWindow.titleVisibility = NSWindowTitleHidden;
        nsWindow.level = _clickThrough ? NSScreenSaverWindowLevel : NSFloatingWindowLevel;

        if (!NSIsEmptyRect(_savedWindowFrame)) {
            [nsWindow setFrame:_savedWindowFrame display:YES animate:NO];
        }

        _isFullscreen = NO;
        _fullscreenItem.title = @"Enter Full Screen";
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kFullscreen];
    }

    // Restart capture if in underneath mode (defer to next run loop so frame is updated)
    if (_captureUnderneath) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startCapture];
        });
    }
}

- (void)toggleCaptureUnderneath:(id)sender {
    _captureUnderneath = !_captureUnderneath;
    _captureUnderneathItem.state = _captureUnderneath ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:_captureUnderneath forKey:kCaptureUnderneath];
    [self startCapture];
}

- (void)toggleClickThrough:(id)sender {
    _clickThrough = !_clickThrough;
    _clickThroughItem.state = _clickThrough ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:_clickThrough forKey:kClickThrough];
    _window->setClickThrough(_clickThrough);
}

- (void)selectShader:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    int shaderType = (int)item.tag;
    _renderer->setShaderType(shaderType);
    [self updateShaderCheckmarks:shaderType];
    [[NSUserDefaults standardUserDefaults] setInteger:shaderType forKey:kShaderType];
}

- (void)randomizeShader:(id)sender {
    int newShader = arc4random_uniform(SHADER_COUNT);
    _renderer->setShaderType(newShader);
    [self updateShaderCheckmarks:newShader];
    [[NSUserDefaults standardUserDefaults] setInteger:newShader forKey:kShaderType];
}

- (void)updateShaderCheckmarks:(int)shaderType {
    for (NSMenuItem* shaderItem in _shaderItems) {
        shaderItem.state = (shaderItem.tag == shaderType) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)increaseParam:(id)sender {
    int idx = (int)((NSMenuItem*)sender).tag;
    float val = _renderer->getParam(idx);
    val = fmin(val + 0.1, 1.0);
    _renderer->setParam(idx, val);
    [[NSUserDefaults standardUserDefaults] setFloat:val forKey:kParamKeys[idx]];
    [self updateParamTitles];
}

- (void)decreaseParam:(id)sender {
    int idx = (int)((NSMenuItem*)sender).tag;
    float val = _renderer->getParam(idx);
    val = fmax(val - 0.1, 0.0);
    _renderer->setParam(idx, val);
    [[NSUserDefaults standardUserDefaults] setFloat:val forKey:kParamKeys[idx]];
    [self updateParamTitles];
}

- (void)resetParams:(id)sender {
    for (int i = 0; i < PARAM_COUNT; i++) {
        _renderer->setParam(i, 0.5);
        [[NSUserDefaults standardUserDefaults] setFloat:0.5 forKey:kParamKeys[i]];
    }
    [self updateParamTitles];
}

- (void)updateParamTitles {
    for (int i = 0; i < (int)_paramItems.count; i++) {
        NSMenuItem* item = _paramItems[i];
        NSMenu* sub = item.submenu;
        float val = _renderer->getParam(i);
        item.title = [NSString stringWithFormat:@"%@: %.0f%%", kParamNames[i], val * 100.0];
        // Update +/- enabled state
        [[sub itemAtIndex:0] setEnabled:val < 0.99];
        [[sub itemAtIndex:1] setEnabled:val > 0.01];
    }
}

- (void)showAbout:(id)sender {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"ShaderGlass for macOS";
    alert.informativeText = @"GPU shader effect overlay\n\n"
        "Copyright (C) 2021-2025 mausimus (mausimus.net)\n"
        "https://github.com/mausimus/ShaderGlass\n\n"
        "Licensed under the GNU General Public License v3.0\n\n"
        "macOS port uses Metal and ScreenCaptureKit.";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"View on GitHub"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/mausimus/ShaderGlass"]];
    }
}

- (void)showScreenRecordingDeniedAlert {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Screen Recording Permission Required";
    alert.informativeText = @"ShaderGlass needs Screen Recording permission to capture desktop content.\n\n"
        "1. Open System Settings > Privacy & Security > Screen Recording\n"
        "2. Enable ShaderGlassMac\n"
        "3. Restart the app";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Quit"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    }
    [NSApp terminate:nil];
}

#pragma mark - NSWindowDelegate

- (void)windowDidMove:(NSNotification*)notification {
    if (_captureUnderneath) {
        [self startCapture];
    }
}

- (void)windowDidResize:(NSNotification*)notification {
    if (_captureUnderneath) {
        [self startCapture];
    }
}

- (void)windowDidChangeScreen:(NSNotification*)notification {
    if (_captureUnderneath) {
        [self startCapture];
    }
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];

        // Create menu bar
        NSMenu* menuBar = [[NSMenu alloc] init];

        // App menu
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"ShaderGlass"];
        NSMenuItem* aboutItem = [appMenu addItemWithTitle:@"About ShaderGlass" action:@selector(showAbout:) keyEquivalent:@""];
        aboutItem.target = delegate;
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit ShaderGlass" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        // View menu
        NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:viewMenuItem];
        NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];

        NSMenuItem* fullscreenItem = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen"
                                                                action:@selector(toggleFullScreen:)
                                                         keyEquivalent:@"f"];
        fullscreenItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        fullscreenItem.target = delegate;
        delegate.fullscreenItem = fullscreenItem;
        [viewMenu addItem:fullscreenItem];

        [viewMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem* captureUnderneathItem = [[NSMenuItem alloc] initWithTitle:@"Capture Area Underneath"
                                                                       action:@selector(toggleCaptureUnderneath:)
                                                                keyEquivalent:@"u"];
        captureUnderneathItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        captureUnderneathItem.target = delegate;
        captureUnderneathItem.state = delegate.captureUnderneath ? NSControlStateValueOn : NSControlStateValueOff;
        delegate.captureUnderneathItem = captureUnderneathItem;
        [viewMenu addItem:captureUnderneathItem];

        NSMenuItem* clickThroughItem = [[NSMenuItem alloc] initWithTitle:@"Click Through (Lock)"
                                                                  action:@selector(toggleClickThrough:)
                                                           keyEquivalent:@"l"];
        clickThroughItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        clickThroughItem.target = delegate;
        clickThroughItem.state = delegate.clickThrough ? NSControlStateValueOn : NSControlStateValueOff;
        delegate.clickThroughItem = clickThroughItem;
        [viewMenu addItem:clickThroughItem];

        [viewMenuItem setSubmenu:viewMenu];

        // Shader menu
        NSMenuItem* shaderMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:shaderMenuItem];
        NSMenu* shaderMenu = [[NSMenu alloc] initWithTitle:@"Shader"];

        NSArray* shaderNames = @[
            @"None (Passthrough)",   // 0
            @"Scanlines",            // 1
            @"CRT",                  // 2
            @"LCD",                  // 3
            @"VHS",                  // 4
            @"Gameboy",              // 5
            @"Phosphor Glow",        // 6
            @"NTSC",                 // 7
            @"ASCII",                // 8
            @"Matrix Rain",          // 9
            @"Thermal",              // 10
            @"Pixelate",             // 11
            @"Aperture Grille",      // 12
            @"Chromatic Aberration", // 13
            @"Glitch",               // 14
            @"Old Film",             // 15
            @"Underwater",           // 16
            @"Heat Haze",            // 17
            @"Drunk",                // 18
            @"Hologram",             // 19
            @"X-Ray",                // 20
            @"Night Vision",         // 21
            @"Surveillance",         // 22
            @"VCR Tracking",         // 23
            @"Broken TV",            // 24
            @"Static",               // 25
            @"Rainbow Shift",        // 26
            @"Kaleidoscope",         // 27
            @"Halftone",             // 28
            @"Sketch",               // 29
            @"Emboss",               // 30
            @"Edge Detect",          // 31
            @"Neon Glow",            // 32
            @"Cyberpunk",            // 33
            @"Vaporwave",            // 34
            @"Ordered Dither",       // 35
            @"CGA 4-Color",          // 36
            @"Amber Monitor",        // 37
            @"Green Monitor",        // 38
            @"Newspaper",            // 39
            @"Blueprint",            // 40
            @"Dot Matrix",           // 41
            @"Posterize",            // 42
            @"Color Separation",     // 43
            @"Sin Wave",             // 44
            @"Fisheye",              // 45
            @"Twirl",                // 46
            @"Bulge",                // 47
            @"Shockwave",            // 48
            @"Heartbeat",            // 49
            @"Cross-hatch",          // 50
            @"Pointillism",          // 51
            @"Voronoi",              // 52
            @"Rain on Glass",        // 53
            @"Frosted Glass",        // 54
            @"Tilt Shift",           // 55
            @"Mirror",               // 56
            @"Split Glitch",         // 57
            @"Datamosh",             // 58
            @"Bit Crush",            // 59
            @"Invert",               // 60
            @"Sepia",                // 61
            @"High Contrast"         // 62
        ];
        NSMutableArray* shaderItems = [NSMutableArray array];

        for (int i = 0; i < (int)shaderNames.count; i++) {
            NSString* keyEquiv = @"";
            if (i < 10) keyEquiv = [NSString stringWithFormat:@"%d", i];

            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:shaderNames[i]
                                                          action:@selector(selectShader:)
                                                   keyEquivalent:keyEquiv];
            item.tag = i;
            item.target = delegate;
            int savedShaderType = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kShaderType];
            item.state = (i == savedShaderType) ? NSControlStateValueOn : NSControlStateValueOff;
            [shaderMenu addItem:item];
            [shaderItems addObject:item];
        }

        [shaderMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem* randomItem = [[NSMenuItem alloc] initWithTitle:@"Randomize"
                                                            action:@selector(randomizeShader:)
                                                     keyEquivalent:@"r"];
        randomItem.keyEquivalentModifierMask = 0; // No modifier, just R
        randomItem.target = delegate;
        [shaderMenu addItem:randomItem];

        delegate.shaderItems = shaderItems;
        [shaderMenuItem setSubmenu:shaderMenu];

        // Parameters menu
        NSMenuItem* paramMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:paramMenuItem];
        NSMenu* paramMenu = [[NSMenu alloc] initWithTitle:@"Parameters"];
        NSMutableArray* paramItems = [NSMutableArray array];

        for (int i = 0; i < PARAM_COUNT; i++) {
            float val = delegate.renderer->getParam(i);
            NSString* title = [NSString stringWithFormat:@"%@: %.0f%%", kParamNames[i], val * 100.0];
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            NSMenu* sub = [[NSMenu alloc] initWithTitle:kParamNames[i]];

            NSMenuItem* incItem = [[NSMenuItem alloc] initWithTitle:@"Increase (+10%)" action:@selector(increaseParam:) keyEquivalent:@""];
            incItem.tag = i;
            incItem.target = delegate;
            [sub addItem:incItem];

            NSMenuItem* decItem = [[NSMenuItem alloc] initWithTitle:@"Decrease (-10%)" action:@selector(decreaseParam:) keyEquivalent:@""];
            decItem.tag = i;
            decItem.target = delegate;
            [sub addItem:decItem];

            [item setSubmenu:sub];
            [paramMenu addItem:item];
            [paramItems addObject:item];
        }

        [paramMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset All to 50%"
                                                           action:@selector(resetParams:)
                                                    keyEquivalent:@""];
        resetItem.target = delegate;
        [paramMenu addItem:resetItem];

        delegate.paramItems = paramItems;
        [paramMenuItem setSubmenu:paramMenu];

        // Window menu
        NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:windowMenuItem];
        NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
        [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
        [windowMenuItem setSubmenu:windowMenu];
        [app setWindowsMenu:windowMenu];

        [app setMainMenu:menuBar];

        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
