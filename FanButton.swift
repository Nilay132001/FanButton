import AppKit

final class FanButton: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let cliPaths = ["/opt/homebrew/bin/thermalforge", "/usr/local/bin/thermalforge"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Fan control")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Boost fans", action: #selector(boost), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Automatic (macOS)", action: #selector(automatic), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    @objc private func boost() { run("max") }
    @objc private func automatic() { run("auto") }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func run(_ argument: String) {
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            showError("Install ThermalForge first. See README.md in this project.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [argument]
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async { self.showError(message) }
                }
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Fan control failed"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = FanButton()
app.delegate = delegate
app.run()
