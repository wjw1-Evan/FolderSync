#!/bin/bash

# 生成 FolderSync 应用程序图标脚本
# 使用方法: ./generate-icon.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}开始生成 FolderSync 应用程序图标...${NC}"

# 检查 Python 是否可用
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误: 需要 Python 3 来生成图标${NC}"
    echo -e "${YELLOW}请安装 Python 3 或使用其他方法创建图标${NC}"
    exit 1
fi

# 检查是否安装了 Pillow
if ! python3 -c "import PIL" 2>/dev/null; then
    echo -e "${YELLOW}正在安装 Pillow (PIL)...${NC}"
    pip3 install --user Pillow || {
        echo -e "${RED}错误: 无法安装 Pillow。请手动运行: pip3 install Pillow${NC}"
        exit 1
    }
fi

# 创建临时目录
TEMP_DIR=$(mktemp -d)
ICONSET_DIR="${TEMP_DIR}/FolderSync.iconset"

echo -e "${YELLOW}创建图标集目录...${NC}"
mkdir -p "$ICONSET_DIR"

# 使用 Python 生成图标
export ICONSET_DIR
python3 << 'PYTHON_SCRIPT'
import os
from PIL import Image, ImageDraw, ImageFont
import math

def create_icon(size):
    """创建指定尺寸的图标"""
    # 创建透明背景
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # 计算中心点和半径
    center = size // 2
    radius = int(size * 0.35)
    padding = int(size * 0.1)
    
    # 定义颜色（现代蓝色渐变主题）
    primary_color = (52, 152, 219)      # 蓝色
    secondary_color = (41, 128, 185)   # 深蓝色
    accent_color = (46, 204, 113)       # 绿色（表示同步成功）
    
    # 绘制背景圆形（带渐变效果）
    for i in range(radius):
        alpha = int(255 * (1 - i / radius) * 0.3)
        color = (*primary_color, alpha)
        draw.ellipse(
            [center - radius + i, center - radius + i,
             center + radius - i, center + radius - i],
            fill=color
        )
    
    # 绘制主圆形背景
    draw.ellipse(
        [center - radius, center - radius,
         center + radius, center + radius],
        fill=(*primary_color, 255),
        outline=(*secondary_color, 255),
        width=max(2, size // 64)
    )
    
    # 绘制同步箭头（两个循环箭头）
    arrow_size = int(radius * 0.6)
    arrow_thickness = max(3, size // 32)
    
    # 第一个箭头（左上）
    arrow1_center_x = center - int(radius * 0.3)
    arrow1_center_y = center - int(radius * 0.3)
    
    # 第二个箭头（右下）
    arrow2_center_x = center + int(radius * 0.3)
    arrow2_center_y = center + int(radius * 0.3)
    
    def draw_arrow(draw, cx, cy, size, thickness, color, angle_offset=0):
        """绘制一个循环箭头"""
        points = []
        # 绘制圆形箭头路径
        for i in range(0, 360, 10):
            angle = math.radians(i + angle_offset)
            x = cx + int(size * 0.7 * math.cos(angle))
            y = cy + int(size * 0.7 * math.sin(angle))
            points.append((x, y))
        
        # 绘制箭头路径
        if len(points) > 1:
            for i in range(len(points) - 1):
                draw.line([points[i], points[i+1]], fill=color, width=thickness)
        
        # 绘制箭头头部
        arrow_angle = math.radians(45 + angle_offset)
        arrow_x = cx + int(size * 0.7 * math.cos(arrow_angle))
        arrow_y = cy + int(size * 0.7 * math.sin(arrow_angle))
        
        # 箭头头部三角形
        head_size = thickness * 2
        for offset in [-20, 0, 20]:
            head_angle = arrow_angle + math.radians(offset)
            head_x = arrow_x + int(head_size * math.cos(head_angle))
            head_y = arrow_y + int(head_size * math.sin(head_angle))
            draw.ellipse(
                [head_x - thickness, head_y - thickness,
                 head_x + thickness, head_y + thickness],
                fill=color
            )
    
    # 绘制两个箭头
    arrow_color = (255, 255, 255, 255)  # 白色箭头
    draw_arrow(draw, arrow1_center_x, arrow1_center_y, arrow_size, arrow_thickness, arrow_color, 0)
    draw_arrow(draw, arrow2_center_x, arrow2_center_y, arrow_size, arrow_thickness, arrow_color, 180)
    
    # 添加文件夹图标元素（小文件夹图标在中心）
    folder_size = int(radius * 0.4)
    folder_x = center - folder_size // 2
    folder_y = center - folder_size // 4
    
    # 绘制文件夹
    folder_color = (255, 255, 255, 200)
    # 文件夹主体
    draw.rectangle(
        [folder_x, folder_y + folder_size // 4,
         folder_x + folder_size, folder_y + folder_size],
        fill=folder_color,
        outline=(*secondary_color, 200),
        width=max(1, size // 128)
    )
    # 文件夹标签
    draw.polygon(
        [(folder_x, folder_y + folder_size // 4),
         (folder_x + folder_size // 3, folder_y + folder_size // 4),
         (folder_x + folder_size // 3, folder_y),
         (folder_x + folder_size // 2, folder_y)],
        fill=folder_color,
        outline=(*secondary_color, 200),
        width=max(1, size // 128)
    )
    
    return img

# macOS 图标所需的所有尺寸
sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

iconset_dir = os.environ.get('ICONSET_DIR', '/tmp/FolderSync.iconset')

# 确保目录存在
os.makedirs(iconset_dir, exist_ok=True)

print(f"生成图标到: {iconset_dir}")

for size, filename in sizes:
    print(f"生成 {filename} ({size}x{size})...")
    icon = create_icon(size)
    icon.save(os.path.join(iconset_dir, filename), 'PNG')

print("✅ 所有图标尺寸已生成")
PYTHON_SCRIPT

if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 图标生成失败${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 使用 iconutil 转换为 .icns 文件
echo -e "${YELLOW}转换为 .icns 格式...${NC}"
ICON_OUTPUT="FolderSync.icns"

if command -v iconutil &> /dev/null; then
    iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
    
    if [ -f "$ICON_OUTPUT" ]; then
        echo -e "${GREEN}✅ 图标已生成: ${ICON_OUTPUT}${NC}"
        
        # 清理临时目录
        rm -rf "$TEMP_DIR"
        
        # 如果存在应用程序包，复制图标
        if [ -d "FolderSync.app" ]; then
            echo -e "${YELLOW}复制图标到应用程序包...${NC}"
            cp "$ICON_OUTPUT" "FolderSync.app/Contents/Resources/"
            echo -e "${GREEN}✅ 图标已添加到应用程序包${NC}"
        fi
    else
        echo -e "${RED}错误: 无法创建 .icns 文件${NC}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
else
    echo -e "${YELLOW}iconutil 不可用，保留图标集目录: ${ICONSET_DIR}${NC}"
    echo -e "${YELLOW}您可以使用以下命令手动转换:${NC}"
    echo -e "${YELLOW}iconutil -c icns ${ICONSET_DIR}${NC}"
fi
