import AppKit
import SwiftTerm
import SwiftUI

/// embedded terminal — spawn `/usr/bin/ssh <alias>` ผ่าน SwiftTerm.LocalProcessTerminalView
/// ssh ใช้ ~/.ssh/config ของระบบโดยอัตโนมัติ → IdentityFile, port, ProxyJump ฯลฯ ได้หมด
struct SSHTerminalView: NSViewRepresentable {
    let host: SSHHost
    /// true เมื่อแท็บนี้เป็น active — updateNSView จะ makeFirstResponder เมื่อ transition false→true
    var isActive: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        var args: [String]
        let alias = host.alias
        if !host.defaultPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let escapedPath = host.defaultPath.replacingOccurrences(of: "'", with: "'\\''")
            args = ["-t", alias, "cd '\(escapedPath)' && exec $SHELL -l"]
        } else {
            args = [alias]
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        DispatchQueue.main.async {
            term.startProcess(executable: "/usr/bin/ssh", args: args, environment: envArray)
            // focus terminal ทันทีที่สร้าง (open session ครั้งแรก)
            term.window?.makeFirstResponder(term)
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // focus เมื่อแท็บนี้กลายเป็น active (false → true)
        if isActive && !context.coordinator.wasActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
        context.coordinator.wasActive = isActive
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var wasActive: Bool = false

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
