import SwiftUI

struct SFTPBrowserView: View {
    @State var session: SFTPSession
    @State private var passwordInput: String = ""
    @State private var showPasswordSheet: Bool = false
    @State private var pathInput: String = ""

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
        .sheet(isPresented: $showPasswordSheet) {
            PasswordPrompt(
                host: session.host,
                lastError: session.lastError,
                onCancel: { showPasswordSheet = false },
                onSubmit: { pw in
                    showPasswordSheet = false
                    passwordInput = pw
                    Task { await session.connect(password: pw) }
                }
            )
        }
        .onChange(of: session.needsPassword) { _, needs in
            if needs { showPasswordSheet = true }
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
                } label: { Label("ลองใหม่ (key auth)", systemImage: "arrow.clockwise") }
                Button {
                    showPasswordSheet = true
                } label: { Label("ใช้ password", systemImage: "key") }
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
    }

    private func icon(for e: SFTPEntry) -> String {
        if e.isDirectory { return "folder.fill" }
        if e.isSymlink { return "link" }
        return "doc"
    }
}

private struct PasswordPrompt: View {
    let host: SSHHost
    let lastError: String?
    var onCancel: () -> Void
    var onSubmit: (String) -> Void

    @State private var password: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("รหัสผ่านสำหรับ \(host.user)@\(host.hostName.isEmpty ? host.alias : host.hostName)")
                .font(.headline)
            if let err = lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            SecureField("password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(password) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Connect") { onSubmit(password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private extension Color {
    static var tint: Color { .accentColor }
}
