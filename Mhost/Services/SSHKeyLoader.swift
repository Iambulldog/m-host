import Citadel
import Crypto
import Foundation
import NIOCore

/// ผลลัพธ์ของการโหลด private key — รองรับทั้ง Ed25519 และ RSA
enum LoadedSSHKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey)
}

/// load OpenSSH private key (Ed25519 หรือ RSA) จากไฟล์
/// - unencrypted → โหลดตรง
/// - encrypted (มี passphrase) → ใช้ /usr/bin/ssh-keygen ถอดรหัสลง temp file แล้วโหลดต่อ
enum SSHKeyLoader {

    enum LoadError: LocalizedError {
        case fileNotFound(String)
        case notOpenSSHFormat
        case invalidBase64
        case invalidMagic
        case encryptedKeyNeedsPassphrase
        case wrongPassphrase
        case multipleKeysNotSupported
        case unsupportedKeyType(String)
        case invalidKeyData
        case unexpectedEOF
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let p): return "ไม่พบไฟล์ key: \(p)"
            case .notOpenSSHFormat: return "ไฟล์ไม่ใช่ OpenSSH private key"
            case .invalidBase64: return "ถอด base64 ของ key ไม่ได้"
            case .invalidMagic: return "key magic bytes ไม่ตรง"
            case .encryptedKeyNeedsPassphrase: return "key มี passphrase — ต้องใส่ passphrase เพื่อปลดล็อค"
            case .wrongPassphrase: return "passphrase ไม่ถูก"
            case .multipleKeysNotSupported: return "key file มีหลาย keys — V1 รองรับ key เดียว"
            case .unsupportedKeyType(let t): return "key type ไม่รองรับ: \(t) (V1 รองรับเฉพาะ ed25519)"
            case .invalidKeyData: return "ข้อมูล key เสียหาย"
            case .unexpectedEOF: return "key file สั้นเกินไป"
            case .readError(let m): return "อ่าน key ไม่ได้: \(m)"
            }
        }
    }

    /// อ่าน Ed25519 private key จาก path (รองรับ ~ expand)
    /// ถ้า key มี passphrase → throw `.encryptedKeyNeedsPassphrase` ให้ caller ไป prompt
    /// แล้วเรียก `loadEd25519(at:passphrase:)` แทน
    static func loadEd25519(at path: String) throws -> Curve25519.Signing.PrivateKey {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LoadError.fileNotFound(expanded)
        }
        let pem: String
        do {
            pem = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw LoadError.readError(error.localizedDescription)
        }

        guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else {
            throw LoadError.notOpenSSHFormat
        }

        // เอา base64 ระหว่าง markers
        let base64 = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()

        guard let data = Data(base64Encoded: base64) else {
            throw LoadError.invalidBase64
        }

        var reader = Reader(data: data)

        // magic: "openssh-key-v1\0"
        let magic = try reader.readRaw(15)
        guard magic == Data("openssh-key-v1\0".utf8) else {
            throw LoadError.invalidMagic
        }

        // ciphername — ต้อง "none" (ไม่เข้ารหัส)
        let cipher = try reader.readSshString()
        guard cipher == "none" else {
            throw LoadError.encryptedKeyNeedsPassphrase
        }

        // kdfname — ต้อง "none"
        let kdf = try reader.readSshString()
        guard kdf == "none" else {
            throw LoadError.encryptedKeyNeedsPassphrase
        }

        // kdfoptions — empty
        _ = try reader.readSshBytes()

        // number of keys — ต้อง 1
        let nKeys = try reader.readUInt32()
        guard nKeys == 1 else {
            throw LoadError.multipleKeysNotSupported
        }

        // public key blob (skip)
        _ = try reader.readSshBytes()

        // private keys section
        let privSection = try reader.readSshBytes()
        var privReader = Reader(data: privSection)

        // check1, check2 (ต้องเท่ากัน — ใช้ verify ตอน decrypt; เราไม่เข้ารหัสเลย skip)
        _ = try privReader.readUInt32()
        _ = try privReader.readUInt32()

        // key type — ต้อง "ssh-ed25519"
        let keyType = try privReader.readSshString()
        guard keyType == "ssh-ed25519" else {
            throw LoadError.unsupportedKeyType(keyType)
        }

        // public key (32 bytes) — skip
        _ = try privReader.readSshBytes()

        // private key blob: 64 bytes (32 priv + 32 pub) — เอา 32 bytes แรก
        let privBlob = try privReader.readSshBytes()
        guard privBlob.count >= 32 else {
            throw LoadError.invalidKeyData
        }
        let rawPriv = privBlob.prefix(32)

        return try Curve25519.Signing.PrivateKey(rawRepresentation: rawPriv)
    }

    /// ลำดับ default ที่จะลอง ถ้า host ไม่ได้ระบุ IdentityFile
    static var defaultIdentityCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.ssh/id_ed25519",
            "\(home)/.ssh/id_rsa",  // จะ fail (ไม่ใช่ ed25519) — แค่ใส่ไว้เพื่อ check existence ตอน UI
        ]
    }

    /// ตรวจว่า key file มี passphrase หรือไม่
    /// - OpenSSH: ดู ciphername ใน header (none = ไม่เข้ารหัส)
    /// - PKCS#1: ดู `Proc-Type: 4,ENCRYPTED` หรือ `DEK-Info`
    static func isEncrypted(at path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return false
        }
        // PKCS#1 RSA — ใช้ DEK-Info header ตอนเข้ารหัส
        if pem.contains("BEGIN RSA PRIVATE KEY") {
            return pem.contains("Proc-Type: 4,ENCRYPTED") || pem.contains("DEK-Info")
        }
        guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let base64 = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let data = Data(base64Encoded: base64), data.count > 24 else { return false }

        var reader = Reader(data: data)
        do {
            _ = try reader.readRaw(15)
            let cipher = try reader.readSshString()
            return cipher != "none"
        } catch {
            return false
        }
    }

    /// โหลด ed25519 ที่มี passphrase — ใช้ /usr/bin/ssh-keygen ถอดรหัสลง temp file
    /// แล้วโหลดต่อตาม flow เดิม
    static func loadEd25519(at path: String, passphrase: String) throws -> Curve25519.Signing.PrivateKey {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LoadError.fileNotFound(expanded)
        }

        // 1) copy เข้า temp (ssh-keygen แก้ไฟล์ใน-place เลยห้ามแตะต้นฉบับ)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhost-key-\(UUID().uuidString)")
        do {
            let raw = try Data(contentsOf: URL(fileURLWithPath: expanded))
            try raw.write(to: tmp)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmp.path
            )
        } catch {
            throw LoadError.readError(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 2) ssh-keygen -p -f <tmp> -P <oldphrase> -N "" → ถอด passphrase
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = [
            "-p",
            "-f", tmp.path,
            "-P", passphrase,
            "-N", ""
        ]
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw LoadError.readError("เรียก ssh-keygen ไม่ได้: \(error.localizedDescription)")
        }

        if proc.terminationStatus != 0 {
            let errStr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // ssh-keygen แสดง "Bad passphrase, try again" หรือ "incorrect passphrase"
            let lower = errStr.lowercased()
            if lower.contains("bad passphrase") || lower.contains("incorrect passphrase") {
                throw LoadError.wrongPassphrase
            }
            throw LoadError.readError("ssh-keygen exit \(proc.terminationStatus): \(errStr)")
        }

        // 3) ตอนนี้ tmp เป็น unencrypted แล้ว → load ตาม flow ปกติ
        return try loadEd25519(at: tmp.path)
    }

    // MARK: - RSA support

    /// detect key type จาก OpenSSH header — return "ssh-ed25519" / "ssh-rsa" / etc.
    static func keyType(at path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: expanded, encoding: .utf8) else { return nil }

        // PKCS#1 RSA (BEGIN RSA PRIVATE KEY)
        if pem.contains("BEGIN RSA PRIVATE KEY") { return "ssh-rsa" }

        // OpenSSH format — อ่าน public key blob เพื่อหา key type
        guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        let base64 = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let data = Data(base64Encoded: base64) else { return nil }

        var reader = Reader(data: data)
        do {
            _ = try reader.readRaw(15)              // magic
            _ = try reader.readSshString()          // ciphername
            _ = try reader.readSshString()          // kdfname
            _ = try reader.readSshBytes()           // kdfoptions
            _ = try reader.readUInt32()             // nKeys
            // public key blob: length-prefixed string เริ่มต้นด้วย key type
            let pubBlob = try reader.readSshBytes()
            var pubReader = Reader(data: pubBlob)
            return try pubReader.readSshString()
        } catch {
            return nil
        }
    }

    /// load RSA private key — Citadel 0.12.1 ไม่มี public API โหลด RSA จากไฟล์
    /// (init รับ UnsafeMutablePointer<BIGNUM> จาก BoringSSL เท่านั้น) — เราจึงสลับไปใช้
    /// `/usr/bin/sftp` subprocess ใน SFTPSession แทน ซึ่งรองรับทุก key type ที่ ssh ของระบบรองรับ
    /// (ดู SFTPSession.swift)
    static func loadRSA(at path: String) throws -> Insecure.RSA.PrivateKey {
        throw LoadError.unsupportedKeyType(
            "ssh-rsa via Citadel — เลิกใช้แล้ว เพราะ Mhost SFTP สลับไปใช้ /usr/bin/sftp subprocess"
        )
    }

    static func loadRSA(at path: String, passphrase: String) throws -> Insecure.RSA.PrivateKey {
        throw LoadError.unsupportedKeyType("ssh-rsa via Citadel — เลิกใช้แล้ว")
    }

    /// โหลด key อัตโนมัติ — ตรวจ type ก่อน เลือก loader ที่ถูก
    static func loadKey(at path: String, passphrase: String? = nil) throws -> LoadedSSHKey {
        let type = keyType(at: path) ?? "ssh-ed25519"  // default ลอง ed25519 ถ้าตรวจไม่ได้
        let isEnc = isEncrypted(at: path)

        switch type {
        case "ssh-ed25519":
            if isEnc {
                guard let p = passphrase, !p.isEmpty else { throw LoadError.encryptedKeyNeedsPassphrase }
                return .ed25519(try loadEd25519(at: path, passphrase: p))
            }
            return .ed25519(try loadEd25519(at: path))
        case "ssh-rsa":
            if isEnc {
                guard let p = passphrase, !p.isEmpty else { throw LoadError.encryptedKeyNeedsPassphrase }
                return .rsa(try loadRSA(at: path, passphrase: p))
            }
            return .rsa(try loadRSA(at: path))
        default:
            throw LoadError.unsupportedKeyType("\(type) (รองรับเฉพาะ ssh-ed25519, ssh-rsa)")
        }
    }

    /// ตัด leading 0x00 ที่ใส่มาเพื่อ sign-extension ใน mpint format
    /// (RSA components ต้องเป็น unsigned big integer)
    private static func stripLeadingZero(_ data: Data) -> Data {
        var result = data
        while result.count > 1 && result.first == 0 {
            result = result.dropFirst()
        }
        return result
    }

    // MARK: - Reader

    private struct Reader {
        let data: Data
        var offset: Int = 0

        init(data: Data) { self.data = data }

        mutating func readRaw(_ count: Int) throws -> Data {
            guard offset + count <= data.count else { throw LoadError.unexpectedEOF }
            let s = data.subdata(in: offset..<(offset + count))
            offset += count
            return s
        }

        mutating func readUInt32() throws -> UInt32 {
            let b = try readRaw(4)
            return b.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self).bigEndian
            }
        }

        mutating func readSshBytes() throws -> Data {
            let n = try readUInt32()
            return try readRaw(Int(n))
        }

        mutating func readSshString() throws -> String {
            let b = try readSshBytes()
            return String(data: b, encoding: .utf8) ?? ""
        }
    }
}
