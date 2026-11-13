import AppKit

/// 在 App 里执行 scripts/setup_signing.sh，把输出带回界面显示。
/// 只跑我们自己项目里的那一个脚本，不接受外部输入。
enum ScriptRunner {

    struct Outcome {
        var ok: Bool
        var text: String
    }

    static func runSetupSigning() -> Outcome {
        // .app 里没带 scripts/，先找 bundle 同级，再找开发目录
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("scripts/setup_signing.sh"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scripts/setup_signing.sh"),
            URL(fileURLWithPath: NSString(string: "~/Documents/deepseek-harness/default-workspace/LocalTranslate/scripts/setup_signing.sh").expandingTildeInPath),
        ]
        guard let script = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return Outcome(ok: false, text: "找不到 setup_signing.sh。这个脚本随源码一起，装在 /Applications 里时不带；从项目目录跑一次即可。")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        task.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return Outcome(ok: false, text: "执行失败：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = task.terminationStatus == 0
        let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
        return Outcome(ok: ok, text: ok ? "已执行：\n\(tail)\n\n重新打包后授权就不会再掉了。" : "脚本没跑通：\n\(tail)")
    }
}

/// 配置导出/导入。默认不含密钥，勾选后才会带上——明文文件放桌上很容易被顺手拷走。
enum ConfigArchive {

    enum ArchiveError: LocalizedError {
        case badFormat

        var errorDescription: String? { "文件不是本 App 导出的配置格式" }
    }

    struct Payload: Codable {
        var kind = "localtranslate-config"
        var version = 1
        var draft: PrefsDraft
        var keys: [String: String]?
    }

    static func exportJSON(includeKeys: Bool) throws -> Data {
        var draft = PrefsDraft.load()
        draft.keyEdits = [:]
        var payload = Payload(draft: draft)
        if includeKeys {
            var keys: [String: String] = [:]
            for profile in draft.profiles {
                let value = SecretStore.shared.apiKey(for: profile.keyAccount)
                if !value.isEmpty { keys[profile.id] = value }
            }
            payload.keys = keys
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func importJSON(_ data: Data) throws {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.kind == "localtranslate-config" else {
            throw ArchiveError.badFormat
        }
        payload.draft.apply()
        if let keys = payload.keys {
            for profile in payload.draft.profiles {
                if let value = keys[profile.id], !value.isEmpty {
                    SecretStore.shared.setAPIKey(value, account: profile.keyAccount)
                }
            }
        }
        ProfileStore.reload()
        NotificationCenter.default.post(name: .localTranslatePrefsSaved, object: nil)
    }
}

/// 双击 Option 划词。和快捷键互补：手指不用离开鼠标就能触发。
final class DoubleOptionMonitor {

    static let shared = DoubleOptionMonitor()

    var onTrigger: (() -> Void)?

    private var monitor: Any?
    private var lastTap = Date.distantPast
    private let interval: TimeInterval = 0.35

    private init() {}

    static var isEnabled: Bool {
        get { Config.shared.doubleOptionTranslate }
        set {
            Config.shared.doubleOptionTranslate = newValue
            shared.setActive(newValue)
        }
    }

    func setActive(_ active: Bool) {
        if active {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event)
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    var isActive: Bool { monitor != nil }

    private func handle(_ event: NSEvent) {
        // 只认 Option 的单键按下：按下时只有 option 置位
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option else { return }
        let now = Date()
        if now.timeIntervalSince(lastTap) <= interval {
            lastTap = .distantPast
            DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
        } else {
            lastTap = now
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
