import SwiftUI

@main
struct PostyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.appModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { appDelegate.showConnectionManager() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            LabeledContent("Codex") {
                HStack {
                    Circle()
                        .fill(appModel.codexAvailable ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(appModel.codexStatus)
                }
            }
            Text("Posty only enables AI when Codex reports the Azure provider and both Luna and Terra are available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 180)
        .task { await appModel.checkCodex() }
    }
}
