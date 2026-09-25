import SwiftUI
import AppKit

/// Host app. Its only job is to carry the Quick Look extensions; launching it
/// once registers them with macOS.
@main
struct EPSQuickLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("EPS QuickLook の準備ができました")
                .font(.title2).bold()

            Text("Finder で .eps ファイルを選んで スペースキー を押すとプレビューできます。\n上下キー（左右キー）で次のファイルに移れます。")
                .multilineTextAlignment(.center)

            Text("表示されない場合は、システム設定 →「一般」→「ログイン項目と機能拡張」→「Quick Look」で EPS QuickLook をオンにしてください。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("システム設定を開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }

            Text("このウィンドウは閉じてかまいません。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(width: 480)
    }
}
