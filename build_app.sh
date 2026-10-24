#!/bin/bash
set -e

echo "🚀 Building MacMic Native App for macOS (Apple Silicon arm64)..."

APP_NAME="MacMic.app"
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# 1. Clean previous build
rm -rf "$APP_NAME" MacMic_bin
mkdir -p "$MACOS" "$RESOURCES"

# 2. Compile Pure Swift Application into arm64 native Mach-O binary
echo "📦 Compiling Swift sources and statically linking libopus.a..."
swiftc -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos12.0 -parse-as-library -O \
    -I swift-src \
    /opt/homebrew/opt/opus/lib/libopus.a \
    swift-src/OpusDecoder.swift \
    swift-src/AudioDeviceManager.swift \
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

# 3. Copy Icon
cp AppIcon.icns "$RESOURCES/"

# 4. Generate Info.plist
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

# 5. Ad-hoc codesign
codesign --force --deep --sign - "$APP_NAME"

echo "🎉 Successfully built pure Swift native $APP_NAME for Apple Silicon!"
ls -lh "$MACOS/MacMic"
