import AppKit
import Foundation
import Security

/// API Key 存储。
///
/// 两条硬规则，都是被真实故障逼出来的：
///
/// 1. **绝不在主线程碰钥匙串。** 登录钥匙串一旦上锁（合盖息屏后会自动锁），
///    SecItemCopyMatching 会卡在解密那一步等用户输口令。命令行/后台进程里没有
///    能点的弹窗，调用方就永久挂住——实测卡了 12 分钟不动。
///    所以钥匙串调用一律丢到专用队列，主线程只读内存缓存。
///
/// 2. **拿不到钥匙串也不能静默失效。** 读不到就退回 0600 权限的本地文件，
///    并把当前存在哪儿显示出来，别让「填了 Key 却毫无反应」变成一个谜。
final class SecretStore {

    static let shared = SecretStore()

    /// 自测时整体换到另一个 service 名下，绝不碰用户真实的钥匙串条目
    static var serviceOverride: String?

    private var service: String { SecretStore.serviceOverride ?? "com.localtranslate.apikey" }
    private let account = SecretStore.defaultAccount
    private let queue = DispatchQueue(label: "com.localtranslate.secretstore", qos: .userInitiated)

    private var cache: [String: String] = [:]
    private var loadingAccounts: Set<String> = []
    private var loadState: LoadState = .idle
    private let lock = NSLock()

    /// 旧版全局那把 key 的 account，迁移用
    static let legacyAccount = "default"
    static let defaultAccount = "default"

    enum LoadState: Equatable {
        case idle
        case loading
        case keychain
        case file
        case blocked(reason: String)

        var label: String {
            switch self {
            case .idle: return "还没读过"
            case .loading: return "读取中"
            case .keychain: return "钥匙串"
            case .file: return "本地文件(0600)"
            case .blocked(let reason): return "本地文件(0600)，钥匙串不可用：\(reason)"
            }
        }
    }

    private init() {}

    /// 自测用：把兜底文件挪到临时目录，别污染用户真实数据
    /// 兜底文件的目录，自测会挪走它
    static var directoryOverride: URL?

    /// 每个 account 一个文件，别互相覆盖
    private func fileURL(_ acct: String) -> URL {
        let dir = SecretStore.directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LocalTranslate", isDirectory: true)
        return dir.appendingPathComponent("key-\(acct)")
    }

    private func query(account acct: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
    }

    // MARK: - 读写入口

    /// 读：只取内存缓存，主线程安全。缓存还没到位时先回文件里的值或空串，
    /// 后台读到后发通知，界面自己补。
    /// 写：异步落盘 + 异步进钥匙串，调用方不等待。
    var apiKey: String {
        get { apiKey(for: account) }
        set { write(apiKey: newValue, for: account) }
    }

    /// 旧配置里那把全局 key，迁移到各服务条目时用
    var legacyAPIKey: String { apiKey(for: Self.legacyAccount) }

    /// 按 account 取。密钥按服务分开存，多个服务各自的 key 互不干扰。
    func apiKey(for acct: String) -> String {
        lock.lock()
        let cached = cache[acct]
        let shouldLoad = (cached == nil && !loadingAccounts.contains(acct))
        if shouldLoad { loadingAccounts.insert(acct) }
        lock.unlock()

        if let cached { return cached }
        if shouldLoad { startBackgroundLoad(acct) }
        return fileValue(acct) ?? ""
    }

    func setAPIKey(_ value: String, account acct: String) {
        write(apiKey: value, for: acct)
    }

    /// 主动重新读一次（设置界面打开时调用）
    func reload() {
        lock.lock()
        cache.removeAll()
        loadingAccounts.removeAll()
        lock.unlock()
        startBackgroundLoad(account)
        for profile in ProfileStore.all() {
            startBackgroundLoad(profile.keyAccount)
        }
    }

    private func startBackgroundLoad(_ acct: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.readKeychain(acct)
            self.lock.lock()
            if let value = outcome.value {
                self.cache[acct] = value
                self.loadState = .keychain
            } else {
                self.cache[acct] = self.fileValue(acct)
                self.loadState = .blocked(reason: "状态码 \(outcome.status ?? -1)")
                Debug.log("钥匙串读取失败（状态码 \(outcome.status ?? -1)），改用本地文件")
            }
            self.loadingAccounts.remove(acct)
            let gotFromKeychain = (outcome.value != nil)
            self.lock.unlock()

            if gotFromKeychain {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .localTranslateSecretLoaded, object: nil)
                }
            }
        }
    }

    /// 当前存在哪儿，给设置界面和 --selftest config 显示
    var storageLocationLabel: String {
        lock.lock()
        let state = loadState
        let cached = cache[account]
        lock.unlock()
        switch state {
        case .keychain: return LoadState.keychain.label
        case .blocked:  return state.label
        case .file:     return LoadState.file.label
        default:
            if let cached = cached, !cached.isEmpty { return state.label }
            return fileValue(account) != nil ? LoadState.file.label : "未存储"
        }
    }

    // MARK: - 钥匙串调用（只在后台队列跑）

    private struct KeychainRead {
        var value: String?
        var status: OSStatus?
    }

    /// 给 probe 用的可变盒子（闭包里要改的捕获值）
    private final class ReadBox {
        var outcome: KeychainRead?
        var ran = false
    }

    private func readKeychain(_ acct: String) -> KeychainRead {
        var query = query(account: acct)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // 不弹授权框：别的签名身份写的记录会要求用户批准，后台没人能点。
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return KeychainRead(value: nil, status: status)
        }
        return KeychainRead(value: string, status: status)
    }

    /// true = 进了钥匙串；false = 只能靠文件
    @discardableResult
    private func writeKeychain(_ value: String, _ acct: String) -> Bool {
        let data = Data(value.utf8)

        var probe = query(account: acct)
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        probe[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var existing: CFTypeRef?
        let found = SecItemCopyMatching(probe as CFDictionary, &existing)

        if found == errSecSuccess {
            let status = SecItemUpdate(query(account: acct) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return true }
            Debug.log("钥匙串更新状态码 \(status)")
            return false
        }

        var add = query(account: acct)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        Debug.log("钥匙串写入状态码 \(status)")
        return false
    }

    private func fileValue(_ acct: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(acct)) else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    @discardableResult
    private func writeToFile(_ value: String, _ acct: String) -> Bool {
        let url = fileURL(acct)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try value.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            Debug.log("本地文件写入失败: \(error)")
            return false
        }
    }

    // MARK: - 写

    /// 异步写入，调用方不等待。
    func write(apiKey value: String, for acct: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cache[acct] = trimmed.isEmpty ? nil : trimmed
        lock.unlock()

        if trimmed.isEmpty {
            queue.async {
                SecItemDelete(self.query(account: acct) as CFDictionary)
                try? FileManager.default.removeItem(at: self.fileURL(acct))
            }
            return
        }

        // 先落一份 0600 的文件，保证「填了 Key 一定存住了」；钥匙串是更好的一层，成不成都不影响可用
        if writeToFile(trimmed, acct) {
            lock.lock()
            // 先按文件记账，后台真写进钥匙串了再升级成「钥匙串」。
            // 不这么做的话写完立刻查位置会显示「还没读过」，看着像没保存。
            if loadState != .keychain { loadState = .file }
            lock.unlock()
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.writeKeychain(trimmed, acct) {
                self.loadState = .keychain
                Debug.log("API Key 已写入钥匙串")
            } else {
                self.loadState = .blocked(reason: "写入被拒")
                Debug.log("钥匙串写入失败，继续使用本地文件")
            }
            self.lock.unlock()
        }
    }

    // MARK: - 探测

    /// 带超时的钥匙串可达性检查，给 --selftest 用。
    /// 超时要当结论报出来，不能跟着一起挂住。
    func probe(timeout: TimeInterval = 3) -> (available: Bool, detail: String) {
        let sem = DispatchSemaphore(value: 0)
        let box = ReadBox()
        queue.async {
            box.outcome = self.readKeychain(self.account)
            box.ran = true
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return (false, "钥匙串 \(Int(timeout)) 秒内无响应（登录钥匙串被锁或在等用户口令）")
        }
        guard box.ran, let outcome = box.outcome else {
            return (false, "钥匙串查询没跑起来")
        }
        if let value = outcome.value {
            return (true, "钥匙串可读（\(value.count) 字符）")
        }
        return (false, "钥匙串返回状态码 \(outcome.status ?? -1)")
    }
}

extension Notification.Name {
    /// 钥匙串异步读取完成
    static let localTranslateSecretLoaded = Notification.Name("LocalTranslateSecretLoaded")
}
