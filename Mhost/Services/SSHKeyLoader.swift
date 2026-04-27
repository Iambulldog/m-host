import Crypto
import Foundation

/// load OpenSSH private key (Ed25519, unencrypted) จากไฟล์
/// V1 รองรับเฉพาะ Ed25519 ที่ไม่มี passphrase — เป็น default ของ ssh-keygen สมัยใหม่
/// (RSA + key มี passphrase ไว้ค่อยทำ Phase 2)
enum SSHKeyLoader {

    enum LoadError: LocalizedError {
        case fileNotFound(String)
        case notOpenSSHFormat
        case invalidBase64
        case invalidMagic
        case encryptedKeyNotSupported
        case multipleKeysNotSupported
        case unsupportedKeyType(String)
        case invalidKeyData
        case unexpectedEOF
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let p): return "ไม่พบไฟล์ key: \(p)"
            case .notOpenSSHFormat: return "ไฟล์ไม่ใช่ OpenSSH private key (เริ่มต้นด้วย -----BEGIN OPENSSH PRIVATE KEY-----)"
            case .invalidBase64: return "ถอด base64 ของ key ไม่ได้"
            case .invalidMagic: return "key magic bytes ไม่ตรง"
            case .encryptedKeyNotSupported: return "key มี passphrase — V1 ยังไม่รองรับ"
            case .multipleKeysNotSupported: return "key file มีหลาย keys — V1 รองรับ key เดียว"
            case .unsupportedKeyType(let t): return "key type ไม่รองรับ: \(t) (V1 รองรับเฉพาะ ed25519)"
            case .invalidKeyData: return "ข้อมูล key เสียหาย"
            case .unexpectedEOF: return "key file สั้นเกินไป"
            case .readError(let m): return "อ่าน key ไม่ได้: \(m)"
            }
        }
    }

    /// อ่าน Ed25519 private key จาก path (รองรับ ~ expand)
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
            throw LoadError.encryptedKeyNotSupported
        }

        // kdfname — ต้อง "none"
        let kdf = try reader.readSshString()
        guard kdf == "none" else {
            throw LoadError.encryptedKeyNotSupported
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
