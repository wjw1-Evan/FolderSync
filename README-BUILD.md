# 构建说明

## 快速开始

### 构建应用程序

```bash
# 方法 1: 直接使用 bash 运行
bash build-app.sh

# 方法 2: 如果脚本有执行权限
./build-app.sh
```

### 生成图标

```bash
# 方法 1: 直接使用 bash 运行
bash generate-icon.sh

# 方法 2: 如果脚本有执行权限
./generate-icon.sh
```

## 故障排除

如果遇到 "no such file or directory" 错误：

1. **检查当前目录**：
   ```bash
   pwd
   # 应该显示: /Users/mac/Projects/FolderSync
   ```

2. **检查文件是否存在**：
   ```bash
   ls -la *.sh
   ```

3. **检查文件权限**：
   ```bash
   chmod +x build-app.sh generate-icon.sh
   ```

4. **使用完整路径运行**：
   ```bash
   bash /Users/mac/Projects/FolderSync/build-app.sh
   ```

5. **如果文件不存在，重新创建**：
   ```bash
   cd /Users/mac/Projects/FolderSync
   # 确保在正确的目录下
   ```

## 构建流程

1. `build-app.sh` 会自动：
   - 清理之前的构建
   - 编译 Release 版本
   - 创建应用程序包结构
   - 生成并添加图标（如果不存在）
   - 创建 Info.plist

2. 生成的应用程序位于：`FolderSync.app`

## 依赖要求

- Swift 5.9+
- Python 3（用于图标生成）
- Pillow 库（`pip3 install Pillow`）
