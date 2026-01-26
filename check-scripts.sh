#!/bin/bash

# 脚本诊断工具
# 用于检查构建脚本是否可用

echo "=== FolderSync 脚本诊断工具 ==="
echo ""

# 检查当前目录
CURRENT_DIR=$(pwd)
echo "当前目录: $CURRENT_DIR"
EXPECTED_DIR="/Users/mac/Projects/FolderSync"

if [ "$CURRENT_DIR" != "$EXPECTED_DIR" ]; then
    echo "⚠️  警告: 当前不在项目根目录"
    echo "   期望目录: $EXPECTED_DIR"
    echo "   请运行: cd $EXPECTED_DIR"
    echo ""
fi

# 检查脚本文件
echo "检查脚本文件:"
echo ""

SCRIPTS=("build-app.sh" "generate-icon.sh")

for script in "${SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            echo "✅ $script - 存在且可执行"
            # 检查 shebang
            SHEBANG=$(head -1 "$script")
            if [[ "$SHEBANG" == "#!/bin/bash"* ]] || [[ "$SHEBANG" == "#!/usr/bin/env bash"* ]]; then
                echo "   Shebang: $SHEBANG"
            else
                echo "   ⚠️  警告: 不标准的 shebang: $SHEBANG"
            fi
        else
            echo "⚠️  $script - 存在但不可执行"
            echo "   修复: chmod +x $script"
        fi
    else
        echo "❌ $script - 不存在"
    fi
    echo ""
done

# 测试执行
echo "测试脚本执行:"
echo ""

if [ -f "build-app.sh" ] && [ -x "build-app.sh" ]; then
    echo "尝试执行 build-app.sh (仅显示前3行)..."
    bash build-app.sh 2>&1 | head -3
    echo ""
fi

if [ -f "generate-icon.sh" ] && [ -x "generate-icon.sh" ]; then
    echo "尝试执行 generate-icon.sh (仅显示前3行)..."
    bash generate-icon.sh 2>&1 | head -3
    echo ""
fi

# 提供解决方案
echo "=== 解决方案 ==="
echo ""
echo "如果脚本无法执行，请尝试："
echo ""
echo "1. 确保在正确的目录:"
echo "   cd /Users/mac/Projects/FolderSync"
echo ""
echo "2. 使用 bash 直接运行:"
echo "   bash build-app.sh"
echo "   bash generate-icon.sh"
echo ""
echo "3. 如果权限问题，添加执行权限:"
echo "   chmod +x build-app.sh generate-icon.sh"
echo ""
echo "4. 检查文件编码（应该是 UTF-8）:"
echo "   file build-app.sh generate-icon.sh"
echo ""
