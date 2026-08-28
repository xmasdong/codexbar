import SwiftUI

@main
struct codexBarApp: App {
    @StateObject private var store = TokenStore.shared
    @StateObject private var oauth = OAuthManager.shared

    init() {
        // App 级后台续期，脱离菜单 View 生命周期（菜单关闭时 View 不存在，其内 Timer 不跑）
        BackgroundRefresher.shared.start(interval: 300)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(oauth)
        } label: {
            MenuBarIconView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标：显示 terminal 图标 + 活跃账号的 5h / 周额度
struct MenuBarIconView: View {
    @ObservedObject var store: TokenStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            if let active = store.accounts.first(where: { $0.isActive }) {
                if active.secondaryExhausted {
                    Text(L.weeklyLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else if active.primaryExhausted {
                    Text(L.hourLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Text("\(Int(active.primaryUsedPercent))%·\(Int(active.secondaryUsedPercent))%")
                        .font(.system(size: 10, weight: .medium))
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: active.primaryUsedPercent)
                }
            }
        }
    }

    private var iconName: String {
        // 有活跃账号：只看它的状态。无活跃账号：显中性图标，
        // 不拿全部账号的最差状态误报（否则池里任一号额度满就显三角，误导）。
        guard let active = store.accounts.first(where: { $0.isActive }) else {
            return "terminal.fill"
        }
        let ref = [active]
        if ref.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if ref.contains(where: { $0.secondaryExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if ref.contains(where: { $0.quotaExhausted || $0.primaryUsedPercent >= 80 || $0.secondaryUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        return "terminal.fill"
    }
}
