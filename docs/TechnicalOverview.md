# FolderSync Technical Overview

This document describes the architecture, key components, and communication protocols of FolderSync.

## 1. Architecture

FolderSync is built using a layered architecture:

- **FolderSync.App**: MAUI-based UI layer (ViewModels, Pages, Services).
- **FolderSync.Sync**: Core synchronization logic, file monitoring, and coordinator.
- **FolderSync.P2P**: Decentralized networking layer using NetMQ (ZeroMQ).
- **FolderSync.Security**: Encryption (AES-256), hashing (SHA256), and authentication services.
- **FolderSync.Data**: Persistence layer using SQLite and Entity Framework Core.
- **FolderSync.Core**: Shared interfaces and data models.

## 2. Key Components

### SyncCoordinator
The central orchestrator that connects the network layer, sync engine, and file transfer services. It handles message routing and high-level sync workflows.

### SyncEngine
Manages local file metadata and calculates differences between local state and database state. It triggers events when changes are detected.

### PeerService (P2P)
Handles node discovery via UDP beaconing and messaging using ZeroMQ Router/Dealer patterns.

### FileTransferService
A TCP-based service for chunked file transmission. It supports:
- **AES-256 Encryption**: Transparently applied via stream wrappers.
- **GZip Compression**: Dynamically applied to compressible file types.
- **Resumable Transfers**: Uses file offsets to resume interrupted transfers.

## 3. Communication Protocol

### Messaging (ZeroMQ)
All control messages are JSON-serialized and sent over TCP/ZMQ.
- `HandshakeMessage`: Initial identity exchange.
- `SyncMetaMessage`: Sending file metadata deltas.
- `FileRequestMessage`: Requesting a specific file (with offset).
- `PairingRequest/Response`: Establishing trust between devices.

### File Transfer (Raw TCP)
Large file data is sent over a dedicated TCP port to avoid blocking control messages.
- Format: `[4 bytes: MetaLength][UTF8: MetaJSON][Binary: Encrypted/Compressed Data]`

## 4. Security Model

- **Device Trust**: Devices must be manually marked as "Trusted" before they can sync data.
- **Communication Security**: All file data is encrypted with a system-wide or user-defined password using Pbkdf2 key derivation.
- **Application Security**: Optional PIN lock for accessing settings and device management.
- **Anomaly Detection**: Monitoring service tracks high-frequency deletions to prevent data loss from compromised nodes.

## 5. Storage

- **Database**: SQLite stores `SyncConfiguration`, `FileMetadata`, `PeerDevice`, `SyncHistory`, and `SyncConflict`.
- **Archiving**: The `VersionManager` retains up to 10 versions of modified files in a hidden `.sync/versions` directory.

---
*Generated for FolderSync Development Phase 11.*
