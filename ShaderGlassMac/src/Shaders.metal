#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float textureHeight;
    float scanlineIntensity;
};

constant float4 quadVertices[] = {
    float4(-1,  1, 0, 1),  // top-left
    float4(-1, -1, 0, 1),  // bottom-left
    float4( 1,  1, 0, 1),  // top-right
    float4( 1, -1, 0, 1),  // bottom-right
};

constant float2 texCoords[] = {
    float2(0, 0),  // top-left
    float2(0, 1),  // bottom-left
    float2(1, 0),  // top-right
    float2(1, 1),  // bottom-right
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = quadVertices[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float4 color = tex.sample(s, in.texCoord);

    // Simple scanline effect
    float scanline = sin(in.texCoord.y * uniforms.textureHeight * 3.14159265) * 0.5 + 0.5;
    float scanlineEffect = mix(1.0 - uniforms.scanlineIntensity, 1.0, scanline);
    color.rgb *= scanlineEffect;

    return color;
}
