import SwiftUI

struct SyncMenuBarLabel: View {
    @ObservedObject var syncManager: SyncManager

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, isActive: syncManager.isSyncing)
        } else {
            // macOS 14.0 fallback: 使用变色效果表示正在同步
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.variableColor.iterative, isActive: syncManager.isSyncing)
        }
    }
}
