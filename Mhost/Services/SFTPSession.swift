import Citadel
import Crypto
import Foundation
import NIOCore
import Observation
import Security

/// macOS Keychain wrapper สำหรับเก็บ password/passphrase ของ SSH/SFTP
/// Termius-style: บันทึกครั้งเดียว ครั้งหน้า auto-fill
/// เก็บใน file นี้รวมเพื่อหลีกเลี่ยงปัญหา Xcode sync group ไม่เห็นไฟล์ใหม่
enum KeychainHelper {

    enum Kind: String {
        case keyPassphrase
        case userPassword

        var serviceName: String { "mommam.Mhost.\(rawValue)" }
    }

    @discardableResult
    static func save(_ secret: String, kind: Kind, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(kind: Kind, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(kind: Kind, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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

/// แทน entry หนึ่ง row ใน SFTP browser
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

    /// อะไรที่ต้องการให้ user ป้อน
    enum Credential: Equatable {
        case none
        case keyPassphrase  // key มี passphrase
        case userPassword   // ไม่มี key หรือ key ใช้ไม่ได้ → fallback password
    }

    var status: Status = .idle
    var entries: [SFTPEntry] = []
    var currentPath: String
    /// ต้องการ credential อะไร (UI ใช้ trigger sheet ที่เหมาะ)
    var needs: Credential = .none
    /// alias เก่า — ให้ UI ที่ยังใช้ของเดิมไม่พัง
    var needsPassword: Bool { needs == .userPassword }
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

    /// connect — flow:
    /// 1. ถ้ามี IdentityFile → ลองโหลด ed25519
    ///    - ไม่เข้ารหัส → ใช้เลย
    ///    - เข้ารหัส + ไม่มี passphrase → set `needs = .keyPassphrase` → return
    ///    - เข้ารหัส + มี passphrase → ใช้ ssh-keygen ถอด
    /// 2. ถ้า key ใช้ไม่ได้ทั้งหมด + ไม่มี password → set `needs = .userPassword` → return
    /// 3. มี password → ลอง password auth
    func connect(passphrase: String? = nil,
                 password: String? = nil,
                 saveToKeychain: Bool = false) async {
        status = .connecting
        lastError = nil
        needs = .none

        let username = host.user.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSUserName()
            : host.user
        let portInt = Int(host.port.trimmingCharacters(in: .whitespaces)) ?? 22
        let hostName = host.hostName.trimmingCharacters(in: .whitespaces).isEmpty
            ? host.alias
            : host.hostName

        // 1. ลอง key auth
        var auth: SSHAuthenticationMethod?
        var usedPassphraseFromUser: String?
        let keyPath = resolveIdentityFile()
        if let p = keyPath {
            do {
                let isEnc = SSHKeyLoader.isEncrypted(at: p)
                let phrase: String? = passphrase
                    ?? (isEnc ? KeychainHelper.load(kind: .keyPassphrase, account: p) : nil)
                if isEnc && (phrase == nil || phrase?.isEmpty == true) {
                    needs = .keyPassphrase
                    status = .idle
                    return
                }
                let key = try SSHKeyLoader.loadKey(at: p, passphrase: phrase)
                if isEnc, passphrase != nil { usedPassphraseFromUser = phrase }
                switch key {
                case .ed25519(let priv):
                    auth = .ed25519(username: username, privateKey: priv)
                case .rsa(let priv):
                    auth = .rsa(username: username, privateKey: priv)
                }
            } catch SSHKeyLoader.LoadError.wrongPassphrase {
                KeychainHelper.delete(kind: .keyPassphrase, account: keyPath ?? "")
                lastError = "passphrase ไม่ถูก ลองใหม่"
                needs = .keyPassphrase
                status = .idle
                return
            } catch SSHKeyLoader.LoadError.encryptedKeyNeedsPassphrase {
                needs = .keyPassphrase
                status = .idle
                return
            } catch {
                lastError = "key auth: \(error.localizedDescription)"
            }
        }

        // 2. ถ้าไม่มี key หรือ key ใช้ไม่ได้ ใช้ password
        var usedPasswordFromUser: String?
        // ใช้ canonical account key เดียวกับที่ HostEditor ใช้ตอน save
        let pwAccount = host.keychainAccount
        if auth == nil {
            // ลำดับ: argument > Keychain > prompt
            let pw: String? = password
                ?? KeychainHelper.load(kind: .userPassword, account: pwAccount)
            guard let p = pw, !p.isEmpty else {
                needs = .userPassword
                status = .idle
                return
            }
            if password != nil { usedPasswordFromUser = p }
            auth = .passwordBased(username: username, password: p)
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

            // 4. บันทึก credential ที่ user เพิ่งใส่ (ถ้าเลือก save) ลง Keychain
            if saveToKeychain {
                if let ph = usedPassphraseFromUser, let kp = keyPath {
                    KeychainHelper.save(ph, kind: .keyPassphrase, account: kp)
                }
                if let pw = usedPasswordFromUser {
                    KeychainHelper.save(pw, kind: .userPassword, account: pwAccount)
                }
            }
        } catch {
            // ถ้า fail (อาจเพราะ password ผิดที่มาจาก Keychain) — ลบของเก่าทิ้ง
            if password == nil, usedPasswordFromUser == nil {
                KeychainHelper.delete(kind: .userPassword, account: pwAccount)
            }
            let raw = "\(type(of: error)).\(error)"
            // friendly message
            let lower = raw.lowercased()
            if lower.contains("allauthentication") || lower.contains("authenticationfailed")
                || lower.contains("password") {
                let detail = """
                Server ปฏิเสธ password auth — server น่าจะตั้ง 'PasswordAuthentication no'
                ต้องใช้ key auth (V1 รองรับเฉพาะ ed25519 ไม่มี passphrase)

                แนะนำ: สร้าง ed25519 key ใหม่ + เพิ่มเข้า authorized_keys ของ server แล้ว
                ตั้ง SSH Key ใน Mhost ให้ชี้ key นั้น
                """
                status = .failed(detail)
                lastError = detail
            } else {
                status = .failed(raw)
                lastError = raw
            }
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
                // Citadel เก็บ permissions เป็น UInt32 (Unix mode bits) — เช็ค type bits เอง
                // S_IFMT = 0o170000, S_IFDIR = 0o040000, S_IFLNK = 0o120000
                let mode: UInt32 = c.attributes.permissions ?? 0
                let typeBits = mode & 0o170000
                let isDir = typeBits == 0o040000
                let isLink = typeBits == 0o120000
                let size = c.attributes.size ?? 0
                // Citadel เก็บ time ไว้ใน nested struct accessModificationTime
                let mtime = c.attributes.accessModificationTime?.modificationTime
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

    /// path เต็มของ entry ในโฟลเดอร์ปัจจุบัน
    func remotePath(of entry: SFTPEntry) -> String {
        if currentPath.hasSuffix("/") {
            return currentPath + entry.name
        }
        return currentPath + "/" + entry.name
    }

    /// download ไฟล์จาก remote → save ลง local URL
    /// คืน success/error
    func download(_ entry: SFTPEntry, to localURL: URL) async -> Result<Void, Error> {
        guard let sftp else {
            return .failure(NSError(domain: "Mhost.SFTP", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "ยังไม่ได้ connect"]))
        }
        let remote = remotePath(of: entry)
        do {
            // อ่านทั้งไฟล์เป็น ByteBuffer แล้ว write ลง URL
            // (Citadel: sftp.withFile(filePath:flags:) → callback คืน file handle)
            let buffer = try await sftp.withFile(filePath: remote, flags: .read) { file in
                try await file.readAll()
            }
            // ByteBuffer → Data (ใช้ readableBytesView เพื่อเลี่ยง dependency NIOFoundationCompat)
            let data = Data(buffer.readableBytesView)
            try data.write(to: localURL, options: .atomic)
            return .success(())
        } catch {
            return .failure(error)
        }
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
