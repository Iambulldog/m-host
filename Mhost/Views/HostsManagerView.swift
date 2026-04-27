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
        .onChange(of: manager.errorMessage) { _, newValue in
            if newValue == nil {
                lastSuccessMessage = "Hosts file saved successfully."
                showSuccessBanner = true
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
                    HostEntryRow(entry: entry, onToggle: {
                        manager.toggleEntry(entry)
                    }, onDelete: {
                        entryToDelete = entry
                    })
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
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
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(entry.isEnabled ? .green : .gray)
                .frame(width: 8, height: 8)

            Text(entry.ip)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 140, alignment: .leading)

            Text(entry.hostname)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(entry.isEnabled ? .primary : .secondary)

            if let comment = entry.comment, !comment.isEmpty {
                Text("# \(comment)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isHovering {
                Button(action: onToggle) {
                    Image(systemName: entry.isEnabled ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(entry.isEnabled ? "Disable" : "Enable")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
