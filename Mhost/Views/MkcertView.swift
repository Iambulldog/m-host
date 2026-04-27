import SwiftUI

struct MkcertView: View {
    @State private var manager = MkcertManager()
    @State private var showFullLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("mkcert — Local SSL Certificates")
                    .font(.headline)
                Spacer()
                Button(action: { manager.refreshInstallStatus() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh install status")
            }
            .padding()

            Divider()

            Form {
                Section("Status") {
                    HStack {
                        Image(systemName: manager.mkcertInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(manager.mkcertInstalled ? .green : .red)
                        if manager.mkcertInstalled, let path = manager.mkcertPath {
                            Text("mkcert installed: ").foregroundStyle(.secondary)
                            Text(path).font(.system(.caption, design: .monospaced))
                        } else {
                            Text("mkcert not installed").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if !manager.mkcertInstalled {
                        HStack {
                            Image(systemName: manager.brewInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(manager.brewInstalled ? .green : .orange)
                            Text(manager.brewInstalled
                                 ? "Homebrew พร้อมใช้งาน — กดปุ่มติดตั้งด้านล่างได้เลย"
                                 : "ยังไม่มี Homebrew — ต้องติดตั้งก่อน")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button {
                            Task { await manager.installMkcertViaBrew() }
                        } label: {
                            HStack {
                                if manager.isRunning {
                                    ProgressView().controlSize(.small).padding(.trailing, 4)
                                }
                                Image(systemName: "arrow.down.circle")
                                Text(manager.isRunning ? "กำลังติดตั้ง..." : "ติดตั้ง mkcert (ผ่าน Homebrew)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(manager.isRunning || !manager.brewInstalled)
                    } else {
                        Button {
                            Task { await manager.installLocalCA() }
                        } label: {
                            HStack {
                                if manager.isRunning {
                                    ProgressView().controlSize(.small).padding(.trailing, 4)
                                }
                                Image(systemName: "lock.shield")
                                Text(manager.isRunning ? "กำลังติดตั้ง CA..." : "Install Local CA (mkcert -install)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(manager.isRunning)
                        .help("ติดตั้ง root CA ใน System Keychain เพื่อให้ browser เชื่อใจ certificate")
                    }
                }

                if manager.mkcertInstalled {
                    Section("Root CA Location (mkcert -CAROOT)") {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.purple)
                            if let root = manager.caRootPath {
                                Text(root)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } else {
                                Text("ไม่สามารถอ่าน CAROOT ได้").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                manager.revealCARootInFinder()
                            } label: { Image(systemName: "folder") }
                            .help("เปิดใน Finder")
                            .disabled(manager.caRootPath == nil)

                            Button {
                                manager.copyCARootToPasteboard()
                            } label: { Image(systemName: "doc.on.doc") }
                            .help("คัดลอก path")
                            .disabled(manager.caRootPath == nil)
                        }
                        Text("ใช้ไฟล์ rootCA.pem ในโฟลเดอร์นี้ติดตั้งบนเครื่องอื่น (เช่น มือถือ/อุปกรณ์ใน LAN) เพื่อให้เชื่อใจ certificate ของ mkcert")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Domain") {
                    TextField("Domain Name:", text: $manager.domain,
                              prompt: Text("เช่น localhost หรือ myapp.local หรือ *.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Output Directory (เลือกที่เก็บไฟล์)") {
                    HStack {
                        if let dir = manager.outputDirectory {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(dir.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text("ยังไม่ได้เลือกโฟลเดอร์").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Browse...") { manager.selectOutputDirectory() }
                    }
                }

                Section {
                    Button {
                        Task { await manager.runMkcert() }
                    } label: {
                        HStack {
                            if manager.isRunning {
                                ProgressView().controlSize(.small).padding(.trailing, 4)
                            }
                            Image(systemName: "key.fill")
                            Text(manager.isRunning ? "กำลังสร้าง..." : "Generate Certificate")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(
                        manager.isRunning ||
                        !manager.mkcertInstalled ||
                        manager.domain.trimmingCharacters(in: .whitespaces).isEmpty ||
                        manager.outputDirectory == nil
                    )
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            // Bar-style status log (แถบบาง ๆ ด้านล่าง)
            statusBar
        }
        .sheet(isPresented: $showFullLog) {
            FullLogSheet(log: manager.fullLog, isPresented: $showFullLog)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        Divider()
        HStack(spacing: 8) {
            // สถานะไอคอน
            Group {
                if manager.isRunning {
                    ProgressView().controlSize(.small)
                } else if manager.statusMessage.isEmpty {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                } else if manager.isSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)

            // ข้อความล่าสุดบรรทัดเดียว
            Text(latestStatusLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(manager.statusMessage.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(manager.statusMessage)

            // ปุ่มดู log เต็ม
            if !manager.fullLog.isEmpty {
                Button {
                    showFullLog = true
                } label: {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .help("ดู log ทั้งหมด")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(barBackground)
    }

    private var latestStatusLine: String {
        if manager.statusMessage.isEmpty { return "Ready" }
        // เอาเฉพาะบรรทัดแรกที่ไม่ว่าง
        return manager.statusMessage
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "Ready"
    }

    private var barBackground: some ShapeStyle {
        if manager.statusMessage.isEmpty { return AnyShapeStyle(.bar) }
        if manager.isSuccess { return AnyShapeStyle(Color.green.opacity(0.10)) }
        return AnyShapeStyle(Color.red.opacity(0.10))
    }
}

// Full log sheet (เปิดดู log เต็มเมื่อคลิกปุ่ม)
struct FullLogSheet: View {
    let log: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("mkcert log")
                    .font(.headline)
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(log.isEmpty ? "(no output)" : log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.opacity(0.05))
        }
        .frame(width: 640, height: 420)
    }
}

#Preview { MkcertView() }
