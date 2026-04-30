import AppKit
import SwiftUI

// MARK: - Model

struct SSHKeyEntry: Identifiable, Equatable {
    let id: String           // full path to private key
    let filename: String     // e.g. "id_ed25519"
    let directory: String    // parent directory path
    let keyType: String      // e.g. "ED25519", "RSA"
    let fingerprint: String  // e.g. "SHA256:abc..."
    let comment: String
    var hasPub: Bool

    var privatePath: String { id }
    var pubPath: String { id + ".pub" }

    /// abbreviated directory label — shows ~ instead of /Users/xxx
    var directoryLabel: String {
        let home = NSHomeDirectory()
        if directory.hasPrefix(home) {
            return "~" + directory.dropFirst(home.count)
        }
        return directory
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class SSHKeyManager {
    var keys: [SSHKeyEntry] = []
    var searchPaths: [String] = {
        [(NSHomeDirectory() as NSString).appendingPathComponent(".ssh")]
    }()
    var statusMessage: String = ""
    var statusIsError: Bool = false

    // MARK: - Search paths management

    func addSearchPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "เลือก"
        panel.message = "เลือกโฟลเดอร์ที่มี SSH key"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard !searchPaths.contains(path) else { return }
        searchPaths.append(path)
        loadKeys()
    }

    func removeSearchPath(_ path: String) {
        searchPaths.removeAll { $0 == path }
        loadKeys()
    }

    // MARK: - List

    func loadKeys() {
        let fm = FileManager.default
        var result: [SSHKeyEntry] = []
        var seen = Set<String>()

        for dir in searchPaths {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let pubSet = Set(items.filter { $0.hasSuffix(".pub") }.map { String($0.dropLast(4)) })

            for name in items.sorted() {
                guard !name.hasSuffix(".pub") && !name.hasSuffix(".old") else { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                guard !seen.contains(full) else { continue }
                guard let pem = try? String(contentsOfFile: full, encoding: .utf8),
                      pem.contains("PRIVATE KEY") else { continue }
                seen.insert(full)

                let kType = detectType(pem: pem)
                let (fp, cmt) = fingerprintSync(path: full)

                result.append(SSHKeyEntry(
                    id: full,
                    filename: name,
                    directory: dir,
                    keyType: kType,
                    fingerprint: fp,
                    comment: cmt,
                    hasPub: pubSet.contains(name)
                ))
            }
        }
        keys = result
    }

    // MARK: - Generate

    func generate(type: KeyType, bits: Int, filename: String,
                  directory: String, passphrase: String, comment: String) async {
        statusMessage = "กำลังสร้าง key..."
        statusIsError = false

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            do {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                // apply 0700 only for ~/.ssh
                let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
                if directory == sshDir {
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
                }
            } catch {
                statusMessage = "สร้างโฟลเดอร์ไม่ได้: \(error.localizedDescription)"
                statusIsError = true
                return
            }
        }

        let fn = filename.trimmingCharacters(in: .whitespaces).ifEmpty(type.defaultFilename)
        let outPath = (directory as NSString).appendingPathComponent(fn)

        if fm.fileExists(atPath: outPath) {
            statusMessage = "ไฟล์ \(fn) มีอยู่แล้วในโฟลเดอร์นี้"
            statusIsError = true
            return
        }

        let cmt = comment.trimmingCharacters(in: .whitespaces).ifEmpty(defaultComment)
        var args = ["-t", type.rawValue]
        if type == .rsa { args += ["-b", String(bits)] }
        args += ["-f", outPath, "-N", passphrase, "-C", cmt]

        let r = await runProcess("/usr/bin/ssh-keygen", args: args)
        if r.exit == 0 {
            statusMessage = "สร้าง \(fn) สำเร็จ"
            statusIsError = false
            // เพิ่ม directory ใน searchPaths ถ้ายังไม่มี
            if !searchPaths.contains(directory) {
                searchPaths.append(directory)
            }
            loadKeys()
        } else {
            statusMessage = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                .ifEmpty("สร้าง key ไม่สำเร็จ")
            statusIsError = true
        }
    }

    // MARK: - Delete

    func delete(_ entry: SSHKeyEntry) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: entry.privatePath)
        if entry.hasPub { try? fm.removeItem(atPath: entry.pubPath) }
        loadKeys()
        statusMessage = "ลบ \(entry.filename) แล้ว"
        statusIsError = false
    }

    // MARK: - Copy public key

    func copyPublicKey(of entry: SSHKeyEntry) {
        guard entry.hasPub,
              let pub = try? String(contentsOfFile: entry.pubPath, encoding: .utf8) else {
            statusMessage = "ไม่พบไฟล์ .pub"
            statusIsError = true
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pub.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        statusMessage = "คัดลอก public key แล้ว"
        statusIsError = false
    }

    // MARK: - Helpers

    var defaultComment: String {
        "\(NSUserName())@\(Host.current().localizedName ?? "Mac")"
    }

    private func detectType(pem: String) -> String {
        if pem.contains("BEGIN OPENSSH PRIVATE KEY") {
            if let t = SSHKeyTypeDetector.detect(pem: pem) { return t }
        }
        if pem.contains("BEGIN RSA PRIVATE KEY") { return "RSA" }
        if pem.contains("BEGIN EC PRIVATE KEY")  { return "ECDSA" }
        return "Unknown"
    }

    private func fingerprintSync(path: String) -> (fp: String, comment: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-lf", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return ("—", "") }
        proc.waitUntilExit()
        let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "256 SHA256:xxx comment (ED25519)"
        let parts = out.components(separatedBy: " ")
        let fp = parts.count >= 2 ? parts[1] : "—"
        let cmt = parts.count > 3
            ? parts[2..<max(3, parts.count - 1)].joined(separator: " ")
            : ""
        return (fp, cmt)
    }

    private func runProcess(_ exec: String, args: [String]) async -> (exit: Int32, err: String) {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exec)
            proc.arguments = args
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = Pipe()
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.terminationHandler = { p in
                let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (p.terminationStatus, e))
            }
            do { try proc.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}

// MARK: - Key type enum

enum KeyType: String, CaseIterable {
    case ed25519 = "ed25519"
    case rsa     = "rsa"

    var label: String {
        switch self {
        case .ed25519: return "ED25519"
        case .rsa:     return "RSA"
        }
    }
    var defaultFilename: String {
        switch self {
        case .ed25519: return "id_ed25519"
        case .rsa:     return "id_rsa"
        }
    }
}

// MARK: - Key-type detector

private enum SSHKeyTypeDetector {
    private static func beUInt32(_ data: Data, at i: Int) -> UInt32? {
        guard i + 4 <= data.count else { return nil }
        return (UInt32(data[i]) << 24) | (UInt32(data[i+1]) << 16)
             | (UInt32(data[i+2]) << 8)  |  UInt32(data[i+3])
    }

    static func detect(pem: String) -> String? {
        let base64 = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let data = Data(base64Encoded: base64) else { return nil }
        var offset = 15
        func readUInt32() -> UInt32? {
            guard let v = beUInt32(data, at: offset) else { return nil }
            offset += 4; return v
        }
        func readBytes() -> Data? {
            guard let n = readUInt32(), offset + Int(n) <= data.count else { return nil }
            let d = data[offset..<(offset+Int(n))]; offset += Int(n); return d
        }
        func readString() -> String? { readBytes().flatMap { String(data: $0, encoding: .utf8) } }
        _ = readString(); _ = readString(); _ = readBytes(); _ = readUInt32()
        guard let pubBlob = readBytes() else { return nil }
        let pb = Data(pubBlob)
        var o2 = 0
        func readBytes2() -> Data? {
            guard let n = beUInt32(pb, at: o2) else { return nil }
            o2 += 4
            guard o2 + Int(n) <= pb.count else { return nil }
            let d = pb[o2..<(o2+Int(n))]; o2 += Int(n); return d
        }
        guard let typeData = readBytes2(), let t = String(data: typeData, encoding: .utf8) else { return nil }
        switch t {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa":     return "RSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return "ECDSA"
        default: return t
        }
    }
}

// MARK: - Main View

struct SSHKeyManagerView: View {
    @State private var vm = SSHKeyManager()

    // generate form
    @State private var keyType: KeyType = .ed25519
    @State private var passphrase: String = ""
    @State private var showPassphrase: Bool = false
    @State private var comment: String = ""
    @State private var filename: String = "id_ed25519"
    @State private var saveDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    @State private var rsaBits: Int = 4096
    @State private var showAdvanced: Bool = false
    @State private var isGenerating: Bool = false

    @State private var confirmDelete: SSHKeyEntry? = nil

    var showDirLabel: Bool { vm.searchPaths.count > 1 }

    var body: some View {
        HStack(spacing: 0) {
            keyList.frame(minWidth: 320)
            Divider()
            generatePanel.frame(minWidth: 290, maxWidth: 360)
        }
        .onAppear { vm.loadKeys() }
        .confirmationDialog(
            "ลบ key \(confirmDelete?.filename ?? "")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("ลบ", role: .destructive) {
                if let e = confirmDelete { vm.delete(e) }
                confirmDelete = nil
            }
            Button("ยกเลิก", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("ลบไฟล์ private key และ .pub — ไม่สามารถกู้คืนได้")
        }
    }

    // MARK: - Key list

    private var keyList: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("SSH Keys")
                    .font(.headline)
                Spacer()
                Button { vm.loadKeys() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }
                .buttonStyle(.plain).help("โหลดใหม่")
                Button { vm.addSearchPath() } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 14))
                }
                .buttonStyle(.plain).help("เพิ่มโฟลเดอร์ที่จะสแกนหา key")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            // Search path chips
            if vm.searchPaths.count > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.searchPaths, id: \.self) { path in
                            dirChip(path)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
                .background(Color(NSColor.controlBackgroundColor))
            }

            Divider()

            if vm.keys.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("ไม่พบ SSH key ในโฟลเดอร์ที่เลือก")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
            } else {
                List(vm.keys) { entry in
                    keyRow(entry)
                        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                }
                .listStyle(.plain)
            }

            if !vm.statusMessage.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: vm.statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(vm.statusIsError ? Color.red : Color.green)
                    Text(vm.statusMessage).font(.caption).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func dirChip(_ path: String) -> some View {
        let home = NSHomeDirectory()
        let label = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let isDefault = path == (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")

        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
            if !isDefault {
                Button {
                    vm.removeSearchPath(path)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.10))
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .help("กดเพื่อเปิดโฟลเดอร์ใน Finder")
    }

    @ViewBuilder
    private func keyRow(_ entry: SSHKeyEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.filename)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                    Text(entry.keyType)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
                Text(entry.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
                if !entry.comment.isEmpty {
                    Text(entry.comment)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                if showDirLabel {
                    Text(entry.directoryLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.quaternary).lineLimit(1)
                }
                if !entry.hasPub {
                    Label("ไม่มีไฟล์ .pub", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button { vm.copyPublicKey(of: entry) } label: {
                    Image(systemName: "doc.on.doc").help("คัดลอก public key")
                }
                .buttonStyle(.plain).disabled(!entry.hasPub)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.privatePath)]
                    )
                } label: {
                    Image(systemName: "folder").help("เปิดใน Finder")
                }
                .buttonStyle(.plain)

                Button { confirmDelete = entry } label: {
                    Image(systemName: "trash").foregroundStyle(.red).help("ลบ key")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 14))
        }
    }

    // MARK: - Generate panel

    private var generatePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("สร้าง Key ใหม่")
                    .font(.headline).padding(.top, 14)

                // Key type
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("ประเภท Key")
                    Picker("", selection: $keyType) {
                        ForEach(KeyType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: keyType) { _, t in
                        if filename == KeyType.ed25519.defaultFilename || filename == KeyType.rsa.defaultFilename {
                            filename = t.defaultFilename
                        }
                    }
                }

                // Save location
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("บันทึกที่")
                    HStack(spacing: 6) {
                        let home = NSHomeDirectory()
                        let label = saveDirectory.hasPrefix(home)
                            ? "~" + saveDirectory.dropFirst(home.count)
                            : saveDirectory
                        Text(label)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        Button("เลือก") { pickSaveDirectory() }
                            .buttonStyle(.bordered)
                    }
                }

                // Passphrase
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Passphrase")
                    HStack(spacing: 6) {
                        Group {
                            if showPassphrase {
                                TextField("ว่าง = ไม่มี passphrase", text: $passphrase)
                            } else {
                                SecureField("ว่าง = ไม่มี passphrase", text: $passphrase)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        Button {
                            showPassphrase.toggle()
                        } label: {
                            Image(systemName: showPassphrase ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Comment
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Comment")
                    TextField(vm.defaultComment, text: $comment)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Advanced
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("ชื่อไฟล์")
                            TextField(keyType.defaultFilename, text: $filename)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        if keyType == .rsa {
                            VStack(alignment: .leading, spacing: 6) {
                                fieldLabel("ขนาด Key (bits)")
                                Picker("", selection: $rsaBits) {
                                    Text("2048").tag(2048)
                                    Text("4096").tag(4096)
                                }
                                .pickerStyle(.segmented).frame(maxWidth: 160)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.callout)

                Divider()

                Button {
                    isGenerating = true
                    let fn = filename.trimmingCharacters(in: .whitespaces).ifEmpty(keyType.defaultFilename)
                    let cmt = comment.trimmingCharacters(in: .whitespaces)
                    let dir = saveDirectory
                    Task {
                        await vm.generate(
                            type: keyType, bits: rsaBits,
                            filename: fn, directory: dir,
                            passphrase: passphrase, comment: cmt
                        )
                        isGenerating = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isGenerating { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus.diamond.fill") }
                        Text(isGenerating ? "กำลังสร้าง..." : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
                .controlSize(.large)

                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func pickSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "เลือก"
        panel.message = "เลือกโฟลเดอร์ที่จะบันทึก key"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }

    @ViewBuilder
    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - String helper

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
