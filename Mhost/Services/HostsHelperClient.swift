import Foundation

/// HostsHelperClient
/// ใช้ PrivilegedSession (persistent root shell) — ขอรหัส admin แค่ครั้งเดียวต่อการเปิดแอป
final class HostsHelperClient {

    private let dnsRefreshCommand = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"

    /// เขียนทับไฟล์ /etc/hosts (ขอรหัส admin ครั้งแรก, ครั้งถัดไปเงียบ)
    func replaceHostsFile(content: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PrivilegedSession.shared.writeFile(content: content, to: "/etc/hosts")
                // flush DNS cache (best-effort, ไม่กระทบผลลัพธ์ถ้า fail)
                _ = try? PrivilegedSession.shared.runAsRoot(self.dnsRefreshCommand)
                DispatchQueue.main.async { completion(true, nil) }
            } catch PrivilegedSession.RunnerError.userCancelled {
                DispatchQueue.main.async { completion(false, "ผู้ใช้ยกเลิกการให้สิทธิ์") }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    /// รีเฟรช DNS cache แบบ manual จาก UI
    func refreshDNSCache(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try PrivilegedSession.shared.runAsRoot(self.dnsRefreshCommand)
                DispatchQueue.main.async { completion(true, nil) }
            } catch PrivilegedSession.RunnerError.userCancelled {
                DispatchQueue.main.async { completion(false, "ผู้ใช้ยกเลิกการให้สิทธิ์") }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    /// รันคำสั่งใด ๆ ด้วยสิทธิ์ admin (สำหรับ mkcert -install เป็นต้น)
    func runPrivilegedCommand(executablePath: String,
                              arguments: [String],
                              completion: @escaping (Int32, String, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let quotedArgs = arguments
                .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: " ")
            let cmd = "'\(executablePath)' \(quotedArgs)"
            do {
                let (exitCode, output) = try PrivilegedSession.shared.runRaw(cmd)
                DispatchQueue.main.async {
                    if exitCode == 0 {
                        completion(0, output, "")
                    } else {
                        completion(exitCode, "", output)
                    }
                }
            } catch PrivilegedSession.RunnerError.userCancelled {
                DispatchQueue.main.async { completion(-1, "", "ผู้ใช้ยกเลิกการให้สิทธิ์") }
            } catch {
                DispatchQueue.main.async { completion(-1, "", error.localizedDescription) }
            }
        }
    }

    /// รันโดยไม่ต้องการสิทธิ์ admin (เช่น mkcert generate cert ในโฟลเดอร์ user)
    func runCommand(executablePath: String,
                    arguments: [String],
                    completion: @escaping (Int32, String, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try PrivilegedSession.run(executable: executablePath, arguments: arguments)
                DispatchQueue.main.async { completion(result.exitCode, result.stdout, result.stderr) }
            } catch {
                DispatchQueue.main.async { completion(-1, "", error.localizedDescription) }
            }
        }
    }
}
