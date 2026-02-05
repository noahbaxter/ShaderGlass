/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

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
    float paramIntensity;   // 0-1: overall effect strength
    float paramCurvature;   // 0-1: CRT curvature amount
    float paramScanline;    // 0-1: scanline visibility
    float paramBlur;        // 0-1: glow/blur amount
    float paramColorBleed;  // 0-1: chromatic aberration
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
float4 scanlines(texture2d<float> tex, sampler s, float2 uv, float height, float scanWeight) {
    float4 color = tex.sample(s, uv);
    float scanline = sin(uv.y * height * 3.14159265) * 0.5 + 0.5;
    float depth = mix(0.85, 1.0, 1.0 - scanWeight * 0.3);
    color.rgb *= mix(depth, 1.0, scanline);
    return color;
}

// 2: CRT with curvature and scanlines
float4 crt(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
           float curvature, float scanWeight, float colorBleed) {
    float2 center = uv - 0.5;
    float dist = dot(center, center);
    float curveAmount = curvature * 0.2;
    float2 curved = uv + center * dist * curveAmount;

    if (curved.x < 0.0 || curved.x > 1.0 || curved.y < 0.0 || curved.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    float4 color = tex.sample(s, curved);
    float scanline = sin(curved.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    float scanDepth = mix(0.75, 1.0, 1.0 - scanWeight * 0.5);
    color.rgb *= mix(scanDepth, 1.0, scanline);
    float vignette = 1.0 - dist * 0.5;
    color.rgb *= vignette;
    float2 offset = center * colorBleed * 0.004;
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
float4 phosphor(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
                float scanWeight, float blurAmount) {
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
    float scanDepth = mix(0.7, 1.0, 1.0 - scanWeight * 0.6);
    color.rgb *= mix(scanDepth, 1.0, scanline);

    // Add glow
    color.rgb += glow.rgb * blurAmount * 0.6;
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
    float stripe = fmod(floor(uv.x * resolution.x), 3.0);
    float3 mask;
    if (stripe < 1.0) mask = float3(1.0, 0.0, 0.0);
    else if (stripe < 2.0) mask = float3(0.0, 1.0, 0.0);
    else mask = float3(0.0, 0.0, 1.0);
    color.rgb = color.rgb * (mask * 0.5 + 0.5);
    float scanline = sin(uv.y * resolution.y * 3.14159265) * 0.5 + 0.5;
    color.rgb *= mix(0.8, 1.0, scanline);
    color.rgb *= 1.2;
    color.rgb = min(color.rgb, float3(1.0));
    return color;
}

// Helper: pseudo-random
float rand(float2 co) {
    return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

// 13: Chromatic Aberration (heavy RGB split)
float4 chromatic(texture2d<float> tex, sampler s, float2 uv, float colorBleed) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float strength = dist * colorBleed * 0.08;
    float2 dir = normalize(center + 0.0001);
    float r = tex.sample(s, uv + dir * strength).r;
    float g = tex.sample(s, uv).g;
    float b = tex.sample(s, uv - dir * strength).b;
    return float4(r, g, b, 1.0);
}

// 14: Glitch / Data Corruption
float4 glitch(texture2d<float> tex, sampler s, float2 uv, float time) {
    float glitchLine = step(0.98, rand(float2(floor(uv.y * 50.0), floor(time * 10.0))));
    float offset = glitchLine * (rand(float2(time, uv.y)) - 0.5) * 0.2;
    float2 glitchUV = float2(uv.x + offset, uv.y);
    float4 color = tex.sample(s, glitchUV);
    if (glitchLine > 0.5) {
        float shift = rand(float2(uv.y, time)) * 0.1;
        color.r = tex.sample(s, glitchUV + float2(shift, 0)).r;
        color.b = tex.sample(s, glitchUV - float2(shift, 0)).b;
    }
    float blockGlitch = step(0.995, rand(float2(floor(uv.x * 20.0), floor(time * 5.0))));
    if (blockGlitch > 0.5) color.rgb = 1.0 - color.rgb;
    return color;
}

// 15: Old Film (scratches, grain, sepia, vignette)
float4 oldFilm(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = float3(gray * 1.2, gray * 1.0, gray * 0.7);
    float grain = rand(uv + fract(time)) * 0.15;
    color.rgb += grain - 0.075;
    float scratch = step(0.998, rand(float2(floor(uv.x * 500.0), time)));
    color.rgb += scratch * 0.3;
    float flicker = 0.95 + rand(float2(time, 0.0)) * 0.1;
    color.rgb *= flicker;
    float vignette = 1.0 - length(uv - 0.5) * 0.8;
    color.rgb *= vignette;
    return color;
}

// 16: Underwater (wobble + blue tint + caustics)
float4 underwater(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 wobble = float2(
        sin(uv.y * 20.0 + time * 2.0) * 0.01,
        cos(uv.x * 20.0 + time * 1.5) * 0.01
    );
    float4 color = tex.sample(s, uv + wobble);
    color.rgb *= float3(0.6, 0.85, 1.0);
    float caustic = sin(uv.x * 50.0 + time) * sin(uv.y * 50.0 + time * 1.3) * 0.5 + 0.5;
    color.rgb += caustic * 0.1 * float3(0.5, 0.7, 1.0);
    color.rgb *= 0.7 + 0.3 * (1.0 - uv.y);
    return color;
}

// 17: Heat Haze / Mirage
float4 heatHaze(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 distort = float2(
        sin(uv.y * 30.0 + time * 3.0) * cos(uv.x * 20.0 + time * 2.0),
        cos(uv.y * 25.0 + time * 2.5) * sin(uv.x * 25.0 + time * 1.8)
    ) * 0.008;
    return tex.sample(s, uv + distort);
}

// 18: Drunk / Dizzy
float4 drunk(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 center = uv - 0.5;
    float angle = sin(time * 0.5) * 0.1;
    float2 rotated;
    rotated.x = center.x * cos(angle) - center.y * sin(angle);
    rotated.y = center.x * sin(angle) + center.y * cos(angle);
    float2 newUV = rotated + 0.5;
    float blur = 0.005 + sin(time * 2.0) * 0.003;
    float4 color = tex.sample(s, newUV);
    color += tex.sample(s, newUV + float2(blur, 0));
    color += tex.sample(s, newUV - float2(blur, 0));
    color += tex.sample(s, newUV + float2(0, blur));
    color += tex.sample(s, newUV - float2(0, blur));
    color /= 5.0;
    float doubleVision = 0.02 + sin(time) * 0.01;
    float4 ghost = tex.sample(s, newUV + float2(doubleVision, 0));
    color = mix(color, ghost, 0.3);
    return color;
}

// 19: Hologram
float4 hologram(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float scanline = sin(uv.y * 200.0 + time * 10.0) * 0.5 + 0.5;
    float flicker = 0.8 + sin(time * 30.0) * 0.2;
    float3 holo = float3(0.2, 0.9, 1.0) * gray;
    holo *= scanline * 0.3 + 0.7;
    holo *= flicker;
    float edge = abs(tex.sample(s, uv + float2(0.002, 0)).r - color.r) +
                 abs(tex.sample(s, uv + float2(0, 0.002)).r - color.r);
    holo += edge * float3(0, 1, 1) * 2.0;
    float glitchBand = step(0.97, sin(uv.y * 100.0 + time * 50.0));
    holo += glitchBand * float3(0, 0.5, 0.5);
    return float4(holo, 0.8);
}

// 20: X-Ray / Negative
float4 xray(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    gray = 1.0 - gray;
    gray = pow(gray, 1.5);
    return float4(gray * 0.8, gray * 0.9, gray * 1.0, 1.0);
}

// 21: Night Vision (green + noise + vignette)
float4 nightVision(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    gray = pow(gray, 0.7);
    float noise = rand(uv + fract(time * 100.0)) * 0.2;
    gray += noise - 0.1;
    float vignette = 1.0 - pow(length(uv - 0.5) * 1.5, 2.0);
    gray *= vignette;
    float scanline = sin(uv.y * 500.0) * 0.05 + 0.95;
    gray *= scanline;
    return float4(gray * 0.2, gray * 1.0, gray * 0.2, 1.0);
}

// 22: Surveillance Camera
float4 surveillance(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(gray), color.rgb, 0.3);
    color.rgb *= 0.9;
    float scanline = sin(uv.y * 400.0 + time * 5.0) * 0.03 + 0.97;
    color.rgb *= scanline;
    float noise = rand(uv + fract(time * 60.0)) * 0.08;
    color.rgb += noise - 0.04;
    float vignette = 1.0 - pow(length(uv - 0.5) * 1.2, 2.5);
    color.rgb *= vignette;
    float interference = sin(uv.y * 100.0 + time * 20.0) * 0.02;
    color.rgb += interference;
    return color;
}

// 23: VCR Tracking Errors
float4 vcrTracking(texture2d<float> tex, sampler s, float2 uv, float time) {
    float trackingNoise = sin(time * 0.5) * 0.5 + 0.5;
    float band = smoothstep(0.0, 0.1, abs(uv.y - trackingNoise)) *
                 smoothstep(0.0, 0.1, abs(uv.y - trackingNoise - 0.15));
    float offset = (1.0 - band) * 0.3;
    float2 trackUV = float2(fract(uv.x + offset), uv.y);
    float4 color = tex.sample(s, trackUV);
    color.rgb *= band * 0.5 + 0.5;
    float noise = rand(float2(uv.y, time)) * (1.0 - band) * 0.5;
    color.rgb += noise;
    float staticNoise = rand(uv + time) * (1.0 - band) * 0.3;
    color.rgb = mix(color.rgb, float3(staticNoise), 1.0 - band);
    return color;
}

// 24: Broken TV (rolling)
float4 brokenTV(texture2d<float> tex, sampler s, float2 uv, float time) {
    float roll = fract(time * 0.3);
    float2 rollUV = float2(uv.x, fract(uv.y + roll));
    float4 color = tex.sample(s, rollUV);
    float rollLine = smoothstep(0.0, 0.02, abs(rollUV.y - roll)) *
                     smoothstep(0.0, 0.02, abs(rollUV.y - roll - 0.05));
    color.rgb *= rollLine * 0.5 + 0.5;
    float hSync = step(0.98, sin(uv.y * 500.0 + time * 100.0));
    color.r = mix(color.r, tex.sample(s, rollUV + float2(hSync * 0.1, 0)).r, 0.5);
    float brightness = 0.7 + sin(time * 10.0) * 0.3;
    color.rgb *= brightness;
    return color;
}

// 25: Static / Snow
float4 staticNoise(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float noise = rand(uv * 1000.0 + time * 100.0);
    float staticAmount = 0.3;
    color.rgb = mix(color.rgb, float3(noise), staticAmount);
    return color;
}

// 26: Rainbow Shift
float4 rainbowShift(texture2d<float> tex, sampler s, float2 uv, float time) {
    float shift = sin(uv.y * 10.0 + time) * 0.1;
    float r = tex.sample(s, uv + float2(shift, 0)).r;
    float g = tex.sample(s, uv + float2(shift * 0.5, 0)).g;
    float b = tex.sample(s, uv).b;
    float hueShift = uv.y + time * 0.2;
    float3 color = float3(r, g, b);
    float3 shifted;
    shifted.r = color.r * (0.5 + 0.5 * sin(hueShift * 6.28));
    shifted.g = color.g * (0.5 + 0.5 * sin(hueShift * 6.28 + 2.09));
    shifted.b = color.b * (0.5 + 0.5 * sin(hueShift * 6.28 + 4.18));
    return float4(mix(color, shifted, 0.5), 1.0);
}

// 27: Kaleidoscope
float4 kaleidoscope(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 center = uv - 0.5;
    float angle = atan2(center.y, center.x);
    float radius = length(center);
    int segments = 8;
    float segAngle = 6.28318 / float(segments);
    angle = fmod(abs(angle), segAngle);
    if (fmod(floor(abs(atan2(center.y, center.x)) / segAngle), 2.0) > 0.5) {
        angle = segAngle - angle;
    }
    angle += time * 0.2;
    float2 newUV = float2(cos(angle), sin(angle)) * radius + 0.5;
    return tex.sample(s, newUV);
}

// 28: Halftone (comic book dots)
float4 halftone(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float dotSize = 6.0;
    float2 pixelCoord = uv * resolution / dotSize;
    float2 center = (floor(pixelCoord) + 0.5) * dotSize / resolution;
    float4 color = tex.sample(s, center);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float2 local = fract(pixelCoord) - 0.5;
    float dist = length(local);
    float radius = gray * 0.7;
    float dot = smoothstep(radius + 0.05, radius - 0.05, dist);
    return float4(float3(dot), 1.0);
}

// 29: Sketch / Pencil
float4 sketch(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = tex.sample(s, uv);
    float tl = dot(tex.sample(s, uv + float2(-texel.x, -texel.y)).rgb, float3(0.333));
    float t  = dot(tex.sample(s, uv + float2(0, -texel.y)).rgb, float3(0.333));
    float tr = dot(tex.sample(s, uv + float2(texel.x, -texel.y)).rgb, float3(0.333));
    float l  = dot(tex.sample(s, uv + float2(-texel.x, 0)).rgb, float3(0.333));
    float r  = dot(tex.sample(s, uv + float2(texel.x, 0)).rgb, float3(0.333));
    float bl = dot(tex.sample(s, uv + float2(-texel.x, texel.y)).rgb, float3(0.333));
    float b  = dot(tex.sample(s, uv + float2(0, texel.y)).rgb, float3(0.333));
    float br = dot(tex.sample(s, uv + float2(texel.x, texel.y)).rgb, float3(0.333));
    float gx = -tl - 2.0*l - bl + tr + 2.0*r + br;
    float gy = -tl - 2.0*t - tr + bl + 2.0*b + br;
    float edge = 1.0 - sqrt(gx*gx + gy*gy);
    edge = pow(edge, 2.0);
    float paper = 0.95 + rand(uv * 500.0) * 0.05;
    return float4(float3(edge * paper), 1.0);
}

// 30: Emboss
float4 emboss(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = tex.sample(s, uv);
    float4 tl = tex.sample(s, uv + float2(-texel.x, -texel.y));
    float4 br = tex.sample(s, uv + float2(texel.x, texel.y));
    float3 diff = (br.rgb - tl.rgb) * 2.0 + 0.5;
    return float4(diff, 1.0);
}

// 31: Edge Detection (Sobel)
float4 edgeDetect(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float tl = dot(tex.sample(s, uv + float2(-texel.x, -texel.y)).rgb, float3(0.333));
    float t  = dot(tex.sample(s, uv + float2(0, -texel.y)).rgb, float3(0.333));
    float tr = dot(tex.sample(s, uv + float2(texel.x, -texel.y)).rgb, float3(0.333));
    float l  = dot(tex.sample(s, uv + float2(-texel.x, 0)).rgb, float3(0.333));
    float r  = dot(tex.sample(s, uv + float2(texel.x, 0)).rgb, float3(0.333));
    float bl = dot(tex.sample(s, uv + float2(-texel.x, texel.y)).rgb, float3(0.333));
    float b  = dot(tex.sample(s, uv + float2(0, texel.y)).rgb, float3(0.333));
    float br = dot(tex.sample(s, uv + float2(texel.x, texel.y)).rgb, float3(0.333));
    float gx = -tl - 2.0*l - bl + tr + 2.0*r + br;
    float gy = -tl - 2.0*t - tr + bl + 2.0*b + br;
    float edge = sqrt(gx*gx + gy*gy);
    return float4(float3(edge), 1.0);
}

// 32: Neon Glow
float4 neonGlow(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float time) {
    float2 texel = 1.0 / resolution;
    float4 color = tex.sample(s, uv);
    float tl = dot(tex.sample(s, uv + float2(-texel.x, -texel.y)).rgb, float3(0.333));
    float t  = dot(tex.sample(s, uv + float2(0, -texel.y)).rgb, float3(0.333));
    float tr = dot(tex.sample(s, uv + float2(texel.x, -texel.y)).rgb, float3(0.333));
    float l  = dot(tex.sample(s, uv + float2(-texel.x, 0)).rgb, float3(0.333));
    float r  = dot(tex.sample(s, uv + float2(texel.x, 0)).rgb, float3(0.333));
    float bl = dot(tex.sample(s, uv + float2(-texel.x, texel.y)).rgb, float3(0.333));
    float b  = dot(tex.sample(s, uv + float2(0, texel.y)).rgb, float3(0.333));
    float br = dot(tex.sample(s, uv + float2(texel.x, texel.y)).rgb, float3(0.333));
    float gx = -tl - 2.0*l - bl + tr + 2.0*r + br;
    float gy = -tl - 2.0*t - tr + bl + 2.0*b + br;
    float edge = sqrt(gx*gx + gy*gy);
    float hue = fract(uv.x + uv.y + time * 0.2);
    float3 neon;
    neon.r = 0.5 + 0.5 * sin(hue * 6.28);
    neon.g = 0.5 + 0.5 * sin(hue * 6.28 + 2.09);
    neon.b = 0.5 + 0.5 * sin(hue * 6.28 + 4.18);
    float4 glow = float4(0);
    for (int x = -3; x <= 3; x++) {
        for (int y = -3; y <= 3; y++) {
            glow += tex.sample(s, uv + float2(x, y) * texel * 2.0);
        }
    }
    glow /= 49.0;
    float3 result = edge * neon * 2.0 + glow.rgb * neon * 0.5;
    return float4(result, 1.0);
}

// 33: Cyberpunk (high contrast + color shift)
float4 cyberpunk(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    color.rgb = pow(color.rgb, float3(1.2));
    color.rgb = (color.rgb - 0.5) * 1.5 + 0.5;
    float3 tint1 = float3(1.0, 0.2, 0.6);
    float3 tint2 = float3(0.2, 0.8, 1.0);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(color.rgb * tint1, color.rgb * tint2, gray);
    float scanline = sin(uv.y * 400.0) * 0.05 + 0.95;
    color.rgb *= scanline;
    float noise = rand(uv + time) * 0.05;
    color.rgb += noise;
    return color;
}

// 34: Vaporwave (pink/cyan aesthetic)
float4 vaporwave(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float2 center = uv - 0.5;
    float dist = length(center);
    float2 curved = uv + center * dist * 0.1;
    color = tex.sample(s, curved);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float3 vapor;
    vapor.r = mix(color.r, gray, 0.3) * 1.2;
    vapor.g = mix(color.g, gray, 0.5) * 0.7;
    vapor.b = mix(color.b, gray, 0.2) * 1.3;
    vapor = mix(vapor, float3(1.0, 0.4, 0.8), 0.15);
    vapor = mix(vapor, float3(0.3, 0.9, 0.9), gray * 0.2);
    float scanline = sin(uv.y * 300.0 + time) * 0.03 + 0.97;
    vapor *= scanline;
    float sun = smoothstep(0.3, 0.0, length(uv - float2(0.5, 0.7)));
    vapor += sun * float3(1.0, 0.5, 0.3) * 0.3;
    return float4(vapor, 1.0);
}

// 35: Ordered Dither (Bayer 4x4)
float4 orderedDither(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    int2 pixelCoord = int2(uv * resolution);
    int x = pixelCoord.x % 4;
    int y = pixelCoord.y % 4;
    // Inline Bayer 4x4 threshold calculation
    float threshold;
    int idx = x + y * 4;
    if (idx == 0) threshold = 0.0/16.0;
    else if (idx == 1) threshold = 8.0/16.0;
    else if (idx == 2) threshold = 2.0/16.0;
    else if (idx == 3) threshold = 10.0/16.0;
    else if (idx == 4) threshold = 12.0/16.0;
    else if (idx == 5) threshold = 4.0/16.0;
    else if (idx == 6) threshold = 14.0/16.0;
    else if (idx == 7) threshold = 6.0/16.0;
    else if (idx == 8) threshold = 3.0/16.0;
    else if (idx == 9) threshold = 11.0/16.0;
    else if (idx == 10) threshold = 1.0/16.0;
    else if (idx == 11) threshold = 9.0/16.0;
    else if (idx == 12) threshold = 15.0/16.0;
    else if (idx == 13) threshold = 7.0/16.0;
    else if (idx == 14) threshold = 13.0/16.0;
    else threshold = 5.0/16.0;
    float3 quantized;
    quantized.r = step(threshold, color.r);
    quantized.g = step(threshold, color.g);
    quantized.b = step(threshold, color.b);
    return float4(quantized, 1.0);
}

// 36: CGA 4-Color
float4 cga(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 pixelSize = 4.0 / resolution;
    float2 pixelUV = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;
    float4 color = tex.sample(s, pixelUV);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float3 cgaColors[4] = {
        float3(0, 0, 0),
        float3(0, 1, 1),
        float3(1, 0, 1),
        float3(1, 1, 1)
    };
    int idx = clamp(int(gray * 4.0), 0, 3);
    return float4(cgaColors[idx], 1.0);
}

// 37: Amber Monitor
float4 amberMonitor(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    gray = pow(gray, 0.9);
    float scanline = sin(uv.y * resolution.y * 3.14159) * 0.15 + 0.85;
    gray *= scanline;
    float glow = gray * 1.2;
    float2 center = uv - 0.5;
    float vignette = 1.0 - dot(center, center) * 0.5;
    gray *= vignette;
    return float4(gray * 1.0, gray * 0.7, gray * 0.1, 1.0);
}

// 38: Green Monitor (classic terminal)
float4 greenMonitor(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    gray = pow(gray, 0.85);
    float scanline = sin(uv.y * resolution.y * 3.14159) * 0.2 + 0.8;
    gray *= scanline;
    float2 center = uv - 0.5;
    float curve = dot(center, center) * 0.1;
    float vignette = 1.0 - dot(center, center) * 0.6;
    gray *= vignette;
    float bloom = 0.0;
    float2 texel = 1.0 / resolution;
    for (int i = -2; i <= 2; i++) {
        bloom += dot(tex.sample(s, uv + float2(i, 0) * texel * 2.0).rgb, float3(0.333));
    }
    bloom /= 5.0;
    gray = mix(gray, bloom, 0.2);
    return float4(gray * 0.2, gray * 1.0, gray * 0.3, 1.0);
}

// 39: Paper / Newspaper
float4 newspaper(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float dotSize = 4.0;
    float2 pixelCoord = uv * resolution / dotSize;
    float2 center = (floor(pixelCoord) + 0.5) * dotSize / resolution;
    float4 color = tex.sample(s, center);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float2 local = fract(pixelCoord) - 0.5;
    float dist = length(local);
    float radius = (1.0 - gray) * 0.6;
    float dot = smoothstep(radius + 0.1, radius - 0.1, dist);
    float paper = 0.95 + rand(floor(uv * 200.0)) * 0.05;
    float3 result = mix(float3(0.1, 0.08, 0.05), float3(0.9, 0.87, 0.8) * paper, dot);
    return float4(result, 1.0);
}

// 40: Blueprint
float4 blueprint(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = tex.sample(s, uv);
    float tl = dot(tex.sample(s, uv + float2(-texel.x, -texel.y)).rgb, float3(0.333));
    float tr = dot(tex.sample(s, uv + float2(texel.x, -texel.y)).rgb, float3(0.333));
    float bl = dot(tex.sample(s, uv + float2(-texel.x, texel.y)).rgb, float3(0.333));
    float br = dot(tex.sample(s, uv + float2(texel.x, texel.y)).rgb, float3(0.333));
    float t = dot(tex.sample(s, uv + float2(0, -texel.y)).rgb, float3(0.333));
    float b = dot(tex.sample(s, uv + float2(0, texel.y)).rgb, float3(0.333));
    float l = dot(tex.sample(s, uv + float2(-texel.x, 0)).rgb, float3(0.333));
    float r = dot(tex.sample(s, uv + float2(texel.x, 0)).rgb, float3(0.333));
    float gx = -tl - 2.0*l - bl + tr + 2.0*r + br;
    float gy = -tl - 2.0*t - tr + bl + 2.0*b + br;
    float edge = sqrt(gx*gx + gy*gy);
    float grid = step(0.98, fract(uv.x * 50.0)) + step(0.98, fract(uv.y * 50.0));
    grid *= 0.1;
    float3 bg = float3(0.1, 0.2, 0.4);
    float3 line = float3(0.7, 0.8, 1.0);
    float3 result = mix(bg, line, edge * 2.0 + grid);
    return float4(result, 1.0);
}

// 41: Dot Matrix Printer
float4 dotMatrix(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float dotSize = 3.0;
    float2 pixelCoord = uv * resolution / dotSize;
    float2 center = (floor(pixelCoord) + 0.5) * dotSize / resolution;
    float4 color = tex.sample(s, center);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float2 local = fract(pixelCoord);
    float horiz = step(0.3, local.x) * step(local.x, 0.7);
    float vert = step(0.2, local.y) * step(local.y, 0.8);
    float dot = horiz * vert;
    dot *= step(0.3, gray);
    float paper = 0.95;
    return float4(mix(float3(paper), float3(0.1), dot), 1.0);
}

// 42: Posterize
float4 posterize(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float levels = 5.0;
    color.rgb = floor(color.rgb * levels) / (levels - 1.0);
    return color;
}

// 43: Color Separation (RGB split view)
float4 colorSeparation(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    if (uv.x < 0.333) {
        return float4(color.r, 0, 0, 1);
    } else if (uv.x < 0.666) {
        return float4(0, color.g, 0, 1);
    } else {
        return float4(0, 0, color.b, 1);
    }
}

// 44: Sin Wave Distortion
float4 sinWave(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 distort = float2(
        sin(uv.y * 20.0 + time * 3.0) * 0.03,
        sin(uv.x * 20.0 + time * 2.0) * 0.03
    );
    return tex.sample(s, uv + distort);
}

// 45: Fisheye
float4 fisheye(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float power = 2.0;
    float bind = 0.5;
    float2 newUV;
    if (dist < bind) {
        float scale = pow(dist / bind, power) * bind / dist;
        newUV = center * scale + 0.5;
    } else {
        newUV = uv;
    }
    if (newUV.x < 0.0 || newUV.x > 1.0 || newUV.y < 0.0 || newUV.y > 1.0) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(s, newUV);
}

// 46: Twirl / Spiral
float4 twirl(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float angle = atan2(center.y, center.x);
    float twist = (0.5 - dist) * 3.0 + time * 0.5;
    angle += twist;
    float2 newUV = float2(cos(angle), sin(angle)) * dist + 0.5;
    return tex.sample(s, newUV);
}

// 47: Bulge
float4 bulge(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float scale = 1.0 + (0.3 - dist) * 0.8;
    scale = max(scale, 0.5);
    float2 newUV = center / scale + 0.5;
    return tex.sample(s, newUV);
}

// 48: Shockwave
float4 shockwave(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float wave = fract(time * 0.5);
    float width = 0.1;
    float ring = smoothstep(wave - width, wave, dist) * smoothstep(wave + width, wave, dist);
    float2 offset = normalize(center + 0.0001) * ring * 0.05;
    return tex.sample(s, uv + offset);
}

// 49: Heartbeat Pulse
float4 heartbeat(texture2d<float> tex, sampler s, float2 uv, float time) {
    float beat = abs(sin(time * 4.0));
    beat = pow(beat, 4.0);
    float2 center = uv - 0.5;
    float scale = 1.0 - beat * 0.05;
    float2 newUV = center / scale + 0.5;
    float4 color = tex.sample(s, newUV);
    color.rgb *= 1.0 + beat * 0.2;
    float vignette = 1.0 - length(center) * beat * 0.5;
    color.rgb *= vignette;
    return color;
}

// 50: Cross-hatch
float4 crosshatch(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float2 pixelCoord = uv * resolution;
    float line1 = step(0.9, fract((pixelCoord.x + pixelCoord.y) / 6.0));
    float line2 = step(0.9, fract((pixelCoord.x - pixelCoord.y) / 6.0));
    float line3 = step(0.9, fract(pixelCoord.x / 4.0));
    float line4 = step(0.9, fract(pixelCoord.y / 4.0));
    float hatch = 0.0;
    if (gray < 0.25) hatch = max(max(line1, line2), max(line3, line4));
    else if (gray < 0.5) hatch = max(line1, line2);
    else if (gray < 0.75) hatch = line1;
    float paper = 0.95;
    return float4(float3(mix(paper, 0.1, hatch)), 1.0);
}

// 51: Pointillism
float4 pointillism(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float dotSize = 5.0;
    float2 pixelCoord = uv * resolution / dotSize;
    float2 cellCenter = (floor(pixelCoord) + 0.5) * dotSize / resolution;
    float2 jitter = float2(
        rand(floor(pixelCoord)) - 0.5,
        rand(floor(pixelCoord) + 100.0) - 0.5
    ) * dotSize * 0.3 / resolution;
    float4 color = tex.sample(s, cellCenter + jitter);
    float2 local = fract(pixelCoord) - 0.5;
    float dist = length(local);
    float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float radius = 0.3 + brightness * 0.2;
    float dot = smoothstep(radius + 0.1, radius - 0.1, dist);
    return float4(color.rgb * dot + float3(0.95) * (1.0 - dot), 1.0);
}

// 52: Voronoi Cells
float4 voronoi(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float cellSize = 20.0;
    float2 scaled = uv * resolution / cellSize;
    float2 cell = floor(scaled);
    float minDist = 10.0;
    float2 closestPoint;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            float2 neighbor = cell + float2(x, y);
            float2 point = neighbor + float2(
                rand(neighbor),
                rand(neighbor + 100.0)
            );
            float dist = length(scaled - point);
            if (dist < minDist) {
                minDist = dist;
                closestPoint = point;
            }
        }
    }
    float2 sampleUV = closestPoint * cellSize / resolution;
    float4 color = tex.sample(s, sampleUV);
    float edge = smoothstep(0.0, 0.1, minDist);
    return float4(color.rgb * edge, 1.0);
}

// 53: Rain on Glass
float4 rainGlass(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 distort = float2(0);
    for (int i = 0; i < 5; i++) {
        float speed = 0.5 + float(i) * 0.2;
        float2 dropUV = uv * float2(3.0 + float(i), 5.0);
        dropUV.y += time * speed;
        float2 cell = floor(dropUV);
        float2 local = fract(dropUV) - 0.5;
        float2 offset = float2(rand(cell) - 0.5, rand(cell + 50.0) - 0.5) * 0.5;
        float dist = length(local - offset);
        float drop = smoothstep(0.2, 0.0, dist);
        distort += (local - offset) * drop * 0.02;
    }
    float4 color = tex.sample(s, uv + distort);
    color.rgb *= 0.95;
    return color;
}

// 54: Frosted Glass
float4 frostedGlass(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = float4(0);
    int samples = 16;
    for (int i = 0; i < samples; i++) {
        float angle = float(i) * 6.28318 / float(samples);
        float radius = rand(uv + float(i)) * 0.02;
        float2 offset = float2(cos(angle), sin(angle)) * radius;
        color += tex.sample(s, uv + offset);
    }
    color /= float(samples);
    return color;
}

// 55: Tilt Shift (fake miniature)
float4 tiltShift(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float focusY = 0.5;
    float focusWidth = 0.15;
    float blur = smoothstep(0.0, focusWidth, abs(uv.y - focusY));
    blur = pow(blur, 2.0);
    float2 texel = 1.0 / resolution;
    float4 color = tex.sample(s, uv);
    if (blur > 0.01) {
        float4 blurred = float4(0);
        int samples = 8;
        for (int i = 0; i < samples; i++) {
            float angle = float(i) * 6.28318 / float(samples);
            float2 offset = float2(cos(angle), sin(angle)) * texel * blur * 10.0;
            blurred += tex.sample(s, uv + offset);
        }
        blurred /= float(samples);
        color = mix(color, blurred, blur);
    }
    color.rgb = pow(color.rgb, float3(0.9));
    color.rgb *= 1.1;
    return color;
}

// 56: Mirror (horizontal)
float4 mirror(texture2d<float> tex, sampler s, float2 uv) {
    float2 mirrorUV = float2(abs(uv.x - 0.5) * 2.0, uv.y);
    if (mirrorUV.x > 1.0) mirrorUV.x = 2.0 - mirrorUV.x;
    return tex.sample(s, mirrorUV);
}

// 57: Split Screen Glitch
float4 splitGlitch(texture2d<float> tex, sampler s, float2 uv, float time) {
    int splits = 5;
    float segment = floor(uv.y * float(splits));
    float offset = sin(segment * 3.14159 + time * 5.0) * 0.1;
    offset *= step(0.8, rand(float2(segment, floor(time * 10.0))));
    float2 glitchUV = float2(fract(uv.x + offset), uv.y);
    float4 color = tex.sample(s, glitchUV);
    float colorGlitch = step(0.95, rand(float2(segment, floor(time * 20.0))));
    if (colorGlitch > 0.5) {
        color.rgb = color.bgr;
    }
    return color;
}

// 58: Datamosh
float4 datamosh(texture2d<float> tex, sampler s, float2 uv, float time) {
    float blockSize = 16.0;
    float2 block = floor(uv * blockSize) / blockSize;
    float glitch = step(0.7, rand(block + floor(time * 2.0)));
    float2 offset = float2(
        (rand(block + time) - 0.5) * 0.2,
        (rand(block + time + 100.0) - 0.5) * 0.2
    ) * glitch;
    float4 color = tex.sample(s, uv + offset);
    float colorCorrupt = step(0.9, rand(block + floor(time * 3.0)));
    if (colorCorrupt > 0.5) {
        color.rgb = fract(color.rgb * 2.0 + float3(rand(block)));
    }
    return color;
}

// 59: Bit Crush (color depth reduction)
float4 bitCrush(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 pixelSize = 4.0 / resolution;
    float2 pixelUV = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;
    float4 color = tex.sample(s, pixelUV);
    float bits = 4.0;
    color.rgb = floor(color.rgb * bits) / bits;
    return color;
}

// 60: Invert Colors
float4 invert(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = 1.0 - color.rgb;
    return color;
}

// 61: Sepia
float4 sepia(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    return float4(gray * 1.2, gray * 1.0, gray * 0.7, 1.0);
}

// 62: High Contrast
float4 highContrast(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = (color.rgb - 0.5) * 2.0 + 0.5;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 63: GBA (Game Boy Advance) LCD
float4 gba(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float2 pixelCoord = uv * resolution / 3.0;
    float2 subpixel = fract(pixelCoord);
    float grid = smoothstep(0.0, 0.15, subpixel.x) * smoothstep(1.0, 0.85, subpixel.x) *
                 smoothstep(0.0, 0.15, subpixel.y) * smoothstep(1.0, 0.85, subpixel.y);
    color.rgb *= mix(0.75, 1.0, grid);
    color.rgb = pow(color.rgb, float3(0.9)) * 1.1;
    color.rgb *= float3(1.0, 0.98, 0.95);
    return color;
}

// 64: SNES / 16-bit color reduction
float4 snes(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 pixelSize = 2.0 / resolution;
    float2 pixelUV = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;
    float4 color = tex.sample(s, pixelUV);
    float levels = 32.0;
    color.rgb = floor(color.rgb * levels) / levels;
    return color;
}

// 65: NES / 8-bit palette
float4 nes(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 pixelSize = 3.0 / resolution;
    float2 pixelUV = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;
    float4 color = tex.sample(s, pixelUV);
    float levels = 4.0;
    color.rgb = floor(color.rgb * levels) / levels;
    color.rgb = pow(color.rgb, float3(0.8));
    return color;
}

// 66: Sharpen
float4 sharpen(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 center = tex.sample(s, uv) * 5.0;
    float4 neighbors = tex.sample(s, uv + float2(texel.x, 0)) +
                       tex.sample(s, uv - float2(texel.x, 0)) +
                       tex.sample(s, uv + float2(0, texel.y)) +
                       tex.sample(s, uv - float2(0, texel.y));
    float4 color = center - neighbors;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return float4(color.rgb, 1.0);
}

// 67: Box Blur
float4 boxBlur(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = float4(0);
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            color += tex.sample(s, uv + float2(x, y) * texel);
        }
    }
    return color / 25.0;
}

// 68: Motion Blur (horizontal)
float4 motionBlur(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = float4(0);
    for (int i = -4; i <= 4; i++) {
        float weight = 1.0 - abs(float(i)) / 5.0;
        color += tex.sample(s, uv + float2(i, 0) * texel * 3.0) * weight;
    }
    return color / 5.4;
}

// 69: Radial Blur
float4 radialBlur(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float4 color = float4(0);
    for (int i = 0; i < 8; i++) {
        float scale = 1.0 - float(i) * 0.01;
        color += tex.sample(s, center * scale + 0.5);
    }
    return color / 8.0;
}

// 70: Brightness Boost
float4 brightnessBoost(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = pow(color.rgb, float3(0.7));
    return color;
}

// 71: Darken
float4 darken(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = pow(color.rgb, float3(1.5));
    return color;
}

// 72: Warm Tint
float4 warmTint(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.r *= 1.1;
    color.g *= 1.0;
    color.b *= 0.85;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 73: Cool Tint
float4 coolTint(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.r *= 0.85;
    color.g *= 0.95;
    color.b *= 1.15;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 74: Vignette
float4 vignette(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float2 center = uv - 0.5;
    float dist = length(center);
    float vig = 1.0 - smoothstep(0.3, 0.8, dist);
    color.rgb *= vig;
    return color;
}

// 75: Film Grain
float4 filmGrain(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float grain = rand(uv + fract(time * 60.0)) * 0.1 - 0.05;
    color.rgb += grain;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 76: Duotone (two-color)
float4 duotone(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float3 dark = float3(0.1, 0.0, 0.3);
    float3 light = float3(1.0, 0.8, 0.2);
    return float4(mix(dark, light, gray), 1.0);
}

// 77: Tritone
float4 tritone(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float3 shadows = float3(0.0, 0.1, 0.2);
    float3 mids = float3(0.8, 0.2, 0.1);
    float3 highlights = float3(1.0, 0.9, 0.7);
    float3 result;
    if (gray < 0.5) {
        result = mix(shadows, mids, gray * 2.0);
    } else {
        result = mix(mids, highlights, (gray - 0.5) * 2.0);
    }
    return float4(result, 1.0);
}

// 78: Pop Art (saturated posterize)
float4 popArt(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = pow(color.rgb, float3(0.8));
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(gray), color.rgb, 2.5);
    color.rgb = floor(color.rgb * 4.0) / 3.0;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 79: Ink / Threshold
float4 ink(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float bw = step(0.5, gray);
    return float4(float3(bw), 1.0);
}

// 80: Stipple
float4 stipple(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float noise = rand(floor(uv * resolution / 2.0));
    float stip = step(noise, gray);
    return float4(float3(stip), 1.0);
}

// 81: Mosaic (hex tiles)
float4 hexMosaic(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float size = 12.0;
    float2 scaled = uv * resolution / size;
    float2 hexPos;
    hexPos.x = scaled.x;
    hexPos.y = scaled.y + fmod(floor(scaled.x), 2.0) * 0.5;
    float2 center = (floor(hexPos) + 0.5) * size / resolution;
    return tex.sample(s, center);
}

// 82: Oil Paint
float4 oilPaint(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float4 color = float4(0);
    float totalWeight = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            float4 sample_color = tex.sample(s, uv + float2(x, y) * texel * 2.0);
            float lum = dot(sample_color.rgb, float3(0.333));
            float weight = 1.0 / (1.0 + abs(lum - dot(tex.sample(s, uv).rgb, float3(0.333))) * 10.0);
            color += sample_color * weight;
            totalWeight += weight;
        }
    }
    color /= totalWeight;
    color.rgb = floor(color.rgb * 10.0) / 10.0;
    return float4(color.rgb, 1.0);
}

// 83: Watercolor
float4 watercolor(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float2 texel = 1.0 / resolution;
    float2 wobble = float2(
        rand(floor(uv * 50.0)) - 0.5,
        rand(floor(uv * 50.0) + 100.0) - 0.5
    ) * texel * 6.0;
    float4 color = float4(0);
    for (int i = 0; i < 5; i++) {
        float2 offset = float2(rand(uv + float(i)), rand(uv + float(i) + 50.0)) * texel * 4.0;
        color += tex.sample(s, uv + wobble + offset);
    }
    color /= 5.0;
    color.rgb = mix(color.rgb, float3(1.0), 0.1);
    color.rgb = pow(color.rgb, float3(0.9));
    return color;
}

// 84: Stained Glass
float4 stainedGlass(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float cellSize = 25.0;
    float2 scaled = uv * resolution / cellSize;
    float2 cell = floor(scaled);
    float minDist = 10.0;
    float2 closestPoint;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            float2 neighbor = cell + float2(x, y);
            float2 point = neighbor + float2(rand(neighbor), rand(neighbor + 100.0));
            float dist = length(scaled - point);
            if (dist < minDist) {
                minDist = dist;
                closestPoint = point;
            }
        }
    }
    float2 sampleUV = closestPoint * cellSize / resolution;
    float4 color = tex.sample(s, sampleUV);
    color.rgb = pow(color.rgb, float3(0.8)) * 1.2;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    float edge = smoothstep(0.02, 0.08, minDist);
    float lead = 1.0 - step(edge, 0.1) * 0.7;
    return float4(color.rgb * lead, 1.0);
}

// 85: Zoom Blur
float4 zoomBlur(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float4 color = float4(0);
    for (int i = 0; i < 10; i++) {
        float scale = 1.0 + float(i) * 0.005;
        color += tex.sample(s, center * scale + 0.5);
    }
    return color / 10.0;
}

// 86: Barrel Distortion
float4 barrel(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float dist = dot(center, center);
    float2 distorted = uv + center * dist * -0.3;
    if (distorted.x < 0.0 || distorted.x > 1.0 || distorted.y < 0.0 || distorted.y > 1.0) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(s, distorted);
}

// 87: Pincushion Distortion
float4 pincushion(texture2d<float> tex, sampler s, float2 uv) {
    float2 center = uv - 0.5;
    float dist = dot(center, center);
    float2 distorted = uv + center * dist * 0.3;
    if (distorted.x < 0.0 || distorted.x > 1.0 || distorted.y < 0.0 || distorted.y > 1.0) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(s, distorted);
}

// 88: Ripple
float4 ripple(texture2d<float> tex, sampler s, float2 uv, float time) {
    float2 center = uv - 0.5;
    float dist = length(center);
    float wave = sin(dist * 30.0 - time * 5.0) * 0.01 / (dist + 0.1);
    float2 offset = normalize(center + 0.0001) * wave;
    return tex.sample(s, uv + offset);
}

// 89: Pixelate Circle
float4 pixelateCircle(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float dotSize = 8.0;
    float2 pixelCoord = uv * resolution / dotSize;
    float2 center = (floor(pixelCoord) + 0.5) * dotSize / resolution;
    float4 color = tex.sample(s, center);
    float2 local = fract(pixelCoord) - 0.5;
    float dist = length(local);
    float mask = smoothstep(0.5, 0.4, dist);
    return float4(color.rgb * mask + float3(0.1) * (1.0 - mask), 1.0);
}

// 90: Pixelate Diamond
float4 pixelateDiamond(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float size = 8.0;
    float2 pixelCoord = uv * resolution / size;
    float2 center = (floor(pixelCoord) + 0.5) * size / resolution;
    float4 color = tex.sample(s, center);
    float2 local = abs(fract(pixelCoord) - 0.5);
    float diamond = local.x + local.y;
    float mask = smoothstep(0.5, 0.4, diamond);
    return float4(color.rgb * mask + float3(0.05) * (1.0 - mask), 1.0);
}

// 91: CRT Shadow Mask
float4 shadowMask(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float2 pixelCoord = uv * resolution;
    int xMod = int(fmod(floor(pixelCoord.x), 3.0));
    int yMod = int(fmod(floor(pixelCoord.y), 3.0));
    float3 mask = float3(0.6);
    if (xMod == 0 && yMod == 0) mask.r = 1.0;
    else if (xMod == 1 && yMod == 1) mask.g = 1.0;
    else if (xMod == 2 && yMod == 2) mask.b = 1.0;
    color.rgb *= mask;
    float scanline = sin(uv.y * resolution.y * 3.14159) * 0.5 + 0.5;
    color.rgb *= mix(0.8, 1.0, scanline);
    return color;
}

// 92: CRT Slot Mask
float4 slotMask(texture2d<float> tex, sampler s, float2 uv, float2 resolution) {
    float4 color = tex.sample(s, uv);
    float2 pixelCoord = uv * resolution;
    int col = int(fmod(floor(pixelCoord.x), 6.0));
    float3 mask;
    if (col < 2) mask = float3(1.0, 0.3, 0.3);
    else if (col < 4) mask = float3(0.3, 1.0, 0.3);
    else mask = float3(0.3, 0.3, 1.0);
    float slot = step(0.5, fmod(floor(pixelCoord.y / 2.0), 2.0));
    mask = mix(mask, float3(0.5), slot * 0.3);
    color.rgb *= mask;
    color.rgb *= 1.3;
    color.rgb = min(color.rgb, float3(1.0));
    return color;
}

// 93: Grayscale
float4 grayscale(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    return float4(float3(gray), 1.0);
}

// 94: Solarize
float4 solarize(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    color.rgb = mix(color.rgb, 1.0 - color.rgb, step(0.5, color.rgb));
    return color;
}

// 95: Color Rotate (hue shift)
float4 colorRotate(texture2d<float> tex, sampler s, float2 uv, float time) {
    float4 color = tex.sample(s, uv);
    float angle = time * 0.5;
    float cosA = cos(angle);
    float sinA = sin(angle);
    float3x3 hueRot = float3x3(
        float3(0.299 + 0.701*cosA + 0.168*sinA, 0.587 - 0.587*cosA + 0.330*sinA, 0.114 - 0.114*cosA - 0.497*sinA),
        float3(0.299 - 0.299*cosA - 0.328*sinA, 0.587 + 0.413*cosA + 0.035*sinA, 0.114 - 0.114*cosA + 0.292*sinA),
        float3(0.299 - 0.300*cosA + 1.250*sinA, 0.587 - 0.588*cosA - 1.050*sinA, 0.114 + 0.886*cosA - 0.203*sinA)
    );
    color.rgb = hueRot * color.rgb;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// 96: Flip Horizontal
float4 flipH(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, float2(1.0 - uv.x, uv.y));
}

// 97: Flip Vertical
float4 flipV(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, float2(uv.x, 1.0 - uv.y));
}

// 98: Tile (2x2 repeat)
float4 tile(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, fract(uv * 2.0));
}

// 99: Rotate 90
float4 rotate90(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, float2(uv.y, 1.0 - uv.x));
}

// 100: Letterbox (cinematic bars)
float4 letterbox(texture2d<float> tex, sampler s, float2 uv) {
    float4 color = tex.sample(s, uv);
    float bar = 0.12;
    if (uv.y < bar || uv.y > 1.0 - bar) {
        return float4(0, 0, 0, 1);
    }
    float vig = 1.0 - pow(length(uv - 0.5) * 1.2, 2.0) * 0.3;
    color.rgb *= vig;
    return color;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 resolution = float2(uniforms.textureWidth, uniforms.textureHeight);

    switch (uniforms.shaderType) {
        case 0:  return passthrough(tex, s, in.texCoord);
        case 1:  return scanlines(tex, s, in.texCoord, uniforms.textureHeight, uniforms.paramScanline);
        case 2:  return crt(tex, s, in.texCoord, resolution, uniforms.paramCurvature, uniforms.paramScanline, uniforms.paramColorBleed);
        case 3:  return lcd(tex, s, in.texCoord, resolution / 3.0);
        case 4:  return vhs(tex, s, in.texCoord, resolution, uniforms.time);
        case 5:  return gameboy(tex, s, in.texCoord, resolution);
        case 6:  return phosphor(tex, s, in.texCoord, resolution, uniforms.paramScanline, uniforms.paramBlur);
        case 7:  return ntsc(tex, s, in.texCoord, resolution, uniforms.time);
        case 8:  return ascii(tex, s, in.texCoord, resolution);
        case 9:  return matrixRain(tex, s, in.texCoord, resolution, uniforms.time);
        case 10: return thermal(tex, s, in.texCoord);
        case 11: return pixelate(tex, s, in.texCoord, resolution);
        case 12: return aperture(tex, s, in.texCoord, resolution);
        case 13: return chromatic(tex, s, in.texCoord, uniforms.paramColorBleed);
        case 14: return glitch(tex, s, in.texCoord, uniforms.time);
        case 15: return oldFilm(tex, s, in.texCoord, uniforms.time);
        case 16: return underwater(tex, s, in.texCoord, uniforms.time);
        case 17: return heatHaze(tex, s, in.texCoord, uniforms.time);
        case 18: return drunk(tex, s, in.texCoord, uniforms.time);
        case 19: return hologram(tex, s, in.texCoord, uniforms.time);
        case 20: return xray(tex, s, in.texCoord);
        case 21: return nightVision(tex, s, in.texCoord, uniforms.time);
        case 22: return surveillance(tex, s, in.texCoord, uniforms.time);
        case 23: return vcrTracking(tex, s, in.texCoord, uniforms.time);
        case 24: return brokenTV(tex, s, in.texCoord, uniforms.time);
        case 25: return staticNoise(tex, s, in.texCoord, uniforms.time);
        case 26: return rainbowShift(tex, s, in.texCoord, uniforms.time);
        case 27: return kaleidoscope(tex, s, in.texCoord, uniforms.time);
        case 28: return halftone(tex, s, in.texCoord, resolution);
        case 29: return sketch(tex, s, in.texCoord, resolution);
        case 30: return emboss(tex, s, in.texCoord, resolution);
        case 31: return edgeDetect(tex, s, in.texCoord, resolution);
        case 32: return neonGlow(tex, s, in.texCoord, resolution, uniforms.time);
        case 33: return cyberpunk(tex, s, in.texCoord, uniforms.time);
        case 34: return vaporwave(tex, s, in.texCoord, uniforms.time);
        case 35: return orderedDither(tex, s, in.texCoord, resolution);
        case 36: return cga(tex, s, in.texCoord, resolution);
        case 37: return amberMonitor(tex, s, in.texCoord, resolution);
        case 38: return greenMonitor(tex, s, in.texCoord, resolution);
        case 39: return newspaper(tex, s, in.texCoord, resolution);
        case 40: return blueprint(tex, s, in.texCoord, resolution);
        case 41: return dotMatrix(tex, s, in.texCoord, resolution);
        case 42: return posterize(tex, s, in.texCoord);
        case 43: return colorSeparation(tex, s, in.texCoord);
        case 44: return sinWave(tex, s, in.texCoord, uniforms.time);
        case 45: return fisheye(tex, s, in.texCoord);
        case 46: return twirl(tex, s, in.texCoord, uniforms.time);
        case 47: return bulge(tex, s, in.texCoord);
        case 48: return shockwave(tex, s, in.texCoord, uniforms.time);
        case 49: return heartbeat(tex, s, in.texCoord, uniforms.time);
        case 50: return crosshatch(tex, s, in.texCoord, resolution);
        case 51: return pointillism(tex, s, in.texCoord, resolution);
        case 52: return voronoi(tex, s, in.texCoord, resolution);
        case 53: return rainGlass(tex, s, in.texCoord, uniforms.time);
        case 54: return frostedGlass(tex, s, in.texCoord, resolution);
        case 55: return tiltShift(tex, s, in.texCoord, resolution);
        case 56: return mirror(tex, s, in.texCoord);
        case 57: return splitGlitch(tex, s, in.texCoord, uniforms.time);
        case 58: return datamosh(tex, s, in.texCoord, uniforms.time);
        case 59: return bitCrush(tex, s, in.texCoord, resolution);
        case 60: return invert(tex, s, in.texCoord);
        case 61: return sepia(tex, s, in.texCoord);
        case 62: return highContrast(tex, s, in.texCoord);
        case 63: return gba(tex, s, in.texCoord, resolution);
        case 64: return snes(tex, s, in.texCoord, resolution);
        case 65: return nes(tex, s, in.texCoord, resolution);
        case 66: return sharpen(tex, s, in.texCoord, resolution);
        case 67: return boxBlur(tex, s, in.texCoord, resolution);
        case 68: return motionBlur(tex, s, in.texCoord, resolution);
        case 69: return radialBlur(tex, s, in.texCoord);
        case 70: return brightnessBoost(tex, s, in.texCoord);
        case 71: return darken(tex, s, in.texCoord);
        case 72: return warmTint(tex, s, in.texCoord);
        case 73: return coolTint(tex, s, in.texCoord);
        case 74: return vignette(tex, s, in.texCoord);
        case 75: return filmGrain(tex, s, in.texCoord, uniforms.time);
        case 76: return duotone(tex, s, in.texCoord);
        case 77: return tritone(tex, s, in.texCoord);
        case 78: return popArt(tex, s, in.texCoord);
        case 79: return ink(tex, s, in.texCoord);
        case 80: return stipple(tex, s, in.texCoord, resolution);
        case 81: return hexMosaic(tex, s, in.texCoord, resolution);
        case 82: return oilPaint(tex, s, in.texCoord, resolution);
        case 83: return watercolor(tex, s, in.texCoord, resolution);
        case 84: return stainedGlass(tex, s, in.texCoord, resolution);
        case 85: return zoomBlur(tex, s, in.texCoord);
        case 86: return barrel(tex, s, in.texCoord);
        case 87: return pincushion(tex, s, in.texCoord);
        case 88: return ripple(tex, s, in.texCoord, uniforms.time);
        case 89: return pixelateCircle(tex, s, in.texCoord, resolution);
        case 90: return pixelateDiamond(tex, s, in.texCoord, resolution);
        case 91: return shadowMask(tex, s, in.texCoord, resolution);
        case 92: return slotMask(tex, s, in.texCoord, resolution);
        case 93: return grayscale(tex, s, in.texCoord);
        case 94: return solarize(tex, s, in.texCoord);
        case 95: return colorRotate(tex, s, in.texCoord, uniforms.time);
        case 96: return flipH(tex, s, in.texCoord);
        case 97: return flipV(tex, s, in.texCoord);
        case 98: return tile(tex, s, in.texCoord);
        case 99: return rotate90(tex, s, in.texCoord);
        case 100: return letterbox(tex, s, in.texCoord);
        default: return passthrough(tex, s, in.texCoord);
    }
}
