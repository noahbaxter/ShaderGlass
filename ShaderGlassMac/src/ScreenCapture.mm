/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#import "ScreenCapture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Cocoa/Cocoa.h>

@interface ScreenCaptureImpl : NSObject <SCStreamDelegate, SCStreamOutput>
@property (nonatomic, strong) SCStream* stream;
@property (nonatomic, strong) SCDisplay* display;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, assign) ScreenCapture::FrameCallback callback;
@property (nonatomic, assign) ScreenCapture::ErrorCallback errorCallback;
@property (nonatomic, weak) NSWindow* excludedWindow;
@property (nonatomic, assign) CGRect sourceRect;
@property (nonatomic, assign) CGFloat sourceScale;
@end

@implementation ScreenCaptureImpl

- (instancetype)init {
    self = [super init];
    if (self) {
        _captureQueue = dispatch_queue_create("com.shaderglass.capture", DISPATCH_QUEUE_SERIAL);
        _sourceRect = CGRectNull;
        _sourceScale = 0;
    }
    return self;
}

- (void)startWithCallback:(ScreenCapture::FrameCallback)callback {
    _callback = callback;

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent* content, NSError* error) {
        if (error) {
            NSLog(@"Failed to get shareable content: %@", error);
            if (self->_errorCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_errorCallback();
                });
            }
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupStreamWithContent:content];
        });
    }];
}

- (void)setupStreamWithContent:(SCShareableContent*)content {
    NSScreen* mainScreen = [NSScreen mainScreen];
    CGDirectDisplayID displayID = [[[mainScreen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];

    for (SCDisplay* display in content.displays) {
        if (display.displayID == displayID) {
            _display = display;
            break;
        }
    }

    if (!_display) {
        NSLog(@"Could not find main display");
        return;
    }

    // Create filter - exclude our own window
    NSMutableArray<SCWindow*>* excludedWindows = [NSMutableArray array];
    if (_excludedWindow) {
        for (SCWindow* win in content.windows) {
            if (win.windowID == (CGWindowID)[_excludedWindow windowNumber]) {
                [excludedWindows addObject:win];
                break;
            }
        }
    }

    SCContentFilter* filter;
    if (excludedWindows.count > 0) {
        filter = [[SCContentFilter alloc] initWithDisplay:_display excludingWindows:excludedWindows];
    } else {
        filter = [[SCContentFilter alloc] initWithDisplay:_display excludingWindows:@[]];
    }

    SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
    CGFloat scale = _sourceScale > 0 ? _sourceScale : mainScreen.backingScaleFactor;

    if (!CGRectIsNull(_sourceRect) && !CGRectIsEmpty(_sourceRect)) {
        // Capture specific area (underneath window mode)
        config.sourceRect = _sourceRect;
        config.width = (size_t)(_sourceRect.size.width * scale);
        config.height = (size_t)(_sourceRect.size.height * scale);
    } else {
        // Capture full display
        config.width = (size_t)(_display.width * scale);
        config.height = (size_t)(_display.height * scale);
    }

    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.showsCursor = NO;
    config.minimumFrameInterval = CMTimeMake(1, 60);

    _stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

    NSError* error = nil;
    [_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_captureQueue error:&error];
    if (error) {
        NSLog(@"Failed to add stream output: %@", error);
        return;
    }

    [_stream startCaptureWithCompletionHandler:^(NSError* error) {
        if (error) {
            NSLog(@"Failed to start capture: %@", error);
        } else {
            NSLog(@"Screen capture started");
        }
    }];
}

- (void)stop {
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:^(NSError* error) {
            if (error) {
                NSLog(@"Failed to stop capture: %@", error);
            }
        }];
        _stream = nil;
    }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    if (_callback) {
        CVPixelBufferRetain(pixelBuffer);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_callback(pixelBuffer, width, height);
            CVPixelBufferRelease(pixelBuffer);
        });
    }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    NSLog(@"Stream stopped with error: %@", error);
}

@end

ScreenCapture::ScreenCapture() {
    impl = (__bridge_retained void*)[[ScreenCaptureImpl alloc] init];
}

ScreenCapture::~ScreenCapture() {
    stop();
    CFRelease(impl);
}

bool ScreenCapture::start(FrameCallback callback) {
    ScreenCaptureImpl* captureImpl = (__bridge ScreenCaptureImpl*)impl;
    [captureImpl startWithCallback:callback];
    return true;
}

void ScreenCapture::stop() {
    ScreenCaptureImpl* captureImpl = (__bridge ScreenCaptureImpl*)impl;
    [captureImpl stop];
}

void ScreenCapture::setExcludedWindow(void* nsWindow) {
    ScreenCaptureImpl* captureImpl = (__bridge ScreenCaptureImpl*)impl;
    captureImpl.excludedWindow = (__bridge NSWindow*)nsWindow;
}

void ScreenCapture::setSourceRect(CGRect rect, CGFloat scale) {
    ScreenCaptureImpl* captureImpl = (__bridge ScreenCaptureImpl*)impl;
    captureImpl.sourceRect = rect;
    captureImpl.sourceScale = scale;
}

void ScreenCapture::setErrorCallback(ErrorCallback callback) {
    ScreenCaptureImpl* captureImpl = (__bridge ScreenCaptureImpl*)impl;
    captureImpl.errorCallback = callback;
}
