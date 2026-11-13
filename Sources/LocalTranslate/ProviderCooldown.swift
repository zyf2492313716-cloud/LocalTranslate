import Foundation

/// 免费服务的临时冷却。
///
/// 谷歌这类免费接口一旦被限流，会连续失败几十次；每张卡片都挂一条红色报错，
/// 用户看到的就是"整个 App 都坏了"。这里把被限流的服务记下来，冷却期内直接跳过、
/// 不建卡片，到点自动恢复——期间其它引擎照常出译文。
enum ProviderCooldown {

    private static let key = "providerCooldownUntil"
    private static let lock = NSLock()

    private static func load() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    private static func save(_ map: [String: Double]) {
        UserDefaults.standard.set(map, forKey: key)
    }

    /// 标记某个服务冷却一段时间
    static func mark(_ profileID: String, seconds: TimeInterval, reason: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map[profileID] = Date().timeIntervalSince1970 + seconds
        // 顺手清掉已经过期的，别让字典无限长
        let now = Date().timeIntervalSince1970
        map = map.filter { $0.value > now }
        save(map)
        Debug.log("服务冷却：\(profileID) \(Int(seconds))s（\(reason)）")
    }

    static func isCoolingDown(_ profileID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = load()[profileID] else { return false }
        return until > Date().timeIntervalSince1970
    }

    /// 剩余秒数，用于给用户一句人话
    static func remaining(_ profileID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let until = load()[profileID] else { return 0 }
        return max(0, Int(until - Date().timeIntervalSince1970))
    }

    static func clear(_ profileID: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map.removeValue(forKey: profileID)
        save(map)
    }

    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        save([:])
    }
}
