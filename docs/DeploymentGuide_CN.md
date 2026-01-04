# FolderSync 部署与开发者指南

本文档面向希望自行构建或部署 FolderSync 的开发者和系统管理员。

## 1. 环境要求

- **SDK**: .NET 10.0
- **工作负载**: `maui`, `maccatalyst` (用于 Mac 部署)
- **依赖**: 
  - NetMQ (用于 P2P 通信)
  - SQLite (用于元数据存储)
  - Open.NAT (用于穿透)

## 2. 构建指南

### 获取代码
```bash
git clone https://github.com/your-repo/FolderSync.git
cd FolderSync
```

### 构建本地版本 (Mac Catalyst)
```bash
dotnet build src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst
```

### 发布安装包
```bash
dotnet publish src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst -c Release -p:CreatePackage=true
```

## 3. 网络配置

FolderSync 默认使用以下端口：
- **5000-5001**: UDP (用于节点发现/Beacon)
- **5002**: TCP (用于消息指令交换)
- **5004**: TCP (用于文件传输数据流)

**NAT 穿透**: 如果路由器支持 UPnP，应用会自动尝试在外部打开对应端口。

## 4. 数据库维护

应用使用 SQLite 存储元数据。
- 数据库位置: 
  - **Mac**: `~/Library/Application Support/FolderSync/foldersync.db`
  - **Windows**: `%AppData%\Local\FolderSync\foldersync.db`

### 自动清理
应用内置了 `CleanupService`，每 24 小时执行一次：
- 删除 30 天前的同步历史。
- 清理已完成的临时片段文件 (`.part`)。

## 5. 安全体系

- **传输层加密**: AES-256 (基于用户定义的密码)。
- **哈希校验**: SHA-256 确保传输后文件一致。
- **本地存储**: 敏感信息（如节点身份密钥）均被加密存储。

---
&copy; 2025 FolderSync Project
