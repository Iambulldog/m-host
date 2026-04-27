import SwiftUI

struct SFTPBrowserView: View {
    @State var session: SFTPSession
    @State private var showCredentialSheet: Bool = false
    /// kind ที่ใช้แสดงสำหรับ sheet ปัจจุบัน
    @State private var credentialKind: SFTPSession.Credential = .userPassword
    @State private var pathInput: String = ""
    /// status ของ download — ใช้แสดง progress/result ใน status bar
    @State private var downloadStatus: String?
    @State private var isDownloading: Bool = false

    init(host: SSHHost) {
        _session = State(initialValue: SFTPSession(host: host))
    }

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            // toolbar / breadcrumb
            HStack(spacing: 6) {
                Button { Task { await session.goUp() } } label: {
                    Image(systemName: "arrow.up")
                }
                .help("ขึ้นโฟลเดอร์ระดับบน")
                .disabled(!session.isConnected)

                Button { Task { await session.loadDirectory(session.currentPath) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .disabled(!session.isConnected)

                TextField("path", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        let p = pathInput.trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty {
                            Task { await session.loadDirectory(p) }
                        }
                    }

                if session.isConnected {
                    Button(role: .destructive) {
                        Task { await session.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "power")
                    }
                }
            }
            .padding(8)
            .onChange(of: session.currentPath) { _, newVal in
                pathInput = newVal
            }

            Divider()

            // status / connect prompt
            if !session.isConnected {
                connectScreen
            } else {
                fileTable
            }
        }
        .onAppear {
            pathInput = session.currentPath
            if !session.isConnected, case .idle = session.status {
                Task { await session.connect() }
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            CredentialPrompt(
                host: session.host,
                kind: credentialKind,
                lastError: session.lastError,
                onCancel: { showCredentialSheet = false },
                onSubmit: { secret, save in
                    showCredentialSheet = false
                    Task {
                        switch credentialKind {
                        case .keyPassphrase:
                            await session.connect(passphrase: secret, saveToKeychain: save)
                        case .userPassword:
                            await session.connect(password: secret, saveToKeychain: save)
                        case .none:
                            break
                        }
                    }
                }
            )
        }
        .onChange(of: session.needs) { _, needs in
            switch needs {
            case .keyPassphrase, .userPassword:
                credentialKind = needs
                showCredentialSheet = true
            case .none:
                break
            }
        }
    }

    // MARK: - sub views

    @ViewBuilder
    private var connectScreen: some View {
        VStack(spacing: 12) {
            Spacer()
            switch session.status {
            case .connecting:
                ProgressView("กำลังต่อ \(session.host.alias)...")
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("ต่อไม่ได้").font(.headline)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button {
                    Task { await session.connect() }
                } label: { Label("ลองใหม่", systemImage: "arrow.clockwise") }
                Button {
                    credentialKind = .userPassword
                    showCredentialSheet = true
                } label: { Label("ใช้ password แทน", systemImage: "key") }
            case .idle:
                Image(systemName: "server.rack")
                    .font(.largeTitle).foregroundStyle(.tint)
                Text("SFTP — \(session.host.alias)").font(.headline)
                Text("\(session.host.user)@\(session.host.hostName.isEmpty ? session.host.alias : session.host.hostName)")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await session.connect() }
                } label: {
                    Label("Connect", systemImage: "play.circle.fill")
                        .frame(width: 200)
                }
                .controlSize(.large)
            case .connected:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var fileTable: some View {
        VStack(spacing: 0) {
            Table(session.entries) {
                TableColumn("Name") { e in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: e))
                            .foregroundStyle(e.isDirectory ? Color.tint : .secondary)
                        Text(e.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        Task { await session.enter(e) }
                    }
                    .contextMenu {
                        if !e.isDirectory {
                            Button {
                                downloadEntry(e)
                            } label: { Label("Download…", systemImage: "arrow.down.circle") }
                        }
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(session.remotePath(of: e), forType: .string)
                        } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    }
                }
                TableColumn("Size") { e in
                    Text(e.displaySize)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 120)
                TableColumn("Modified") { e in
                    Text(e.displayDate)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 140, max: 180)
            }
            // download status bar
            if let status = downloadStatus {
                Divider()
                HStack(spacing: 6) {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { downloadStatus = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
    }

    private func downloadEntry(_ e: SFTPEntry) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = e.name
        panel.message = "บันทึก \(e.name) จาก \(session.host.alias)"
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isDownloading = true
        downloadStatus = "กำลังดาวน์โหลด \(e.name)…"
        Task {
            let result = await session.download(e, to: url)
            await MainActor.run {
                isDownloading = false
                switch result {
                case .success:
                    downloadStatus = "✓ บันทึก \(url.lastPathComponent) แล้ว (\(e.displaySize))"
                case .failure(let err):
                    downloadStatus = "✗ ดาวน์โหลดไม่สำเร็จ: \(err.localizedDescription)"
                }
            }
        }
    }

    private func icon(for e: SFTPEntry) -> String {
        if e.isDirectory { return "folder.fill" }
        if e.isSymlink { return "link" }
        return "doc"
    }
}

private struct CredentialPrompt: View {
    let host: SSHHost
    let kind: SFTPSession.Credential
    let lastError: String?
    var onCancel: () -> Void
    /// (secret, saveToKeychain)
    var onSubmit: (String, Bool) -> Void

    @State private var secret: String = ""
    @State private var saveToKeychain: Bool = true  // default ON เหมือน Termius

    private var title: String {
        switch kind {
        case .keyPassphrase:
            return "Passphrase ของ key"
        case .userPassword:
            return "รหัสผ่านสำหรับ \(host.user)@\(host.hostName.isEmpty ? host.alias : host.hostName)"
        case .none:
            return ""
        }
    }

    private var placeholder: String {
        switch kind {
        case .keyPassphrase: return "passphrase"
        case .userPassword: return "password"
        case .none: return ""
        }
    }

    private var subtitle: String? {
        switch kind {
        case .keyPassphrase:
            return "key มี passphrase — ใส่เพื่อปลดล็อค key"
        case .userPassword, .none:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let s = subtitle {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            if let err = lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            SecureField(placeholder, text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(secret, saveToKeychain) }
            Toggle("บันทึกใน Keychain", isOn: $saveToKeychain)
                .toggleStyle(.checkbox)
                .help("ครั้งหน้าจะ auto-fill ให้ — เก็บไว้ใน macOS Keychain ที่เข้ารหัสด้วย Secure Enclave")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Connect") { onSubmit(secret, saveToKeychain) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private extension Color {
    static var tint: Color { .accentColor }
}
