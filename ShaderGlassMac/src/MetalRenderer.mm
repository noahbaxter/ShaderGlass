/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#import "MetalRenderer.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

struct Vertex {
    simd_float4 position;
    simd_float2 texCoord;
};

struct Uniforms {
    float textureWidth;
    float textureHeight;
    int shaderType;
    float time;
    float paramIntensity;
    float paramCurvature;
    float paramScanline;
    float paramBlur;
    float paramColorBleed;
};

@interface MetalRendererImpl : NSObject <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLTexture> sourceTexture;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, weak) MTKView* mtkView;
@property (nonatomic, assign) Uniforms uniforms;
@end

@implementation MetalRendererImpl

- (instancetype)init {
    self = [super init];
    if (self) {
        _uniforms.textureWidth = 0.0;
        _uniforms.textureHeight = 0.0;
        _uniforms.shaderType = 1;
        _uniforms.time = 0.0;
        _uniforms.paramIntensity = 0.5;
        _uniforms.paramCurvature = 0.5;
        _uniforms.paramScanline = 0.5;
        _uniforms.paramBlur = 0.5;
        _uniforms.paramColorBleed = 0.5;
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
    }
}

- (BOOL)initializeWithView:(MTKView*)view {
    _mtkView = view;
    _device = view.device;

    if (!_device) {
        _device = MTLCreateSystemDefaultDevice();
        view.device = _device;
    }

    if (!_device) {
        NSLog(@"Metal is not supported on this device");
        return NO;
    }

    _commandQueue = [_device newCommandQueue];
    CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textureCache);

    NSString* libraryPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    NSError* error = nil;
    id<MTLLibrary> library;

    if (libraryPath) {
        library = [_device newLibraryWithFile:libraryPath error:&error];
    } else {
        library = [_device newDefaultLibrary];
    }

    if (!library) {
        NSLog(@"Failed to load Metal library: %@", error);
        return NO;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragmentShader"];

    if (!vertexFunc || !fragmentFunc) {
        NSLog(@"Failed to load shader functions");
        return NO;
    }

    MTLRenderPipelineDescriptor* pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat;

    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to create pipeline state: %@", error);
        return NO;
    }

    Vertex vertices[] = {
        { .position = {-1,  1, 0, 1}, .texCoord = {0, 0} },
        { .position = {-1, -1, 0, 1}, .texCoord = {0, 1} },
        { .position = { 1,  1, 0, 1}, .texCoord = {1, 0} },
        { .position = { 1, -1, 0, 1}, .texCoord = {1, 1} },
    };
    _vertexBuffer = [_device newBufferWithBytes:vertices
                                         length:sizeof(vertices)
                                        options:MTLResourceStorageModeShared];

    view.delegate = self;
    view.enableSetNeedsDisplay = NO;
    view.preferredFramesPerSecond = 60;
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

    return YES;
}

- (void)updateTextureWithPixelBuffer:(CVPixelBufferRef)pixelBuffer width:(size_t)width height:(size_t)height {
    if (!pixelBuffer || !_textureCache) return;

    CVMetalTextureRef cvTexture = NULL;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        NULL,
        _textureCache,
        pixelBuffer,
        NULL,
        MTLPixelFormatBGRA8Unorm,
        width,
        height,
        0,
        &cvTexture
    );

    if (result == kCVReturnSuccess && cvTexture) {
        _sourceTexture = CVMetalTextureGetTexture(cvTexture);
        _uniforms.textureWidth = (float)width;
        _uniforms.textureHeight = (float)height;
        CFRelease(cvTexture);
    }

    CVMetalTextureCacheFlush(_textureCache, 0);
}

- (void)setShaderType:(int)type {
    _uniforms.shaderType = type;
}

- (int)shaderType {
    return _uniforms.shaderType;
}

- (void)setParam:(int)index value:(float)value {
    switch (index) {
        case 0: _uniforms.paramIntensity = value; break;
        case 1: _uniforms.paramCurvature = value; break;
        case 2: _uniforms.paramScanline = value; break;
        case 3: _uniforms.paramBlur = value; break;
        case 4: _uniforms.paramColorBleed = value; break;
    }
}

- (float)getParam:(int)index {
    switch (index) {
        case 0: return _uniforms.paramIntensity;
        case 1: return _uniforms.paramCurvature;
        case 2: return _uniforms.paramScanline;
        case 3: return _uniforms.paramBlur;
        case 4: return _uniforms.paramColorBleed;
        default: return 0.0;
    }
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView*)view {
    if (!_sourceTexture) return;

    // Update time for animated shaders
    _uniforms.time += 1.0 / 60.0;

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    MTLRenderPassDescriptor* renderPass = view.currentRenderPassDescriptor;

    if (!renderPass) return;

    renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];

    [encoder setRenderPipelineState:_pipelineState];
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [encoder setFragmentTexture:_sourceTexture atIndex:0];
    [encoder setFragmentBytes:&_uniforms length:sizeof(Uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

@end

MetalRenderer::MetalRenderer() {
    impl = (__bridge_retained void*)[[MetalRendererImpl alloc] init];
}

MetalRenderer::~MetalRenderer() {
    CFRelease(impl);
}

bool MetalRenderer::initialize(void* mtkView) {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    return [renderer initializeWithView:(__bridge MTKView*)mtkView];
}

void MetalRenderer::updateTexture(CVPixelBufferRef pixelBuffer, size_t width, size_t height) {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    [renderer updateTextureWithPixelBuffer:pixelBuffer width:width height:height];
}

void MetalRenderer::setShaderType(int type) {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    [renderer setShaderType:type];
}

int MetalRenderer::getShaderType() {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    return [renderer shaderType];
}

void MetalRenderer::setParam(int index, float value) {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    [renderer setParam:index value:value];
}

float MetalRenderer::getParam(int index) {
    MetalRendererImpl* renderer = (__bridge MetalRendererImpl*)impl;
    return [renderer getParam:index];
}
