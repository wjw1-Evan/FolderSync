# FolderSync Deployment & Developer Guide

This document is intended for developers and system administrators looking to build or deploy FolderSync.

## 1. Prerequisites

- **SDK**: .NET 10.0
- **Workloads**: `maui`, `maccatalyst` (for Mac deployment)
- **Dependencies**: 
  - NetMQ (P2P communication)
  - SQLite (Metadata storage)
  - Open.NAT (NAT traversal)

## 2. Build Instructions

### Clone Repository
```bash
git clone https://github.com/your-repo/FolderSync.git
cd FolderSync
```

### Build Locally (Mac Catalyst)
```bash
dotnet build src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst
```

### Build Locally (Windows)
```bash
dotnet build src/FolderSync.App/FolderSync.App.csproj -f net10.0-windows10.0.19041.0
```

### Publish Release Package
```bash
# MacOS
dotnet publish src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst -c Release -p:CreatePackage=true

# Windows
dotnet publish src/FolderSync.App/FolderSync.App.csproj -f net10.0-windows10.0.19041.0 -c Release
```

## 3. Network Configuration

FolderSync uses the following ports by default:
- **5000-5001**: UDP (Node Discovery / Beacon)
- **5002**: TCP (Message/Control Exchange)
- **5004**: TCP (File Transfer Data Stream)

**NAT Traversal**: If the router supports UPnP, the app will automatically attempt to map these ports externally.

## 4. Maintenance & Storage

Metadata is stored in a SQLite database.
- **Database Location**: 
  - **Mac**: `~/Library/Application Support/FolderSync/foldersync.db`
  - **Windows**: `%AppData%\Local\FolderSync\foldersync.db`

### Automated Cleanup
The internal `CleanupService` runs every 24 hours to:
- Delete sync history older than 30 days.
- Purge finished or expired temporary part files (`.part`).

## 5. Security Architecture

- **Transport Encryption**: AES-256 (derived from system/user password via Pbkdf2).
- **Integrity**: SHA-256 file hashing verification after every transfer.
- **App Privacy**: Optional PIN-code lock for dashboard access.
- **Anomaly Protection**: Limits high-frequency deletion operations from remote peers.

---
&copy; 2025 FolderSync Project
