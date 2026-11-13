import Foundation
import JavaScriptCore

/// JavaScript 插件运行时，对齐 Bob 官方插件规范。
///
/// 遵循 Bob 插件开发指南（https://bobtranslate.com/plugin/）：
/// - 插件实现全局函数：
///     supportLanguages() -> [String]
///     translate(query, completion)
/// - query 结构：
///     text, originalText, from, to, detectFrom, detectTo, onStream, onCompletion
/// - completion 回调参数格式：
///     { result: { from, to, content: { format: "markdown"|"plain"|"lines", text }, toParagraphs: [...] } }
///     { error: { type: "param"|"api"|"network"|"unknown", message, addtion } }
/// - 宿主全局注入：
///     $http.request(options) / $http.get(options) / $http.post(options)
///     $log, $log.info, $log.error, $log.warn
///     $info (info.json 元数据)
///     $option (用户配置选项)
///     $env (环境信息)
///     $data (二进制/Base64/UTF8 处理)
enum PluginRuntime {

    struct PluginError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 自测用：把插件目录挪到临时位置
    static var directoryOverride: URL?

    static var directory: URL {
        if let o = directoryOverride { return o }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalTranslate/plugins", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 列出所有可用插件（.js 文件或包含 main.js 的目录/插件包）
    static func installed() -> [String] {
        ensureDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { url in
            if url.pathExtension.lowercased() == "js" { return true }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return FileManager.default.fileExists(atPath: url.appendingPathComponent("main.js").path)
            }
            return false
        }
        .map { $0.lastPathComponent }
        .sorted()
    }

    /// 官方 Bob 格式示例插件
    static let samplePlugin = """
    // Bob 官方规范示例插件
    function supportLanguages() {
        return ["auto", "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es"];
    }

    function translate(query, completion) {
        $log.info("开始翻译：" + query.text + " -> " + query.to);
        
        // 如果是离线测试或无需网络的插件，可直接回调结果：
        query.onCompletion({
            result: {
                from: query.detectFrom || "auto",
                to: query.to,
                content: {
                    format: "markdown",
                    text: "【插件译文】" + query.text
                }
            }
        });
    }
    """

    static func installSampleIfNeeded() {
        ensureDirectory()
        let target = directory.appendingPathComponent("sample_bob.js")
        if !FileManager.default.fileExists(atPath: target.path) {
            try? samplePlugin.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 执行翻译

    /// 评估并执行插件翻译，支持流式 (onStream) 与最终结果 (onDone/onError)
    /// 最近一次插件翻译里带的 toDict（Cambridge / 有道 这类词典插件会填）。
    /// 插件协议里它是 `result.toDict`，和译文分开，所以这里单独回收一次。
    private(set) static var lastDictionary: DictionaryResult?

    static func consumeDictionary() -> DictionaryResult? {
        defer { lastDictionary = nil }
        return lastDictionary
    }

    static func evaluateTranslate(
        plugin: String,
        text: String,
        source: String,
        target: String,
        onStream: ((String) -> Void)? = nil,
        onNotice: ((String) -> Void)? = nil
    ) -> Result<String, PluginError> {
        guard let prepared = Prepared(plugin: plugin) else {
            return .failure(PluginError(message: "插件读取失败：\(plugin)"))
        }

        let ctx = prepared.ctx
        let detectFrom = LanguageDetector.detectLanguage(text)
        let detectTo = target == "auto" ? "zh-Hans" : target

        let sem = DispatchSemaphore(value: 0)
        var finalResult: Result<String, PluginError>?

        // 构造 Bob 规范的 completion 回调闭包
        let onCompletionBlock: @convention(block) (JSValue) -> Void = { val in
            defer { sem.signal() }
            if val.isObject {
                // 检查 error
                if let errVal = val.objectForKeyedSubscript("error"), !errVal.isUndefined, !errVal.isNull {
                    let msg = errVal.objectForKeyedSubscript("message")?.toString() ?? "插件翻译错误"
                    let addition = errVal.objectForKeyedSubscript("addtion")?.toString()
                    let full = addition != nil && !addition!.isEmpty ? "\(msg) (\(addition!))" : msg
                    finalResult = .failure(PluginError(message: full))
                    return
                }

                // 检查 result
                if let resVal = val.objectForKeyedSubscript("result"), !resVal.isUndefined, !resVal.isNull {
                    // Bob 1.21.0 content 格式
                    if let contentVal = resVal.objectForKeyedSubscript("content"), !contentVal.isUndefined, !contentVal.isNull {
                        let format = contentVal.objectForKeyedSubscript("format")?.toString() ?? "plain"
                        if let resText = contentVal.objectForKeyedSubscript("text")?.toString() {
                            if format == "lines" {
                                finalResult = .success(LineAligner.align(translatedText: resText, to: text))
                            } else {
                                finalResult = .success(resText)
                            }
                            return
                        }
                    }
                    // 词典插件（Cambridge/有道）把词条放在 result.toDict，这里顺手收下来
                    if let dictVal = resVal.objectForKeyedSubscript("toDict"),
                       !dictVal.isUndefined, !dictVal.isNull {
                        Self.lastDictionary = Self.parseDictionary(dictVal)
                    }
                    // toParagraphs 格式兼容（Bob 1.21.0 改为按 format: lines 拼回原文结构）
                    if let parasVal = resVal.objectForKeyedSubscript("toParagraphs"), !parasVal.isUndefined, !parasVal.isNull,
                       let arr = parasVal.toArray() as? [String] {
                        let joined = arr.joined(separator: "\n")
                        finalResult = .success(LineAligner.align(translatedText: joined, to: text))
                        return
                    }
                    // direct text 兼容
                    if let textVal = resVal.objectForKeyedSubscript("text"), !textVal.isUndefined, !textVal.isNull,
                       let t = textVal.toString() {
                        finalResult = .success(t)
                        return
                    }
                }
            }
            finalResult = .failure(PluginError(message: "插件未返回有效翻译结果"))
        }

        // onStream 回调
        let onStreamBlock: @convention(block) (JSValue) -> Void = { val in
            if val.isObject {
                let resVal = val.objectForKeyedSubscript("result")
                let contentVal = resVal?.objectForKeyedSubscript("content")
                if let piece = contentVal?.objectForKeyedSubscript("text").toString() {
                    onStream?(piece)
                }
            }
        }

        // 构造 query JS 对象
        let queryObj = JSValue(newObjectIn: ctx)!
        queryObj.setValue(text, forProperty: "text")
        queryObj.setValue(text, forProperty: "originalText")
        queryObj.setValue(source, forProperty: "from")
        queryObj.setValue(target, forProperty: "to")
        // detectFrom / detectTo 必须是"真实检测出来的语言"，不能原样传 "auto"：
        // Cambridge 这类插件第一步就判断 query.detectFrom === "en"，传 auto 会直接被判成"查不到"。
        let resolvedDetectFrom = detectFrom.isEmpty || detectFrom == "auto"
            ? LanguageDetector.detectLanguage(text) : detectFrom
        let resolvedDetectTo = detectTo.isEmpty || detectTo == "auto" ? target : detectTo
        queryObj.setValue(resolvedDetectFrom, forProperty: "detectFrom")
        queryObj.setValue(resolvedDetectTo, forProperty: "detectTo")
        queryObj.setValue(unsafeBitCast(onCompletionBlock, to: AnyObject.self), forProperty: "onCompletion")
        queryObj.setValue(unsafeBitCast(onStreamBlock, to: AnyObject.self), forProperty: "onStream")

        // 尝试调用 translate(query, completion)
        guard let translateFn = ctx.objectForKeyedSubscript("translate"), !translateFn.isUndefined else {
            return .failure(PluginError(message: "插件缺少全局函数 translate(query, completion)"))
        }

        // 兼容支持传两个参数：query 和 completion
        translateFn.call(withArguments: [queryObj, unsafeBitCast(onCompletionBlock, to: AnyObject.self)])

        if let err = prepared.lastError {
            return .failure(PluginError(message: "插件执行报错：\(err)"))
        }

        // 等待异步 completion 回调（最多等待超时 60s）
        // 必须靠 RunLoop 等待：$http 的回调被派回主线程（JSContext 不是线程安全的），
        // 用 sem.wait 阻塞主线程会把回调永远堵住，表现就是"插件执行超时"。
        var waited: TimeInterval = 0
        while sem.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            waited += 0.02
            if waited >= 60 { break }
        }
        if waited >= 60 {
            return .failure(PluginError(message: "插件执行超时"))
        }

        return finalResult ?? .failure(PluginError(message: "插件未返回结果"))
    }

    /// 检验插件是否支持指定语言列表
    static func querySupportedLanguages(plugin: String) -> [String] {
        guard let prepared = Prepared(plugin: plugin) else { return [] }
        let ctx = prepared.ctx
        guard let fn = ctx.objectForKeyedSubscript("supportLanguages"), !fn.isUndefined else {
            return ["auto", "zh-Hans", "en"]
        }
        let res = fn.call(withArguments: [])
        return (res?.toArray() as? [String]) ?? ["auto", "zh-Hans", "en"]
    }

    /// 直接解压并安装一个 .bobplugin 插件归档包
    static func installBobPlugin(at archiveURL: URL) -> Result<BobPluginInstaller.InstallResult, PluginError> {
        BobPluginInstaller.install(archiveURL: archiveURL)
    }

    // MARK: - 内部上下文准备与环境注入

    final class Prepared {
        let ctx: JSContext
        var lastError: String?
        private let timerManager = PluginTimerManager()
        private var moduleCache: [String: JSValue] = [:]
        private var dataStore: PluginHostKit.DataStore?
        private var mediaResult: (base64: String, texts: [String])?

        var dataStoreHandle: PluginHostKit.DataStore? { dataStore }

        /// 等插件回调。Bob 的插件都是异步回调式，必须把 RunLoop 转起来才收得到。
        func pumpRunLoop(timeout: TimeInterval = 80) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if mediaResult != nil { return }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        func takeMediaResult() -> (base64: String, texts: [String])? {
            defer { mediaResult = nil }
            return mediaResult
        }

        init?(plugin: String) {
            let pluginURL = PluginRuntime.directory.appendingPathComponent(plugin)
            let mainJSURL: URL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: pluginURL.path, isDirectory: &isDir), isDir.boolValue {
                mainJSURL = pluginURL.appendingPathComponent("main.js")
            } else {
                mainJSURL = pluginURL
            }

            guard let code = try? String(contentsOf: mainJSURL, encoding: .utf8),
                  let ctx = JSContext() else { return nil }
            self.ctx = ctx

            ctx.exceptionHandler = { [weak self] _, exception in
                self?.lastError = exception?.toString()
                Debug.log("[plugin error] \(exception?.toString() ?? "")")
            }

            injectAPIs(pluginDir: mainJSURL.deletingLastPathComponent(), pluginID: plugin)
            evaluateEntry(code)
        }

        /// 入口脚本要按 CommonJS 模块跑：新版插件都写 `exports.translate = translate`，
        /// 直接 eval 会报 "Can't find variable: exports"。老插件（0.5.0 时代）是把
        /// `function translate(...)` 直接写在全局，所以两条路都要兜住。
        private func evaluateEntry(_ code: String) {
            let wrapped = """
            (function() {
              var module = { exports: {} };
              var exports = module.exports;
              (function(module, exports, require, __filename, __dirname) {
            \(code)
              })(module, exports, require, "/main.js", "/");
              return module.exports;
            })()
            """
            let exported = ctx.evaluateScript(wrapped)
            var merged = false
            if let exported, exported.isObject {
                for key in ["supportLanguages", "translate", "ocr", "tts",
                            "pluginValidate", "pluginTimeoutInterval", "supportBoundingBox"] {
                    if let value = exported.objectForKeyedSubscript(key), !value.isUndefined {
                        ctx.setObject(value, forKeyedSubscript: key as NSString)
                        merged = true
                    }
                }
            }
            // 老式插件：入口脚本里的函数本来就落在全局，走一遍原始 eval 即可
            if !merged {
                ctx.evaluateScript(code)
            }
        }

        private func injectAPIs(pluginDir: URL, pluginID: String) {
            // 0. Node 风格的 global：不少插件是 webpack 打包的，代码里直接引用 global
            //    （roojay 的 Google 插件就报 "Can't find variable: global"）
            ctx.evaluateScript("""
            (function(){
              var g = this;
              if (typeof g.global === 'undefined') { g.global = g; }
              if (typeof g.globalThis === 'undefined') { g.globalThis = g; }
            }).call(this);
            """)

            // 1. $log
            let logFn: @convention(block) (JSValue) -> Void = { val in
                Debug.log("[plugin log] \(val.toString() ?? "")")
            }
            let logObj = JSValue(object: unsafeBitCast(logFn, to: AnyObject.self), in: ctx)!
            logObj.setValue(unsafeBitCast(logFn, to: AnyObject.self), forProperty: "info")
            logObj.setValue(unsafeBitCast(logFn, to: AnyObject.self), forProperty: "error")
            logObj.setValue(unsafeBitCast(logFn, to: AnyObject.self), forProperty: "warn")
            ctx.setObject(logObj, forKeyedSubscript: "$log" as NSString)

            // 2. $env
            let envObj = JSValue(newObjectIn: ctx)!
            envObj.setValue("LocalTranslate", forProperty: "appName")
            envObj.setValue("1.21.0", forProperty: "version")
            ctx.setObject(envObj, forKeyedSubscript: "$env" as NSString)

            // 3. $info 与 $option 默认值注入（从 info.json 加载）
            let infoURL = pluginDir.appendingPathComponent("info.json")
            let optObj = JSValue(newObjectIn: ctx)!
            if let infoData = try? Data(contentsOf: infoURL),
               let infoDict = (try? JSONSerialization.jsonObject(with: infoData)) as? [String: Any] {
                ctx.setObject(infoDict, forKeyedSubscript: "$info" as NSString)
                if let optionsArr = infoDict["options"] as? [[String: Any]] {
                    // 先铺默认值，再用用户保存的值覆盖——用户在设置里填的 Key 必须生效
                    let saved = PluginOptions.values(for: pluginDir.lastPathComponent)
                    for opt in optionsArr {
                        guard let id = opt["identifier"] as? String else { continue }
                        if let userValue = saved[id] {
                            optObj.setValue(userValue, forProperty: id)
                        } else if let defVal = opt["defaultValue"] {
                            optObj.setValue(defVal, forProperty: id)
                        }
                    }
                }
            } else {
                let defaultInfo: [String: Any] = ["name": pluginDir.lastPathComponent, "identifier": pluginID, "version": "1.0"]
                ctx.setObject(defaultInfo, forKeyedSubscript: "$info" as NSString)
            }
            ctx.setObject(optObj, forKeyedSubscript: "$option" as NSString)

            // 4. $data：完整的二进制对象（OCR 传图、TTS 收音频都靠它）
            let store = PluginHostKit.DataStore()
            self.dataStore = store
            PluginHostKit.installDataBridge(in: ctx, store: store)

            // 5. $file, $timer, $websocket 与内置模块桥
            PluginFileSystem.inject(in: ctx, pluginDir: pluginDir, pluginID: pluginID, store: store)
            timerManager.inject(in: ctx)
            PluginWebSocketBridge.inject(in: ctx, store: store)
            PluginBuiltins.registerCryptoBridge(in: ctx)

            // 6. CommonJS require() 加载器（支持 $util / crypto-js / 相对文件模块）
            let requireFn: @convention(block) (String) -> JSValue? = { [weak self] name in
                self?.loadModule(name: name, pluginDir: pluginDir)
            }
            ctx.setObject(unsafeBitCast(requireFn, to: AnyObject.self), forKeyedSubscript: "require" as NSString)

            // 6. $http：完整契约（回调 / Promise / 二进制 body / streamRequest）
            PluginHostKit.installHTTP(in: ctx, store: store)

            // 7. OCR / TTS 回调需要把图片与音频在 JS 与 Swift 之间搬
            installMediaBridge()
        }

        private func loadModule(name: String, pluginDir: URL) -> JSValue? {
            if let cached = moduleCache[name] { return cached }

            let source: String?
            var resolvedFilename = name
            if name == "$util" {
                source = PluginBuiltins.utilModuleSource
            } else if name == "crypto-js" {
                source = PluginBuiltins.cryptoJSModuleSource
            } else {
                var rel = name
                if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
                else if rel.hasPrefix("/") { rel = String(rel.dropFirst(1)) }
                if !rel.hasSuffix(".js") && !rel.hasSuffix(".json") { rel += ".js" }
                let targetURL = pluginDir.appendingPathComponent(rel)
                resolvedFilename = "/" + rel
                if rel.hasSuffix(".json"), let data = try? Data(contentsOf: targetURL),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let jsVal = JSValue(object: obj, in: ctx) {
                    moduleCache[name] = jsVal
                    return jsVal
                }
                source = try? String(contentsOf: targetURL, encoding: .utf8)
            }

            guard let moduleCode = source else { return nil }
            let wrapper = """
            (function() {
                var module = { exports: {} };
                var exports = module.exports;
                var __filename = \(String(reflecting: resolvedFilename));
                var __dirname = "/";
                (function(module, exports, __filename, __dirname) {
                    \(moduleCode)
                })(module, exports, __filename, __dirname);
                return module.exports;
            })()
            """
            if let exported = ctx.evaluateScript(wrapper) {
                moduleCache[name] = exported
                return exported
            }
            return nil
        }

        // MARK: - OCR / TTS 媒体桥

        /// 插件把图片的 $data 与音频的 base64 交给宿主，靠这两个钩子
        private func installMediaBridge() {
            let finish: @convention(block) (JSValue) -> Void = { [weak self] payload in
                guard let self else { return }
                var base64 = ""
                var texts: [String] = []
                if let result = payload.objectForKeyedSubscript("result"),
                   !result.isUndefined, !result.isNull {
                    if let value = result.objectForKeyedSubscript("value")?.toString() {
                        base64 = value
                    }
                    if let list = result.objectForKeyedSubscript("texts")?.toArray() as? [Any] {
                        for item in list {
                            if let dict = item as? [String: Any], let text = dict["text"] as? String {
                                texts.append(text)
                            } else if let text = item as? String {
                                texts.append(text)
                            }
                        }
                    }
                }
                self.mediaResult = (base64, texts)
            }
            ctx.setObject(unsafeBitCast(finish, to: AnyObject.self), forKeyedSubscript: "__mediaFinish" as NSString)

            let fail: @convention(block) (JSValue) -> Void = { [weak self] payload in
                let message = payload.objectForKeyedSubscript("message")?.toString() ?? "插件返回错误"
                self?.mediaResult = ("", ["__error__:" + message])
            }
            ctx.setObject(unsafeBitCast(fail, to: AnyObject.self), forKeyedSubscript: "__mediaFail" as NSString)
        }
    }
}

// MARK: - 插件 OCR / TTS

extension PluginRuntime {

    struct PluginOCRText {
        var text: String
        var box: CGRect?
    }

    /// 调用插件的 `ocr(query, completion)`
    /// 把插件的 toDict 转成我们卡片用的 DictionaryResult
    private static func parseDictionary(_ value: JSValue) -> DictionaryResult? {
        guard let object = value.toDictionary() as? [String: Any] else { return nil }
        let word = (object["word"] as? String) ?? ""
        var phonetics: [Phonetic] = []
        if let raw = object["phonetics"] as? [[String: Any]] {
            for item in raw {
                let type = (item["type"] as? String) ?? ""
                let text = (item["value"] as? String) ?? ""
                if !text.isEmpty { phonetics.append(Phonetic(type: type, value: text)) }
            }
        }
        var parts: [WordPart] = []
        let partSource = (object["parts"] as? [[String: Any]])
            ?? ((object["additions"] as? [[String: Any]]) ?? [])
        for item in partSource {
            let name = (item["part"] as? String) ?? (item["name"] as? String) ?? ""
            var means: [String] = []
            if let list = item["means"] as? [String] { means = list }
            else if let joined = item["value"] as? String {
                means = joined.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            if !means.isEmpty { parts.append(WordPart(part: name, means: means)) }
        }
        guard !word.isEmpty || !parts.isEmpty else { return nil }
        let result = DictionaryResult(word: word, translations: parts.first?.means ?? [],
                                      phonetics: phonetics, parts: parts, exchanges: [],
                                      collocations: [])
        return result.isEmpty ? nil : result
    }

    static func evaluateOCR(plugin: String, imageData: Data,
                            from: String, detectFrom: String,
                            pixelWidth: Int, pixelHeight: Int) -> Result<(from: String, texts: [PluginOCRText]), PluginError> {
        guard let prepared = Prepared(plugin: plugin) else {
            return .failure(PluginError(message: "插件加载失败：\(plugin)"))
        }
        let ctx = prepared.ctx
        guard let fn = ctx.objectForKeyedSubscript("ocr"), !fn.isUndefined else {
            return .failure(PluginError(message: "这个插件不支持文本识别（没有 ocr 函数）"))
        }
        let query = JSValue(newObjectIn: ctx)!
        if let store = prepared.dataStoreHandle {
            query.setValue(ctx.evaluateScript("__wrapData")?.call(withArguments: [store.create(imageData)]),
                           forProperty: "image")
        }
        query.setValue(from, forProperty: "from")
        query.setValue(detectFrom, forProperty: "detectFrom")
        query.setValue(pixelWidth, forProperty: "pixelWidth")
        query.setValue(pixelHeight, forProperty: "pixelHeight")

        let completion: @convention(block) (JSValue) -> Void = { payload in
            if let error = payload.objectForKeyedSubscript("error"), !error.isUndefined, !error.isNull {
                let message = error.objectForKeyedSubscript("message")?.toString() ?? "识别失败"
                ctx.evaluateScript("__mediaFail")?.call(withArguments: [["message": message]])
                return
            }
            ctx.evaluateScript("__mediaFinish")?.call(withArguments: [payload])
        }
        fn.call(withArguments: [query, unsafeBitCast(completion, to: AnyObject.self)])
        prepared.pumpRunLoop()

        guard let media = prepared.takeMediaResult() else {
            return .failure(PluginError(message: "插件没有回调（ocr 超时）"))
        }
        if let first = media.texts.first, first.hasPrefix("__error__:") {
            return .failure(PluginError(message: String(first.dropFirst("__error__:".count))))
        }
        return .success((from: detectFrom, texts: media.texts.map { PluginOCRText(text: $0, box: nil) }))
    }

    /// 调用插件的 `tts(query, completion)`
    static func evaluateTTS(plugin: String, text: String, lang: String) -> Result<String, PluginError> {
        guard let prepared = Prepared(plugin: plugin) else {
            return .failure(PluginError(message: "插件加载失败：\(plugin)"))
        }
        let ctx = prepared.ctx
        guard let fn = ctx.objectForKeyedSubscript("tts"), !fn.isUndefined else {
            return .failure(PluginError(message: "这个插件不支持语音合成（没有 tts 函数）"))
        }
        let query = JSValue(newObjectIn: ctx)!
        query.setValue(text, forProperty: "text")
        query.setValue(lang, forProperty: "lang")

        let completion: @convention(block) (JSValue) -> Void = { payload in
            if let error = payload.objectForKeyedSubscript("error"), !error.isUndefined, !error.isNull {
                let message = error.objectForKeyedSubscript("message")?.toString() ?? "合成失败"
                ctx.evaluateScript("__mediaFail")?.call(withArguments: [["message": message]])
                return
            }
            ctx.evaluateScript("__mediaFinish")?.call(withArguments: [payload])
        }
        fn.call(withArguments: [query, unsafeBitCast(completion, to: AnyObject.self)])
        prepared.pumpRunLoop()

        guard let media = prepared.takeMediaResult() else {
            return .failure(PluginError(message: "插件没有回调（tts 超时）"))
        }
        if let first = media.texts.first, first.hasPrefix("__error__:") {
            return .failure(PluginError(message: String(first.dropFirst("__error__:".count))))
        }
        guard !media.base64.isEmpty else {
            return .failure(PluginError(message: "插件没有返回音频数据"))
        }
        return .success(media.base64)
    }
}
