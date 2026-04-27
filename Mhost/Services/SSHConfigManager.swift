import AppKit
import Foundation
import Observation

/// อ่าน/เขียน ~/.ssh/config (หรือ path ที่ผู้ใช้เลือก)
/// รองรับ marker `# MhostDefaultPath: <path>` เพื่อเก็บ default working directory
/// ของแต่ละ host (ใช้ตอน Connect → cd)
@Observable
@MainActor
final class SSHConfigManager {

    var hosts: [SSHHost] = []
    var configPath: String = SSHConfigManager.defaultConfigPath()
    var rawText: String = ""
    var errorMessage: String?
    var statusMessage: String = ""

    static func defaultConfigPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.ssh/config"
    }

    init() {
        load()
    }

    // MARK: - Load / Save

    func load() {
        errorMessage = nil
        let url = URL(fileURLWithPath: configPath)
        // สร้างไฟล์ถ้ายังไม่มี (จะมี content ว่าง)
        if !FileManager.default.fileExists(atPath: url.path) {
            // สร้าง ~/.ssh ถ้ายังไม่มี
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            rawText = text
            hosts = Self.parse(text)
            statusMessage = "โหลด \(hosts.count) host จาก \(configPath)"
        } catch {
            errorMessage = "อ่านไฟล์ไม่ได้: \(error.localizedDescription)"
        }
    }

    func save() {
        let text = Self.serialize(hosts: hosts, header: Self.preservedHeader(rawText))
        let url = URL(fileURLWithPath: configPath)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            rawText = text
            statusMessage = "บันทึก \(hosts.count) host ลง \(configPath)"
            errorMessage = nil
        } catch {
            errorMessage = "บันทึกไม่ได้: \(error.localizedDescription)"
        }
    }

    // MARK: - CRUD

    func addHost() {
        var alias = "newhost"
        var i = 1
        while hosts.contains(where: { $0.alias == alias }) {
            i += 1
            alias = "newhost\(i)"
        }
        hosts.append(SSHHost(alias: alias))
    }

    func deleteHost(_ h: SSHHost) {
        hosts.removeAll { $0.id == h.id }
    }

    // MARK: - File picker

    func pickConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "เลือกไฟล์ ssh config"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            load()
        }
    }

    /// คืน path ที่ผู้ใช้เลือก (สำหรับ IdentityFile) — หรือ nil ถ้ายกเลิก
    func pickIdentityFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "เลือก private key (IdentityFile)"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url { return url.path }
        return nil
    }

    // MARK: - Connect (open Terminal.app + ssh + cd)

    /// เปิด Terminal.app + ssh เข้า host พร้อม cd ไป defaultPath (ถ้ามี)
    func connect(_ host: SSHHost) {
        let escapedAlias = host.alias.replacingOccurrences(of: "\"", with: "\\\"")
        var cmd = "ssh \"\(escapedAlias)\""
        if !host.defaultPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let p = host.defaultPath.replacingOccurrences(of: "\"", with: "\\\"")
            // ssh ... -t "cd '/path' && exec \$SHELL -l"
            cmd = "ssh -t \"\(escapedAlias)\" \"cd '\(p)' && exec \\$SHELL -l\""
        }
        // AppleScript เปิด Terminal และส่งคำสั่ง
        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch {
            errorMessage = "เปิด Terminal ไม่ได้: \(error.localizedDescription)"
        }
    }

    // MARK: - Parsing

    /// parse ssh config — รองรับ Host blocks กับ marker MhostDefaultPath ใน comment
    static func parse(_ text: String) -> [SSHHost] {
        var result: [SSHHost] = []
        var current: SSHHost?
        let knownKeys: Set<String> = ["hostname", "user", "port", "identityfile"]

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // marker comment: # MhostDefaultPath: /path
            if line.hasPrefix("#") {
                if var c = current {
                    let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                    let lower = body.lowercased()
                    if lower.hasPrefix("mhostdefaultpath:") {
                        let p = body.dropFirst("MhostDefaultPath:".count).trimmingCharacters(in: .whitespaces)
                        c.defaultPath = String(p)
                        current = c
                    }
                }
                continue
            }

            // split key value
            let parts = line.split(whereSeparator: { $0.isWhitespace || $0 == "=" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1...].joined(separator: " ")

            if key == "host" {
                if let c = current { result.append(c) }
                current = SSHHost(alias: value)
                continue
            }
            guard var c = current else { continue }
            switch key {
            case "hostname": c.hostName = value
            case "user": c.user = value
            case "port": c.port = value
            case "identityfile": c.identityFile = value
            default:
                if !knownKeys.contains(key) {
                    c.extraOptions.append((parts[0], value))
                }
            }
            current = c
        }
        if let c = current { result.append(c) }
        return result
    }

    /// เก็บ comment block ก่อน Host แรก (เพื่อไม่ให้บันทึกแล้วลบทิ้ง)
    static func preservedHeader(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("host ") || l.lowercased() == "host" { break }
            lines.append(raw)
        }
        // ตัด blank lines ท้าย
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func serialize(hosts: [SSHHost], header: String) -> String {
        var out = ""
        if !header.isEmpty { out += header + "\n\n" }
        for (idx, h) in hosts.enumerated() {
            if idx > 0 { out += "\n" }
            out += "Host \(h.alias)\n"
            if !h.hostName.isEmpty     { out += "    HostName \(h.hostName)\n" }
            if !h.user.isEmpty         { out += "    User \(h.user)\n" }
            if !h.port.isEmpty         { out += "    Port \(h.port)\n" }
            if !h.identityFile.isEmpty { out += "    IdentityFile \(h.identityFile)\n" }
            for (k, v) in h.extraOptions {
                out += "    \(k) \(v)\n"
            }
            if !h.defaultPath.isEmpty {
                out += "    # MhostDefaultPath: \(h.defaultPath)\n"
            }
        }
        return out
    }
}
