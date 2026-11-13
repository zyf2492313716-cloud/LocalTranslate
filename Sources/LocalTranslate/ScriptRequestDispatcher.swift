import AppKit

/// AppleScript / JXA request JSON 调度器。
/// 对应 Bob 官方的 `tell application "Bob" to request theParameterJSON`
enum ScriptRequestDispatcher {

    struct RequestPayload: Decodable {
        let path: String
        let body: RequestBody?
    }

    struct RequestBody: Decodable {
        let action: String?
        let text: String?
        let word: String?
        let to: String?
        let target: String?
        let sync: Bool?
        let source: String?
        let result: String?
    }

    static func handle(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let req = try? JSONDecoder().decode(RequestPayload.self, from: data) else {
            return jsonResponse(status: "error", message: "JSON 解析失败")
        }

        let path = req.path.lowercased()
        let body = req.body

        switch path {
        case "translate":
            let action = (body?.action ?? "translateText").lowercased()
            let text = (body?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let targetLang = body?.to ?? body?.target

            if let targetLang, !targetLang.isEmpty {
                Config.shared.targetLanguage = targetLang
            }

            switch action {
            case "translatetext":
                guard !text.isEmpty else {
                    return jsonResponse(status: "error", message: "缺少 text 参数")
                }
                if body?.sync == true {
                    return syncTranslate(text: text, targetLang: targetLang)
                } else {
                    DispatchQueue.main.async {
                        if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
                        let config = Config.shared
                        let mode = TranslateMode(rawValue: config.mode) ?? .translate
                        let profiles = ProfileStore.enabled()
                        TranslationCard.shared.present(source: text, mode: mode, targetLanguage: config.targetLanguage, profiles: profiles)
                        TranslateRunner.shared.run(source: text, mode: mode, targetLanguage: config.targetLanguage, profiles: profiles, card: TranslationCard.shared)
                    }
                    return jsonResponse(status: "success", message: "已弹出翻译窗口")
                }

            case "selectiontranslate":
                DispatchQueue.main.async {
                    if let app = NSApp.delegate as? AppDelegate {
                        app.translateSelection()
                    }
                }
                return jsonResponse(status: "success", message: "已触发划词翻译")

            case "silentselectiontranslate":
                DispatchQueue.main.async {
                    SilentReplace.perform(scope: .selection)
                }
                return jsonResponse(status: "success", message: "已触发静默划词替换")

            case "silentinputboxtranslate":
                DispatchQueue.main.async {
                    SilentReplace.perform(scope: .wholeField)
                }
                return jsonResponse(status: "success", message: "已触发静默输入框替换")

            case "sniptranslate":
                DispatchQueue.main.async {
                    if let app = NSApp.delegate as? AppDelegate {
                        app.screenshotTranslate()
                    }
                }
                return jsonResponse(status: "success", message: "已触发截图翻译")

            default:
                return jsonResponse(status: "error", message: "未知 translate 动作: \(action)")
            }

        case "ocr":
            let action = (body?.action ?? "snipOCR").lowercased()
            switch action {
            case "snipocr":
                DispatchQueue.main.async {
                    if let app = NSApp.delegate as? AppDelegate {
                        app.screenshotTranslate()
                    }
                }
                return jsonResponse(status: "success", message: "已触发截图 OCR")
            case "silentsnipocr":
                DispatchQueue.main.async {
                    if let app = NSApp.delegate as? AppDelegate {
                        app.silentScreenshotOcr()
                    }
                }
                return jsonResponse(status: "success", message: "已触发静默截图 OCR")
            default:
                return jsonResponse(status: "error", message: "未知 OCR 动作: \(action)")
            }

        case "dictionary":
            let word = body?.word ?? body?.text
            DispatchQueue.main.async {
                DictionaryWindow.shared.show(word: word)
            }
            return jsonResponse(status: "success", message: "已打开词典")

        case "favorites":
            DispatchQueue.main.async {
                FavoriteWindow.shared.show()
            }
            return jsonResponse(status: "success", message: "已打开收藏夹")

        case "vocabulary":
            DispatchQueue.main.async {
                VocabularyWindow.shared.show()
            }
            return jsonResponse(status: "success", message: "已打开生词本")

        case "input":
            let prefill = body?.text
            DispatchQueue.main.async {
                InputTranslationWindow.shared.show(prefill: prefill)
            }
            return jsonResponse(status: "success", message: "已打开输入翻译")

        case "favorite":
            // 允许脚本把某段原文+译文直接收藏
            let src = (body?.source ?? body?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let dst = (body?.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty, !dst.isEmpty else {
                return jsonResponse(status: "error", message: "favorite 需要 source 与 result")
            }
            let ok = FavoriteStore.add(source: src, result: dst, model: "script",
                                       targetLanguage: Config.shared.targetLanguage,
                                       sourceLanguage: Config.shared.sourceLanguage)
            return jsonResponse(status: ok ? "success" : "error",
                                message: ok ? "已收藏" : "收藏失败")

        case "settings":
            DispatchQueue.main.async {
                PreferencesWindow.shared.showSettings()
            }
            return jsonResponse(status: "success", message: "已打开设置")

        default:
            return jsonResponse(status: "error", message: "未知 path: \(path)")
        }
    }

    private static func syncTranslate(text: String, targetLang: String?) -> String {
        guard let profile = ProfileStore.firstUsable() else {
            return jsonResponse(status: "error", message: "没有可用的翻译服务")
        }
        let language = targetLang ?? Config.shared.targetLanguage
        var output = ""
        var failure: String?
        let sem = DispatchSemaphore(value: 0)
        let callbacks = TranslationCallbacks(
            onThink: { _ in },
            onDelta: { _ in },
            onDone: { text, _ in output = text },
            onError: { failure = $0 }
        )
        Task {
            await Translator.translate(text: text, targetLanguage: language, mode: .translate, profile: profile, callbacks: callbacks)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {
            return jsonResponse(status: "error", message: "翻译超时")
        }
        if let failure {
            return jsonResponse(status: "error", message: failure)
        }
        return jsonResponse(status: "success", result: output)
    }

    private static func jsonResponse(status: String, result: String? = nil, message: String? = nil) -> String {
        var dict: [String: Any] = ["status": status]
        if let result { dict["result"] = result }
        if let message { dict["message"] = message }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"status\":\"\(status)\"}"
    }
}

@objc(RequestScriptCommand)
final class RequestScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let raw = directParameter as? String else {
            return "{\"status\":\"error\",\"message\":\"缺少参数\"}"
        }
        return ScriptRequestDispatcher.handle(raw)
    }
}

@objc(TranslateScriptCommand)
final class TranslateScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let raw = directParameter as? String else {
            return "{\"status\":\"error\",\"message\":\"缺少翻译文本\"}"
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "{\"status\":\"error\",\"message\":\"缺少翻译文本\"}"
        }
        let cleaned = TextPreprocessor.process(text)
        DispatchQueue.main.async {
            if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
            let config = Config.shared
            let mode = TranslateMode(rawValue: config.mode) ?? .translate
            let profiles = ProfileStore.enabled()
            TranslationCard.shared.present(source: cleaned, mode: mode, targetLanguage: config.targetLanguage, profiles: profiles)
            TranslateRunner.shared.run(source: cleaned, mode: mode, targetLanguage: config.targetLanguage, profiles: profiles, card: TranslationCard.shared)
        }
        return "{\"status\":\"success\",\"message\":\"已调起翻译\",\"source\":\"\(cleaned)\"}"
    }
}
