import AppKit
import SwiftTerm
import SwiftUI

/// embedded terminal — spawn `/usr/bin/ssh <alias>` ผ่าน SwiftTerm.LocalProcessTerminalView
/// ssh ใช้ ~/.ssh/config ของระบบโดยอัตโนมัติ → IdentityFile, port, ProxyJump ฯลฯ ได้หมด
struct SSHTerminalView: NSViewRepresentable {
    let host: SSHHost

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        // build ssh args:
        // - ถ้ามี defaultPath → ssh -t <alias> "cd '<path>' && exec $SHELL -l"
        // - ไม่มี → ssh <alias>
        var args: [String] = []
        let alias = host.alias
        if !host.defaultPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let escapedPath = host.defaultPath.replacingOccurrences(of: "'", with: "'\\''")
            args = ["-t", alias, "cd '\(escapedPath)' && exec $SHELL -l"]
        } else {
            args = [alias]
        }

        // env: บังคับ xterm-256color เสมอ — Mhost.app เปิดมาจาก Finder ไม่มี TERM
        // ที่ใช้ได้ + COLORTERM=truecolor ช่วย htop/vim/nano render สี/ตารางถูก
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // start ssh
        DispatchQueue.main.async {
            term.startProcess(executable: "/usr/bin/ssh",
                              args: args,
                              environment: envArray)
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // no-op — terminal lifecycle handled by process
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        // SwiftTerm callbacks (ไม่ต้องทำอะไรพิเศษสำหรับ V1)
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
