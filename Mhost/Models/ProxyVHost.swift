import Foundation

/// ประเภทเป้าหมายของ vhost ที่ proxy จะตอบกลับ
enum ProxyVHostTargetKind: String, Codable, CaseIterable, Identifiable {
    /// forward ไปยัง URL ปลายทาง (เช่น http://127.0.0.1:3000)
    case forward
    /// serve ไฟล์จากโฟลเดอร์ในเครื่อง
    case folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forward: return "Forward → URL"
        case .folder:  return "Serve folder"
        }
    }
}

/// กฎ vhost หนึ่งตัว
/// `host` ตรงกับ Host header ของ request (เช่น "myapp.local")
/// ถ้า request เข้ามาแล้ว host ตรง (case-insensitive) → ไป target นั้น
/// ถ้าไม่ตรง vhost ใด ๆ → forward ตามปกติออก internet
struct ProxyVHost: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var host: String                  // เช่น "myapp.local" (ห้ามมี scheme)
    var kind: ProxyVHostTargetKind
    /// ขึ้นกับ kind:
    /// - .forward: URL เต็ม เช่น "http://127.0.0.1:3000"
    /// - .folder:  absolute path เช่น "/Users/me/projects/myapp/public"
    var target: String
    var enabled: Bool = true

    func matches(host candidate: String) -> Bool {
        let a = host.lowercased().trimmingCharacters(in: .whitespaces)
        let b = candidate.lowercased().trimmingCharacters(in: .whitespaces)
        // strip port ถ้ามี
        let bare = { (s: String) -> String in
            if let i = s.firstIndex(of: ":") { return String(s[..<i]) }
            return s
        }
        return bare(a) == bare(b)
    }
}
