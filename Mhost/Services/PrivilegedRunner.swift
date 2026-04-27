import Foundation

/// PrivilegedSession
/// ขอสิทธิ์ admin ครั้งเดียวด้วย osascript แล้ว spawn root shell ที่อ่านคำสั่งจาก FIFO
/// ทำให้คำสั่งถัด ๆ ไปไม่ต้องถามรหัสอีก ตลอดอายุของแอป
final class PrivilegedSession {

    enum RunnerError: LocalizedError {
        case osascriptFailed(String)
        case userCancelled
        case nonZeroExit(Int32, String)
        case notAuthorized
        case timeout
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .osascriptFailed(let msg): return "AppleScript failed: \(msg)"
            case .userCancelled: return "ผู้ใช้ยกเลิกการให้สิทธิ์"
            case .nonZeroExit(let code, let stderr): return "Command failed (exit \(code))\n\(stderr)"
            case .notAuthorized: return "ยังไม่ได้รับสิทธิ์ admin"
            case .timeout: return "Command timed out"
            case .ioError(let m): return "I/O error: \(m)"
            }
        }
    }

    static let shared = PrivilegedSession()

    private let cmdFifo: String
    private let outFile: String
    private let doneFile: String
    private let readyFile: String
    private let helperScriptPath: String
    private var fifoWriter: FileHandle?
    private var helperProcess: Process?
    private var isAuthorized = false
    private var sequence: UInt64 = 0
    private let lock = NSLock()      // กัน concurrent run
    private let authLock = NSLock()  // กัน concurrent authorize

    private init() {
        let id = UUID().uuidString.prefix(8)
        cmdFifo  = "/tmp/mhost-cmd-\(id).fifo"
        outFile  = "/tmp/mhost-out-\(id).log"
        doneFile = "/tmp/mhost-done-\(id)"
        readyFile = "/tmp/mhost-ready-\(id)"
        helperScriptPath = "/tmp/mhost-helper-\(id).sh"
    }

    var authorized: Bool {
        authLock.lock(); defer { authLock.unlock() }
        return isAuthorized
    }

    /// ขอสิทธิ์ admin (ครั้งเดียว). ถ้าได้แล้วจะไม่ถามอีก
    func authorize(prompt: String = "Mhost ต้องใช้สิทธิ์ผู้ดูแลระบบเพื่อแก้ไข /etc/hosts และจัดการ certificate") throws {
        authLock.lock()
        defer { authLock.unlock() }
        if isAuthorized { return }

        // ลบไฟล์เก่าทิ้ง (ถ้ามี)
        unlink(cmdFifo)
        unlink(outFile)
        unlink(doneFile)
        unlink(readyFile)
        unlink(helperScriptPath)

        // สร้าง FIFO สำหรับส่งคำสั่ง (mode 666 ให้ทั้ง root helper และ user app เขียนได้)
        guard mkfifo(cmdFifo, 0o666) == 0 else {
            throw RunnerError.ioError("ไม่สามารถสร้าง FIFO: \(String(cString: strerror(errno)))")
        }
        // chmod อีกครั้งเพื่อข้าม umask
        chmod(cmdFifo, 0o666)

        // Helper script: root shell ที่อ่านคำสั่งจาก FIFO ตลอดอายุของ session
        //
        // Protocol: Swift ส่ง "SEQ\nCMD\n" (สองบรรทัด) — helper อ่าน 2 บรรทัด
        //          helper รัน CMD แล้วเขียน "SEQ:exit_code" ลง doneFile
        //          Swift poll จนเจอ SEQ ตรงกับที่ส่งไป
        //
        // เหตุผลใช้ sequence: /tmp มี sticky bit, user unlink ไฟล์ที่ root สร้างไม่ได้
        // → ใช้ sequence แทนการลบไฟล์ ปลอดภัยจาก race condition
        let uid = getuid()
        let gid = getgid()
        let helperScript = """
        #!/bin/sh
        UID_USER=\(uid)
        GID_USER=\(gid)
        exec 3<> '\(cmdFifo)'
        : > '\(readyFile)'
        chown $UID_USER:$GID_USER '\(readyFile)' '\(cmdFifo)' 2>/dev/null
        while IFS= read -r seq <&3; do
          if [ "$seq" = "__EXIT__" ]; then
            break
          fi
          IFS= read -r cmd <&3 || break
          eval "$cmd" > '\(outFile)' 2>&1
          ec=$?
          chown $UID_USER:$GID_USER '\(outFile)' 2>/dev/null
          chmod 644 '\(outFile)' 2>/dev/null
          printf '%s:%s' "$seq" "$ec" > '\(doneFile)'
          chown $UID_USER:$GID_USER '\(doneFile)' 2>/dev/null
          chmod 644 '\(doneFile)' 2>/dev/null
        done
        rm -f '\(cmdFifo)' '\(outFile)' '\(doneFile)' '\(readyFile)' '\(helperScriptPath)'
        """
        try helperScript.write(toFile: helperScriptPath, atomically: true, encoding: .utf8)
        chmod(helperScriptPath, 0o755)

        // รัน helper เป็น root โดยให้ osascript ค้างอยู่ตลอดอายุของ session
        // (ไม่ background; osascript จะ exit เมื่อ helper loop จบจาก __EXIT__)
        let runHelper = "/bin/sh '\(helperScriptPath)'"
        let escapedCmd = runHelper
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        do shell script "\(escapedCmd)" with prompt "\(escapedPrompt)" with administrator privileges
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]

        // ปล่อย stdout/stderr ไปยัง /dev/null ให้ไม่ค้าง pipe buffer
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            p.standardOutput = devNull
            p.standardError = devNull
        }

        do { try p.run() } catch {
            throw RunnerError.osascriptFailed(error.localizedDescription)
        }
        // ⚠️ ไม่เรียก waitUntilExit() — osascript จะรันต่อจนกว่า helper จะ exit
        helperProcess = p

        // รอ helper เขียน ready marker หรือ osascript exit (= user cancel/error)
        let readyDeadline = Date().addingTimeInterval(60) // เผื่อเวลาผู้ใช้กรอกรหัส
        while !FileManager.default.fileExists(atPath: readyFile) {
            if !p.isRunning {
                // osascript ออกก่อนที่ helper จะพร้อม = ถูกยกเลิก/ผิดพลาด
                let code = p.terminationStatus
                if code == 1 { // user cancel
                    throw RunnerError.userCancelled
                }
                throw RunnerError.osascriptFailed("osascript exited with code \(code) ก่อน helper ready")
            }
            if Date() > readyDeadline {
                p.terminate()
                throw RunnerError.timeout
            }
            usleep(100_000) // 100ms
        }

        // เปิด FIFO สำหรับเขียน — helper พร้อมแล้ว
        var attempts = 0
        var writer: FileHandle?
        while attempts < 30 {
            let fd = open(cmdFifo, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                break
            }
            usleep(100_000)
            attempts += 1
        }
        guard let writer else {
            throw RunnerError.ioError("ไม่สามารถเปิด FIFO writer: \(String(cString: strerror(errno)))")
        }
        fifoWriter = writer
        isAuthorized = true
    }

    /// รันคำสั่ง shell ในฐานะ root (ผ่าน session ที่ authorize ไว้) → คืน (exitCode, output)
    @discardableResult
    func runRaw(_ command: String, timeout: TimeInterval = 120) throws -> (exitCode: Int32, output: String) {
        // ถ้า helper ตายไปแล้ว (osascript exit จาก SIGTERM/crash) → reset แล้ว authorize ใหม่
        if let p = helperProcess, !p.isRunning {
            authLock.lock()
            isAuthorized = false
            try? fifoWriter?.close()
            fifoWriter = nil
            helperProcess = nil
            sequence = 0
            authLock.unlock()
        }
        if !authorized {
            try authorize()
        }
        lock.lock()
        defer { lock.unlock() }

        guard let writer = fifoWriter else {
            throw RunnerError.notAuthorized
        }

        // เพิ่ม sequence — ใช้ระบุ response ของคำสั่งนี้
        sequence += 1
        let mySeq = sequence
        let mySeqStr = "S\(mySeq)"

        // ส่ง 2 บรรทัด: SEQ + CMD
        let oneLine = command.replacingOccurrences(of: "\n", with: "; ")
        let payload = "\(mySeqStr)\n\(oneLine)\n".data(using: .utf8) ?? Data()
        try writer.write(contentsOf: payload)

        // รอจน doneFile มี content ขึ้นต้นด้วย "S{seq}:"
        let prefix = "\(mySeqStr):"
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let p = helperProcess, !p.isRunning {
                throw RunnerError.ioError("Helper หยุดทำงานกลางคัน")
            }
            if Date() > deadline { throw RunnerError.timeout }
            if let content = try? String(contentsOfFile: doneFile, encoding: .utf8),
               content.hasPrefix(prefix) {
                let codeStr = String(content.dropFirst(prefix.count))
                let exitCode = Int32(codeStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let output = (try? String(contentsOfFile: outFile, encoding: .utf8)) ?? ""
                return (exitCode, output)
            }
            usleep(50_000)
        }
    }

    /// รันแบบดูแค่ output — throw .nonZeroExit ถ้า exit code != 0
    @discardableResult
    func runAsRoot(_ command: String) throws -> String {
        let (code, out) = try runRaw(command)
        if code != 0 {
            throw RunnerError.nonZeroExit(code, out)
        }
        return out
    }

    /// เขียนไฟล์ด้วยสิทธิ์ root (atomic ผ่าน temp + cp)
    func writeFile(content: String, to destinationPath: String) throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mhost_\(UUID().uuidString).tmp")
        try content.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let cmd = "/bin/cp '\(tmpURL.path)' '\(destinationPath)' && /usr/sbin/chown root:wheel '\(destinationPath)' && /bin/chmod 644 '\(destinationPath)'"
        _ = try runAsRoot(cmd)
    }

    /// รันคำสั่งโดยไม่ใช้สิทธิ์ admin
    @discardableResult
    static func run(executable: String, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    /// ปิด session (ส่ง __EXIT__ ให้ helper เลิกทำงาน + รอ osascript จบ)
    func shutdown() {
        authLock.lock()
        defer { authLock.unlock() }
        guard isAuthorized else { return }

        if let writer = fifoWriter {
            let bye = "__EXIT__\n".data(using: .utf8) ?? Data()
            try? writer.write(contentsOf: bye)
            try? writer.close()
        }
        fifoWriter = nil

        // รอ osascript+helper จบเอง (สูงสุด 2 วินาที) ถ้าไม่จบก็ terminate
        if let p = helperProcess, p.isRunning {
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if p.isRunning { p.terminate() }
        }
        helperProcess = nil
        isAuthorized = false
    }

    deinit {
        shutdown()
    }
}

/// Backward-compat shim — ตัวเก่าที่เคยใช้ static API เดิม
enum PrivilegedRunner {
    typealias RunnerError = PrivilegedSession.RunnerError

    @discardableResult
    static func runAsAdmin(_ command: String, prompt: String = "Mhost ต้องใช้สิทธิ์ผู้ดูแลระบบ") throws -> String {
        try PrivilegedSession.shared.authorize(prompt: prompt)
        return try PrivilegedSession.shared.runAsRoot(command)
    }

    static func writeFile(content: String, to destinationPath: String) throws {
        try PrivilegedSession.shared.writeFile(content: content, to: destinationPath)
    }

    @discardableResult
    static func run(executable: String, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try PrivilegedSession.run(executable: executable, arguments: arguments)
    }
}
