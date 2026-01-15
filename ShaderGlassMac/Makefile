CXX = clang++
CXXFLAGS = -std=c++17 -O2 -Wall -fobjc-arc -Wno-deprecated-declarations
OBJCFLAGS = -x objective-c++
FRAMEWORKS = -framework Cocoa -framework Metal -framework MetalKit -framework CoreVideo -framework ScreenCaptureKit -framework CoreMedia

APP_NAME = ShaderGlassMac
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app

SOURCES = src/main.mm src/ScreenCapture.mm src/MetalRenderer.mm src/AppWindow.mm
OBJECTS = $(SOURCES:src/%.mm=$(BUILD_DIR)/%.o)
SHADER = src/Shaders.metal
SHADER_LIB = $(BUILD_DIR)/default.metallib

all: $(APP_BUNDLE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: src/%.mm | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(OBJCFLAGS) -c $< -o $@

$(SHADER_LIB): $(SHADER) | $(BUILD_DIR)
	xcrun -sdk macosx metal -c $(SHADER) -o $(BUILD_DIR)/Shaders.air
	xcrun -sdk macosx metallib $(BUILD_DIR)/Shaders.air -o $(SHADER_LIB)

$(APP_BUNDLE): $(OBJECTS) $(SHADER_LIB) Info.plist ShaderGlassMac.entitlements
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	$(CXX) $(CXXFLAGS) $(OBJECTS) $(FRAMEWORKS) -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp $(SHADER_LIB) $(APP_BUNDLE)/Contents/Resources/
	codesign --force --sign - --entitlements ShaderGlassMac.entitlements $(APP_BUNDLE)

run: $(APP_BUNDLE)
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run clean
