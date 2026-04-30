import Foundation
import Observation

@Observable
@MainActor
final class HostsFileManager {
    var entries: [HostEntry] = []
    var errorMessage: String?
    private var undoStack: [[HostEntry]] = []
    private var redoStack: [[HostEntry]] = []

    private let hostsPath = "/etc/hosts"

    func loadEntries() {
        do {
            let content = try String(contentsOfFile: hostsPath, encoding: .utf8)
            entries = content.components(separatedBy: "\n").map { HostEntry.parse(line: $0) }
            while entries.last?.isComment == true && entries.last?.comment?.isEmpty == true {
                entries.removeLast()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to read \(hostsPath): \(error.localizedDescription)"
        }
    }

    func saveEntries() {
        let content = entries.map(\.lineRepresentation).joined(separator: "\n") + "\n"
        let helper = HostsHelperClient()
        helper.replaceHostsFile(content: content) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.errorMessage = nil
                    self?.loadEntries()
                } else {
                    self?.errorMessage = "Failed to save: \(error ?? "Unknown error")"
                }
            }
        }
    }

    func addEntry(ip: String, hostname: String) {
        pushUndo()
        let entry = HostEntry(ip: ip, hostname: hostname, comment: nil, isEnabled: true, isComment: false)
        entries.append(entry)
        redoStack.removeAll()
        saveEntries()
    }

    func deleteEntry(_ entry: HostEntry) {
        pushUndo()
        entries.removeAll { $0.id == entry.id }
        redoStack.removeAll()
        saveEntries()
    }

    func toggleEntry(_ entry: HostEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        pushUndo()
        entries[index].isEnabled.toggle()
        redoStack.removeAll()
        saveEntries()
    }
    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(entries)
        entries = last
        saveEntries()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(entries)
        entries = next
        saveEntries()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(entries)
        if undoStack.count > 50 { undoStack.removeFirst() }
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
