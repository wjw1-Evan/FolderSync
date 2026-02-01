#!/bin/bash

# 生成 FolderSync 应用程序图标脚本 (macOS 原生版本)
# 使用方法: ./generate-icon.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}开始生成 FolderSync 应用程序图标 (使用 macOS 原生工具)...${NC}"

# 检查源图标是否存在
SOURCE_ICON="icon_source.png"
if [ ! -f "$SOURCE_ICON" ]; then
    echo -e "${RED}错误: 找不到源图标 $SOURCE_ICON${NC}"
    echo -e "${YELLOW}请确保目录下存在 icon_source.png${NC}"
    exit 1
fi

# 检查 iconutil 是否可用
if ! command -v iconutil &> /dev/null; then
    echo -e "${RED}错误: iconutil 不可用。此脚本仅支持 macOS。${NC}"
    exit 1
fi

# 检查 sips 是否可用
if ! command -v sips &> /dev/null; then
    echo -e "${RED}错误: sips 不可用。此脚本仅支持 macOS。${NC}"
    exit 1
fi

# 创建临时目录
TEMP_DIR=$(mktemp -d)
ICONSET_DIR="${TEMP_DIR}/FolderSync.iconset"

echo -e "${YELLOW}创建图标集目录...${NC}"
mkdir -p "$ICONSET_DIR"

# 生成不同尺寸的图标
echo -e "${YELLOW}使用 sips 调整图标尺寸...${NC}"

# 辅助函数：生成图标
generate_icon() {
    local size=$1
    local name=$2
    echo "生成 ${name}.png (${size}x${size})..."
    sips -s format png -z "$size" "$size" "$SOURCE_ICON" --out "${ICONSET_DIR}/${name}.png" > /dev/null
}

# 按照 macOS 标准生成所有尺寸
generate_icon 16 "icon_16x16"
generate_icon 32 "icon_16x16@2x"
generate_icon 32 "icon_32x32"
generate_icon 64 "icon_32x32@2x"
generate_icon 128 "icon_128x128"
generate_icon 256 "icon_128x128@2x"
generate_icon 256 "icon_256x256"
generate_icon 512 "icon_256x256@2x"
generate_icon 512 "icon_512x512"
generate_icon 1024 "icon_512x512@2x"

# 使用 iconutil 转换为 .icns 文件
echo -e "${YELLOW}转换为 .icns 格式...${NC}"
ICON_OUTPUT="FolderSync.icns"

iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"

if [ -f "$ICON_OUTPUT" ]; then
    echo -e "${GREEN}✅ 图标已生成: ${ICON_OUTPUT}${NC}"
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
    # 如果存在应用程序包，复制图标
    if [ -d "FolderSync.app" ]; then
        echo -e "${YELLOW}复制图标到应用程序包...${NC}"
        # 确保目录存在
        mkdir -p "FolderSync.app/Contents/Resources"
        cp "$ICON_OUTPUT" "FolderSync.app/Contents/Resources/"
        echo -e "${GREEN}✅ 图标已添加到应用程序包${NC}"
    fi
else
    echo -e "${RED}错误: 无法创建 .icns 文件${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo -e "${GREEN}图标生成成功！${NC}"
