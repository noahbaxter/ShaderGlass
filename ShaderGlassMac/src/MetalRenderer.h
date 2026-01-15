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

private:
    void* impl;
};
