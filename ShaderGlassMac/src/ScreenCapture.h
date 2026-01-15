#pragma once

#include <functional>
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>

class ScreenCapture {
public:
    using FrameCallback = std::function<void(CVPixelBufferRef, size_t width, size_t height)>;

    ScreenCapture();
    ~ScreenCapture();

    bool start(FrameCallback callback);
    void stop();

    void setExcludedWindow(void* nsWindow);
    void setSourceRect(CGRect rect, CGFloat scale);

private:
    void* impl;
};
