import Foundation

/// 统一的网络出口。
///
/// 代理只在一个地方配：所有请求都从这里拿 session。
/// 散着用 `URLSession.shared` 的话，迟早会漏掉一处——那一处就绕过代理，
/// 表现成「有的能翻有的不能」，很难查。
///
/// 还有一条硬规则：**本机回环地址不走代理**。
/// Magpie 这类本地网关走代理会直接连不上，而且用户根本想不到是这个原因。
enum NetworkSession {

    private static let lock = NSLock()
    private static var cached: URLSession?
    private static var cachedSignature: String?

    static var shared: URLSession {
        lock.lock(); defer { lock.unlock() }
        let signature = signatureForConfig()
        if let cached, cachedSignature == signature { return cached }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Config.shared.timeoutSeconds
        let proxy = proxyDictionary()
        if !proxy.isEmpty { config.connectionProxyDictionary = proxy }
        let session = URLSession(configuration: config)
        cached = session
        cachedSignature = signature
        return session
    }

    /// 设置一改就得重建 session，否则旧代理还挂在里面
    static func invalidate() {
        lock.lock(); cached = nil; cachedSignature = nil; lock.unlock()
        Debug.log("网络出口已重建")
    }

    private static func signatureForConfig() -> String {
        let c = Config.shared
        return [c.proxyEnabled ? "1" : "0", c.proxyType, c.proxyHost,
                String(c.proxyPort), c.proxyUsername].joined(separator: "|")
    }

    /// 组装 connectionProxyDictionary。关掉或填不全时返回空字典（＝直连）。
    static func proxyDictionary(enabled: Bool? = nil,
                                type: String? = nil,
                                host: String? = nil,
                                port: Int? = nil,
                                username: String? = nil,
                                password: String? = nil) -> [AnyHashable: Any] {
        let c = Config.shared
        let isOn = enabled ?? c.proxyEnabled
        guard isOn else { return [:] }

        let kind = (type ?? c.proxyType).lowercased()
        let hostValue = (host ?? c.proxyHost).trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = port ?? c.proxyPort
        guard !hostValue.isEmpty, (1...65535).contains(portValue) else { return [:] }

        var dict: [AnyHashable: Any] = [:]
        if kind == "socks5" || kind == "socks" {
            dict[kCFNetworkProxiesSOCKSEnable] = 1
            dict[kCFNetworkProxiesSOCKSProxy] = hostValue
            dict[kCFNetworkProxiesSOCKSPort] = portValue
        } else {
            dict[kCFNetworkProxiesHTTPEnable] = 1
            dict[kCFNetworkProxiesHTTPProxy] = hostValue
            dict[kCFNetworkProxiesHTTPPort] = portValue
            dict[kCFNetworkProxiesHTTPSEnable] = 1
            dict[kCFNetworkProxiesHTTPSProxy] = hostValue
            dict[kCFNetworkProxiesHTTPSPort] = portValue
        }

        // 回环与内网直连：本地网关不该被代理吞掉
        dict[kCFNetworkProxiesExceptionsList] = ["127.0.0.1", "localhost", "::1", "*.local"]

        let user = username ?? c.proxyUsername
        if !user.isEmpty {
            dict[kCFNetworkProxiesProxyAutoConfigEnable] = 0
            let secret = password ?? SecretStore.shared.apiKey(for: "proxy-password")
            dict["ProxyUsername"] = user
            if !secret.isEmpty { dict["ProxyPassword"] = secret }
        }
        return dict
    }

    /// 一句话描述当前出口，给设置页显示
    static func describe() -> String {
        let c = Config.shared
        guard c.proxyEnabled, !proxyDictionary().isEmpty else { return "直连（未使用代理）" }
        let kind = c.proxyType.lowercased() == "socks5" ? "SOCKS5" : "HTTP"
        return "\(kind) \(c.proxyHost):\(c.proxyPort)，本机地址直连"
    }
}
