#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float textureWidth;
    float textureHeight;
    int shaderType;  // 0=passthrough, 1=scanlines, 2=crt, 3=lcd, 4=vhs
};

constant float4 quadVertices[] = {
    float4(-1,  1, 0, 1),
    float4(-1, -1, 0, 1),
    float4( 1,  1, 0, 1),
    float4( 1, -1, 0, 1),
};

constant float2 texCoords[] = {
    float2(0, 0),
    float2(0, 1),
    float2(1, 0),
    float2(1, 1),
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = quadVertices[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

// Passthrough - no effect
float4 passthrough(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, uv);
}

// Simple scanlines
float4 scanlines(texture2d<float> tex, sampler s, float2 uv, float height) {
    float4 color = tex.sample(s, uv);
    float scanline = sin(uv.y * height * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.85, 1.0, scanline);
    return color;
}

// CRT with curvature and scanlines
float4 crt(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    // Barrel distortion
    float2 center = uv - 0.5;
    float dist = dot(center, center);
    float2 curved = uv + center * dist * 0.1;

    // Check bounds
    if (curved.x < 0.0 || curved.x > 1.0 || curved.y < 0.0 || curved.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    float4 color = tex.sample(s, curved);

    // Scanlines
    float scanline = sin(curved.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.75, 1.0, scanline);

    // Slight vignette
    float vignette = 1.0 - dist * 0.5;
    color.rgb *= vignette;

    // RGB separation (chromatic aberration)
    float2 offset = center * 0.002;
    color.r = tex.sample(s, curved + offset).r;
    color.b = tex.sample(s, curved - offset).b;

    return color;
}

// LCD grid effect
float4 lcd(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);

    // Create LCD pixel grid
    float2 pixelCoord = uv * resolution;
    float2 subpixel = fract(pixelCoord);

    // RGB subpixel pattern
    float3 mask;
    float xMod = fmod(floor(pixelCoord.x), 3.0);
    if (xMod < 1.0) {
        mask = float3(1.0, 0.5, 0.5);
    } else if (xMod < 2.0) {
        mask = float3(0.5, 1.0, 0.5);
    } else {
        mask = float3(0.5, 0.5, 1.0);
    }

    // Horizontal pixel gaps
    float gap = smoothstep(0.0, 0.1, subpixel.y) * smoothstep(1.0, 0.9, subpixel.y);

    color.rgb *= mask * mix(0.8, 1.0, gap);
    return color;
}

// VHS effect
float4 vhs(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    // Slight horizontal wobble
    float wobble = sin(uv.y * 50.0) * 0.001;
    float2 wobblyUV = float2(uv.x + wobble, uv.y);

    float4 color = tex.sample(s, wobblyUV);

    // Color bleeding / smear
    float4 smear = tex.sample(s, wobblyUV + float2(0.003, 0));
    color.r = mix(color.r, smear.r, 0.3);

    // Reduce color depth
    color.rgb = floor(color.rgb * 32.0) / 32.0;

    // Scanlines
    float scanline = sin(uv.y * resolution.y * 1.5) * 0.5 + 0.5;
    color.rgb *= mix(0.9, 1.0, scanline);

    // Slight desaturation
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(gray), color.rgb, 0.85);

    return color;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 resolution = float2(uniforms.textureWidth, uniforms.textureHeight);

    switch (uniforms.shaderType) {
        case 0: return passthrough(tex, s, in.texCoord);
        case 1: return scanlines(tex, s, in.texCoord, uniforms.textureHeight);
        case 2: return crt(tex, s, in.texCoord, resolution);
        case 3: return lcd(tex, s, in.texCoord, resolution / 3.0);
        case 4: return vhs(tex, s, in.texCoord, resolution);
        default: return passthrough(tex, s, in.texCoord);
    }
}
