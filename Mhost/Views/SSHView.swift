import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SSHView: View {
    @State private var manager = SSHConfigManager()
    @State private var selection: UUID?
    @State private var editingHost: SSHHost? = nil

    // SessionTab: เก็บ session ที่เปิดในแท็บ
    struct SessionTab: Identifiable, Equatable {
        enum Kind { case terminal, sftp }
        let id: UUID = UUID()
        let host: SSHHost
        let kind: Kind
        var tabTitle: String { "\(host.alias) [\(kind == .terminal ? "Terminal" : "SFTP")]" }
        var tabIcon: String { kind == .terminal ? "terminal" : "folder" }
        // sessionKey: ใช้เช็คซ้ำ (host id + kind)
        var sessionKey: String { "\(host.id.uuidString)-\(kind == .terminal ? "t" : "s")" }
    }
    // --- เพิ่ม struct สำหรับจำ state ต่อ sessionKey ---
    struct SessionState {
        var password: String? = nil // สำหรับ SFTP (หรือ passphrase)
    }
    @State private var sessions: [SessionTab] = []
    // แยก selection ของ Terminal กับ SFTP — แต่ละ panel เก็บแท็บที่เลือกของตัวเอง
    @State private var selectedTerminalKey: String? = nil
    @State private var selectedSFTPKey: String? = nil
    // สัดส่วนความสูงของ SFTP panel เมื่อเปิดทั้งสอง kind พร้อมกัน (drag splitter ปรับได้)
    @State private var sftpFraction: CGFloat = 0.5
    @State private var sessionStates: [String: SessionState] = [:]
    @State private var sftpSessions: [String: SFTPSession] = [:] // เพิ่มสำหรับคง session SFTP
    @State private var terminalPasswordCache: [String: String] = [:]
    @State private var terminalPasswordLoadedAccounts: Set<String> = []
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                SSHViewLayout(
                    geometry: geometry,
                    editingHost: $editingHost,
                    manager: manager,
                    selection: $selection,
                    sessions: $sessions,
                    selectedTerminalKey: $selectedTerminalKey,
                    selectedSFTPKey: $selectedSFTPKey,
                    sftpFraction: $sftpFraction,
                    sftpSessions: $sftpSessions,
                    terminalPasswordCache: $terminalPasswordCache,
                    terminalPasswordLoadedAccounts: $terminalPasswordLoadedAccounts,
                    searchText: $searchText
                )
            }
            .navigationTitle("SSH Manager")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        let newHost = SSHHost(
                            id: UUID(),
                            alias: "New Host",
                            hostName: "",
                            user: "",
                            port: "22",
                            identityFile: "",
                            defaultPath: "",
                            extraOptions: []
                        )
                        manager.hosts.append(newHost)
                        manager.save()
                        selection = newHost.id
                        editingHost = newHost
                    }) {
                        Label("Add Host", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct SSHViewLayout: View {
    let geometry: GeometryProxy
    @Binding var editingHost: SSHHost?
    var manager: SSHConfigManager
    @Binding var selection: UUID?
    @Binding var sessions: [SSHView.SessionTab]
    @Binding var selectedTerminalKey: String?
    @Binding var selectedSFTPKey: String?
    @Binding var sftpFraction: CGFloat

    /// keyboard highlight index ใน filtered list (แยกจาก selection ที่ใช้กับ editor)
    @State private var highlightedIndex: Int? = nil
    @State private var draggedHostID: UUID? = nil
    @FocusState private var listFocused: Bool
    @Binding var sftpSessions: [String: SFTPSession]
    @Binding var terminalPasswordCache: [String: String]
    @Binding var terminalPasswordLoadedAccounts: Set<String>
    @Binding var searchText: String

    private var filteredHosts: [SSHHost] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manager.hosts
        }
        let q = searchText.lowercased()
        return manager.hosts.filter {
            $0.alias.lowercased().contains(q) ||
            $0.hostName.lowercased().contains(q) ||
            $0.user.lowercased().contains(q)
        }
    }

    private var canReorderHosts: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let safeWidth = geometry.size.width.isFinite && !geometry.size.width.isNaN && geometry.size.width > 0 ? geometry.size.width : 1
        let sidebarWidth = max(safeWidth * 0.25, 250)
        // editor ต้องกว้างพอให้ field กับ label แสดงครบ — บังคับขั้นต่ำ 340pt
        let rightbarWidth = max(safeWidth * 0.28, 340)
        let mainWidth = editingHost == nil
            ? max(safeWidth - sidebarWidth, 1)
            : max(safeWidth - sidebarWidth - rightbarWidth, 1)
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                Text("SSH Hosts")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                TextField("ค้นหา SSH host...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .onKeyPress(.downArrow) {
                        guard !filteredHosts.isEmpty else { return .handled }
                        highlightedIndex = min((highlightedIndex ?? -1) + 1, filteredHosts.count - 1)
                        listFocused = true
                        return .handled
                    }
                    .onKeyPress(.return) {
                        // Enter จาก search → connect อันแรกเลย
                        if let h = filteredHosts.first {
                            openSession(for: h, kind: .terminal)
                        }
                        return .handled
                    }
                    .onChange(of: searchText) { _, _ in highlightedIndex = nil }
                // List view — keyboard navigable
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(filteredHosts.enumerated()), id: \.element.id) { idx, h in
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(canReorderHosts ? .secondary : .tertiary)
                                    .help(canReorderHosts ? "ลากเพื่อเรียงลำดับ" : "ล้างคำค้นหาก่อนเรียงลำดับ")
                                    .padding(.horizontal, 2)
                                    .contentShape(Rectangle())
                                    .onDrag { dragProvider(for: h) }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.alias).font(.system(.body, design: .monospaced))
                                    if !h.hostName.isEmpty {
                                        Text("\(h.user.isEmpty ? "" : h.user + "@")\(h.hostName)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()

                                Button { openSession(for: h, kind: .terminal) } label: {
                                    Image(systemName: "terminal").foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain).help("เชื่อมต่อ Terminal")
                                Button { openSession(for: h, kind: .sftp) } label: {
                                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain).help("เชื่อมต่อ SFTP")
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .id(h.id)
                            .onTapGesture {
                                selection = h.id
                                editingHost = h
                                highlightedIndex = idx
                            }
                            .listRowBackground(
                                highlightedIndex == idx
                                    ? Color.accentColor.opacity(0.20)
                                    : (selection == h.id ? Color.accentColor.opacity(0.09) : Color.clear)
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: SSHHostReorderDropDelegate(
                                    targetHost: h,
                                    draggedHostID: $draggedHostID,
                                    canReorder: canReorderHosts,
                                    move: moveDraggedHost
                                )
                            )
                        }
                    }
                    .listStyle(.plain)
                    .focusable()
                    .focused($listFocused)
                    .onKeyPress(.upArrow) {
                        guard !filteredHosts.isEmpty else { return .handled }
                        let next = max(0, (highlightedIndex ?? 1) - 1)
                        highlightedIndex = next
                        proxy.scrollTo(filteredHosts[next].id, anchor: .center)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !filteredHosts.isEmpty else { return .handled }
                        let next = min(filteredHosts.count - 1, (highlightedIndex ?? -1) + 1)
                        highlightedIndex = next
                        proxy.scrollTo(filteredHosts[next].id, anchor: .center)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard let idx = highlightedIndex, idx < filteredHosts.count else { return .ignored }
                        openSession(for: filteredHosts[idx], kind: .terminal)
                        return .handled
                    }
                }
                .frame(minWidth: 220)
            }
            .padding(.vertical, 8)
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Main SFTP/Terminal — resizable, state-preserving
            GeometryReader { mainGeo in
                let totalH = max(mainGeo.size.height, 1)
                let hasSFTP = sessions.contains { $0.kind == .sftp }
                let hasTerminal = sessions.contains { $0.kind == .terminal }
                let bothOpen = hasSFTP && hasTerminal

                if !hasSFTP && !hasTerminal {
                    VStack {
                        Spacer()
                        Text("ยังไม่มี session — เลือก host แล้วกดปุ่ม terminal/folder ที่ sidebar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(width: mainGeo.size.width, height: totalH)
                } else {
                    let sftpH: CGFloat = bothOpen
                        ? max(120, min(totalH - 120, totalH * sftpFraction))
                        : (hasSFTP ? totalH : 0)
                    let splitterH: CGFloat = bothOpen ? 6 : 0

                    VStack(spacing: 0) {
                        SFTPSessionPanel(
                            sessions: sessions,
                            selectedKey: $selectedSFTPKey,
                            onClose: closeSession,
                            sftpSessions: $sftpSessions
                        )
                        .frame(height: sftpH)
                        .clipped()

                        PanelSplitter(fraction: $sftpFraction, totalHeight: totalH)
                            .frame(height: splitterH)
                            .opacity(bothOpen ? 1 : 0)
                            .allowsHitTesting(bothOpen)

                        TerminalSessionPanel(
                            sessions: sessions,
                            selectedKey: $selectedTerminalKey,
                            onClose: closeSession,
                            terminalPasswordCache: terminalPasswordCache
                        )
                        .frame(maxHeight: .infinity)
                        .clipped()
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(width: mainWidth)
            .frame(maxHeight: .infinity)
            
            // Right Editor Bar
            if let editing = editingHost {
                Divider()
                ZStack(alignment: .topTrailing) {
                    VStack {
                        HostEditor(
                            host: Binding(
                                get: { editing },
                                set: { newValue in
                                    if let idx = manager.hosts.firstIndex(where: { $0.id == newValue.id }) {
                                        manager.hosts[idx] = newValue
                                    }
                                    // sync editing state ด้วย เพื่อให้ค่าใน editor ตามทันค่าล่าสุด
                                    editingHost = newValue
                                }),
                            onPickIdentity: { manager.pickIdentityFile() },
                            onSave: { pw in
                                // เขียน ssh config ลงดิสก์
                                manager.save()
                                // เก็บ/ลบ password ใน Keychain
                                if let pw {
                                    manager.savePassword(pw, for: editing)
                                    let account = editing.keychainAccount
                                    terminalPasswordLoadedAccounts.insert(account)
                                    if pw.isEmpty {
                                        terminalPasswordCache.removeValue(forKey: account)
                                    } else {
                                        terminalPasswordCache[account] = pw
                                    }
                                }
                            },
                            loadPassword: { host in terminalPasswordCache[host.keychainAccount] },
                            savePassword: { pw, host in
                                manager.savePassword(pw, for: host)
                                let account = host.keychainAccount
                                terminalPasswordLoadedAccounts.insert(account)
                                if pw.isEmpty { terminalPasswordCache.removeValue(forKey: account) }
                                else { terminalPasswordCache[account] = pw }
                            },
                            forgetCredentials: { host in
                                manager.forgetCredentials(for: host)
                                terminalPasswordLoadedAccounts.insert(host.keychainAccount)
                                terminalPasswordCache.removeValue(forKey: host.keychainAccount)
                            }
                        )
                    }
                    .frame(width: rightbarWidth)
                    .frame(maxHeight: .infinity)
                    
                    Button(action: { editingHost = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .background(.bar)
            }
        }
    }

    // MARK: - Host Reordering

    private func dragProvider(for host: SSHHost) -> NSItemProvider {
        guard canReorderHosts else { return NSItemProvider() }
        draggedHostID = host.id
        return NSItemProvider(object: host.id.uuidString as NSString)
    }

    private func moveDraggedHost(_ draggedID: UUID, onto targetHost: SSHHost) {
        guard canReorderHosts,
              draggedID != targetHost.id,
              let fromIndex = manager.hosts.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = manager.hosts.firstIndex(where: { $0.id == targetHost.id }) else { return }

        let moved = manager.hosts.remove(at: fromIndex)
        let insertionIndex = min(targetIndex, manager.hosts.count)
        manager.hosts.insert(moved, at: insertionIndex)
        manager.save()
        selection = draggedID
        highlightedIndex = insertionIndex
    }

    // MARK: - Session Tab Logic
    private func openSession(for host: SSHHost, kind: SSHView.SessionTab.Kind) {
        let key = "\(host.id.uuidString)-\(kind == .terminal ? "t" : "s")"
        if let existingIndex = sessions.firstIndex(where: { $0.sessionKey == key }) {
            // host ในแท็บเป็น snapshot; อัปเดตทุกครั้งเพื่อให้ defaultPath/HostName/User ล่าสุดถูกใช้
            sessions[existingIndex] = SSHView.SessionTab(host: host, kind: kind)
        } else {
            sessions.append(SSHView.SessionTab(host: host, kind: kind))
        }
        if kind == .terminal {
            loadTerminalPasswordIfNeeded(for: host)
        }
        if kind == .sftp {
            let needsNew: Bool
            if let existing = sftpSessions[key] {
                if existing.host != host {
                    needsNew = true
                } else {
                    switch existing.status {
                    case .connecting, .connected: needsNew = false
                    case .idle, .failed: needsNew = true
                    }
                }
            } else {
                needsNew = true
            }
            if needsNew {
                if let existing = sftpSessions[key] {
                    Task { await existing.disconnect() }
                }
                sftpSessions[key] = SFTPSession(host: host)
            }
        }
        // เลือกแท็บใหม่ใน panel ที่ตรง kind — ไม่กระทบ selection ของอีก panel
        if kind == .terminal {
            selectedTerminalKey = key
        } else {
            selectedSFTPKey = key
        }
    }

    private func closeSession(_ tab: SSHView.SessionTab) {
        sessions.removeAll { $0.sessionKey == tab.sessionKey }
        if tab.kind == .sftp, let existing = sftpSessions.removeValue(forKey: tab.sessionKey) {
            Task { await existing.disconnect() }
        }
        if tab.kind == .terminal, selectedTerminalKey == tab.sessionKey {
            selectedTerminalKey = sessions.last(where: { $0.kind == .terminal })?.sessionKey
        } else if tab.kind == .sftp, selectedSFTPKey == tab.sessionKey {
            selectedSFTPKey = sessions.last(where: { $0.kind == .sftp })?.sessionKey
        }
    }

    private func loadTerminalPasswordIfNeeded(for host: SSHHost) {
        let account = host.keychainAccount
        guard !terminalPasswordLoadedAccounts.contains(account) else { return }
        terminalPasswordLoadedAccounts.insert(account)
        if let password = manager.savedPassword(for: host), !password.isEmpty {
            terminalPasswordCache[account] = password
        } else {
            terminalPasswordCache.removeValue(forKey: account)
        }
    }
}
// --- END SSHView ---

private struct SSHHostReorderDropDelegate: DropDelegate {
    let targetHost: SSHHost
    @Binding var draggedHostID: UUID?
    let canReorder: Bool
    let move: (UUID, SSHHost) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        canReorder && draggedHostID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canReorder ? .move : .cancel)
    }

    func dropEntered(info: DropInfo) {
        guard canReorder,
              let draggedHostID,
              draggedHostID != targetHost.id else { return }
        move(draggedHostID, targetHost)
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = canReorder && draggedHostID != nil
        draggedHostID = nil
        return didDrop
    }
}

private struct HostEditor: View {
    @Binding var host: SSHHost
    var onPickIdentity: () -> String?
    /// บันทึก host เข้า ssh config + เก็บ password ลง Keychain
    var onSave: (_ password: String?) -> Void
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
    @State private var saveFlash: Bool = false
    @State private var passwordEdited: Bool = false

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // เว้นที่ให้ปุ่ม X ที่มุมขวาบน
                Spacer().frame(height: 24)

                // — HOST
                sectionHeader("Host")
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Alias")
                    TextField("เช่น pangpang-1", text: $host.alias)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()

                    fieldLabel("HostName")
                    TextField("192.168.1.10 หรือ example.com", text: $host.hostName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()

                    fieldLabel("Port")
                    TextField("22", text: $host.port)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 120, alignment: .leading)
                }

                Divider()

                // — CREDENTIALS
                sectionHeader("Credentials")
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Username")
                    TextField("ubuntu / root", text: $host.user)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()

                    fieldLabel("Password")
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("ว่าง = ใช้ key อย่างเดียว", text: $password)
                            } else {
                                SecureField("ว่าง = ใช้ key อย่างเดียว", text: $password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onChange(of: password) { _, _ in
                            passwordEdited = true
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showPassword ? "ซ่อน password" : "แสดง password")
                    }

                    fieldLabel("SSH Key")
                    TextField("~/.ssh/id_ed25519 (optional)", text: $host.identityFile)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .labelsHidden()
                        .truncationMode(.middle)
                    HStack {
                        Button("Browse...") {
                            if let p = onPickIdentity() { host.identityFile = p }
                        }
                        .font(.caption)
                        Spacer()
                    }

                    Text("Password เก็บใน macOS Keychain (เข้ารหัสกับ Secure Enclave — ไม่เคยเขียนลง ssh config) — auto-fill ตอน Connect")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // — DEFAULT PATH
                sectionHeader("Default Path")
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("Path")
                    TextField("/var/www/html", text: $host.defaultPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()

                    Text("Connect แล้ว auto cd ไป path นี้ — เก็บเป็น `# MhostDefaultPath:` ใน ssh config")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // — ADVANCED (Other options) — collapsed by default
                if !host.extraOptions.isEmpty {
                    Divider()
                    DisclosureGroup("Other options (\(host.extraOptions.count))",
                                    isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(host.extraOptions.enumerated()), id: \.offset) { _, opt in
                                HStack {
                                    Text(opt.key).font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text(opt.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Divider()

                // — ACTIONS
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: {
                        if !password.isEmpty { savePassword("", host) }
                        password = ""
                        forgetCredentials(host)
                    }) {
                        Label("Forget Password/Key", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: {
                         onSave(passwordEdited ? password : nil)
                        // flash icon เพื่อ feedback ว่ากดสำเร็จ
                        saveFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            saveFlash = false
                        }
                    }) {
                        Label(saveFlash ? "Saved" : "Save",
                              systemImage: saveFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // โหลด password จาก Keychain (ถ้ามี)
            if !didLoadPassword {
                didLoadPassword = true
                DispatchQueue.main.async {
                    if let pw = loadPassword(host) {
                        password = pw
                         passwordEdited = false
                    }
                }
            }
        }
    }
}
// --- END HostEditor ---

// MARK: - SSH Host Grid Item View
private struct SSHHostGridItemView: View {
    let host: SSHHost
    let isSelected: Bool
    let canReorder: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDragProvider: () -> NSItemProvider
    let onOpenTerminal: () -> Void
    let onOpenSFTP: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(canReorder ? .secondary : .tertiary)
                .help(canReorder ? "ลากเพื่อเรียงลำดับ" : "ล้างคำค้นหาก่อนเรียงลำดับ")
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .onDrag(onDragProvider)

            VStack(alignment: .leading) {
                Text(host.alias).font(.system(.body, design: .monospaced))
                if !host.hostName.isEmpty {
                    Text("\(host.user.isEmpty ? "" : host.user + "@")\(host.hostName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onOpenTerminal) {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("เชื่อมต่อ Terminal")
            Button(action: onOpenSFTP) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("เชื่อมต่อ SFTP")
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .onTapGesture {
            onSelect()
            onEdit()
        }
    }
}

// MARK: - Tab Button (แชร์ระหว่าง terminal panel กับ sftp panel)
private struct SessionTabButton: View {
    let tab: SSHView.SessionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tab.tabIcon)
                .font(.system(size: 12, weight: .medium))
            Text(tab.host.alias)
                .font(.caption)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.trailing, 2)
    }
}

// MARK: - แถบ splitter ลากปรับขนาด panel
private struct PanelSplitter: View {
    @Binding var fraction: CGFloat
    let totalHeight: CGFloat

    // freeze ค่าเริ่มต้นเมื่อเริ่ม drag — ป้องกัน feedback loop เมื่อ layout resize ระหว่างลาก
    @State private var dragStart: (fraction: CGFloat, height: CGFloat)? = nil
    @State private var hovering: Bool = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovering ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.18))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHover in
            hovering = isHover
            if isHover { NSCursor.resizeUpDown.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // จำค่าแรก ณ เริ่ม gesture — ไม่อัปเดตระหว่างลาก
                    if dragStart == nil {
                        dragStart = (fraction, totalHeight)
                    }
                    let start = dragStart!
                    let delta = value.translation.height / max(start.height, 1)
                    fraction = max(0.15, min(0.85, start.fraction + delta))
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

// MARK: - SFTP Panel (แท็บคงสภาพ)
private struct SFTPSessionPanel: View {
    let sessions: [SSHView.SessionTab]
    @Binding var selectedKey: String?
    let onClose: (SSHView.SessionTab) -> Void
    @Binding var sftpSessions: [String: SFTPSession]

    var body: some View {
        let myTabs = sessions.filter { $0.kind == .sftp }
        let activeKey: String? = {
            if let s = selectedKey, myTabs.contains(where: { $0.sessionKey == s }) { return s }
            return myTabs.last?.sessionKey
        }()
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text("SFTP")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .foregroundStyle(.secondary)
                    ForEach(myTabs, id: \.sessionKey) { tab in
                        SessionTabButton(
                            tab: tab,
                            isSelected: tab.sessionKey == activeKey,
                            onSelect: { selectedKey = tab.sessionKey },
                            onClose: { onClose(tab) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 36)
            Divider()
            // ZStack วาด session ทุกตัว — แสดงเฉพาะตัวที่ active ผ่าน opacity
            // เก็บ ForEach key ด้วย sessionKey เพื่อให้ SwiftUI คง view เดิมไม่ recreate
            ZStack {
                if myTabs.isEmpty {
                    Text("ยังไม่มี SFTP session")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(myTabs, id: \.sessionKey) { tab in
                        if let session = sftpSessions[tab.sessionKey] {
                            SFTPBrowserView(session: session)
                                .id(ObjectIdentifier(session))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(tab.sessionKey == activeKey ? 1 : 0)
                                .allowsHitTesting(tab.sessionKey == activeKey)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
    }
}

// MARK: - Terminal Panel (แท็บคงสภาพ)
private struct TerminalSessionPanel: View {
    let sessions: [SSHView.SessionTab]
    @Binding var selectedKey: String?
    let onClose: (SSHView.SessionTab) -> Void
    let terminalPasswordCache: [String: String]

    var body: some View {
        let myTabs = sessions.filter { $0.kind == .terminal }
        let activeKey: String? = {
            if let s = selectedKey, myTabs.contains(where: { $0.sessionKey == s }) { return s }
            return myTabs.last?.sessionKey
        }()
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text("Terminal")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .foregroundStyle(.secondary)
                    ForEach(myTabs, id: \.sessionKey) { tab in
                        SessionTabButton(
                            tab: tab,
                            isSelected: tab.sessionKey == activeKey,
                            onSelect: { selectedKey = tab.sessionKey },
                            onClose: { onClose(tab) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 36)
            Divider()
            ZStack {
                if myTabs.isEmpty {
                    Text("ยังไม่มี Terminal session")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(myTabs, id: \.sessionKey) { tab in
                         SSHTerminalView(
                             host: tab.host,
                             isActive: tab.sessionKey == activeKey,
                             password: terminalPasswordCache[tab.host.keychainAccount]
                         )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(tab.sessionKey == activeKey ? 1 : 0)
                            .allowsHitTesting(tab.sessionKey == activeKey)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
    }
}
