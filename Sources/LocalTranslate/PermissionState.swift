import AppKit
import ApplicationServices
import ServiceManagement

/// 系统权限与运行环境状态。
///
/// 之前只有出错时才在卡片上闪一句「没有辅助功能权限」，用户根本不知道去哪开、
/// 也不知道开了没有。这里把状态做成能主动看、能一键跳过去、回来还能自己刷新的。
enum PermissionState {

    struct Snapshot {
        var accessibility: Bool
        var signature: String
        var signingIdentity: String
        var keychainUsable: Bool
        var keychainDetail: String
        var launchAtLogin: Bool
        var registeredHotkeys: [String]
    }

    static func current() -> Snapshot {
        let identity = SystemIdentity.signingName
        var registered: [String] = []
        for kind in HotKeyManager.Kind.allCases {
            if let combo = HotKeyManager.shared.registered[kind] {
                registered.append("\(kind.title) \(HotKeyManager.displayString(combo))")
            }
        }
        let (usable, detail) = SecretStore.shared.probe(timeout: 1.5)
        return Snapshot(
            accessibility: AXIsProcessTrusted(),
            signature: SystemIdentity.signatureSummary,
            signingIdentity: identity,
            keychainUsable: usable,
            keychainDetail: detail,
            launchAtLogin: LaunchAtLogin.isEnabled,
            registeredHotkeys: registered
        )
    }

    /// 跳到系统设置的辅助功能页
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 让系统弹出授权请求（首次会出现在列表里）
    @discardableResult
    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return false
    }

    /// 授权状态变了要通知界面刷新（用户从系统设置切回来时）
    static let didChange = Notification.Name("LocalTranslatePermissionChanged")
}

/// 签名身份。掉授权的真正原因几乎都在这里，所以要能看见。
enum SystemIdentity {

    /// 当前 App 的签名摘要
    static var signatureSummary: String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", Bundle.main.bundlePath]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("certificate leaf") { return "固定证书（重编译不掉授权）" }
            if text.contains("cdhash") { return "ad-hoc（重编译会掉授权，需要重新勾选）" }
        } catch {
            // 拿不到就不显示成异常，下面给个保守描述
        }
        return "未知"
    }

    static var signingName: String {
        signatureSummary.contains("固定证书") ? "LocalTranslate Dev" : "ad-hoc"
    }

    /// 辅助功能授权是绑在签名身份上的。ad-hoc 每次重编译 cdhash 都变，
    /// 系统就把新二进制当成没授权过的陌生 App。这里给出可操作的下一步。
    static var needsRegrantHint: Bool { !signatureSummary.contains("固定证书") }
}

/// 开机自启。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 返回 nil 表示成功，否则带系统给的原因
    static func set(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return "需要 macOS 13 以上" }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            Config.shared.launchAtLogin = enabled
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension HotKeyManager.Kind {
    var title: String {
        switch self {
        case .translate: return "划词"
        case .silent: return "静默"
        case .input: return "输入翻译"
        case .screenshot: return "截图翻译"
        case .dictionary: return "词典"
        case .silentReplace: return "静默划词替换"
        case .inputBoxReplace: return "静默输入框替换"
        case .clipboard: return "剪贴板翻译"
        case .speak: return "朗读"
        case .toggleIcons: return "显示/隐藏图标"
        case .silentScreenshotOcr: return "静默截图 OCR"
        case .finderImageOcr: return "访达选图 OCR"
        }
    }
}
