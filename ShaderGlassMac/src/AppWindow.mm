#import "AppWindow.h"
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

@interface ShaderGlassWindow : NSWindow
@end

@implementation ShaderGlassWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

@end

@interface ClickThroughMTKView : MTKView
@property (nonatomic, assign) BOOL clickThrough;
@end

@implementation ClickThroughMTKView

- (NSView*)hitTest:(NSPoint)point {
    if (_clickThrough) {
        return nil;  // Pass clicks through
    }
    return [super hitTest:point];
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return !_clickThrough;
}

@end

AppWindow::AppWindow() : nsWindow(nullptr), mtkView(nullptr) {
}

AppWindow::~AppWindow() {
    close();
}

bool AppWindow::create(int width, int height, const char* title) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(100, 100, width, height);

        NSWindowStyleMask style = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable |
                                  NSWindowStyleMaskResizable;

        ShaderGlassWindow* window = [[ShaderGlassWindow alloc] initWithContentRect:frame
                                                                         styleMask:style
                                                                           backing:NSBackingStoreBuffered
                                                                             defer:NO];

        if (!window) {
            NSLog(@"Failed to create window");
            return false;
        }

        [window setTitle:[NSString stringWithUTF8String:title]];
        [window setLevel:NSFloatingWindowLevel];
        [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorStationary];

        // Make titlebar transparent
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;

        // Create MTKView (with click-through support)
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ClickThroughMTKView* view = [[ClickThroughMTKView alloc] initWithFrame:frame device:device];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.clickThrough = NO;

        [window setContentView:view];

        nsWindow = (__bridge_retained void*)window;
        mtkView = (__bridge_retained void*)view;

        return true;
    }
}

void AppWindow::show() {
    if (nsWindow) {
        NSWindow* window = (__bridge NSWindow*)nsWindow;
        [window makeKeyAndOrderFront:nil];
    }
}

void AppWindow::close() {
    if (mtkView) {
        CFRelease(mtkView);
        mtkView = nullptr;
    }
    if (nsWindow) {
        NSWindow* window = (__bridge_transfer NSWindow*)nsWindow;
        [window close];
        nsWindow = nullptr;
    }
}

void* AppWindow::getNSWindow() {
    return nsWindow;
}

void* AppWindow::getMTKView() {
    return mtkView;
}

void AppWindow::setClickThrough(bool enabled) {
    if (nsWindow) {
        NSWindow* window = (__bridge NSWindow*)nsWindow;
        window.ignoresMouseEvents = enabled;
        window.level = enabled ? NSScreenSaverWindowLevel : NSFloatingWindowLevel;
    }
}
