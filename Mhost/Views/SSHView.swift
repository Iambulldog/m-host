import AppKit
import SwiftUI

struct SSHView: View {
    @State private var manager = SSHConfigManager()
    @State private var selection: UUID?
    /// host ที่กำลัง open session อยู่ (เปิดเป็น sheet)
    @State private var sessionHost: SSHHost?

    var body: some View {
        @Bindable var manager = manager

        return VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.tint)
                Text("SSH Config")
                    .font(.headline)
                Spacer()
                Button {
                    manager.load()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button {
                    manager.save()
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
            }
            .padding()

            // Config path bar
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(manager.configPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Browse...") { manager.pickConfigFile() }
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            HSplitView {
                // Left: list of hosts
                VStack(spacing: 0) {
                    HStack {
                        Text("\(manager.hosts.count) host\(manager.hosts.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            manager.addHost()
                            selection = manager.hosts.last?.id
                        } label: { Image(systemName: "plus") }
                            .help("เพิ่ม host ใหม่")
                        Button {
                            if let id = selection,
                               let h = manager.hosts.first(where: { $0.id == id }) {
                                manager.deleteHost(h)
                                selection = nil
                            }
                        } label: { Image(systemName: "minus") }
                            .help("ลบ host")
                            .disabled(selection == nil)
                    }
                    .padding(8)

                    List(selection: $selection) {
                        ForEach(manager.hosts) { h in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(h.alias).font(.system(.body, design: .monospaced))
                                    if !h.hostName.isEmpty {
                                        Text("\(h.user.isEmpty ? "" : h.user + "@")\(h.hostName)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .tag(h.id)
                        }
                    }
                    .frame(minWidth: 200)
                }
                .frame(minWidth: 220)

                // Right: editor
                if let id = selection,
                   let idx = manager.hosts.firstIndex(where: { $0.id == id }) {
                    HostEditor(
                        host: $manager.hosts[idx],
                        onPickIdentity: { manager.pickIdentityFile() },
                        onOpenSession: { sessionHost = manager.hosts[idx] },
                        loadPassword: { manager.savedPassword(for: $0) },
                        savePassword: { pw, h in manager.savePassword(pw, for: h) },
                        forgetCredentials: { manager.forgetCredentials(for: $0) }
                    )
                    .id(id)  // re-create editor เมื่อ host เปลี่ยน (เพื่อ load password ใหม่)
                } else {
                    VStack {
                        Spacer()
                        Text("เลือก host ทางซ้าย หรือกด + เพื่อเพิ่ม host ใหม่")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // Status bar
            HStack {
                if let err = manager.errorMessage {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(manager.statusMessage.isEmpty ? "Ready" : manager.statusMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .sheet(item: $sessionHost) { host in
            SSHSessionView(host: host) {
                sessionHost = nil
            }
        }
    }
}

private struct HostEditor: View {
    @Binding var host: SSHHost
    var onPickIdentity: () -> String?
    var onOpenSession: () -> Void
    /// load password ที่ save ใน Keychain (ถ้ามี)
    var loadPassword: (SSHHost) -> String?
    /// save password ลง Keychain (ถ้าว่างจะลบ)
    var savePassword: (String, SSHHost) -> Void
    /// ลบทุก credential (password + passphrase) ของ host
    var forgetCredentials: (SSHHost) -> Void

    @State private var password: String = ""
    @State private var showPassword: Bool = false
    @State private var didLoadPassword: Bool = false
    @State private var showAdvanced: Bool = false

    var body: some View {
        Form {
            // — HOST
            Section("Host") {
                LabeledContent("Alias") {
                    TextField("alias", text: $host.alias)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("HostName") {
                    TextField("192.168.1.10 หรือ example.com", text: $host.hostName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Port") {
                    TextField("22", text: $host.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            // — CREDENTIALS (Termius-style)
            Section("Credentials") {
                LabeledContent {
                    TextField("ubuntu / root", text: $host.user)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Label("Username", systemImage: "person")
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("(ว่าง = ใช้ key อย่างเดียว)", text: $password)
                            } else {
                                SecureField("(ว่าง = ใช้ key อย่างเดียว)", text: $password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showPassword ? "ซ่อน password" : "แสดง password")
                    }
                } label: {
                    Label("Password", systemImage: "lock")
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("~/.ssh/id_ed25519 (optional)", text: $host.identityFile)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Browse...") {
                            if let p = onPickIdentity() { host.identityFile = p }
                        }
                    }
                } label: {
                    Label("SSH Key", systemImage: "key")
                }

                Text("Password เก็บใน macOS Keychain (เข้ารหัสกับ Secure Enclave — ไม่เคยเขียนลง ssh config) — auto-fill ตอน Connect")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // — DEFAULT PATH
            Section("Default Path") {
                LabeledContent {
                    TextField("/var/www/html", text: $host.defaultPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } label: {
                    Label("Path", systemImage: "folder")
                }
                Text("Connect แล้ว auto cd ไป path นี้ — เก็บเป็น `# MhostDefaultPath:` ใน ssh config")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // — ADVANCED (Other options) — collapsed by default
            if !host.extraOptions.isEmpty {
                Section {
                    DisclosureGroup("Other options (\(host.extraOptions.count))",
                                     isExpanded: $showAdvanced) {
                        ForEach(Array(host.extraOptions.enumerated()), id: \.offset) { _, opt in
                            HStack {
                                Text(opt.key).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(opt.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // — ACTIONS
            Section {
                Button {
                    // commit password ลง Keychain ก่อนเปิด session — กัน timing issue
                    // ของ onChange ที่อาจยังไม่ทัน save
                    if !password.isEmpty {
                        savePassword(password, host)
                    }
                    onOpenSession()
                } label: {
                    Label("Open Session (Terminal + SFTP)", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(host.alias.trimmingCharacters(in: .whitespaces).isEmpty)

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        password = ""
                        forgetCredentials(host)
                    } label: {
                        Label("Forget Saved Credentials", systemImage: "trash")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .help("ลบ password + passphrase ที่ save ใน Keychain ของ host นี้")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380)
        .onAppear {
            password = loadPassword(host) ?? ""
            didLoadPassword = true
        }
        .onChange(of: password) { _, newVal in
            // กัน save ตอน initial load
            guard didLoadPassword else { return }
            savePassword(newVal, host)
        }
        // ถ้า user/hostname เปลี่ยน → re-key Keychain account ของ password
        .onChange(of: host.user) { _, _ in resaveIfNeeded() }
        .onChange(of: host.hostName) { _, _ in resaveIfNeeded() }
    }

    /// re-save password ลง account ใหม่ (ถ้า user/hostname เปลี่ยน)
    private func resaveIfNeeded() {
        guard didLoadPassword, !password.isEmpty else { return }
        savePassword(password, host)
    }
}

#Preview { SSHView() }
