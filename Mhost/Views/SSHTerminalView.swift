import AppKit
import SwiftTerm
import SwiftUI

/// embedded terminal — spawn `/usr/bin/ssh <alias>` ผ่าน SwiftTerm.LocalProcessTerminalView
/// ssh ใช้ ~/.ssh/config ของระบบโดยอัตโนมัติ → IdentityFile, port, ProxyJump ฯลฯ ได้หมด
/// ถ้ามี password ที่บันทึกไว้ใน Keychain จะใช้ SSH_ASKPASS เพื่อ login เข้า shell ทันที
struct SSHTerminalView: NSViewRepresentable {
    let host: SSHHost
    /// true เมื่อแท็บนี้เป็น active — updateNSView จะ makeFirstResponder เมื่อ transition false→true
    var isActive: Bool = false
    /// password ที่ parent โหลดจาก Keychain และ cache ไว้แล้ว — view นี้ไม่อ่าน Keychain เองเพื่อกัน prompt ซ้ำ
    var password: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        var args: [String] = []
        let alias = host.alias

        let passwordToUse = password?.isEmpty == false ? password : nil
        if passwordToUse != nil {
            args += [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        }

        if !host.defaultPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let escapedPath = host.defaultPath.replacingOccurrences(of: "'", with: "'\\''")
            args += ["-t", alias, "cd '\(escapedPath)' && exec $SHELL -l"]
        } else {
            args += [alias]
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        if let password = passwordToUse {
            let askpassURL = Self.makeAskpassScript(password: password)
            context.coordinator.askpassURL = askpassURL
            env["SSH_ASKPASS"] = askpassURL.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        }

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
        var askpassURL: URL?

        deinit {
            cleanupAskpassScript()
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            cleanupAskpassScript()
        }

        private func cleanupAskpassScript() {
            if let askpassURL {
                try? FileManager.default.removeItem(at: askpassURL)
                self.askpassURL = nil
            }
        }
    }

    private static func makeAskpassScript(password: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhost-terminal-askpass-\(UUID().uuidString).sh")
        let safe = password.replacingOccurrences(of: "'", with: "'\\''")
        try? "#!/bin/sh\nprintf '%s\\n' '\(safe)'\n"
            .write(to: tmp, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        return tmp
    }
}
