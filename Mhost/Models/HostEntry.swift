import Foundation

struct HostEntry: Identifiable, Equatable {
    let id = UUID()
    var ip: String
    var hostname: String
    var comment: String?
    var isEnabled: Bool
    var isComment: Bool

    var lineRepresentation: String {
        if isComment {
            return comment ?? ""
        }
        let prefix = isEnabled ? "" : "# "
        let base = "\(prefix)\(ip)\t\(hostname)"
        if let comment, !comment.isEmpty {
            return "\(base) # \(comment)"
        }
        return base
    }

    static func parse(line: String) -> HostEntry {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || (trimmed.hasPrefix("#") && !isDisabledEntry(trimmed)) {
            return HostEntry(ip: "", hostname: "", comment: trimmed, isEnabled: false, isComment: true)
        }

        var isEnabled = true
        var working = trimmed
        if trimmed.hasPrefix("#") {
            isEnabled = false
            working = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        let parts = working.components(separatedBy: "#")
        let mainPart = parts[0].trimmingCharacters(in: .whitespaces)
        let inlineComment = parts.count > 1
            ? parts.dropFirst().joined(separator: "#").trimmingCharacters(in: .whitespaces)
            : nil

        let components = mainPart.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        guard components.count >= 2 else {
            return HostEntry(ip: "", hostname: "", comment: trimmed, isEnabled: false, isComment: true)
        }

        let ip = components[0]
        let hostname = components[1...].joined(separator: " ")

        return HostEntry(ip: ip, hostname: hostname, comment: inlineComment, isEnabled: isEnabled, isComment: false)
    }

    static func isValidIPAddress(_ string: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        return string.withCString { cstring in
            inet_pton(AF_INET, cstring, &sin.sin_addr) == 1 ||
            inet_pton(AF_INET6, cstring, &sin6.sin6_addr) == 1
        }
    }

    private static func isDisabledEntry(_ line: String) -> Bool {
        let stripped = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("#") { return false }
        let components = stripped.split(whereSeparator: { $0.isWhitespace })
        guard components.count >= 2 else { return false }
        return isValidIPAddress(String(components[0]))
    }
}
