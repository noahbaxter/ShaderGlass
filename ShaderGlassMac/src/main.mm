#import <Cocoa/Cocoa.h>
#import "AppWindow.h"
#import "MetalRenderer.h"
#import "ScreenCapture.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, assign) AppWindow* window;
@property (nonatomic, assign) MetalRenderer* renderer;
@property (nonatomic, assign) ScreenCapture* capture;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Create window
    _window = new AppWindow();
    if (!_window->create(800, 600, "ShaderGlass")) {
        NSLog(@"Failed to create window");
        [NSApp terminate:nil];
        return;
    }

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

    // Start capturing with callback to renderer
    MetalRenderer* renderer = _renderer;
    _capture->start([renderer](CVPixelBufferRef pixelBuffer, size_t width, size_t height) {
        renderer->updateTexture(pixelBuffer, width, height);
    });

    _window->show();
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

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];

        // Create menu bar
        NSMenu* menuBar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];

        NSMenu* appMenu = [[NSMenu alloc] init];
        NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ShaderGlass"
                                                          action:@selector(terminate:)
                                                   keyEquivalent:@"q"];
        [appMenu addItem:quitItem];
        [appMenuItem setSubmenu:appMenu];

        [app setMainMenu:menuBar];

        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
