import Foundation

/// Magpie 本地网关的客户端。
///
/// Magpie 在你机器上跑一个 OpenAI 兼容的网关（默认 127.0.0.1:3425），
/// 把它接进来的好处是不用再往 LocalTranslate 里一个个填 Base URL 和密钥：
/// 模型清单直接跟 Magpie 走，换模型只改 Magpie 那边。
///
/// 回环地址默认不需要密钥（Magpie 自己就是本机进程），
/// 如果开了 gateway-key，填进来走 Bearer 即可。
enum MagpieClient {

    struct Model: Decodable {
        let id: String
        let displayName: String?
        let ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case ownedBy = "owned_by"
        }

        /// 列表里显示的名字：优先 display_name，没有就用 id
        var title: String { displayName?.isEmpty == false ? displayName! : id }

        /// 供应商前缀，比如 workbuddy / antigravity
        var provider: String {
            if let ownedBy, !ownedBy.isEmpty { return ownedBy }
            return id.split(separator: "/").first.map(String.init) ?? "magpie"
        }
    }

    struct Snapshot {
        var reachable: Bool
        var detail: String
        var models: [Model]
    }

    /// 默认网关地址；设置里可以改
    static var baseURL: String {
        let configured = Config.shared.magpieBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "http://127.0.0.1:3425" : configured
    }

    /// 完整 OpenAI 兼容前缀
    static var v1URL: String {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { return base }
        return base + "/v1"
    }

    static var gatewayKey: String { Config.shared.magpieGatewayKey }

    // MARK: - 探测

    /// 摸一次：能不能连上、有多少模型。
    /// 连不上不算错误——很多人不装 Magpie，界面要能把话说明白。
    static func probe(timeout: TimeInterval = 2.5) -> Snapshot {
        guard let url = URL(string: v1URL + "/models") else {
            return Snapshot(reachable: false, detail: "Magpie 地址不合法：\(v1URL)", models: [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let key = gatewayKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let sem = DispatchSemaphore(value: 0)
        var result: Snapshot = Snapshot(reachable: false, detail: "没有响应", models: [])

        NetworkSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error {
                result = Snapshot(reachable: false, detail: "连不上 \(v1URL)：\(error.localizedDescription)", models: [])
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = Snapshot(reachable: false, detail: "没有 HTTP 响应", models: [])
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let hint = http.statusCode == 401 ? "（需要 gateway-key，填到下面）" : ""
                result = Snapshot(reachable: false,
                                  detail: "网关返回 \(http.statusCode)\(hint)", models: [])
                return
            }
            guard let data, let decoded = try? JSONDecoder().decode(ModelList.self, from: data) else {
                result = Snapshot(reachable: false, detail: "返回内容解析不了", models: [])
                return
            }
            result = Snapshot(reachable: true,
                              detail: "已连接，\(decoded.data.count) 个模型",
                              models: decoded.data.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }.resume()

        if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
            return Snapshot(reachable: false, detail: "\(Int(timeout)) 秒内没响应", models: [])
        }
        return result
    }

    private struct ModelList: Decodable {
        let data: [Model]
    }

    // MARK: - 生成服务条目

    /// 把一个 Magpie 模型变成 LocalTranslate 的服务条目。
    /// 名字用 Magpie 的展示名，模型名用它的 id（provider/model）。
    static func profile(for model: Model, gatewayKey explicitKey: String? = nil) -> ServiceProfile {
        ServiceProfile(
            id: UUID().uuidString,
            name: model.title,
            baseURL: v1URL,
            model: model.id,
            enabled: true,
            extraPrompt: "",
            magpieModel: model.id
        )
    }

    /// 这个服务条目是不是来自 Magpie
    static func isMagpieProfile(_ profile: ServiceProfile) -> Bool {
        if profile.magpieModel != nil { return true }
        var base = profile.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base.hasPrefix(v1URL) || profile.baseURL.contains(":3425")
    }
}
