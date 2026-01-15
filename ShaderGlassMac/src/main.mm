#import <Cocoa/Cocoa.h>
#import "AppWindow.h"
#import "MetalRenderer.h"
#import "ScreenCapture.h"

static const int SHADER_COUNT = 63;

// Per-screen state
@interface ScreenState : NSObject
@property (nonatomic, assign) AppWindow* window;
@property (nonatomic, assign) MetalRenderer* renderer;
@property (nonatomic, assign) ScreenCapture* capture;
@property (nonatomic, weak) NSScreen* screen;
@end

@implementation ScreenState
- (void)dealloc {
    if (_capture) { _capture->stop(); delete _capture; }
    if (_renderer) { delete _renderer; }
    if (_window) { delete _window; }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSMutableArray<ScreenState*>* screens;
@property (nonatomic, assign) BOOL captureUnderneath;
@property (nonatomic, assign) BOOL clickThrough;
@property (nonatomic, assign) BOOL isFullscreen;
@property (nonatomic, strong) NSMenuItem* captureUnderneathItem;
@property (nonatomic, strong) NSMenuItem* clickThroughItem;
@property (nonatomic, strong) NSMenuItem* fullscreenItem;
@property (nonatomic, strong) NSArray<NSMenuItem*>* shaderItems;
@property (nonatomic, strong) id localMonitor;
@property (nonatomic, strong) id globalMonitor;
@property (nonatomic, strong) id flagsMonitor;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    _captureUnderneath = YES;  // Default ON
    _clickThrough = YES;       // Default ON
    _isFullscreen = NO;
    _screens = [NSMutableArray array];

    // Create a window for each screen
    for (NSScreen* screen in [NSScreen screens]) {
        ScreenState* state = [[ScreenState alloc] init];
        state.screen = screen;

        // Create window
        state.window = new AppWindow();
        if (!state.window->create(800, 600, "ShaderGlass")) {
            NSLog(@"Failed to create window for screen");
            continue;
        }

        // Position on this screen
        NSWindow* nsWindow = (__bridge NSWindow*)state.window->getNSWindow();
        nsWindow.delegate = self;
        [nsWindow setFrameOrigin:screen.frame.origin];

        // Create renderer
        state.renderer = new MetalRenderer();
        if (!state.renderer->initialize(state.window->getMTKView())) {
            NSLog(@"Failed to initialize renderer");
            continue;
        }

        // Create screen capture
        state.capture = new ScreenCapture();
        state.capture->setExcludedWindow(state.window->getNSWindow());

        // Apply default click-through
        state.window->setClickThrough(_clickThrough);

        [_screens addObject:state];
        state.window->show();
    }

    // Start capture for all screens
    [self startCapture];

    // Auto-enter fullscreen
    [self toggleFullScreen:nil];

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
            BOOL optionHeld = (event.modifierFlags & NSEventModifierFlagOption) != 0;
            for (ScreenState* state in self->_screens) {
                NSWindow* win = (__bridge NSWindow*)state.window->getNSWindow();
                win.ignoresMouseEvents = !optionHeld;
            }
        }
        return event;
    }];
}

- (void)startCapture {
    for (ScreenState* state in _screens) {
        state.capture->stop();

        MetalRenderer* renderer = state.renderer;
        NSWindow* nsWindow = (__bridge NSWindow*)state.window->getNSWindow();

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

            state.capture->setSourceRect(captureRect, scale);
        } else {
            state.capture->setSourceRect(CGRectNull, 0);
        }

        state.capture->start([renderer](CVPixelBufferRef pixelBuffer, size_t width, size_t height) {
            renderer->updateTexture(pixelBuffer, width, height);
        });
    }
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    if (_localMonitor) {
        [NSEvent removeMonitor:_localMonitor];
    }
    if (_globalMonitor) {
        [NSEvent removeMonitor:_globalMonitor];
    }
    if (_flagsMonitor) {
        [NSEvent removeMonitor:_flagsMonitor];
    }
    [_screens removeAllObjects];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

#pragma mark - Menu Actions

- (void)toggleFullScreen:(id)sender {
    if (!_isFullscreen) {
        // Go fullscreen on all screens
        for (ScreenState* state in _screens) {
            NSWindow* nsWindow = (__bridge NSWindow*)state.window->getNSWindow();
            NSScreen* screen = state.screen ?: nsWindow.screen ?: [NSScreen mainScreen];
            NSRect screenFrame = screen.frame;

            nsWindow.styleMask = NSWindowStyleMaskBorderless;
            nsWindow.level = NSMainMenuWindowLevel + 1;
            [nsWindow setFrame:screenFrame display:YES animate:NO];
            [nsWindow makeKeyAndOrderFront:nil];
        }
        _isFullscreen = YES;
        _fullscreenItem.title = @"Exit Full Screen";
    } else {
        // Restore windows
        for (ScreenState* state in _screens) {
            NSWindow* nsWindow = (__bridge NSWindow*)state.window->getNSWindow();
            NSScreen* screen = state.screen ?: nsWindow.screen ?: [NSScreen mainScreen];

            nsWindow.styleMask = NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable |
                                 NSWindowStyleMaskResizable;
            nsWindow.titlebarAppearsTransparent = YES;
            nsWindow.titleVisibility = NSWindowTitleHidden;
            nsWindow.level = _clickThrough ? NSScreenSaverWindowLevel : NSFloatingWindowLevel;

            // Center on screen at reasonable size
            NSRect frame = NSMakeRect(
                screen.frame.origin.x + (screen.frame.size.width - 800) / 2,
                screen.frame.origin.y + (screen.frame.size.height - 600) / 2,
                800, 600
            );
            [nsWindow setFrame:frame display:YES animate:NO];
        }
        _isFullscreen = NO;
        _fullscreenItem.title = @"Enter Full Screen";
    }

    // Restart capture if in underneath mode
    if (_captureUnderneath) {
        [self startCapture];
    }
}

- (void)toggleCaptureUnderneath:(id)sender {
    _captureUnderneath = !_captureUnderneath;
    _captureUnderneathItem.state = _captureUnderneath ? NSControlStateValueOn : NSControlStateValueOff;
    [self startCapture];
}

- (void)toggleClickThrough:(id)sender {
    _clickThrough = !_clickThrough;
    _clickThroughItem.state = _clickThrough ? NSControlStateValueOn : NSControlStateValueOff;
    for (ScreenState* state in _screens) {
        state.window->setClickThrough(_clickThrough);
    }
}

- (void)selectShader:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    int shaderType = (int)item.tag;
    for (ScreenState* state in _screens) {
        state.renderer->setShaderType(shaderType);
    }
    [self updateShaderCheckmarks:shaderType];
}

- (void)randomizeShader:(id)sender {
    int newShader = arc4random_uniform(SHADER_COUNT);
    for (ScreenState* state in _screens) {
        state.renderer->setShaderType(newShader);
    }
    [self updateShaderCheckmarks:newShader];
}

- (void)updateShaderCheckmarks:(int)shaderType {
    for (NSMenuItem* shaderItem in _shaderItems) {
        shaderItem.state = (shaderItem.tag == shaderType) ? NSControlStateValueOn : NSControlStateValueOff;
    }
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
        [appMenu addItemWithTitle:@"About ShaderGlass" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
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
        captureUnderneathItem.state = NSControlStateValueOn;  // Default ON
        delegate.captureUnderneathItem = captureUnderneathItem;
        [viewMenu addItem:captureUnderneathItem];

        NSMenuItem* clickThroughItem = [[NSMenuItem alloc] initWithTitle:@"Click Through (Lock)"
                                                                  action:@selector(toggleClickThrough:)
                                                           keyEquivalent:@"l"];
        clickThroughItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        clickThroughItem.target = delegate;
        clickThroughItem.state = NSControlStateValueOn;  // Default ON
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
            item.state = (i == 1) ? NSControlStateValueOn : NSControlStateValueOff;
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
