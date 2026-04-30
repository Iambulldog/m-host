import SwiftUI

/// container view สำหรับ session ของ host หนึ่งตัว — มี tab Terminal / SFTP
/// เปิดผ่าน `.sheet(item:)` หรือ window เดี่ยว
struct SSHSessionView: View {
    let host: SSHHost
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case terminal, sftp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .sftp: return "SFTP"
            }
        }
        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .sftp: return "folder"
            }
        }
    }
    @State private var tab: Tab = .terminal
    @StateObject private var sftpSession: SFTPSession

    init(host: SSHHost, onClose: @escaping () -> Void) {
        self.host = host
        self.onClose = onClose
        _sftpSession = StateObject(wrappedValue: SFTPSession(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.alias).font(.headline)
                    Text("\(host.user.isEmpty ? "" : host.user + "@")\(host.hostName.isEmpty ? host.alias : host.hostName)\(host.port.isEmpty ? "" : ":" + host.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Label(t.label, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("ปิด session")
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(10)

            Divider()

            // content
            Group {
                switch tab {
                case .terminal:
                    SSHTerminalView(host: host)
                case .sftp:
                    SFTPBrowserView(session: sftpSession)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, idealWidth: 1000, minHeight: 600, idealHeight: 700)
    }
}
