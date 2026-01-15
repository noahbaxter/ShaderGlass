#import <Cocoa/Cocoa.h>
#import "AppWindow.h"
#import "MetalRenderer.h"
#import "ScreenCapture.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, assign) AppWindow* window;
@property (nonatomic, assign) MetalRenderer* renderer;
@property (nonatomic, assign) ScreenCapture* capture;
@property (nonatomic, assign) BOOL captureUnderneath;
@property (nonatomic, strong) NSMenuItem* captureUnderneathItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    _captureUnderneath = NO;

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

    // Create renderer
    _renderer = new MetalRenderer();
    if (!_renderer->initialize(_window->getMTKView())) {
        NSLog(@"Failed to initialize renderer");
        [NSApp terminate:nil];
        return;
    }

    // Create screen capture
    _capture = new ScreenCapture();
    _capture->setExcludedWindow(_window->getNSWindow());

    [self startCapture];
    _window->show();
}

- (void)startCapture {
    _capture->stop();

    MetalRenderer* renderer = _renderer;
    NSWindow* nsWindow = (__bridge NSWindow*)_window->getNSWindow();

    if (_captureUnderneath) {
        // Capture just the area under the window
        NSRect frame = nsWindow.frame;
        NSScreen* screen = nsWindow.screen ?: [NSScreen mainScreen];
        CGFloat scale = screen.backingScaleFactor;

        // Convert to screen coordinates (flip Y)
        NSRect screenFrame = screen.frame;
        CGRect captureRect = CGRectMake(
            frame.origin.x - screenFrame.origin.x,
            screenFrame.size.height - frame.origin.y - frame.size.height + screenFrame.origin.y,
            frame.size.width,
            frame.size.height
        );

        _capture->setSourceRect(captureRect, scale);
    } else {
        _capture->setSourceRect(CGRectNull, 0);
    }

    _capture->start([renderer](CVPixelBufferRef pixelBuffer, size_t width, size_t height) {
        renderer->updateTexture(pixelBuffer, width, height);
    });
}

- (void)applicationWillTerminate:(NSNotification*)notification {
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
    [nsWindow toggleFullScreen:nil];
}

- (void)toggleCaptureUnderneath:(id)sender {
    _captureUnderneath = !_captureUnderneath;
    _captureUnderneathItem.state = _captureUnderneath ? NSControlStateValueOn : NSControlStateValueOff;
    [self startCapture];
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

        NSMenuItem* fullscreenItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Full Screen"
                                                                action:@selector(toggleFullScreen:)
                                                         keyEquivalent:@"f"];
        fullscreenItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
        fullscreenItem.target = delegate;
        [viewMenu addItem:fullscreenItem];

        [viewMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem* captureUnderneathItem = [[NSMenuItem alloc] initWithTitle:@"Capture Area Underneath"
                                                                       action:@selector(toggleCaptureUnderneath:)
                                                                keyEquivalent:@"u"];
        captureUnderneathItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        captureUnderneathItem.target = delegate;
        delegate.captureUnderneathItem = captureUnderneathItem;
        [viewMenu addItem:captureUnderneathItem];

        [viewMenuItem setSubmenu:viewMenu];

        // Window menu (for standard window controls)
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
