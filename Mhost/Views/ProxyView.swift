import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreWLAN

struct ProxyView: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case proxy = "Proxy"
        case vhosts = "VHosts"
        case settings = "Settings"
        var id: String { rawValue }
    }

    @State private var selectedSidebar: SidebarItem? = .proxy
    @State private var selectedVHostId: UUID? = nil
    @State private var server = ProxyServer()
    @State private var mkcert = MkcertManager()
    @State private var showLog = false
    @State private var portText: String = ""
    @State private var localInterfaces: [NetworkInterface] = []
    @State private var logPanelHeight: CGFloat = 120
    @State private var isResizingLogPanel = false
    @State private var dragStartHeight: CGFloat? = nil

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(SidebarItem.allCases, selection: $selectedSidebar) { item in
                Label(item.rawValue, systemImage: sidebarIcon(for: item))
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Proxy")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selectedSidebar {
                    case .proxy:
                        ProxyServerSection(server: $server, portText: $portText, localInterfaces: $localInterfaces, refreshInterfaces: refreshInterfaces)
                    case .vhosts:
                        VHostListSection(
                            vhosts: $server.settings.vhosts,
                            onPickFolder: pickFolder,
                            onDelete: { rowId in
                                server.settings.vhosts.removeAll { $0.id == rowId }
                                server.saveSettings()
                            },
                            onPickCert: { allowedTypes in openFilePanel(allowedTypes: allowedTypes) },
                            onPickKey: { allowedTypes in openFilePanel(allowedTypes: allowedTypes) }
                        )
                    case .settings:
                        SettingsSection(mkcert: $mkcert)
                    case .none:
                        ContentUnavailableView("Select an item in the sidebar", systemImage: "arrow.triangle.swap")
                    }
                }
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Color.gray.opacity(isResizingLogPanel ? 0.4 : 0.15))
                    .frame(height: 6)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartHeight == nil {
                                dragStartHeight = logPanelHeight
                            }
                            isResizingLogPanel = true
                            let drag = dragStartHeight! - value.translation.height
                            let minHeight: CGFloat = 80
                            let maxHeight: CGFloat = 300
                            logPanelHeight = min(max(drag, minHeight), maxHeight)
                        }
                        .onEnded { _ in
                            isResizingLogPanel = false
                            dragStartHeight = nil
                        }
                    )
                    .cornerRadius(3)
                    .padding(.horizontal, 32)
                ProxyLogPanel(lines: server.requestLog, height: logPanelHeight, onClear: { server.requestLog.removeAll() })
                    .frame(height: logPanelHeight)
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: -2)
            }
            .onAppear {
                mkcert.refreshInstallStatus()
                server.attach(mkcert: mkcert)
                portText = String(server.settings.port)
                refreshInterfaces()
            }
        }
    }

    // Helper for file panel (for right bar editable form)
    private func openFilePanel(allowedTypes: [String]) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = allowedTypes.compactMap { UTType(filenameExtension: $0) ?? .data }
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url { return url.path }
        return nil
    }

    private func sidebarIcon(for item: SidebarItem) -> String {
        switch item {
        case .proxy: return "arrow.triangle.swap"
        case .vhosts: return "list.bullet.rectangle"
        case .settings: return "gearshape"
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
}

struct ProxyLogPanel: View {
    let lines: [String]
    let height: CGFloat
    var onClear: (() -> Void)? = nil
    @State private var filterText: String = ""
    @State private var copied: Bool = false

    var filteredLines: [String] {
        if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lines
        } else {
            return lines.filter { $0.localizedCaseInsensitiveContains(filterText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .foregroundColor(.accentColor)
                Text("Proxy Log")
                    .font(.caption.bold())
                Spacer()
                TextField("Filter log...", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(minWidth: 120, maxWidth: 180)
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(filteredLines.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Label(copied ? "Copied!" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if let onClear {
                    Button(action: { onClear() }) {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.red)
                    .help("Clear all log lines")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLines.indices, id: \.self) { idx in
                            let line = filteredLines[idx]
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                                .foregroundColor(
                                    line.localizedCaseInsensitiveContains("error") ? .red :
                                    (line.localizedCaseInsensitiveContains("warn") ? .orange : .primary)
                                )
                                .padding(.vertical, 1.5)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(line.localizedCaseInsensitiveContains("error") ? Color.red.opacity(0.08) : Color.clear)
                                )
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                .background(Color(.windowBackgroundColor).opacity(0.98))
                .cornerRadius(10)
                .onChange(of: filteredLines.count) { _, _ in
                    if let last = filteredLines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = filteredLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProxyServerSection: View {
    @Binding var server: ProxyServer
    @Binding var portText: String
    @Binding var localInterfaces: [NetworkInterface]
    var refreshInterfaces: () -> Void

    var body: some View {
        let debugSSID = currentWiFiSSID
        // DEBUG: Print SSID value (move outside ViewBuilder)
        DispatchQueue.main.async {
            print("[ProxyServerSection] currentWiFiSSID=\(String(describing: debugSSID))")
        }
        return Form {
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
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button {
                            commitPort()
                            server.start()
                        } label: {
                            Label("Start Proxy", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
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
                let ssid = currentWiFiSSID
                // Show Wi-Fi SSID if available
                if let ssid = ssid {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .foregroundColor(.accentColor)
                        Text("Wi-Fi: ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ssid)
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(6)
                        Spacer()
                    }
                }
                if localInterfaces.isEmpty {
                    HStack {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text("ไม่พบ network interface ที่ active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(localInterfaces) { iface in
                        if iface.displayName.lowercased().contains("wi-fi") || iface.displayName.lowercased().contains("wifi") || iface.displayName.lowercased().contains("airport") {
                            InterfaceRow(iface: iface, port: server.settings.port, externalSSID: ssid)
                        } else {
                            InterfaceRow(iface: iface, port: server.settings.port)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("This Mac on the network")
                    if let ssid = currentWiFiSSID {
                        Image(systemName: "wifi").foregroundColor(.accentColor)
                        Text(ssid)
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(6)
                    }
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
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    // Computed property to get current Wi-Fi SSID
    private var currentWiFiSSID: String? {
        if let iface = CWWiFiClient.shared().interface(), let ssid = iface.ssid() {
            return ssid
        }
        return nil
    }

    private func commitPort() {
        if let p = UInt16(portText.trimmingCharacters(in: .whitespaces)), p > 0 {
            server.settings.port = p
            server.saveSettings()
        } else {
            portText = String(server.settings.port)
        }
    }
}

private struct VHostListSection: View {
    @Binding var vhosts: [ProxyVHost]
    var onPickFolder: () -> String?
    var onDelete: (UUID) -> Void
    var onPickCert: ([String]) -> String?
    var onPickKey: ([String]) -> String?
    @State private var searchText: String = ""
    @State private var selectedIds: Set<UUID> = []

    var filteredVhosts: [Binding<ProxyVHost>] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return $vhosts.indices.map { $vhosts[$0] }
        } else {
            return $vhosts.filter { $0.wrappedValue.host.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VHosts (intercept rules)")
                    .font(.headline)
                Spacer()
                Button {
                    let new = ProxyVHost(host: "myapp.local", kind: .forward, target: "http://127.0.0.1:3000")
                    vhosts.append(new)
                    selectedIds = [new.id]
                } label: {
                    Label("Add VHost", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            HStack {
                TextField("Search VHost...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(minWidth: 120, maxWidth: 200)
                Spacer()
                if !selectedIds.isEmpty {
                    Button(action: { for id in selectedIds { onDelete(id) }; selectedIds.removeAll() }) {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .help("ลบ vhost ที่เลือกทั้งหมด")
                    Button(action: { for id in selectedIds { if let idx = vhosts.firstIndex(where: { $0.id == id }) { vhosts[idx].enabled = true } } }) {
                        Label("Enable", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("เปิด vhost ที่เลือกทั้งหมด")
                    Button(action: { for id in selectedIds { if let idx = vhosts.firstIndex(where: { $0.id == id }) { vhosts[idx].enabled = false } } }) {
                        Label("Disable", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("ปิด vhost ที่เลือกทั้งหมด")
                }
            }
            if filteredVhosts.isEmpty {
                Text("ไม่พบ vhost ที่ตรงกับคำค้น หรือยังไม่มี vhost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Table(filteredVhosts, selection: $selectedIds) {
                    TableColumn("") { v in
                        Image(systemName: selectedIds.contains(v.id) ? "checkmark.square.fill" : "square")
                            .onTapGesture {
                                if selectedIds.contains(v.id) { selectedIds.remove(v.id) } else { selectedIds.insert(v.id) }
                            }
                            .foregroundColor(.accentColor)
                    }
                    TableColumn("Host") { v in
                        TextField("host", text: v.host)
                            .textFieldStyle(.roundedBorder)
                    }
                    TableColumn("Type") { v in
                        Picker("Type", selection: v.kind) {
                            ForEach(ProxyVHostTargetKind.allCases) { k in
                                Text(k.label).tag(k)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    TableColumn("Target") { v in
                        TextField(v.kind.wrappedValue == .forward ? "http://127.0.0.1:3000" : "/Users/me/project/public", text: v.target)
                            .textFieldStyle(.roundedBorder)
                    }
                    TableColumn("Cert") { v in
                        HStack(spacing: 4) {
                            TextField(".crt/.pem", text: Binding(
                                get: { v.certPath.wrappedValue ?? "" },
                                set: { v.certPath.wrappedValue = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                if let path = onPickCert(["crt", "pem"]) {
                                    v.certPath.wrappedValue = path
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("เลือกไฟล์ cert")
                        }
                    }
                    TableColumn("Key") { v in
                        HStack(spacing: 4) {
                            TextField(".key", text: Binding(
                                get: { v.keyPath.wrappedValue ?? "" },
                                set: { v.keyPath.wrappedValue = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                if let path = onPickKey(["key"]) {
                                    v.keyPath.wrappedValue = path
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("เลือกไฟล์ key")
                        }
                    }
                    TableColumn("Enabled") { v in
                        Toggle("", isOn: v.enabled)
                            .labelsHidden()
                    }
                }
                .frame(minHeight: 180, maxHeight: 340)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsSection: View {
    @Binding var mkcert: MkcertManager

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }
}

private struct InterfaceRow: View {
    let iface: NetworkInterface
    let port: UInt16
    let externalSSID: String?
    @State private var ssid: String? = nil

    init(iface: NetworkInterface, port: UInt16, externalSSID: String? = nil) {
        self.iface = iface
        self.port = port
        self.externalSSID = externalSSID
    }

    var body: some View {
        // DEBUG: Print SSID value for this row (move outside ViewBuilder)
        if isWiFi {
            DispatchQueue.main.async {
                print("[InterfaceRow] iface=\(iface.displayName) externalSSID=\(String(describing: externalSSID)) ssid=\(String(describing: ssid))")
            }
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint)
            if isWiFi, let displaySSID = (externalSSID ?? ssid) {
                Text("\(displaySSID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(4)
            }
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
        .onAppear {
            if isWiFi && externalSSID == nil {
                ssid = fetchWiFiSSID()
            }
        }
    }

    private var isWiFi: Bool {
        let n = iface.displayName.lowercased()
        return n.contains("wi-fi") || n.contains("wifi") || n.contains("airport")
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

    // Note: Fetching SSID requires Location Services permission on macOS. If not granted, this will return nil.
    private func fetchWiFiSSID() -> String? {
        if let iface = CWWiFiClient.shared().interface(), let ssid = iface.ssid() {
            return ssid
        }
        return nil
    }
}

#Preview { ProxyView() }
