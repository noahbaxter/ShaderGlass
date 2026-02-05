/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#pragma once

#include <functional>
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>

class ScreenCapture {
public:
    using FrameCallback = std::function<void(CVPixelBufferRef, size_t width, size_t height)>;
    using ErrorCallback = std::function<void()>;

    ScreenCapture();
    ~ScreenCapture();

    bool start(FrameCallback callback);
    void stop();

    void setExcludedWindow(void* nsWindow);
    void setSourceRect(CGRect rect, CGFloat scale);
    void setErrorCallback(ErrorCallback callback);

private:
    void* impl;
};
