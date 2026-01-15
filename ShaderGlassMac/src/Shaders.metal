#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float textureWidth;
    float textureHeight;
    int shaderType;
    float time;
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

// 0: Passthrough - no effect
float4 passthrough(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, uv);
}

// 1: Simple scanlines
float4 scanlines(texture2d<float> tex, sampler s, float2 uv, float height) {
    float4 color = tex.sample(s, uv);
    float scanline = sin(uv.y * height * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.85, 1.0, scanline);
    return color;
}

// 2: CRT with curvature and scanlines
float4 crt(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 center = uv - 0.5;
    float dist = dot(center, center);
    float2 curved = uv + center * dist * 0.1;

    if (curved.x < 0.0 || curved.x > 1.0 || curved.y < 0.0 || curved.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    float4 color = tex.sample(s, curved);
    float scanline = sin(curved.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.75, 1.0, scanline);
    float vignette = 1.0 - dist * 0.5;
    color.rgb *= vignette;
    float2 offset = center * 0.002;
    color.r = tex.sample(s, curved + offset).r;
    color.b = tex.sample(s, curved - offset).b;
    return color;
}

// 3: LCD grid effect
float4 lcd(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float2 pixelCoord = uv * resolution;
    float2 subpixel = fract(pixelCoord);

    float3 mask;
    float xMod = fmod(floor(pixelCoord.x), 3.0);
    if (xMod < 1.0) mask = float3(1.0, 0.5, 0.5);
    else if (xMod < 2.0) mask = float3(0.5, 1.0, 0.5);
    else mask = float3(0.5, 0.5, 1.0);

    float gap = smoothstep(0.0, 0.1, subpixel.y) * smoothstep(1.0, 0.9, subpixel.y);
    color.rgb *= mask * mix(0.8, 1.0, gap);
    return color;
}

// 4: VHS effect
float4 vhs(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float time) {
    float wobble = sin(uv.y * 50.0 + time * 2.0) * 0.002;
    float2 wobblyUV = float2(uv.x + wobble, uv.y);

    float4 color = tex.sample(s, wobblyUV);
    float4 smear = tex.sample(s, wobblyUV + float2(0.004, 0));
    color.r = mix(color.r, smear.r, 0.4);
    color.rgb = floor(color.rgb * 24.0) / 24.0;

    float scanline = sin(uv.y * resolution.y * 1.5) * 0.5 + 0.5;
    color.rgb *= mix(0.88, 1.0, scanline);

    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(gray), color.rgb, 0.8);
    return color;
}

// 5: Gameboy (green monochrome with dot matrix)
float4 gameboy(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));

    // 4-level quantization like original GB
    float level = floor(gray * 4.0) / 3.0;

    // GB color palette (dark to light green)
    float3 palette[4] = {
        float3(0.06, 0.22, 0.06),  // Darkest
        float3(0.19, 0.38, 0.19),
        float3(0.55, 0.67, 0.06),
        float3(0.61, 0.74, 0.06)   // Lightest
    };

    int idx = clamp(int(gray * 3.99), 0, 3);
    float3 gbColor = palette[idx];

    // Dot matrix effect
    float2 pixelCoord = uv * resolution / 4.0;
    float2 subpixel = fract(pixelCoord);
    float dot = smoothstep(0.5, 0.3, length(subpixel - 0.5));

    gbColor *= mix(0.7, 1.0, dot);
    return float4(gbColor, 1.0);
}

// 6: Phosphor glow (bloom)
float4 phosphor(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);

    // Simple box blur for glow
    float2 texel = 1.0 / resolution;
    float4 glow = float4(0);
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            glow += tex.sample(s, uv + float2(x, y) * texel * 2.0);
        }
    }
    glow /= 25.0;

    // Scanlines
    float scanline = sin(uv.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.7, 1.0, scanline);

    // Add glow
    color.rgb += glow.rgb * 0.3;
    color.rgb = min(color.rgb, float3(1.0));

    return color;
}

// 7: NTSC artifacts
float4 ntsc(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float time) {
    // Chroma subsampling / color bleeding
    float4 color = tex.sample(s, uv);

    float2 texel = 1.0 / resolution;

    // Horizontal color bleed
    float4 left = tex.sample(s, uv - float2(texel.x * 2.0, 0));
    float4 right = tex.sample(s, uv + float2(texel.x * 2.0, 0));

    // Blend chrominance
    color.rgb = float3(
        color.r,
        mix(color.g, (left.g + right.g) * 0.5, 0.3),
        mix(color.b, (left.b + right.b) * 0.5, 0.4)
    );

    // Rainbow fringing on edges
    float edge = abs(tex.sample(s, uv + float2(texel.x, 0)).r - tex.sample(s, uv - float2(texel.x, 0)).r);
    float phase = uv.x * resolution.x * 0.5 + uv.y * 2.0;
    color.r += edge * sin(phase) * 0.15;
    color.b += edge * cos(phase) * 0.15;

    // Scanlines
    float scanline = sin(uv.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.85, 1.0, scanline);

    return color;
}

// 8: ASCII art effect
float4 ascii(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    // Block size
    float2 blockSize = float2(8.0, 16.0) / resolution;
    float2 blockUV = floor(uv / blockSize) * blockSize + blockSize * 0.5;

    float4 color = tex.sample(s, blockUV);
    float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));

    // Position within block
    float2 local = fract(uv / blockSize);

    // ASCII density patterns (simplified)
    float pattern;
    if (brightness > 0.8) {
        pattern = 1.0; // @
    } else if (brightness > 0.6) {
        // # pattern
        pattern = (fmod(local.x * 4.0, 1.0) > 0.5 || fmod(local.y * 4.0, 1.0) > 0.5) ? 1.0 : 0.0;
    } else if (brightness > 0.4) {
        // + pattern
        pattern = (abs(local.x - 0.5) < 0.15 || abs(local.y - 0.5) < 0.15) ? 1.0 : 0.0;
    } else if (brightness > 0.2) {
        // . pattern
        pattern = length(local - 0.5) < 0.2 ? 1.0 : 0.0;
    } else {
        pattern = 0.0; // space
    }

    return float4(float3(pattern) * color.rgb, 1.0);
}

// 9: Matrix rain effect
float4 matrixRain(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float time) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));

    // Column-based rain
    float col = floor(uv.x * resolution.x / 12.0);
    float rain = fract(sin(col * 43758.5453) * time * 0.5 + col * 0.1);
    float streak = smoothstep(rain, rain + 0.3, uv.y) * smoothstep(rain + 0.5, rain + 0.3, uv.y);

    // Green tint with glow
    float3 matrixColor = float3(0.0, gray, 0.0);
    matrixColor += float3(0.0, streak * 0.5, 0.0);

    // Character grid
    float2 charCoord = fract(uv * resolution / float2(12.0, 16.0));
    float charMask = step(0.1, charCoord.x) * step(charCoord.x, 0.9) *
                     step(0.1, charCoord.y) * step(charCoord.y, 0.9);

    return float4(matrixColor * (0.7 + charMask * 0.3), 1.0);
}

// 10: Thermal/heat vision
float4 thermal(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float intensity = dot(color.rgb, float3(0.299, 0.587, 0.114));

    // Thermal color gradient (black -> blue -> purple -> red -> yellow -> white)
    float3 thermal;
    if (intensity < 0.2) {
        thermal = mix(float3(0, 0, 0.2), float3(0.2, 0, 0.5), intensity * 5.0);
    } else if (intensity < 0.4) {
        thermal = mix(float3(0.2, 0, 0.5), float3(0.8, 0, 0.2), (intensity - 0.2) * 5.0);
    } else if (intensity < 0.6) {
        thermal = mix(float3(0.8, 0, 0.2), float3(1.0, 0.5, 0), (intensity - 0.4) * 5.0);
    } else if (intensity < 0.8) {
        thermal = mix(float3(1.0, 0.5, 0), float3(1.0, 1.0, 0), (intensity - 0.6) * 5.0);
    } else {
        thermal = mix(float3(1.0, 1.0, 0), float3(1.0, 1.0, 1.0), (intensity - 0.8) * 5.0);
    }

    return float4(thermal, 1.0);
}

// 11: Pixelate / mosaic
float4 pixelate(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 pixelSize = 8.0 / resolution;
    float2 pixelUV = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;
    return tex.sample(s, pixelUV);
}

// 12: CRT Aperture Grille (Trinitron style)
float4 aperture(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);

    // Vertical RGB stripes (aperture grille)
    float stripe = fmod(floor(uv.x * resolution.x), 3.0);
    float3 mask;
    if (stripe < 1.0) mask = float3(1.0, 0.0, 0.0);
    else if (stripe < 2.0) mask = float3(0.0, 1.0, 0.0);
    else mask = float3(0.0, 0.0, 1.0);

    // Blend mask with original color
    color.rgb = color.rgb * (mask * 0.5 + 0.5);

    // Scanlines
    float scanline = sin(uv.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.8, 1.0, scanline);

    // Slight bloom
    color.rgb *= 1.2;
    color.rgb = min(color.rgb, float3(1.0));

    return color;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 resolution = float2(uniforms.textureWidth, uniforms.textureHeight);

    switch (uniforms.shaderType) {
        case 0:  return passthrough(tex, s, in.texCoord);
        case 1:  return scanlines(tex, s, in.texCoord, uniforms.textureHeight);
        case 2:  return crt(tex, s, in.texCoord, resolution);
        case 3:  return lcd(tex, s, in.texCoord, resolution / 3.0);
        case 4:  return vhs(tex, s, in.texCoord, resolution, uniforms.time);
        case 5:  return gameboy(tex, s, in.texCoord, resolution);
        case 6:  return phosphor(tex, s, in.texCoord, resolution);
        case 7:  return ntsc(tex, s, in.texCoord, resolution, uniforms.time);
        case 8:  return ascii(tex, s, in.texCoord, resolution);
        case 9:  return matrixRain(tex, s, in.texCoord, resolution, uniforms.time);
        case 10: return thermal(tex, s, in.texCoord);
        case 11: return pixelate(tex, s, in.texCoord, resolution);
        case 12: return aperture(tex, s, in.texCoord, resolution);
        default: return passthrough(tex, s, in.texCoord);
    }
}
