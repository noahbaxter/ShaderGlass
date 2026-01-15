#!/bin/bash
# Dev script - builds and hot-reloads ShaderGlassMac
# Preserves Screen Recording permissions by keeping bundle identity stable

set -e
cd "$(dirname "$0")"

APP_NAME="ShaderGlassMac"
APP_BUNDLE="build/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Kill existing instance if running
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

# Create bundle structure once (if doesn't exist)
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy Info.plist only if changed or missing
if [ ! -f "${APP_BUNDLE}/Contents/Info.plist" ] || ! cmp -s Info.plist "${APP_BUNDLE}/Contents/Info.plist"; then
    cp Info.plist "${APP_BUNDLE}/Contents/"
fi

echo "Building..."

# Compile source files (only if changed)
NEED_LINK=0
for src in main ScreenCapture MetalRenderer AppWindow; do
    if [ ! -f "build/${src}.o" ] || [ "src/${src}.mm" -nt "build/${src}.o" ] || [ "src/${src}.h" -nt "build/${src}.o" ] 2>/dev/null; then
        echo "  Compiling ${src}.mm"
        clang++ -std=c++17 -O0 -g -Wall -fobjc-arc -Wno-deprecated-declarations \
            -x objective-c++ -c "src/${src}.mm" -o "build/${src}.o"
        NEED_LINK=1
    fi
done

# Compile shaders (only if changed)
if [ ! -f "build/default.metallib" ] || [ "src/Shaders.metal" -nt "build/default.metallib" ]; then
    echo "  Compiling Shaders.metal"
    xcrun -sdk macosx metal -c src/Shaders.metal -o build/Shaders.air 2>&1 | grep -v "warning:" || true
    xcrun -sdk macosx metallib build/Shaders.air -o build/default.metallib
    cp build/default.metallib "${APP_BUNDLE}/Contents/Resources/"
fi

# Link only if needed
if [ "$NEED_LINK" -eq 1 ] || [ ! -f "$APP_BINARY" ]; then
    echo "  Linking..."
    clang++ -std=c++17 -O0 -g -Wall -fobjc-arc -Wno-deprecated-declarations \
        build/main.o build/ScreenCapture.o build/MetalRenderer.o build/AppWindow.o \
        -framework Cocoa -framework Metal -framework MetalKit -framework CoreVideo \
        -framework ScreenCaptureKit -framework CoreMedia \
        -o "$APP_BINARY"
fi

# Sign with dev certificate if available, otherwise ad-hoc
CERT_NAME="ShaderGlass Dev"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    # Sign with persistent certificate (permissions survive rebuilds)
    if [ ! -f "build/.signed" ] || [ "$NEED_LINK" -eq 1 ]; then
        echo "  Signing with '$CERT_NAME' certificate..."
        codesign --force --sign "$CERT_NAME" --entitlements ShaderGlassMac.entitlements "$APP_BUNDLE"
        touch "build/.signed"
    fi
else
    # Fall back to ad-hoc signing (will prompt for permissions each clean build)
    if [ ! -f "build/.signed" ]; then
        echo ""
        echo "First build - signing app bundle (ad-hoc)..."
        echo "TIP: Run ./setup-dev-cert.sh to create a persistent certificate"
        codesign --force --sign - --entitlements ShaderGlassMac.entitlements "$APP_BUNDLE"
        touch "build/.signed"
        echo ""
        echo "=== IMPORTANT ==="
        echo "Grant Screen Recording permission when prompted."
        echo "Run ./setup-dev-cert.sh to avoid re-prompting after 'make clean'"
        echo "================="
        echo ""
    fi
fi

echo "Launching..."
open "$APP_BUNDLE"
