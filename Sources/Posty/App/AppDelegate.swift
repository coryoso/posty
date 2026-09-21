import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appModel = AppModel()
    private var windows: [String: NSWindow] = [:]
    private var workspaceModels: [String: WorkspaceModel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        Task { await appModel.checkCodex() }
        // A Settings-only SwiftUI scene finishes its own restoration after this callback.
        // Defer the manually managed first window so SwiftUI cannot order it out again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showConnectionManager()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = windows.values.first {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                showConnectionManager()
            }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
        if let model = workspaceModels.removeValue(forKey: id) { Task { await model.disconnect() } }
    }

    func showConnectionManager(createNew: Bool = false) {
        let identifier = UUID().uuidString
        let view = ConnectionManagerView(
            appModel: appModel,
            initiallyCreatesProfile: createNew,
            onConnect: { [weak self] profile in self?.openWorkspace(profile, in: identifier) }
        )
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.title = "Connections"
        window.setContentSize(NSSize(width: 980, height: 640))
        window.minSize = NSSize(width: 760, height: 500)
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.delegate = self
        window.center()
        windows[identifier] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openWorkspace(_ profile: ConnectionProfile, in identifier: String) {
        guard let window = windows[identifier] else { return }
        let model = WorkspaceModel(profile: profile, appModel: appModel)
        let view = WorkspaceView(model: model)
        window.contentViewController = NSHostingController(rootView: view)
        window.title = profile.name
        window.minSize = NSSize(width: 920, height: 620)
        window.contentMinSize = NSSize(width: 920, height: 620)
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "com.corneliuscarl.Posty.workspace"
        window.tabbingMode = .preferred
        workspaceModels[identifier] = model
        resizeForWorkspace(window)
        // The hosting controller establishes its fitting size on the next layout pass.
        // Reassert the workspace size afterward so a compact connection picker cannot
        // collapse the editor/result split views during the content swap.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.resizeForWorkspace(window)
        }
        Task { await model.connect() }
    }

    private func resizeForWorkspace(_ window: NSWindow) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: max(920, min(1440, visibleFrame.width - 40)),
            height: max(620, min(900, visibleFrame.height - 40))
        )
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }
}
