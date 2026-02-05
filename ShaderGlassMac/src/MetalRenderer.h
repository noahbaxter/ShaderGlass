/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#pragma once

#include <CoreVideo/CoreVideo.h>

class MetalRenderer {
public:
    MetalRenderer();
    ~MetalRenderer();

    bool initialize(void* mtkView);
    void updateTexture(CVPixelBufferRef pixelBuffer, size_t width, size_t height);
    void render();
    void resize(float width, float height);
    void setShaderType(int type);
    int getShaderType();
    void setParam(int index, float value);
    float getParam(int index);

private:
    void* impl;
};
