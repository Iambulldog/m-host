import Foundation

/// ตัวแทน entry หนึ่ง host ในไฟล์ ~/.ssh/config
/// เก็บฟิลด์ทั่วไปเป็น property ตรง ๆ ส่วนคีย์อื่น ๆ เก็บใน `extraOptions`
/// `defaultPath` ไม่ใช่คีย์มาตรฐานของ ssh config — เก็บเป็น comment marker
/// `# MhostDefaultPath: /var/www/html` เพื่อให้ปุ่ม Connect ใน UI ใช้ cd หลัง ssh
struct SSHHost: Identifiable, Equatable {
    var id: UUID = UUID()
    var alias: String                  // ชื่อ Host (e.g. "myserver")
    var hostName: String = ""          // HostName
    var user: String = ""              // User
    var port: String = ""              // Port (string เพื่อให้ว่างได้)
    var identityFile: String = ""      // IdentityFile (~/.ssh/id_rsa)
    var defaultPath: String = ""       // path สำหรับ cd หลัง ssh (เก็บใน comment)
    /// คีย์อื่น ๆ ที่ไม่ได้แมพเป็น property ตรง ๆ (key,value)
    var extraOptions: [(key: String, value: String)] = []

    static func == (lhs: SSHHost, rhs: SSHHost) -> Bool {
        lhs.id == rhs.id &&
        lhs.alias == rhs.alias &&
        lhs.hostName == rhs.hostName &&
        lhs.user == rhs.user &&
        lhs.port == rhs.port &&
        lhs.identityFile == rhs.identityFile &&
        lhs.defaultPath == rhs.defaultPath &&
        lhs.extraOptions.map({ "\($0.key)=\($0.value)" }) ==
        rhs.extraOptions.map({ "\($0.key)=\($0.value)" })
    }
}
