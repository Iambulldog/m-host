import Foundation
import Security
import Network

/// จัดการ certificate สำหรับ MITM ของ proxy
/// เรียก mkcert สร้าง cert ต่อ host แล้ว import เป็น SecIdentity เพื่อใช้กับ NWProtocolTLS
/// ใช้ NSLock กัน race เพราะถูกเรียกจาก background IO queue
final class ProxyCertManager {

    enum CertError: LocalizedError {
        case mkcertNotFound
        case mkcertFailed(String)
        case opensslFailed(String)
        case importFailed(OSStatus)
        case identityMissing

        var errorDescription: String? {
            switch self {
            case .mkcertNotFound: return "ไม่พบ mkcert"
            case .mkcertFailed(let m): return "mkcert ผิดพลาด: \(m)"
            case .opensslFailed(let m): return "openssl ผิดพลาด: \(m)"
            case .importFailed(let s): return "นำเข้า PKCS12 ไม่สำเร็จ (OSStatus \(s))"
            case .identityMissing: return "ไม่พบ SecIdentity ใน PKCS12"
            }
        }
    }

    private let tempDir: URL
    private var identityCache: [String: SecIdentity] = [:]
    private let lock = NSLock()
    /// password ของ PKCS12 ภายใน — ใช้เพราะ macOS รุ่นใหม่ไม่รับ p12 ที่ password ว่าง
    /// (errSecAuthFailed/-25293) ค่านี้ไม่มีผลกับใครเพราะไฟล์อยู่ใน temp + import แล้ว
    /// ก็ลบทิ้ง
    private let p12Password = "mhost-mitm"

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhost-proxy-certs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// คืน SecIdentity สำหรับ host (สร้าง cert ผ่าน mkcert ถ้ายังไม่มี cache)
    func identity(for host: String, mkcertPath: String?) throws -> SecIdentity {
        lock.lock()
        if let cached = identityCache[host] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let mkcert = mkcertPath else { throw CertError.mkcertNotFound }

        let safe = host
            .replacingOccurrences(of: "*", with: "wildcard")
            .replacingOccurrences(of: "/", with: "_")
        let certURL = tempDir.appendingPathComponent("\(safe).pem")
        let keyURL  = tempDir.appendingPathComponent("\(safe)-key.pem")
        let p12URL  = tempDir.appendingPathComponent("\(safe).p12")

        // 1) สร้าง cert/key ด้วย mkcert (ไม่ต้อง admin — เขียนใน temp)
        if !FileManager.default.fileExists(atPath: certURL.path) ||
           !FileManager.default.fileExists(atPath: keyURL.path) {
            let r = try runProcess(mkcert,
                arguments: ["-cert-file", certURL.path, "-key-file", keyURL.path, host])
            if r.exitCode != 0 {
                throw CertError.mkcertFailed("\(r.stderr)\n\(r.stdout)")
            }
        }

        // 2) แปลง PEM → PKCS12 ด้วย openssl (มากับ macOS แน่นอน)
        // ใช้ password ไม่ว่าง + macalg sha1 เพื่อ compat กับ SecPKCS12Import
        // ใน macOS Sequoia/26 (เคย errSecAuthFailed -25293 ตอนใช้ pass ว่าง)
        let openssl = "/usr/bin/openssl"
        let r = try runProcess(openssl, arguments: [
            "pkcs12", "-export",
            "-macalg", "sha1",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(p12Password)",
            "-name", host
        ])
        if r.exitCode != 0 {
            throw CertError.opensslFailed("\(r.stderr)\n\(r.stdout)")
        }

        // 3) Import PKCS12 → SecIdentity
        let data = try Data(contentsOf: p12URL)
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        if status != errSecSuccess { throw CertError.importFailed(status) }
        guard let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw CertError.identityMissing
        }
        let identity = raw as! SecIdentity
        lock.lock()
        identityCache[host] = identity
        lock.unlock()
        return identity
    }

    /// ลบ cache (เผื่อต้องการ regenerate)
    func clearCache() {
        lock.lock()
        identityCache.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - helper

    private struct ProcResult { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runProcess(_ path: String, arguments: [String]) throws -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcResult(exitCode: p.terminationStatus, stdout: out, stderr: err)
    }
}
