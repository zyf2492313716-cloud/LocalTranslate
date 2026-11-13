import Foundation

/// 外部调起用的 URL 协议：localtranslate://
///
/// 解析做成纯函数，注册和分发是另一层，这样自测能离线验所有分支。
///
/// 支持的地址：
///   localtranslate://translate?text=hello&to=zh-Hans
///   localtranslate://translate?text=hello&copy=1    翻完直接进剪贴板
///   localtranslate://input                          打开输入翻译
///   localtranslate://screenshot                     截图翻译
///   localtranslate://dictionary?word=pressure       查词
///   localtranslate://vocabulary                     生词本
///   localtranslate://settings                       设置
///   localtranslate://speak?text=...                 朗读
enum URLRouter {

    enum Command: Equatable {
        case translate(text: String, target: String?, copy: Bool)
        case input
        case screenshot
        case dictionary(word: String?)
        case vocabulary
        case favorites
        case history
        case helper
        case settings
        case speak(text: String)
    }

    enum ParseResult: Equatable {
        case command(Command)
        case failure(String)
    }

    static let scheme = "localtranslate"

    static func parse(_ url: URL) -> ParseResult {
        guard url.scheme?.lowercased() == scheme else {
            return .failure("不是 \(scheme):// 开头的地址")
        }
        // localtranslate://translate 里 host 就是动作名
        let action = (url.host ?? "").lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        switch action {
        case "translate":
            let text = (value("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure("translate 缺少 text 参数") }
            let copy = ["1", "true", "yes"].contains((value("copy") ?? "").lowercased())
            return .command(.translate(text: text, target: value("to"), copy: copy))
        case "input":
            return .command(.input)
        case "screenshot":
            return .command(.screenshot)
        case "dictionary":
            let word = (value("word") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .command(.dictionary(word: word.isEmpty ? nil : word))
        case "vocabulary":
            return .command(.vocabulary)
        case "favorites":
            return .command(.favorites)
        case "helper":
            return .command(.helper)
        case "history":
            return .command(.history)
        case "settings":
            return .command(.settings)
        case "speak":
            let text = (value("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure("speak 缺少 text 参数") }
            return .command(.speak(text: text))
        default:
            return .failure("不认识的动作：\(action.isEmpty ? "(空)" : action)")
        }
    }
}

/// 命令行翻译：给脚本用。
///
/// AppleScript 走 `do shell script` 调这个，比硬啃 scripting definition 便宜得多，
/// 而且用 `open "localtranslate://..."` 也能达到同样效果。
///
///   LocalTranslate --translate "hello" [--to zh-Hans]
/// 成功把译文打到 stdout，失败把原因打到 stderr 并以 1 退出。
enum ScriptCLI {

    static func translate(_ arguments: [String]) -> Int32 {
        var text: String?
        var target: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--to", index + 1 < arguments.count {
                target = arguments[index + 1]
                index += 2
                continue
            }
            if text == nil { text = arg }
            index += 1
        }

        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            FileHandle.standardError.write(Data("用法: LocalTranslate --translate \"文本\" [--to zh-Hans]\n".utf8))
            return 2
        }
        guard let profile = ProfileStore.firstUsable() else {
            FileHandle.standardError.write(Data("没有可用的翻译服务，先在设置里配一个\n".utf8))
            return 1
        }

        let language = target ?? Config.shared.targetLanguage
        let sem = DispatchSemaphore(value: 0)
        var output = ""
        var failure: String?
        let callbacks = TranslationCallbacks(
            onThink: { _ in },
            onDelta: { _ in },
            onDone: { text, _ in output = text },
            onError: { failure = $0 }
        )
        let task = Task {
            await Translator.translate(text: raw, targetLanguage: language, mode: .translate,
                                       profile: profile, callbacks: callbacks)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 90) == .timedOut {
            task.cancel()
            FileHandle.standardError.write(Data("翻译超时\n".utf8))
            return 1
        }
        if let failure {
            FileHandle.standardError.write(Data((failure + "\n").utf8))
            return 1
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            FileHandle.standardError.write(Data("没有拿到译文\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data((trimmed + "\n").utf8))
        return 0
    }
}
