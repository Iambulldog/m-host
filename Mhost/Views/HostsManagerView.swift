import SwiftUI

struct HostsManagerView: View {
    @State private var manager = HostsFileManager()
    @State private var showAddSheet = false
    @State private var searchText = ""
    @State private var entryToDelete: HostEntry?
    @State private var lastSuccessMessage: String = ""
    @State private var showSuccessBanner: Bool = false

    private var filteredEntries: [HostEntry] {
        let hostEntries = manager.entries.filter { !$0.isComment }
        if searchText.isEmpty { return hostEntries }
        return hostEntries.filter {
            $0.ip.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            undoRedoBar
            searchBar
            Divider()
            entryList
            errorBar
        }
        .onAppear { manager.loadEntries() }
        .onChange(of: manager.successMessage) { _, newValue in
            if let newValue, !newValue.isEmpty {
                lastSuccessMessage = newValue
                showSuccessBanner = true
                manager.successMessage = nil
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddEntrySheet(isPresented: $showAddSheet) { ip, hostname in
                manager.addEntry(ip: ip, hostname: hostname)
            }
        }
        .alert("Delete Entry?", isPresented: .init(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { entryToDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    manager.deleteEntry(entry)
                    entryToDelete = nil
                }
            }
        } message: {
            if let entry = entryToDelete {
                Text("Remove \(entry.ip) → \(entry.hostname) from /etc/hosts?")
            }
        }
        .overlay(
            Group {
                if showSuccessBanner {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(lastSuccessMessage)
                            .foregroundColor(.primary)
                        Spacer()
                        Button("Dismiss") { showSuccessBanner = false }
                            .font(.caption)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .shadow(radius: 4)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }
            }, alignment: .top
        )
    }

    private var toolbar: some View {
        HStack {
            Text("Hosts Entries")
                .font(.headline)
            Spacer()
            Button(action: { manager.loadEntries() }) {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Button(action: {
                showSuccessBanner = false
                manager.refreshDNSCache()
            }) {
                Label("Refresh DNS Cache", systemImage: "arrow.clockwise.circle")
            }
            Button(action: { showAddSheet = true }) {
                Label("Add Entry", systemImage: "plus")
            }
        }
        .padding()
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search hosts...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var undoRedoBar: some View {
        HStack {
            Button(action: { manager.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!manager.canUndo)
            Button(action: { manager.redo() }) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!manager.canRedo)
            if searchText.isEmpty {
                Text("Drag and hold a row to reorder entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Clear search to reorder entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var entryList: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Host Entries" : "No Results",
                systemImage: searchText.isEmpty ? "server.rack" : "magnifyingglass",
                description: Text(searchText.isEmpty ? "Click + to add a new entry" : "No entries match your search")
            )
        } else {
            List {
                ForEach(filteredEntries) { entry in
                    HostEntryRow(
                        entry: entry,
                        canReorder: searchText.isEmpty,
                        onToggle: {
                            showSuccessBanner = false
                            manager.toggleEntry(entry)
                        },
                        onDelete: { entryToDelete = entry },
                        onSave: { ip, hostname, comment in
                            showSuccessBanner = false
                            return manager.updateEntry(id: entry.id, ip: ip, hostname: hostname, comment: comment)
                        }
                    )
                    .moveDisabled(!searchText.isEmpty)
                }
                .onMove(perform: moveEntries)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func moveEntries(from offsets: IndexSet, to destination: Int) {
        guard searchText.isEmpty else { return }
        showSuccessBanner = false
        manager.moveHostEntries(fromOffsets: offsets, toOffset: destination)
    }

    @ViewBuilder
    private var errorBar: some View {
        if let error = manager.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { manager.errorMessage = nil }
                    .font(.caption)
            }
            .padding(8)
            .background(.red.opacity(0.1))
        }
    }
}

struct HostEntryRow: View {
    let entry: HostEntry
    let canReorder: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onSave: (String, String, String?) -> Bool

    @State private var ip: String
    @State private var hostname: String
    @State private var comment: String
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case ip
        case hostname
        case comment
    }

    init(
        entry: HostEntry,
        canReorder: Bool,
        onToggle: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSave: @escaping (String, String, String?) -> Bool
    ) {
        self.entry = entry
        self.canReorder = canReorder
        self.onToggle = onToggle
        self.onDelete = onDelete
        self.onSave = onSave
        _ip = State(initialValue: entry.ip)
        _hostname = State(initialValue: entry.hostname)
        _comment = State(initialValue: entry.comment ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: canReorder ? "line.3.horizontal" : "line.3.horizontal.decrease")
                    .foregroundStyle(canReorder ? .secondary : .tertiary)
                    .help(canReorder ? "Click and hold to reorder" : "Clear search to reorder")

                Button(action: onToggle) {
                    Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.isEnabled ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.isEnabled ? "Disable entry" : "Enable entry")

                TextField("IP Address", text: $ip)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 140, maxWidth: 170)
                    .focused($focusedField, equals: .ip)
                    .onSubmit(commitEdits)

                TextField("Hostname", text: $hostname)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .hostname)
                    .onSubmit(commitEdits)

                TextField("Comment (optional)", text: $comment)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 180)
                    .focused($focusedField, equals: .comment)
                    .onSubmit(commitEdits)

                Spacer(minLength: 8)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 68)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(entry.isEnabled ? 1 : 0.72)
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                commitEdits()
            }
        }
        .onChange(of: entry) { _, newValue in
            if focusedField == nil {
                syncDraft(with: newValue)
            }
        }
    }

    private func commitEdits() {
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedIP.isEmpty else {
            validationMessage = "IP address is required."
            return
        }
        guard HostsFileManager.validateIP(trimmedIP) else {
            validationMessage = "Invalid IP address (IPv4 or IPv6)"
            return
        }
        guard !trimmedHostname.isEmpty else {
            validationMessage = "Hostname is required."
            return
        }

        let didSave = onSave(trimmedIP, trimmedHostname, trimmedComment.isEmpty ? nil : trimmedComment)
        guard didSave else { return }

        ip = trimmedIP
        hostname = trimmedHostname
        comment = trimmedComment
        validationMessage = nil
    }

    private func syncDraft(with entry: HostEntry) {
        ip = entry.ip
        hostname = entry.hostname
        comment = entry.comment ?? ""
        validationMessage = nil
    }
}

struct AddEntrySheet: View {
    @Binding var isPresented: Bool
    let onAdd: (String, String) -> Void

    @State private var ip = "127.0.0.1"
    @State private var hostname = ""
    @State private var ipError: String?

    private var isValid: Bool {
        !ip.trimmingCharacters(in: .whitespaces).isEmpty &&
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty &&
        ipError == nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add New Host Entry")
                .font(.headline)

            Form {
                TextField("IP Address:", text: $ip)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: ip) { _, newValue in
                        validateIP(newValue)
                    }

                if let ipError {
                    Text(ipError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("Hostname:", text: $hostname)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    onAdd(
                        ip.trimmingCharacters(in: .whitespaces),
                        hostname.trimmingCharacters(in: .whitespaces)
                    )
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func validateIP(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ipError = nil
            return
        }
        ipError = HostsFileManager.validateIP(trimmed) ? nil : "Invalid IP address (IPv4 or IPv6)"
    }
}
