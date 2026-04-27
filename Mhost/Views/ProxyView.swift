import AppKit
import SwiftUI

struct ProxyView: View {
    @State private var server = ProxyServer()
    @State private var mkcert = MkcertManager()
    @State private var showLog = false
    @State private var portText: String = ""
    @State private var localInterfaces: [NetworkInterface] = []

    var body: some View {
        // shadowing trick — เปิดใช้ $-binding กับ @Observable class
        @Bindable var server = server
        @Bindable var mkcert = mkcert

        return VStack(spacing: 0) {
            // Header bar
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.tint)
                Text("Proxy Server")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(server.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(server.isRunning ? "Running on :\(server.settings.port)" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            Form {
                // — Server controls
                Section("Server") {
                    HStack {
                        Text("Port")
                            .frame(width: 80, alignment: .leading)
                        TextField("8888", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .disabled(server.isRunning)
                            .onSubmit { commitPort() }
                            .onAppear { portText = String(server.settings.port) }
                        Text("(default 8888)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        if server.isRunning {
                            Button(role: .destructive) { server.stop() } label: {
                                Label("Stop Proxy", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                commitPort()
                                server.start()
                            } label: {
                                Label("Start Proxy", systemImage: "play.circle.fill")
                            }
                        }
                        Spacer()
                        if let err = server.lastError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Text("ตั้ง System Settings → Network → Advanced → Proxies (HTTP / HTTPS) ให้ชี้มาที่ 127.0.0.1:\(server.settings.port) เพื่อให้ traffic ผ่าน proxy")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // — Local IPs (สำหรับให้ device อื่นใน LAN ชี้ proxy มา)
                Section {
                    if localInterfaces.isEmpty {
                        HStack {
                            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                            Text("ไม่พบ network interface ที่ active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(localInterfaces) { iface in
                            InterfaceRow(iface: iface, port: server.settings.port)
                        }
                    }
                } header: {
                    HStack {
                        Text("This Mac on the network")
                        Spacer()
                        Button { refreshInterfaces() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("รีเฟรชรายการ IP")
                    }
                } footer: {
                    Text("จาก device อื่นใน LAN ตั้ง proxy เป็น <IP ด้านบน>:\(server.settings.port) เพื่อให้ผ่าน proxy นี้")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // — mkcert CAROOT (สำหรับติดตั้ง rootCA)
                Section("Root CA (mkcert)") {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.purple)
                        if mkcert.mkcertInstalled {
                            if let root = mkcert.caRootPath {
                                Text(root)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } else {
                                Text("ไม่สามารถอ่าน CAROOT ได้").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("ยังไม่ได้ติดตั้ง mkcert — ติดตั้งจากแท็บ mkcert ก่อน")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { mkcert.revealCARootInFinder() }
                            label: { Image(systemName: "folder") }
                            .help("เปิดใน Finder")
                            .disabled(mkcert.caRootPath == nil)
                        Button { mkcert.copyCARootToPasteboard() }
                            label: { Image(systemName: "doc.on.doc") }
                            .help("คัดลอก path")
                            .disabled(mkcert.caRootPath == nil)
                    }
                    Text("ใช้ rootCA.pem ในโฟลเดอร์นี้ install ที่ device อื่น (เช่น มือถือใน LAN) เพื่อให้ device นั้นเชื่อใจ certificate ที่ proxy MITM ออกมา")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // — VHosts list
                Section("VHosts (intercept rules)") {
                    if server.settings.vhosts.isEmpty {
                        Text("ยังไม่มี vhost — กด \"Add VHost\" เพิ่มกฎใหม่")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($server.settings.vhosts) { $v in
                            let rowId = v.id
                            VHostRow(
                                v: $v,
                                onPickFolder: pickFolder,
                                onDelete: {
                                    server.settings.vhosts.removeAll { $0.id == rowId }
                                    server.saveSettings()
                                }
                            )
                            Divider()
                        }
                    }
                    Button {
                        server.settings.vhosts.append(
                            ProxyVHost(host: "myapp.local",
                                       kind: .forward,
                                       target: "http://127.0.0.1:3000")
                        )
                        server.saveSettings()
                    } label: {
                        Label("Add VHost", systemImage: "plus.circle")
                    }
                }
                // auto-save ทุกครั้งที่ vhosts เปลี่ยน — ไม่ต้องกด Save
                .onChange(of: server.settings.vhosts) { _, _ in
                    server.saveSettings()
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            // Log bar
            statusBar
        }
        .onAppear {
            mkcert.refreshInstallStatus()
            server.attach(mkcert: mkcert)
            portText = String(server.settings.port)
            refreshInterfaces()
        }
        .sheet(isPresented: $showLog) {
            ProxyLogSheet(lines: server.requestLog, isPresented: $showLog)
        }
    }

    private func commitPort() {
        if let p = UInt16(portText.trimmingCharacters(in: .whitespaces)), p > 0 {
            server.settings.port = p
            server.saveSettings()
        } else {
            portText = String(server.settings.port)
        }
    }

    private func refreshInterfaces() {
        localInterfaces = NetworkInterfaceProvider.current(includeIPv6: false)
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "เลือกโฟลเดอร์ที่จะ serve เป็น static"
        if panel.runModal() == .OK, let url = panel.url { return url.path }
        return nil
    }

    @ViewBuilder
    private var statusBar: some View {
        Divider()
        HStack(spacing: 8) {
            Circle().fill(server.isRunning ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(server.requestLog.last ?? "Ready")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !server.requestLog.isEmpty {
                Button { showLog = true } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.borderless)
                    .help("ดู log ทั้งหมด")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct ProxyLogSheet: View {
    let lines: [String]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Proxy log").font(.headline)
                Text("(\(lines.count) lines)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(lines.joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("คัดลอก log ทั้งหมด")
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            // เลื่อนได้ทั้งแนวตั้ง + แนวนอน — แต่ละบรรทัดไม่ wrap
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("(no log)")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .padding()
            }
            .background(Color.black.opacity(0.05))
        }
        .frame(minWidth: 700, idealWidth: 1000, minHeight: 400, idealHeight: 600)
    }
}

private struct InterfaceRow: View {
    let iface: NetworkInterface
    let port: UInt16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(iface.displayName).font(.system(.body))
                Text(iface.name).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(iface.ip)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(iface.ip):\(port)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("คัดลอก \(iface.ip):\(port)")
        }
    }

    private var icon: String {
        let n = iface.displayName.lowercased()
        if n.contains("wi-fi") || n.contains("wifi") || n.contains("airport") { return "wifi" }
        if n.contains("ethernet") || n.contains("usb") { return "cable.connector" }
        if n.contains("bluetooth") { return "bolt.horizontal" }
        if n.contains("vpn") || iface.name.hasPrefix("utun") || iface.name.hasPrefix("ppp") { return "lock.shield" }
        if iface.name.hasPrefix("bridge") { return "network" }
        return "network"
    }
}

private struct VHostRow: View {
    @Binding var v: ProxyVHost
    var onPickFolder: () -> String?
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $v.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("เปิด/ปิดกฎนี้")

                TextField("", text: $v.host, prompt: Text("myapp.local"))
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $v.kind) {
                    ForEach(ProxyVHostTargetKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("ลบ vhost นี้")
            }
            HStack(spacing: 8) {
                switch v.kind {
                case .forward:
                    TextField(
                        "",
                        text: $v.target,
                        prompt: Text("http://127.0.0.1:3000")
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                case .folder:
                    TextField(
                        "",
                        text: $v.target,
                        prompt: Text("/Users/me/project/public")
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    Button("Browse...") {
                        if let p = onPickFolder() { v.target = p }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview { ProxyView() }
