# FolderSync User Guide

Welcome to **FolderSync** — a secure, fast, and cross-platform peer-to-peer (P2P) file synchronization tool.

## 1. Quick Start

### Installation & Launch
- **MacOS**: Run `FolderSync.App.app`. On first launch, the system may prompt for network access permission; select "Allow" to ensure P2P functionality works correctly.
- **Windows**: Run `FolderSync.App.exe`.

### First Sync
1. **Launch App**: Open the FolderSync dashboard.
2. **Add Folder**: Click the "Add Folder" button and select a local directory you want to sync.
3. **Discover Peers**: As long as they are on the same Local Area Network (LAN), your other computers will automatically appear in the "Discovered Peers" list.
4. **Start Syncing**: The app will automatically detect file changes and begin synchronization.

## 2. Core Features

### P2P Discovery & Device Management
FolderSync does not use a central cloud; it transfers data directly between your devices.
- **Auto-Discovery**: Devices on the same network are displayed automatically.
- **Device Pairing**: In the "Devices" tab, you can manage all known devices. Click "Trust" to establish a secure connection with a new device.

### Version Control & Annotations
The app automatically retains historical versions of files (default is 10).
- **Version History**: View backups of all files in the "Versions" tab.
- **Version Notes**: You can add "Notes" to important backups for easier identification later.
- **Version Diff**: Right-click a file (or use the Versions page) to view structural differences for text files.

### Security & Privacy
- **App Lock**: Enable App Lock in "Settings" and set a 4-6 digit PIN to protect your configurations from unauthorized changes.
- **Anomaly Detection**: If a high volume of deletions is detected in a short period (possibly an error or intrusion), the app will issue a security alert.
- **Data Encryption**: All file transfers are encrypted using AES-256.

### Filters & Scheduling
- **Filters**: Supports JSON-formatted rules to exclude irrelevant folders like `.git` or `node_modules`.
- **Sync Schedule**: Configure allowed sync hours in "Settings," such as nighttime only (`00:00 - 06:00`).

## 3. UI Guide
- **Home**: View current folder sync status and peer overview.
- **Devices**: Manage trust relationships and view remote node status.
- **Versions**: Browse historical archives and manage version notes.
- **Activity Log**: View history logs of all file operations (Add, Update, Delete).
- **File Conflicts**: Resolve files with overlapping changes from different locations.
- **Settings**: Configure device name, sync rules, language (English/Chinese), and App Lock.

## 4. FAQ

**Q: How do I change the language?**
A: Select "English" or "简体中文" from the language dropdown in the "Settings" page; the UI will update immediately.

**Q: Why do I have conflict files?**
A: When two devices modify the same file simultaneously, FolderSync preserves both versions to prevent data loss. Please resolve these manually in the "Conflicts" page.

---
Thank you for using FolderSync!
