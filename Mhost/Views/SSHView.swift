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
                        onOpenSession: { sessionHost = manager.hosts[idx] }
                    )
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

    var body: some View {
        Form {
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
                LabeledContent("User") {
                    TextField("ubuntu", text: $host.user)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("22", text: $host.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("Identity") {
                LabeledContent("IdentityFile") {
                    HStack {
                        TextField("~/.ssh/id_rsa", text: $host.identityFile)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Browse...") {
                            if let p = onPickIdentity() { host.identityFile = p }
                        }
                    }
                }
            }

            Section("Default Path (cd หลัง connect)") {
                LabeledContent("Path") {
                    TextField("/var/www/html", text: $host.defaultPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("เก็บเป็น `# MhostDefaultPath:` ในไฟล์ ssh config — ปุ่ม Connect จะ ssh -t \\\"alias\\\" 'cd <path> && exec $SHELL -l' ให้อัตโนมัติ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !host.extraOptions.isEmpty {
                Section("Other options") {
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

            Section {
                Button {
                    onOpenSession()
                } label: {
                    Label("Open Session (Terminal + SFTP)", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(host.alias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
    }
}

#Preview { SSHView() }
