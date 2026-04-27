import Foundation
import Network
import Observation
import Security

/// HTTP/HTTPS forward proxy with vhost interception + MITM.
///
/// พฤติกรรม:
/// - Listen TCP บน `port` (default 8888)
/// - HTTP request: ถ้า Host ตรงกับ vhost → forward URL หรือ serve folder. ไม่ตรง → forward ออก internet
/// - HTTPS (CONNECT): ตรง vhost → MITM ผ่าน mkcert per-host cert. ไม่ตรง → tunnel ปกติ
///
/// Threading: ทุก IO ทำบน internal serial queue. UI state ถูกอัปเดตผ่าน DispatchQueue.main
@Observable
final class ProxyServer {

    // MARK: - Public state (read on main, written on main)
    var isRunning: Bool = false
    var settings: ProxySettings = ProxySettingsStore.load()
    var lastError: String?
    var requestLog: [String] = []
    var mkcertCAReady: Bool = false

    // MARK: - Private (touched from internal queue)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mhost.proxy.io", qos: .userInitiated)
    private let certs = ProxyCertManager()
    /// per-host TLS sub-listener สำหรับ MITM
    private var tlsListeners: [String: (listener: NWListener, port: UInt16)] = [:]
    /// เก็บ snapshot path ของ mkcert ตอน attach (อ่านจาก main แล้วเก็บไว้ใช้ใน IO queue)
    private var mkcertPathSnapshot: String?

    // MARK: - Wiring (called from MainActor / UI)

    @MainActor
    func attach(mkcert: MkcertManager) {
        self.mkcertPathSnapshot = mkcert.mkcertPath
        self.mkcertCAReady = (mkcert.mkcertPath != nil)
    }

    func saveSettings() {
        ProxySettingsStore.save(settings)
    }

    func reloadSettings() {
        settings = ProxySettingsStore.load()
    }

    // MARK: - Lifecycle

    func start() {
        if isRunning { return }
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let portObj = NWEndpoint.Port(rawValue: settings.port) else {
                lastError = "Port ไม่ถูกต้อง"
                return
            }
            let l = try NWListener(using: params, on: portObj)
            let portValue = settings.port
            l.newConnectionHandler = { [weak self] conn in
                self?.handleNewProxyConnection(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.appendLog("✓ proxy listening on :\(portValue)")
                    case .failed(let err):
                        self.lastError = "listener failed: \(err.localizedDescription)"
                        self.isRunning = false
                    case .cancelled:
                        self.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "เริ่ม listener ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for (_, entry) in self.tlsListeners { entry.listener.cancel() }
            self.tlsListeners.removeAll()
        }
        Task { @MainActor [weak self] in
            self?.isRunning = false
            self?.appendLog("✗ proxy stopped")
        }
    }

    // MARK: - Logging (always called on main)

    @MainActor
    private func appendLog(_ line: String) {
        let stamp = Self.shortStamp()
        requestLog.append("[\(stamp)] \(line)")
        if requestLog.count > 200 {
            requestLog.removeFirst(requestLog.count - 200)
        }
    }

    private func log(_ line: String) {
        Task { @MainActor [weak self] in self?.appendLog(line) }
    }

    private static func shortStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// snapshot vhosts จาก main (call จาก IO queue ผ่าน sync)
    private func vhostsSnapshot() -> [ProxyVHost] {
        var snap: [ProxyVHost] = []
        if Thread.isMainThread {
            snap = settings.vhosts
        } else {
            DispatchQueue.main.sync { snap = self.settings.vhosts }
        }
        return snap
    }

    // MARK: - Incoming proxy connections

    private func handleNewProxyConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHttpHead(conn: conn, accumulated: Data()) { [weak self] head, leftover in
            guard let self else { conn.cancel(); return }
            self.dispatch(conn: conn, headData: head, leftover: leftover)
        }
    }

    /// อ่าน byte จนเจอ \r\n\r\n; คืน (head, leftover)
    private func readHttpHead(conn: NWConnection,
                              accumulated: Data,
                              completion: @escaping (Data, Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            var buf = accumulated
            if let d = data { buf.append(d) }
            let term = Data("\r\n\r\n".utf8)
            if let r = buf.range(of: term) {
                completion(buf.subdata(in: 0..<r.upperBound),
                           buf.subdata(in: r.upperBound..<buf.count))
                return
            }
            if error != nil || isComplete || buf.count > 64 * 1024 {
                completion(buf, Data())
                return
            }
            self?.readHttpHead(conn: conn, accumulated: buf, completion: completion)
        }
    }

    private func dispatch(conn: NWConnection, headData: Data, leftover: Data) {
        guard let head = String(data: headData, encoding: .utf8) else {
            log("✗ malformed head")
            conn.cancel()
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            conn.cancel(); return
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0].uppercased()
        let target = parts[1]

        if method == "CONNECT" {
            handleConnect(clientConn: conn, target: target)
        } else {
            handleHttp(clientConn: conn, head: head, leftover: leftover, method: method, target: target)
        }
    }

    // MARK: - HTTP

    private func handleHttp(clientConn: NWConnection,
                            head: String,
                            leftover: Data,
                            method: String,
                            target: String) {
        let lines = head.components(separatedBy: "\r\n")
        let hostHeader = lines.first(where: { $0.lowercased().hasPrefix("host:") })
            .map { $0.dropFirst("host:".count).trimmingCharacters(in: .whitespaces) }
            ?? ""
        let hostOnly: String = {
            if let i = hostHeader.firstIndex(of: ":") { return String(hostHeader[..<i]) }
            return hostHeader
        }()

        let snapshot = vhostsSnapshot()
        if let v = snapshot.first(where: { $0.enabled && $0.matches(host: hostOnly) }) {
            log("→ HTTP vhost \(hostOnly) [\(v.kind.rawValue)] \(method) \(target)")
            switch v.kind {
            case .forward:
                forwardHttpToURL(clientConn: clientConn,
                                 originalHead: head, leftover: leftover,
                                 originalTarget: target,
                                 forwardURL: v.target,
                                 originalHost: hostOnly)
            case .folder:
                serveStatic(clientConn: clientConn, target: target, folder: v.target)
            }
            return
        }

        log("→ HTTP passthrough \(hostHeader) \(method) \(target)")
        forwardHttpUpstream(clientConn: clientConn,
                            originalHead: head, leftover: leftover,
                            target: target, hostHeader: hostHeader)
    }

    private func forwardHttpUpstream(clientConn: NWConnection,
                                     originalHead: String,
                                     leftover: Data,
                                     target: String,
                                     hostHeader: String) {
        var upstreamHost = ""
        var upstreamPort: UInt16 = 80
        var path = target

        if let url = URL(string: target), let h = url.host {
            upstreamHost = h
            upstreamPort = UInt16(url.port ?? 80)
            path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?\(q)" }
        } else if !hostHeader.isEmpty {
            let comps = hostHeader.split(separator: ":", maxSplits: 1).map(String.init)
            upstreamHost = comps[0]
            if comps.count > 1, let p = UInt16(comps[1]) { upstreamPort = p }
        } else {
            sendSimple(conn: clientConn, status: 400, body: "Bad request: no host"); return
        }

        let rewrittenHead = rewriteRequestHead(originalHead, newRequestPath: path)
        guard let portObj = NWEndpoint.Port(rawValue: upstreamPort) else {
            sendSimple(conn: clientConn, status: 502, body: "Bad upstream port"); return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(upstreamHost), port: portObj, using: .tcp)
        pipeHttpToUpstream(client: clientConn, upstream: upstream,
                           rewrittenHead: rewrittenHead, leftover: leftover)
    }

    /// forward HTTP/HTTPS ไป URL ปลายทาง
    /// - originalHost: vhost name เดิม (เช่น "children-lotto.test") ใช้เป็น SNI ตอน TLS upstream
    ///   เพื่อให้ปลายทางเลือก cert ถูก + ใช้ override Host header
    private func forwardHttpToURL(clientConn: NWConnection,
                                  originalHead: String,
                                  leftover: Data,
                                  originalTarget: String,
                                  forwardURL: String,
                                  originalHost: String? = nil) {
        guard let base = URL(string: forwardURL),
              let host = base.host else {
            sendSimple(conn: clientConn, status: 502,
                       body: "Bad forward URL: \(forwardURL)")
            return
        }
        let scheme = base.scheme?.lowercased() ?? "http"
        let port: UInt16 = UInt16(base.port ?? (scheme == "https" ? 443 : 80))
        var requestPath = originalTarget
        if let u = URL(string: originalTarget), u.host != nil {
            requestPath = u.path.isEmpty ? "/" : u.path
            if let q = u.query { requestPath += "?\(q)" }
        }
        let basePath = base.path.isEmpty ? "" : base.path
        // หลีกเลี่ยง "//" เมื่อ base ลงท้ายด้วย / และ request เริ่มด้วย /
        let combined: String
        if requestPath.hasPrefix("/") {
            let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            combined = trimmed + requestPath
        } else if basePath.hasSuffix("/") {
            combined = basePath + requestPath
        } else if basePath.isEmpty {
            combined = "/" + requestPath
        } else {
            combined = basePath + "/" + requestPath
        }

        // เก็บ Host header เดิม (vhost name) ไว้ — ปลายทาง dev server มักคาดหวังชื่อนี้
        // มากกว่า 127.0.0.1 (เช่น Laravel route.matcher, Nginx server_name)
        let hostHeaderValue = originalHost ?? base.host
        let rewrittenHead = rewriteRequestHead(originalHead,
                                               newRequestPath: combined,
                                               overrideHost: hostHeaderValue)
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            sendSimple(conn: clientConn, status: 502, body: "Bad forward port"); return
        }

        let params: NWParameters
        if scheme == "https" {
            let tlsOpts = NWProtocolTLS.Options()
            // skip upstream cert verification (เหมือน curl -k)
            // dev container/Laravel/Caddy ของ user มักใช้ self-signed หรือ cert ที่ Mac ไม่ trust
            sec_protocol_options_set_verify_block(
                tlsOpts.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue
            )
            // ตั้ง SNI ให้ตรงกับ vhost name เดิม (server เลือก cert ตาม SNI ได้ถูก)
            if let sni = originalHost ?? base.host {
                sec_protocol_options_set_tls_server_name(
                    tlsOpts.securityProtocolOptions, sni
                )
            }
            params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: portObj, using: params)
        pipeHttpToUpstream(client: clientConn, upstream: upstream,
                           rewrittenHead: rewrittenHead, leftover: leftover)
    }

    private func pipeHttpToUpstream(client: NWConnection,
                                    upstream: NWConnection,
                                    rewrittenHead: String,
                                    leftover: Data) {
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                var blob = Data(rewrittenHead.utf8)
                blob.append(leftover)
                upstream.send(content: blob, completion: .contentProcessed { _ in
                    self?.pipe(from: client, to: upstream)
                    self?.pipe(from: upstream, to: client)
                })
            case .failed(let err):
                self?.sendSimple(conn: client, status: 502,
                                 body: "Upstream failed: \(err.localizedDescription)")
                upstream.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func pipe(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                dst.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    dst.cancel()
                })
                src.cancel()
                return
            }
            self?.pipe(from: src, to: dst)
        }
    }

    private func rewriteRequestHead(_ head: String,
                                    newRequestPath: String,
                                    overrideHost: String? = nil) -> String {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return head }
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        if parts.count >= 3 {
            lines[0] = "\(parts[0]) \(newRequestPath) \(parts[2])"
        }
        if let newHost = overrideHost {
            for i in 0..<lines.count {
                if lines[i].lowercased().hasPrefix("host:") {
                    lines[i] = "Host: \(newHost)"
                }
            }
        }
        lines.removeAll(where: {
            let lc = $0.lowercased()
            return lc.hasPrefix("proxy-connection:") || lc.hasPrefix("proxy-authorization:")
        })
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Static folder serving

    private func serveStatic(clientConn: NWConnection, target: String, folder: String) {
        var path = target
        if let url = URL(string: target), url.host != nil {
            path = url.path.isEmpty ? "/" : url.path
        }
        if path.contains("..") { sendSimple(conn: clientConn, status: 400, body: "Bad path"); return }
        if path.hasSuffix("/") { path += "index.html" }
        let fileURL = URL(fileURLWithPath: folder).appendingPathComponent(path.removingPercentEncoding ?? path)
        guard let data = try? Data(contentsOf: fileURL) else {
            sendSimple(conn: clientConn, status: 404, body: "Not found: \(path)")
            return
        }
        let mime = mimeType(for: fileURL.pathExtension)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var blob = Data(head.utf8)
        blob.append(data)
        clientConn.send(content: blob, isComplete: true, completion: .contentProcessed { _ in
            clientConn.cancel()
        })
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js":  return "application/javascript; charset=utf-8"
        case "json":return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private func sendSimple(conn: NWConnection, status: Int, body: String) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 502: phrase = "Bad Gateway"
        default: phrase = "Error"
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var blob = Data(head.utf8)
        blob.append(bodyData)
        conn.send(content: blob, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - HTTPS / CONNECT

    private func handleConnect(clientConn: NWConnection, target: String) {
        let comps = target.split(separator: ":", maxSplits: 1).map(String.init)
        let host = comps[0]
        let port: UInt16 = comps.count > 1 ? UInt16(comps[1]) ?? 443 : 443
        let snapshot = vhostsSnapshot()
        let vhost = snapshot.first(where: { $0.enabled && $0.matches(host: host) })

        let ok = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: Mhost\r\n\r\n"
        clientConn.send(content: Data(ok.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if let v = vhost {
                self.log("→ HTTPS vhost MITM \(host):\(port) [\(v.kind.rawValue)]")
                self.startMitm(clientConn: clientConn, host: host, vhost: v)
            } else {
                self.log("→ HTTPS tunnel \(host):\(port)")
                self.startTunnel(clientConn: clientConn, host: host, port: port)
            }
        })
    }

    private func startTunnel(clientConn: NWConnection, host: String, port: UInt16) {
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            clientConn.cancel(); return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: portObj, using: .tcp)
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pipe(from: clientConn, to: upstream)
                self?.pipe(from: upstream, to: clientConn)
            case .failed:
                clientConn.cancel(); upstream.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func startMitm(clientConn: NWConnection, host: String, vhost: ProxyVHost) {
        do {
            let port = try ensureTLSSubListener(for: host)
            let upstream = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(integerLiteral: port),
                using: .tcp
            )
            upstream.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.pipe(from: clientConn, to: upstream)
                    self?.pipe(from: upstream, to: clientConn)
                case .failed(let err):
                    self?.log("✗ MITM upstream fail: \(err.localizedDescription)")
                    clientConn.cancel(); upstream.cancel()
                default: break
                }
            }
            upstream.start(queue: queue)
        } catch {
            log("✗ MITM error \(host): \(error.localizedDescription)")
            clientConn.cancel()
        }
    }

    /// สร้าง (หรือดึง) NWListener TLS สำหรับ host พร้อม cert mkcert — คืน port
    private func ensureTLSSubListener(for host: String) throws -> UInt16 {
        if let entry = tlsListeners[host] { return entry.port }

        let identity = try certs.identity(for: host, mkcertPath: mkcertPathSnapshot)
        guard let secIdentity = sec_identity_create(identity) else {
            throw ProxyCertManager.CertError.identityMissing
        }

        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, secIdentity)

        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params, on: .any)
        // capture vhost snapshot
        let vhostCopy = vhostsSnapshot().first(where: { $0.matches(host: host) })

        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            self.readHttpHead(conn: conn, accumulated: Data()) { head, leftover in
                guard let s = String(data: head, encoding: .utf8),
                      let firstLine = s.components(separatedBy: "\r\n").first else {
                    conn.cancel(); return
                }
                let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { conn.cancel(); return }
                let target = parts[1]
                guard let v = vhostCopy else {
                    self.sendSimple(conn: conn, status: 502, body: "vhost gone")
                    return
                }
                switch v.kind {
                case .forward:
                    self.forwardHttpToURL(clientConn: conn, originalHead: s, leftover: leftover,
                                          originalTarget: target, forwardURL: v.target,
                                          originalHost: host)
                case .folder:
                    self.serveStatic(clientConn: conn, target: target, folder: v.target)
                }
            }
        }
        l.start(queue: queue)

        // poll port (NWListener อาจ assign port หลัง start)
        let deadline = Date().addingTimeInterval(2.0)
        while l.port == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let p = l.port else {
            l.cancel()
            throw ProxyCertManager.CertError.identityMissing
        }
        let portValue: UInt16 = p.rawValue
        tlsListeners[host] = (l, portValue)
        return portValue
    }
}
