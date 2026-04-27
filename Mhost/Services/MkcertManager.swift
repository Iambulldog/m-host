import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class MkcertManager {
    var domain: String = "localhost"
    var outputDirectory: URL?
    var statusMessage: String = ""
    var fullLog: String = ""
    var isSuccess: Bool = false
    var isRunning: Bool = false
    var mkcertInstalled: Bool = false
    var mkcertPath: String?
    var brewInstalled: Bool = false
    /// path ที่ mkcert ใช้เก็บ rootCA (ผลของคำสั่ง `mkcert -CAROOT`)
    var caRootPath: String?

    private func appendLog(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        fullLog += "[\(stamp)] \(text)\n"
    }

    private let helper = HostsHelperClient()

    init() {
        refreshInstallStatus()
    }

    // MARK: - Detection

    func refreshInstallStatus() {
        mkcertPath = findExecutable(name: "mkcert", searchPaths: [
            "/opt/homebrew/bin/mkcert",
            "/usr/local/bin/mkcert",
            "/usr/bin/mkcert"
        ])
        mkcertInstalled = mkcertPath != nil

        brewInstalled = findExecutable(name: "brew", searchPaths: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]) != nil

        if mkcertInstalled {
            refreshCARootPath()
        } else {
            caRootPath = nil
        }
    }

    /// อ่านค่า CAROOT จาก `mkcert -CAROOT` (ที่อยู่ของ rootCA ที่ mkcert ใช้)
    func refreshCARootPath() {
        guard let path = mkcertPath else { caRootPath = nil; return }
        do {
            let result = try PrivilegedSession.run(executable: path, arguments: ["-CAROOT"])
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            caRootPath = trimmed.isEmpty ? nil : trimmed
        } catch {
            caRootPath = nil
        }
    }

    /// เปิด Finder ที่โฟลเดอร์ CAROOT
    func revealCARootInFinder() {
        guard let p = caRootPath, !p.isEmpty else { return }
        let url = URL(fileURLWithPath: p, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// คัดลอก path CAROOT ไปยัง pasteboard
    func copyCARootToPasteboard() {
        guard let p = caRootPath, !p.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(p, forType: .string)
    }

    private func findExecutable(name: String, searchPaths: [String]) -> String? {
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - User Actions

    func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "เลือกโฟลเดอร์ที่ต้องการบันทึกไฟล์ certificate"

        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }

    /// ติดตั้ง mkcert ผ่าน Homebrew (ถ้ามี brew แล้ว)
    func installMkcertViaBrew() async {
        guard brewInstalled else {
            statusMessage = "ไม่พบ Homebrew\n\nติดตั้ง Homebrew ก่อน:\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            isSuccess = false
            return
        }
        let brewPath = findExecutable(name: "brew", searchPaths: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]) ?? "/opt/homebrew/bin/brew"

        isRunning = true
        statusMessage = "กำลังติดตั้ง mkcert ผ่าน Homebrew..."
        appendLog("$ brew install mkcert nss")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.runCommand(executablePath: brewPath, arguments: ["install", "mkcert", "nss"]) { exitCode, output, errorOutput in
                Task { @MainActor in
                    self.isRunning = false
                    self.refreshInstallStatus()
                    if !output.isEmpty { self.appendLog(output) }
                    if !errorOutput.isEmpty { self.appendLog(errorOutput) }
                    if exitCode == 0 && self.mkcertInstalled {
                        self.statusMessage = "ติดตั้ง mkcert สำเร็จ"
                        self.isSuccess = true
                    } else {
                        let detail = errorOutput.isEmpty ? output : errorOutput
                        self.statusMessage = "ติดตั้งไม่สำเร็จ (exit \(exitCode)) — \(detail.prefix(120))"
                        self.isSuccess = false
                    }
                    cont.resume()
                }
            }
        }
    }

    /// รัน `mkcert -install` (ติดตั้ง local CA) — ต้องใช้ admin เพราะติดตั้งใน System Keychain
    func installLocalCA() async {
        guard let path = mkcertPath else {
            statusMessage = "ไม่พบ mkcert"
            isSuccess = false
            return
        }
        isRunning = true
        statusMessage = "กำลังติดตั้ง mkcert local CA..."
        appendLog("$ sudo \(path) -install")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.runPrivilegedCommand(executablePath: path, arguments: ["-install"]) { exitCode, output, errorOutput in
                Task { @MainActor in
                    self.isRunning = false
                    if !output.isEmpty { self.appendLog(output) }
                    if !errorOutput.isEmpty { self.appendLog(errorOutput) }
                    if exitCode == 0 {
                        self.statusMessage = "ติดตั้ง local CA สำเร็จ"
                        self.isSuccess = true
                    } else {
                        let detail = errorOutput.isEmpty ? output : errorOutput
                        self.statusMessage = "ติดตั้ง local CA ไม่สำเร็จ (exit \(exitCode)) — \(detail.prefix(120))"
                        self.isSuccess = false
                    }
                    cont.resume()
                }
            }
        }
    }

    /// สร้าง certificate สำหรับ domain ที่เลือก
    func runMkcert() async {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmedDomain.isEmpty else {
            statusMessage = "กรุณากรอกชื่อ domain"
            isSuccess = false
            return
        }
        guard let outputDir = outputDirectory else {
            statusMessage = "กรุณาเลือกโฟลเดอร์ที่จะเก็บไฟล์ certificate"
            isSuccess = false
            return
        }
        guard let path = mkcertPath else {
            statusMessage = "ไม่พบ mkcert — กดปุ่ม \"Install mkcert\" เพื่อติดตั้งผ่าน Homebrew"
            isSuccess = false
            return
        }

        // สร้าง filename จาก domain (ปลอดภัย)
        let safeDomain = trimmedDomain
            .replacingOccurrences(of: "*", with: "wildcard")
            .replacingOccurrences(of: "/", with: "_")
        let certPath = outputDir.appendingPathComponent("\(safeDomain).pem").path
        let keyPath  = outputDir.appendingPathComponent("\(safeDomain)-key.pem").path

        isRunning = true
        statusMessage = "กำลังสร้าง certificate สำหรับ \(trimmedDomain)..."
        appendLog("$ \(path) -cert-file \(certPath) -key-file \(keyPath) \(trimmedDomain)")

        // mkcert generate cert/key ลงโฟลเดอร์ของผู้ใช้ — ไม่ต้องใช้ admin
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            helper.runCommand(
                executablePath: path,
                arguments: ["-cert-file", certPath, "-key-file", keyPath, trimmedDomain]
            ) { exitCode, output, errorOutput in
                Task { @MainActor in
                    self.isRunning = false
                    if !output.isEmpty { self.appendLog(output) }
                    if !errorOutput.isEmpty { self.appendLog(errorOutput) }
                    if exitCode == 0 {
                        self.statusMessage = "สำเร็จ — \(certPath)"
                        self.isSuccess = true
                    } else {
                        let detail = errorOutput.isEmpty ? output : errorOutput
                        var msg = "ผิดพลาด (exit \(exitCode)) — \(detail.prefix(120))"
                        if detail.contains("local CA is not installed") || detail.contains("not installed in the system trust store") {
                            msg = "ยังไม่ได้ติดตั้ง local CA — กด Install Local CA ก่อน"
                        }
                        self.statusMessage = msg
                        self.isSuccess = false
                    }
                    cont.resume()
                }
            }
        }
    }
}
