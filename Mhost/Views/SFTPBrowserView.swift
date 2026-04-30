import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileMonitor

/// watches a file for write events — used to detect saves from external editors
final class FileMonitor: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.onChange() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil }
}

// MARK: - QL bridge

/// thin singleton that bridges SwiftUI to NSQuickLookPanel
private final class QLController: NSObject, QLPreviewPanelDataSource {
    static let shared = QLController()
    var previewURL: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL != nil ? 1 : 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    func show(url: URL) {
        previewURL = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        if panel.isVisible { panel.reloadData() }
        else { panel.makeKeyAndOrderFront(nil) }
    }
}

// MARK: - SFTPBrowserView

struct SFTPBrowserView: View {
    @ObservedObject var session: SFTPSession

    @State private var showCredentialSheet = false
    @State private var credentialKind: SFTPSession.Credential = .userPassword
    @State private var pathInput = ""

    // download
    @State private var downloadStatus: String?
    @State private var isDownloading = false

    // upload / drop
    @State private var isDroppingOver = false
    @State private var uploadStatus: String?
    @State private var isUploading = false

    // preview + monitor
    @State private var previewEntry: SFTPEntry? = nil
    @State private var previewTempURL: URL? = nil
    @State private var previewDirty = false
    @State private var fileMonitor: FileMonitor? = nil

    // hover highlight
    @State private var hoveredEntryID: SFTPEntry.ID? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !session.isConnected {
                connectScreen
            } else {
                fileArea
            }
        }
        .onAppear {
            pathInput = session.currentPath
            if !session.isConnected, case .idle = session.status {
                Task { await session.connect() }
            }
        }
        .onChange(of: session.currentPath) { _, v in pathInput = v }
        .onChange(of: session.needs) { _, needs in
            switch needs {
            case .keyPassphrase, .userPassword:
                credentialKind = needs
                showCredentialSheet = true
            case .none: break
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            CredentialPrompt(host: session.host, kind: credentialKind,
                             lastError: session.lastError,
                             onCancel: { showCredentialSheet = false },
                             onSubmit: { secret, save in
                showCredentialSheet = false
                Task {
                    switch credentialKind {
                    case .keyPassphrase: await session.connect(passphrase: secret, saveToKeychain: save)
                    case .userPassword:  await session.connect(password: secret, saveToKeychain: save)
                    case .none: break
                    }
                }
            })
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { Task { await session.goUp() } } label: {
                Image(systemName: "arrow.up")
            }
            .help("ขึ้นโฟลเดอร์ระดับบน").disabled(!session.isConnected)

            Button { Task { await session.loadDirectory(session.currentPath) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload").disabled(!session.isConnected)

            TextField("path", text: $pathInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit {
                    let p = pathInput.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty { Task { await session.loadDirectory(p) } }
                }

            if session.isConnected {
                Button(role: .destructive) { Task { await session.disconnect() } } label: {
                    Label("Disconnect", systemImage: "power")
                }
            }
        }
        .padding(8)
    }

    // MARK: - Connect screen

    private var connectScreen: some View {
        VStack(spacing: 12) {
            Spacer()
            switch session.status {
            case .connecting:
                ProgressView("กำลังต่อ \(session.host.alias)...")
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text("ต่อไม่ได้").font(.headline)
                Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                Button { Task { await session.connect() } } label: { Label("ลองใหม่", systemImage: "arrow.clockwise") }
                Button { credentialKind = .userPassword; showCredentialSheet = true } label: {
                    Label("ใช้ password แทน", systemImage: "key")
                }
            case .idle:
                Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.tint)
                Text("SFTP — \(session.host.alias)").font(.headline)
                Text("\(session.host.user)@\(session.host.hostName.isEmpty ? session.host.alias : session.host.hostName)")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await session.connect() } } label: {
                    Label("Connect", systemImage: "play.circle.fill").frame(width: 200)
                }.controlSize(.large)
            case .connected:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File area (table + status bars)

    private var fileArea: some View {
        VStack(spacing: 0) {
            if session.entries.isEmpty, let e = session.lastError, !e.isEmpty {
                emptyErrorView(e)
            } else {
                fileTable
            }

            // preview dirty banner
            if previewDirty, let entry = previewEntry {
                dirtyBanner(entry)
            }

            // upload status bar
            if let s = uploadStatus {
                statusBar(text: s, spinning: isUploading, tint: .blue) { uploadStatus = nil }
            }

            // download status bar
            if let s = downloadStatus {
                statusBar(text: s, spinning: isDownloading, tint: .green) { downloadStatus = nil }
            }
        }
    }

    // MARK: - File table

    // column widths (fixed — aligned between header and rows)
    private let colSize: CGFloat = 80
    private let colDate: CGFloat = 140

    private var fileTable: some View {
        VStack(spacing: 0) {
            // column headers
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Size")
                    .frame(width: colSize, alignment: .trailing)
                Text("Modified")
                    .frame(width: colDate, alignment: .trailing)
                    .padding(.trailing, 16)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)

            Divider()

            List {
                ForEach(session.entries) { e in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: e))
                            .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        Text(e.name)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(e.displaySize)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: colSize, alignment: .trailing)
                        Text(e.displayDate)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: colDate, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Task { await session.enter(e) } }
                    .contextMenu { rowMenu(e) }
                    .onDrag { dragProvider(for: e) }
                    .onHover { hoveredEntryID = $0 ? e.id : nil }
                    .listRowBackground(
                        hoveredEntryID == e.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                }
            }
            .listStyle(.plain)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDroppingOver) { providers in
                dropFiles(providers)
                return true
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDroppingOver ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowMenu(_ e: SFTPEntry) -> some View {
        if !e.isDirectory {
            Button { openPreview(e, useQL: true) } label: {
                Label("Quick Look", systemImage: "eye")
            }
            Button { openPreview(e, useQL: false) } label: {
                Label("เปิดด้วยแอพ...", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button { downloadEntry(e) } label: {
                Label("Download…", systemImage: "arrow.down.circle")
            }
        }
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(session.remotePath(of: e), forType: .string)
        } label: { Label("Copy path", systemImage: "doc.on.doc") }
    }

    // MARK: - Drag OUT

    private func dragProvider(for e: SFTPEntry) -> NSItemProvider {
        guard !e.isDirectory else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = e.name
        // register async file delivery — called when drop target accepts
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { [session] completion in
            Task { @MainActor in
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mhost-drag-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let dst = tmp.appendingPathComponent(e.name)
                switch await session.download(e, to: dst) {
                case .success: completion(dst, false, nil)
                case .failure(let err): completion(nil, false, err)
                }
            }
            return Progress(totalUnitCount: -1)
        }
        return provider
    }

    // MARK: - Drop IN

    private func dropFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _ in
                guard let url else { return }
                // copy to temp so we have access after security scope closes
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mhost-drop-\(UUID().uuidString)")
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.createDirectory(
                    at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: url, to: tmp)
                let remotePath = session.currentPath + "/" + url.lastPathComponent
                Task { @MainActor in await uploadFile(localURL: tmp, to: remotePath) }
            }
        }
    }

    // MARK: - Download

    private func downloadEntry(_ e: SFTPEntry) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = e.name
        panel.message = "บันทึก \(e.name) จาก \(session.host.alias)"
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isDownloading = true
        downloadStatus = "กำลัง download \(e.name)…"
        Task {
            switch await session.download(e, to: url) {
            case .success:
                downloadStatus = "✓ \(url.lastPathComponent) (\(e.displaySize))"
            case .failure(let err):
                downloadStatus = "✗ \(err.localizedDescription)"
            }
            isDownloading = false
        }
    }

    // MARK: - Upload

    private func uploadFile(localURL: URL, to remotePath: String) async {
        isUploading = true
        uploadStatus = "กำลัง upload \(localURL.lastPathComponent)…"
        switch await session.upload(localURL: localURL, to: remotePath) {
        case .success:
            uploadStatus = "✓ upload \(localURL.lastPathComponent) สำเร็จ"
            await session.loadDirectory(session.currentPath)
        case .failure(let err):
            uploadStatus = "✗ upload ไม่สำเร็จ: \(err.localizedDescription)"
        }
        isUploading = false
    }

    // MARK: - Preview

    private func openPreview(_ entry: SFTPEntry, useQL: Bool) {
        // stop any existing monitor
        fileMonitor?.stop()
        previewDirty = false

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhost-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dst = tmp.appendingPathComponent(entry.name)

        downloadStatus = "กำลังโหลด \(entry.name) เพื่อพรีวิว…"
        isDownloading = true
        Task {
            switch await session.download(entry, to: dst) {
            case .success:
                downloadStatus = nil
                isDownloading = false
                previewEntry = entry
                previewTempURL = dst
                startMonitor(dst)
                if useQL {
                    QLController.shared.show(url: dst)
                } else {
                    pickAppAndOpen(url: dst)
                }
            case .failure(let err):
                downloadStatus = "✗ โหลดไม่ได้: \(err.localizedDescription)"
                isDownloading = false
            }
        }
    }

    /// open an NSOpenPanel to pick an app, then open url with it
    private func pickAppAndOpen(url: URL) {
        let panel = NSOpenPanel()
        panel.title = "เลือกแอพ"
        panel.message = "เลือกแอพที่ต้องการเปิด \(url.lastPathComponent)"
        panel.prompt = "เปิด"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.applicationBundle]
        if panel.runModal() == .OK, let appURL = panel.url {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
        } else {
            // fallback: default app
            NSWorkspace.shared.open(url)
        }
    }

    private func startMonitor(_ url: URL) {
        let monitor = FileMonitor(url: url) {
            Task { @MainActor in
                self.previewDirty = true
            }
        }
        monitor.start()
        fileMonitor = monitor
    }

    // MARK: - Dirty banner

    private func dirtyBanner(_ entry: SFTPEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up.fill").foregroundStyle(.orange)
            Text("\(entry.name) ถูกแก้ไข — upload กลับ?")
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if isUploading { ProgressView().controlSize(.small) }
            Button("Upload") {
                guard let localURL = previewTempURL else { return }
                let remotePath = session.remotePath(of: entry)
                Task {
                    previewDirty = false
                    fileMonitor?.stop()
                    await uploadFile(localURL: localURL, to: remotePath)
                    startMonitor(localURL) // resume watching
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isUploading)

            Button("ยกเลิก") { previewDirty = false }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    // MARK: - Reusable status bar

    private func statusBar(text: String, spinning: Bool, tint: Color, onDismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
        Divider()
        HStack(spacing: 6) {
            if spinning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(tint)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { onDismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        } // VStack
    }

    // MARK: - Error empty state

    private func emptyErrorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("ไม่สามารถโหลด directory ได้").font(.headline)
            Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button { Task { await session.loadDirectory(session.currentPath) } } label: {
                Label("ลองใหม่", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func icon(for e: SFTPEntry) -> String {
        if e.isDirectory { return "folder.fill" }
        if e.isSymlink  { return "link" }
        return "doc"
    }
}

// MARK: - CredentialPrompt

private struct CredentialPrompt: View {
    let host: SSHHost
    let kind: SFTPSession.Credential
    let lastError: String?
    var onCancel: () -> Void
    var onSubmit: (String, Bool) -> Void

    @State private var secret = ""
    @State private var saveToKeychain = true

    private var title: String {
        switch kind {
        case .keyPassphrase: return "Passphrase ของ key"
        case .userPassword:  return "รหัสผ่านสำหรับ \(host.user)@\(host.hostName.isEmpty ? host.alias : host.hostName)"
        case .none: return ""
        }
    }
    private var placeholder: String {
        switch kind {
        case .keyPassphrase: return "passphrase"
        case .userPassword:  return "password"
        case .none: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let err = lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            SecureField(placeholder, text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(secret, saveToKeychain) }
            Toggle("บันทึกใน Keychain", isOn: $saveToKeychain).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Connect") { onSubmit(secret, saveToKeychain) }
                    .keyboardShortcut(.defaultAction).disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
