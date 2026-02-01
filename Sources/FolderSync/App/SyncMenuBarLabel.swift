import SwiftUI

struct SyncMenuBarLabel: View {
    @ObservedObject var syncManager: SyncManager
    @State private var isRotating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                isRotating
                    ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
                    : .default,
                value: isRotating
            )
            .onAppear {
                updateAnimation()
            }
            .onChange(of: syncManager.isSyncing) {
                updateAnimation()
            }
    }

    private func updateAnimation() {
        if syncManager.isSyncing {
            isRotating = true
        } else {
            isRotating = false
        }
    }
}
