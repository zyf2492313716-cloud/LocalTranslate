import Foundation
import Network

/// 浏览器助手用的本地小服务。
///
/// 只监听 127.0.0.1，只做一件事：`GET /translate?text=...&to=...` 返回 JSON 译文。
/// 浏览器扩展把选中文字发过来，拿到结果就能在页面上直接显示——不用切窗口，也不碰剪贴板。
///
/// 安全边界：绑定回环地址、只认 GET、只允许本机来源；没有鉴权（本机任意进程都能用），
/// 因为它本来就只能读到你主动发来的文本，收益/成本比不划算再套一层 token。
final class HelperServer {

    static let shared = HelperServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.localtranslate.helper")
    private(set) var port: UInt16 = 0
    private(set) var isRunning = false

    /// 启动。端口被占用时自动往后找 5 个。
    @discardableResult
    func start(preferredPort: UInt16 = 8765) -> UInt16? {
        guard !isRunning else { return port }
        for offset in 0..<5 {
            let candidate = preferredPort &+ UInt16(offset)
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            guard let listener = try? NWListener(using: parameters) else { continue }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
            if listener.state == .ready {
                self.listener = listener
                self.port = candidate
                self.isRunning = true
                Debug.log("浏览器助手服务已启动 127.0.0.1:\(candidate)")
                return candidate
            }
            listener.cancel()
        }
        Debug.log("浏览器助手服务启动失败（端口都被占用）")
        return nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(connection, status: 400, body: ["ok": false, "error": "bad request"])
                return
            }
            let path = String(parts[1])   // parts[0] 是方法名 GET
            if path.hasPrefix("/health") {
                self.respond(connection, status: 200, body: ["ok": true])
                return
            }
            guard path.hasPrefix("/translate") else {
                self.respond(connection, status: 404, body: ["ok": false, "error": "not found"])
                return
            }
            guard let query = URLComponents(string: "http://x" + path),
                  let text = query.queryItems?.first(where: { $0.name == "text" })?.value,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.respond(connection, status: 400, body: ["ok": false, "error": "缺少 text 参数"])
                return
            }
            let target = query.queryItems?.first(where: { $0.name == "to" })?.value

            Task {
                let result = await HelperServer.translate(text: text, target: target)
                switch result {
                case .success(let payload):
                    self.respond(connection, status: 200, body: payload)
                case .failure(let failure):
                    self.respond(connection, status: 200, body: ["ok": false, "error": failure.message])
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(json.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(json)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 翻译

    /// 和静默翻译共用同一套「哪家能翻就用哪家」的逻辑
    struct Failure: Error { var message: String }

    private static func translate(text: String, target: String?) async -> Result<[String: Any], Failure> {
        let usable = ProfileStore.enabled().filter { $0.isConfigured }
        guard !usable.isEmpty else { return .failure(Failure(message: "还没有可用的翻译服务")) }
        let effectiveTarget = target ?? LanguageDetector.resolveTargetLanguage(
            source: text, fallbackTarget: Config.shared.targetLanguage)

        var lastError = ""
        for profile in usable {
            if ProviderCooldown.isCoolingDown(profile.id) { continue }
            if profile.providerKind == .apple, #available(macOS 15.0, *) {
                let status = await AppleTranslator.availability(
                    targetLanguage: effectiveTarget,
                    sourceLanguage: LanguageDetector.detectLanguage(text))
                if status != .installed { lastError = "Apple 缺语言包"; continue }
            }
            let outcome = await Translator.translatePlain(
                text: text, targetLanguage: effectiveTarget, profile: profile)
            if case .success(let translated) = outcome,
               !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success([
                    "ok": true,
                    "text": translated,
                    "engine": profile.name,
                    "target": effectiveTarget,
                ])
            }
            if case .failure(let message) = outcome { lastError = message }
        }
        return .failure(Failure(message: lastError.isEmpty ? "所有服务都没翻出来" : lastError))
    }
}
