import Foundation
import Observation

@Observable
@MainActor
final class HostsFileManager {
    var entries: [HostEntry] = []
    var errorMessage: String?
    var successMessage: String?
    private var undoStack: [[HostEntry]] = []
    private var redoStack: [[HostEntry]] = []

    private let hostsPath = "/etc/hosts"
    private let helper = HostsHelperClient()

    private struct Snapshot {
        let entries: [HostEntry]
        let undoStack: [[HostEntry]]
        let redoStack: [[HostEntry]]
    }

    func loadEntries() {
        do {
            let content = try String(contentsOfFile: hostsPath, encoding: .utf8)
            entries = content.components(separatedBy: "\n").map { HostEntry.parse(line: $0) }
            while entries.last?.isComment == true && entries.last?.comment?.isEmpty == true {
                entries.removeLast()
            }
            errorMessage = nil
            successMessage = nil
        } catch {
            errorMessage = "Failed to read \(hostsPath): \(error.localizedDescription)"
        }
    }

    private func saveEntries(restoring snapshot: Snapshot? = nil, successMessage message: String) {
        let content = entries.map(\.lineRepresentation).joined(separator: "\n") + "\n"
        helper.replaceHostsFile(content: content) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.errorMessage = nil
                    self.successMessage = message
                } else {
                    if let snapshot {
                        self.entries = snapshot.entries
                        self.undoStack = snapshot.undoStack
                        self.redoStack = snapshot.redoStack
                    }
                    self.errorMessage = "Failed to save: \(error ?? "Unknown error")"
                }
            }
        }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(entries: entries, undoStack: undoStack, redoStack: redoStack)
    }

    private func saveMutation(successMessage message: String, mutation: () -> Void) {
        let snapshot = makeSnapshot()
        mutation()
        saveEntries(restoring: snapshot, successMessage: message)
    }

    func addEntry(ip: String, hostname: String) {
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty, !trimmedHostname.isEmpty else {
            errorMessage = "IP address and hostname are required."
            return
        }
        guard Self.validateIP(trimmedIP) else {
            errorMessage = "Invalid IP address (IPv4 or IPv6)"
            return
        }

        saveMutation(successMessage: "Host entry added.") {
            pushUndo()
            let entry = HostEntry(ip: trimmedIP, hostname: trimmedHostname, comment: nil, isEnabled: true, isComment: false)
            entries.append(entry)
            redoStack.removeAll()
        }
    }

    func deleteEntry(_ entry: HostEntry) {
        saveMutation(successMessage: "Host entry deleted.") {
            pushUndo()
            entries.removeAll { $0.id == entry.id }
            redoStack.removeAll()
        }
    }

    func toggleEntry(_ entry: HostEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }

        saveMutation(successMessage: entries[index].isEnabled ? "Host entry disabled." : "Host entry enabled.") {
            pushUndo()
            entries[index].isEnabled.toggle()
            redoStack.removeAll()
        }
    }

    @discardableResult
    func updateEntry(id: UUID, ip: String, hostname: String, comment: String?) -> Bool {
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedComment = trimmedComment?.isEmpty == true ? nil : trimmedComment

        guard !trimmedIP.isEmpty else {
            errorMessage = "IP address is required."
            return false
        }
        guard Self.validateIP(trimmedIP) else {
            errorMessage = "Invalid IP address (IPv4 or IPv6)"
            return false
        }
        guard !trimmedHostname.isEmpty else {
            errorMessage = "Hostname is required."
            return false
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Host entry not found."
            return false
        }

        let current = entries[index]
        guard current.ip != trimmedIP || current.hostname != trimmedHostname || current.comment != normalizedComment else {
            errorMessage = nil
            return true
        }

        saveMutation(successMessage: "Host entry updated.") {
            pushUndo()
            entries[index].ip = trimmedIP
            entries[index].hostname = trimmedHostname
            entries[index].comment = normalizedComment
            redoStack.removeAll()
        }
        return true
    }

    func moveHostEntries(fromOffsets: IndexSet, toOffset: Int) {
        guard !fromOffsets.isEmpty else { return }

        saveMutation(successMessage: "Host entry order updated.") {
            pushUndo()

            var hostEntries = entries.filter { !$0.isComment }
            hostEntries = reordered(hostEntries, fromOffsets: fromOffsets, toOffset: toOffset)

            var reorderedIterator = hostEntries.makeIterator()
            for index in entries.indices where !entries[index].isComment {
                if let nextEntry = reorderedIterator.next() {
                    entries[index] = nextEntry
                }
            }

            redoStack.removeAll()
        }
    }

    func refreshDNSCache() {
        helper.refreshDNSCache { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.errorMessage = nil
                    self.successMessage = "DNS cache refreshed."
                } else {
                    self.errorMessage = "Failed to refresh DNS cache: \(error ?? "Unknown error")"
                }
            }
        }
    }

    func undo() {
        let snapshot = makeSnapshot()
        guard let last = undoStack.popLast() else { return }

        redoStack.append(entries)
        entries = last
        saveEntries(restoring: snapshot, successMessage: "Undo complete.")
    }

    func redo() {
        let snapshot = makeSnapshot()
        guard let next = redoStack.popLast() else { return }

        undoStack.append(entries)
        entries = next
        saveEntries(restoring: snapshot, successMessage: "Redo complete.")
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(entries)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func reordered(_ items: [HostEntry], fromOffsets: IndexSet, toOffset: Int) -> [HostEntry] {
        var remaining = items
        let sortedOffsets = fromOffsets.sorted()
        let movingItems = sortedOffsets.map { remaining[$0] }

        for index in sortedOffsets.reversed() {
            remaining.remove(at: index)
        }

        let removedBeforeDestination = sortedOffsets.filter { $0 < toOffset }.count
        let adjustedDestination = max(0, min(toOffset - removedBeforeDestination, remaining.count))
        remaining.insert(contentsOf: movingItems, at: adjustedDestination)
        return remaining
    }

    static func validateIP(_ ip: String) -> Bool {
        HostEntry.isValidIPAddress(ip)
    }
}

extension HostsFileManager {
    /// หา SSHHost จาก HostEntry (mapping ตาม ip/hostname)
    func findHost(for entry: HostEntry) -> SSHHost? {
        // ตัวอย่าง mapping: สมมุติว่า ip = hostName, hostname = alias
        SSHHost(
            alias: entry.hostname,
            hostName: entry.ip,
            user: "",
            port: "",
            identityFile: "",
            defaultPath: "",
            extraOptions: []
        )
    }
}
