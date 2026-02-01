#!/bin/bash

# 构建 macOS 应用程序包脚本
# 使用方法: ./build-app.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}开始构建 FolderSync 应用程序...${NC}"

# 清理之前的构建
echo -e "${YELLOW}清理之前的构建...${NC}"
swift package clean

# 构建 Release 版本
echo -e "${YELLOW}构建 Release 版本...${NC}"
swift build -c release

# 获取可执行文件路径
EXECUTABLE_PATH=".build/release/FolderSync"
APP_NAME="FolderSync"
APP_BUNDLE="${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"

# 检查可执行文件是否存在
if [ ! -f "$EXECUTABLE_PATH" ]; then
    echo -e "${RED}错误: 找不到可执行文件 $EXECUTABLE_PATH${NC}"
    exit 1
fi

# 清理旧的应用程序包
if [ -d "$APP_BUNDLE" ]; then
    echo -e "${YELLOW}删除旧的应用程序包...${NC}"
    rm -rf "$APP_BUNDLE"
fi

# 创建应用程序包结构
echo -e "${YELLOW}创建应用程序包结构...${NC}"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
mkdir -p "$APP_CONTENTS/Frameworks"

# 复制可执行文件
echo -e "${YELLOW}复制可执行文件...${NC}"
cp "$EXECUTABLE_PATH" "$APP_MACOS/$APP_NAME"

# 复制 WebRTC.framework (通常在 .build/release 或 XCframework 路径中)
echo -e "${YELLOW}复制 WebRTC.framework...${NC}"
# 优先从 build 目录找编译好的 framework
WEBRTC_FRAMEWORK=".build/release/WebRTC.framework"
if [ ! -d "$WEBRTC_FRAMEWORK" ]; then
    # 备选路径：XCframework 中的 macOS 版本
    WEBRTC_FRAMEWORK=$(find .build/artifacts -name "WebRTC.framework" | grep "macos" | head -n 1)
fi

if [ -d "$WEBRTC_FRAMEWORK" ]; then
    cp -R "$WEBRTC_FRAMEWORK" "$APP_CONTENTS/Frameworks/"
    echo -e "${GREEN}✅ WebRTC.framework 已复制到 Frameworks${NC}"
else
    echo -e "${RED}警告: 找不到 WebRTC.framework，应用程序运行可能会崩溃${NC}"
fi

# 修复 RPATH
echo -e "${YELLOW}修复可执行文件 RPATH...${NC}"
# 添加对 Frameworks 目录的搜索路径
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS/$APP_NAME" 2>/dev/null || true
# 确保 WebRTC.framework 引用正确 (如果它已经是 @rpath/WebRTC.framework/WebRTC 则无需修改，但加上此步更稳妥)
install_name_tool -change "@rpath/WebRTC.framework/WebRTC" "@loader_path/../Frameworks/WebRTC.framework/WebRTC" "$APP_MACOS/$APP_NAME" 2>/dev/null || true

# 使可执行文件可执行
chmod +x "$APP_MACOS/$APP_NAME"

# 创建 Info.plist
echo -e "${YELLOW}创建 Info.plist...${NC}"
cat > "$APP_CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.FolderSync.App</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 FolderSync. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>FolderSync</string>
</dict>
</plist>
EOF

# 创建 PkgInfo（可选，但有助于兼容性）
echo "APPL????" > "$APP_CONTENTS/PkgInfo"

# 生成并添加图标
echo -e "${YELLOW}生成应用程序图标...${NC}"
if [ -f "FolderSync.icns" ]; then
    echo -e "${YELLOW}使用现有的图标文件...${NC}"
    cp "FolderSync.icns" "$APP_RESOURCES/"
elif [ -f "generate-icon.sh" ]; then
    # 运行图标生成脚本
    if ./generate-icon.sh 2>/dev/null; then
        if [ -f "FolderSync.icns" ]; then
            cp "FolderSync.icns" "$APP_RESOURCES/"
            echo -e "${GREEN}✅ 图标已添加到应用程序包${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  图标生成失败，将使用默认图标${NC}"
    fi
fi

# Info.plist 已包含图标引用

echo -e "${GREEN}✅ 应用程序包构建完成: ${APP_BUNDLE}${NC}"
echo -e "${GREEN}应用程序位置: $(pwd)/${APP_BUNDLE}${NC}"
