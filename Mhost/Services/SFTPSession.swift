import Combine
import Foundation
import Security

// MARK: - KeychainHelper

enum KeychainHelper {

    enum Kind: String {
        case keyPassphrase
        case userPassword

        var serviceName: String { "mommam.Mhost.\(rawValue)" }
    }

    @discardableResult
    static func save(_ secret: String, kind: Kind, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load(kind: Kind, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(kind: Kind, account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account
        ]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    static func deleteAll(forHost host: SSHHost) {
        let user = host.user.isEmpty ? NSUserName() : host.user
        let hostName = host.hostName.isEmpty ? host.alias : host.hostName
        delete(kind: .userPassword, account: "\(user)@\(hostName)")
        if !host.identityFile.isEmpty {
            delete(kind: .keyPassphrase, account: host.identityFile)
        }
        let defaultKey = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
        delete(kind: .keyPassphrase, account: defaultKey)
    }
}

// MARK: - SFTPEntry

struct SFTPEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modificationTime: Date?

    var displayDate: String {
        guard let t = modificationTime else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: t)
    }

    var displaySize: String {
        if isDirectory { return "—" }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: Int64(size))
    }
}

// MARK: - SFTPSession

/// ssh/scp-based SFTP — stateless subprocess per operation
/// ใช้ ~/.ssh/config + ssh-agent + macOS Keychain ของระบบ
/// รองรับทุก key type, ProxyJump, ControlMaster, ฯลฯ
@MainActor
final class SFTPSession: ObservableObject {

    enum Status {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    enum Credential: Equatable {
        case none
        case keyPassphrase
        case userPassword
    }

    @Published var status: Status = .idle
    @Published var entries: [SFTPEntry] = []
    @Published var currentPath: String
    @Published var needs: Credential = .none
    @Published var lastError: String?
    @Published var isLoadingDirectory: Bool = false

    var needsPassword: Bool { needs == .userPassword }
    var isConnected: Bool { if case .connected = status { return true }; return false }

    let host: SSHHost

    /// password ที่ใช้ connect สำเร็จ (nil = key/agent auth)
    private var connectedPassword: String? = nil
    private var directoryLoadGeneration = 0

    init(host: SSHHost) {
        self.host = host
        let p = host.defaultPath.trimmingCharacters(in: .whitespaces)
        self.currentPath = p.isEmpty ? "." : p
    }

    /// kept for API compatibility
    func cleanupAskpassScript() {}

    // MARK: - Connect / Disconnect

    /// 1. ถ้าไม่มี password → BatchMode=yes (key + ssh-agent)
    /// 2. ถ้ามี password → SSH_ASKPASS
    func connect(passphrase: String? = nil,
                 password: String? = nil,
                 saveToKeychain: Bool = false) async {
        await disconnect()
        status = .connecting
        lastError = nil
        needs = .none

        let pwToUse = password ?? KeychainHelper.load(kind: .userPassword, account: host.keychainAccount)
        let usePassword = !(pwToUse ?? "").isEmpty

        var args = sshBaseArgs(usePassword: usePassword)
        args += [host.alias, "echo mhost-ok"]

        let r = await runSSH(args: args, password: usePassword ? pwToUse : nil, timeout: 25)

        if r.exit == 0 && r.out.contains("mhost-ok") {
            connectedPassword = usePassword ? pwToUse : nil
            status = .connected
            if saveToKeychain, let pw = password, !pw.isEmpty {
                KeychainHelper.save(pw, kind: .userPassword, account: host.keychainAccount)
            }
            let initial = host.defaultPath.trimmingCharacters(in: .whitespaces)
            await loadDirectory(initial.isEmpty ? "." : initial)
        } else {
            await classifyError(r.err + "\n" + r.out,
                                triedPassword: usePassword,
                                hadPasswordFromUser: password != nil)
        }
    }

    func disconnect() async {
        directoryLoadGeneration += 1
        isLoadingDirectory = false
        connectedPassword = nil
        status = .idle
        entries = []
        lastError = nil
    }

    // MARK: - Directory operations

    /// ssh alias "cd path && pwd && ls -la --time-style='+%Y-%m-%d %H:%M:%S'"
    func loadDirectory(_ path: String) async {
        guard isConnected else { return }
        guard !isLoadingDirectory else { return }

        isLoadingDirectory = true
        directoryLoadGeneration += 1
        let generation = directoryLoadGeneration
        defer {
            if directoryLoadGeneration == generation {
                isLoadingDirectory = false
            }
        }

        let escaped = shellEscape(path)
        let cmd = "cd \(escaped) && pwd && (ls -la --time-style='+%Y-%m-%d %H:%M:%S' 2>/dev/null || ls -la)"
        var args = sshBaseArgs(usePassword: connectedPassword != nil)
        args += [host.alias, cmd]

        let r = await runSSH(args: args, password: connectedPassword, timeout: 30)
        guard directoryLoadGeneration == generation, isConnected else { return }

        if r.exit != 0 {
            lastError = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        var lines = r.out.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }

        // first line = pwd output
        let pwd = lines.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)

        var newEntries: [SFTPEntry] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("total ") else { continue }
            if let e = parseLsLine(t) { newEntries.append(e) }
        }

        currentPath = pwd.isEmpty ? path : pwd
        entries = newEntries.sorted {
            if $0.name == ".." { return true }
            if $1.name == ".." { return false }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        lastError = nil
    }

    func enter(_ entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        let next: String
        if entry.name == ".." {
            next = parentPath(currentPath)
        } else {
            next = currentPath.hasSuffix("/") ? currentPath + entry.name : currentPath + "/" + entry.name
        }
        await loadDirectory(next)
    }

    func goUp() async { await loadDirectory(parentPath(currentPath)) }

    func remotePath(of entry: SFTPEntry) -> String {
        currentPath.hasSuffix("/") ? currentPath + entry.name : currentPath + "/" + entry.name
    }

    // MARK: - Upload (scp)

    func upload(localURL: URL, to remotePath: String) async -> Result<Void, Error> {
        guard isConnected else { return .failure(err("ยังไม่ได้ connect", code: 1)) }
        let dst = "\(host.alias):\(remotePath)"
        var args: [String] = ["-p", "-o", "StrictHostKeyChecking=accept-new"]
        if connectedPassword != nil {
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        args += [localURL.path, dst]
        let r = await runProcess("/usr/bin/scp", args: args, password: connectedPassword, timeout: 300)
        if r.exit == 0 { return .success(()) }
        let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(err(msg.isEmpty ? "upload ไม่สำเร็จ" : msg, code: 3))
    }

    // MARK: - Download (scp)

    func download(_ entry: SFTPEntry, to localURL: URL) async -> Result<Void, Error> {
        guard isConnected else {
            return .failure(err("ยังไม่ได้ connect", code: 1))
        }
        let src = "\(host.alias):\(remotePath(of: entry))"
        var args: [String] = ["-p", "-o", "StrictHostKeyChecking=accept-new"]
        if connectedPassword != nil {
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        args += [src, localURL.path]

        let r = await runProcess("/usr/bin/scp", args: args, password: connectedPassword, timeout: 300)

        if r.exit == 0 && FileManager.default.fileExists(atPath: localURL.path) {
            return .success(())
        }
        let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(err(msg.isEmpty ? "download ไม่สำเร็จ" : msg, code: 2))
    }

    // MARK: - Error classification

    private func classifyError(_ raw: String, triedPassword: Bool, hadPasswordFromUser: Bool) async {
        let lower = raw.lowercased()
        if lower.contains("permission denied") || lower.contains("authentication failed")
            || lower.contains("no supported authentication methods") {
            if triedPassword && !hadPasswordFromUser {
                KeychainHelper.delete(kind: .userPassword, account: host.keychainAccount)
            }
            lastError = triedPassword
                ? "password ไม่ถูก หรือ server ปฏิเสธ"
                : "key auth ไม่ผ่าน — กรอก password ของ \(host.user.isEmpty ? "user" : host.user)"
            needs = .userPassword
            status = .idle
        } else if lower.contains("could not resolve hostname") {
            setFailed("DNS resolve ไม่ได้: \(host.hostName.isEmpty ? host.alias : host.hostName)")
        } else if lower.contains("connection refused") {
            setFailed("connection refused — port อาจปิด")
        } else if lower.contains("connection timed out") || lower.contains("timed out") {
            setFailed("connection timeout")
        } else if lower.contains("host key verification failed") {
            setFailed("Host key ไม่ตรง — ตรวจ ~/.ssh/known_hosts")
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            setFailed(trimmed.isEmpty ? "เชื่อมต่อไม่สำเร็จ" : trimmed)
        }
    }

    private func setFailed(_ msg: String) {
        status = .failed(msg)
        lastError = msg
    }

    // MARK: - SSH arg builders

    private func sshBaseArgs(usePassword: Bool) -> [String] {
        var a: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        if usePassword {
            a += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        } else {
            a += [
                "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no"
            ]
        }
        return a
    }

    private func runSSH(args: [String], password: String?, timeout: TimeInterval) async
        -> (exit: Int32, out: String, err: String)
    {
        await runProcess("/usr/bin/ssh", args: args, password: password, timeout: timeout)
    }

    // MARK: - Async process runner

    /// spawn subprocess — non-blocking via terminationHandler + withCheckedContinuation
    private func runProcess(
        _ exec: String,
        args: [String],
        password: String?,
        timeout: TimeInterval
    ) async -> (exit: Int32, out: String, err: String) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"

        let askpassURL: URL? = password.map { pw in
            let url = Self.makeAskpassScript(password: pw)
            env["SSH_ASKPASS"] = url.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            return url
        }

        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exec)
            proc.arguments = args
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // guard against double-resume
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var fired = false
                func call(_ body: () -> Void) {
                    lock.lock(); defer { lock.unlock() }
                    guard !fired else { return }
                    fired = true
                    body()
                }
            }
            let once = Once()
            let finish: @Sendable (Int32, String, String) -> Void = { r0, r1, r2 in
                once.call {
                    if let u = askpassURL { try? FileManager.default.removeItem(at: u) }
                    cont.resume(returning: (r0, r1, r2))
                }
            }

            // timeout watchdog
            let watchdog = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
                finish(-1, "", "timeout (\(Int(timeout))s)")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            proc.terminationHandler = { p in
                watchdog.cancel()
                // safe to read after process exits — pipes have EOF
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                finish(p.terminationStatus, out, err)
            }

            do {
                try proc.run()
            } catch {
                watchdog.cancel()
                finish(-1, "", "เรียก \(exec) ไม่ได้: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Parsing

    /// ls -la --time-style='+%Y-%m-%d %H:%M:%S' format:
    /// "drwxr-xr-x 5 user group 4096 2024-01-15 10:30:00 dirname"
    /// parts: [0]perms [1]nlinks [2]user [3]group [4]size [5]date [6]time [7...]name
    private func parseLsLine(_ line: String) -> SFTPEntry? {
        guard line.count >= 10 else { return nil }
        let mode = line.prefix(10)
        guard let type = mode.first else { return nil }
        let isDir = type == "d", isLink = type == "l"
        guard type == "-" || isDir || isLink else { return nil }
        guard mode.dropFirst().allSatisfy({ "rwxstST-@+".contains($0) }) else { return nil }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 8 else { return nil }

        let size = UInt64(parts[4]) ?? 0

        var modDate: Date? = nil
        var nameRaw: String
        
        let p5 = parts[5]
        if p5.contains("-") && p5.count == 10 {
            // --time-style format: 2024-01-15 10:30:00
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            modDate = df.date(from: "\(parts[5]) \(parts[6])")
            nameRaw = parts[7...].joined(separator: " ")
        } else {
            // standard posix ls: Jan 15 10:30 or Jan 15 2024
            nameRaw = parts.count > 8 ? parts[8...].joined(separator: " ") : ""
        }

        let name: String
        if isLink, let arrow = nameRaw.range(of: " -> ") {
            name = String(nameRaw[..<arrow.lowerBound])
        } else {
            name = nameRaw
        }
        guard name != "." && !name.isEmpty else { return nil }

        return SFTPEntry(name: name, isDirectory: isDir, isSymlink: isLink,
                         size: size, modificationTime: modDate)
    }

    // MARK: - Utilities

    private func shellEscape(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return "~/\(shellEscape(rest))"
        }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func parentPath(_ p: String) -> String {
        guard p != "/" && !p.isEmpty && p != "." else { return "/" }
        let t = p.hasSuffix("/") ? String(p.dropLast()) : p
        let parent = (t as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func err(_ msg: String, code: Int) -> NSError {
        NSError(domain: "Mhost.SFTP", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func makeAskpassScript(password: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhost-askpass-\(UUID().uuidString).sh")
        let safe = password.replacingOccurrences(of: "'", with: "'\\''")
        try? "#!/bin/sh\nprintf '%s\\n' '\(safe)'\n"
            .write(to: tmp, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        return tmp
    }
}
