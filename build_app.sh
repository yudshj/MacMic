#!/bin/bash
set -e

MODE="${1:-standard}"
case "$MODE" in
    release)
        OPT_FLAGS=(-O -whole-module-optimization)
        echo "🚀 Building MacMic RELEASE for macOS (Apple Silicon arm64) — WMO + stripped..."
        ;;
    standard)
        OPT_FLAGS=(-O)
        echo "🚀 Building MacMic Native App for macOS (Apple Silicon arm64)..."
        ;;
    *)
        echo "usage: $0 [standard|release]" >&2; exit 2 ;;
esac

APP_NAME="MacMic.app"
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# 1. Clean previous build
rm -rf "$APP_NAME" MacMic_bin
mkdir -p "$MACOS" "$RESOURCES"

# 2. Build vendored RNNoise (static, BSD-3) if missing
./scripts/build_rnnoise.sh

# 3. Compile Pure Swift Application into arm64 native Mach-O binary
echo "📦 Compiling Swift sources and statically linking libopus.a..."
swiftc -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos12.0 -parse-as-library "${OPT_FLAGS[@]}" \
    -I swift-src \
    /opt/homebrew/opt/opus/lib/libopus.a \
    third_party/rnnoise/lib/librnnoise.a \
    swift-src/OpusDecoder.swift \
    swift-src/AudioDeviceManager.swift \
    swift-src/Denoiser.swift \
    swift-src/AudioEngine.swift \
    swift-src/ADBHelper.swift \
    swift-src/MacMicClient.swift \
    swift-src/Localization.swift \
    swift-src/LaunchAtLoginHelper.swift \
    swift-src/SettingsView.swift \
    swift-src/MenuBarManager.swift \
    swift-src/ViewModel.swift \
    swift-src/ContentView.swift \
    swift-src/main.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Network \
    -framework ServiceManagement \
    -o "$MACOS/MacMic"

chmod +x "$MACOS/MacMic"

# 4. Copy Icon
cp AppIcon.icns "$RESOURCES/"

# 4b. Bundle third-party licence texts (BSD-3 requires them with binary redistribution).
# Opus: prefer the COPYING of the Homebrew build we link against; fall back to the copy in licenses/.
LICENSES_DIR="$RESOURCES/licenses"
mkdir -p "$LICENSES_DIR"
OPUS_COPYING="$(brew --prefix opus 2>/dev/null)/COPYING"
if [[ ! -f "$OPUS_COPYING" ]]; then
    OPUS_COPYING="licenses/opus-COPYING.txt"
fi
cp "$OPUS_COPYING" "$LICENSES_DIR/opus-COPYING.txt"
cp third_party/rnnoise/COPYING "$LICENSES_DIR/rnnoise-COPYING.txt"
echo "📄 Bundled licences: $(ls "$LICENSES_DIR" | tr '\n' ' ')"

# 5. Generate Info.plist
cat << 'PLIST' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>MacMic</string>
    <key>CFBundleExecutable</key>
    <string>MacMic</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.macmic.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacMic</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MacMic 需要访问音频子系统以将手机音频实时路由为虚拟麦克风信号</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacMic 需要访问局域网以发现并连接手机端音频串流服务</string>
</dict>
</plist>
PLIST

# 6. Release: drop symbol/debug tables (must happen before signing)
if [[ "$MODE" == "release" ]]; then
    BEFORE=$(stat -f%z "$MACOS/MacMic")
    strip -x -S "$MACOS/MacMic"
    AFTER=$(stat -f%z "$MACOS/MacMic")
    echo "🔻 Stripped $(( (BEFORE - AFTER) / 1024 )) KB ($(( BEFORE / 1024 / 1024 )) MB -> $(( AFTER / 1024 / 1024 )) MB)"
fi

# 7. Ad-hoc codesign
codesign --force --deep --sign - "$APP_NAME"

echo "🎉 Successfully built pure Swift native $APP_NAME for Apple Silicon ($MODE)!"
ls -lh "$MACOS/MacMic"
