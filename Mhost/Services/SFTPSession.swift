import Citadel
import Crypto
import Foundation
import NIOCore
import Observation

/// แทน entry หนึ่ง row ใน SFTP browser
struct SFTPEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modificationTime: UInt32?

    var displayDate: String {
        guard let t = modificationTime else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    var displaySize: String {
        if isDirectory { return "—" }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: Int64(size))
    }
}

/// Citadel-based SFTP session per host
/// ลำดับ auth: ลอง key (จาก IdentityFile หรือ ~/.ssh/id_ed25519) ก่อน ถ้าไม่ได้ → password
@Observable
@MainActor
final class SFTPSession {

    enum Status {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    var status: Status = .idle
    var entries: [SFTPEntry] = []
    var currentPath: String
    /// ต้องใส่ password ไหม (true ถ้า key auth ไม่สำเร็จ)
    var needsPassword: Bool = false
    var lastError: String?

    private var sshClient: SSHClient?
    private var sftp: SFTPClient?
    let host: SSHHost

    init(host: SSHHost) {
        self.host = host
        let p = host.defaultPath.trimmingCharacters(in: .whitespaces)
        self.currentPath = p.isEmpty ? "." : p
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// connect — ถ้า password ว่าง ลอง key auth ก่อน
    func connect(password: String? = nil) async {
        status = .connecting
        lastError = nil
        needsPassword = false

        let username = host.user.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSUserName()
            : host.user
        let portInt = Int(host.port.trimmingCharacters(in: .whitespaces)) ?? 22
        let hostName = host.hostName.trimmingCharacters(in: .whitespaces).isEmpty
            ? host.alias
            : host.hostName

        // 1. ลอง key auth ก่อนถ้ามี IdentityFile
        var auth: SSHAuthenticationMethod?
        let keyPath = resolveIdentityFile()
        if let p = keyPath {
            do {
                let priv = try SSHKeyLoader.loadEd25519(at: p)
                auth = .ed25519(username: username, privateKey: priv)
            } catch {
                // เก็บ error ไว้แสดงถ้า password ก็ fail
                lastError = "key auth: \(error.localizedDescription)"
            }
        }

        // 2. ถ้าไม่มี key หรือ key ใช้ไม่ได้ ใช้ password
        if auth == nil {
            guard let pw = password, !pw.isEmpty else {
                needsPassword = true
                status = .idle
                return
            }
            auth = .passwordBased(username: username, password: pw)
        }

        // 3. connect
        do {
            sshClient = try await SSHClient.connect(
                host: hostName,
                port: portInt,
                authenticationMethod: auth!,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            sftp = try await sshClient?.openSFTP()
            status = .connected
            await loadDirectory(currentPath)
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        if let s = sftp { try? await s.close() }
        if let c = sshClient { try? await c.close() }
        sftp = nil
        sshClient = nil
        status = .idle
        entries = []
    }

    /// list directory
    func loadDirectory(_ path: String) async {
        guard let sftp else { return }
        do {
            let messages = try await sftp.listDirectory(atPath: path)
            // แต่ละ SFTPMessage.Name มี components — flatMap
            let allComponents = messages.flatMap { $0.components }
            entries = allComponents.compactMap { c -> SFTPEntry? in
                let name = c.filename
                if name == "." { return nil }
                let perms = c.attributes.permissions
                let isDir = perms?.contains(.directory) ?? false
                let isLink = perms?.contains(.symbolicLink) ?? false
                let size = c.attributes.size ?? 0
                let mtime = c.attributes.modificationTime
                return SFTPEntry(
                    name: name,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    size: size,
                    modificationTime: mtime
                )
            }
            // เรียง: dir ก่อน, แล้วตามชื่อ
            .sorted { (a, b) in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.lowercased() < b.name.lowercased()
            }
            currentPath = path
            lastError = nil
        } catch {
            lastError = "list failed: \(error.localizedDescription)"
        }
    }

    /// double-click folder
    func enter(_ entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        let next: String
        if entry.name == ".." {
            next = parentPath(currentPath)
        } else if currentPath.hasSuffix("/") {
            next = currentPath + entry.name
        } else {
            next = currentPath + "/" + entry.name
        }
        await loadDirectory(next)
    }

    /// breadcrumb up
    func goUp() async {
        await loadDirectory(parentPath(currentPath))
    }

    private func parentPath(_ p: String) -> String {
        if p == "/" || p.isEmpty || p == "." { return "/" }
        let trimmed = p.hasSuffix("/") ? String(p.dropLast()) : p
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - Identity file resolution

    /// คืน path ของ IdentityFile ถ้ามี
    /// 1. ใช้ host.identityFile ถ้าผู้ใช้ตั้งไว้
    /// 2. fallback ไป ~/.ssh/id_ed25519 ถ้าไฟล์มีอยู่
    private func resolveIdentityFile() -> String? {
        let trimmed = host.identityFile.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return expanded
            }
        }
        // fallback default
        let defaultEd = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
        if FileManager.default.fileExists(atPath: defaultEd) {
            return defaultEd
        }
        return nil
    }
}
