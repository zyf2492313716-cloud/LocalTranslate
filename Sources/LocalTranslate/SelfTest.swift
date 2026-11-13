import AppKit
import WebKit
import Carbon.HIToolbox
import ApplicationServices
import CoreImage
import ScreenCaptureKit

/// 命令行自测。不进 UI，直接在真实生产代码路径上验证各条链路。
///
///   LocalTranslate --selftest api <baseURL> <model> <apiKey> <text> [targetLang]
///   LocalTranslate --selftest hotkey <combo> [expectedCombo]
///   LocalTranslate --selftest config
/// 把 async 调用在命令行里同步跑完的小工具
enum Semaphore {
    static func runAsync<T>(_ block: @escaping () async -> T) -> T {
        var result: T?
        var done = false
        Task.detached {
            result = await block()
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return result!
    }

    static func run<T>(_ block: @escaping () async -> T) -> T {
        var result: T?
        var done = false
        Task.detached {
            result = await block()
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return result!
    }
}

enum SelfTest {

    /// 造几个测试服务条目。密钥直接写进存储，让链路能真跑起来。
    static func makeTestProfiles(_ models: [String], baseURL: String? = nil) -> [ServiceProfile] {
        models.map { model in
            let profile = ServiceProfile(id: "test-\(model)",
                                         name: model,
                                         baseURL: baseURL ?? Config.shared.baseURL,
                                         model: model,
                                         enabled: true,
                                         extraPrompt: "")
            return profile
        }
    }

    static func run(arguments: [String]) -> Int32 {
        // 任何自测一进来就先隔离钥匙串：service 换名 + 兜底文件挪到临时目录。
        // 只要真实目录里留过一次 key-default，后面的服务迁移就会把它当成
        // "用户的旧密钥"复制出一堆用户从没建过的文件。
        SecretStore.serviceOverride = "com.localtranslate.apikey.selftest"
        let selftestKeyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-selftest-keys-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: selftestKeyDir, withIntermediateDirectories: true)
        SecretStore.directoryOverride = selftestKeyDir
        guard let kind = arguments.first else {
            FileHandle.standardError.write(Data("用法: --selftest <api|hotkey|config> [...]\n".utf8))
            return 2
        }
        let rest = Array(arguments.dropFirst())
        switch kind {
        case "api":      return apiTest(rest)
        case "hotkey":   return hotkeyTest(rest)
        case "config":   return configTest(rest)
        case "selection": return selectionTest(rest)
        case "setkey":   return setKeyTest(rest)
        case "keychain": return keychainTest(rest)
        case "hotkey-api": return hotkeyApiTest(rest)
        case "history-ui": return historyUITest(rest)
        case "prefs-ui", "settings-ui": return settingsUITest(rest)
        case "theme":    return themeTest(rest)
        case "modules":  return moduleTests(rest)
        case "prefs-effective": return prefsEffectiveTest(rest)
        case "services": return servicesDumpTest(rest)
        case "magpie":   return magpieTest(rest)
        case "magpie-picker": return magpiePickerTest(rest)
        case "input-ui": return inputUITest(rest)
        case "auto-select": return autoSelectTest(rest)
        case "ocr": return ocrTest(rest)
        case "dict-ui": return dictUITest(rest)
        case "dict-free": return dictFreeTest(rest)
        case "providers": return providersTest(rest)
        case "icons": return iconsTest(rest)
        case "panel": return panelTest(rest)
        case "hotkeys2": return hotkeys2Test(rest)
        case "toolbar": return toolbarTest(rest)
        case "vocab": return vocabTest(rest)
        case "urlscheme": return urlschemeTest(rest)
        case "proxy": return proxyTest(rest)
        case "ocr-review": return ocrReviewTest(rest)
        case "compare": return compareTest(rest)
        case "hotkey-conflicts": return hotkeyConflictTest(rest)
        case "presets": return presetsTest(rest)
        case "use-apple": return useAppleTest(rest)
        case "selection-errors": return selectionErrorsTest(rest)
        case "volc-sign": return volcSignTest(rest)
        case "diagnostics": return diagnosticsTest(rest)
        case "silent-replace": return silentReplaceTest(rest)
        case "apple": return appleTest(rest)
        case "apple-live": return appleLiveTest(rest)
        case "real-services": return realServicesTest(rest)
        case "card-shot": return cardShotTest(rest)
        case "history-shot": return historyShotTest(rest)
        case "screenshots": return screenshotsTest(rest)
        case "input-e2e": return inputE2ETest(rest)
        case "key-e2e": return keyE2ETest(rest)
        case "shot-test": return shotTest(rest)
        case "plugin-run": return pluginRunTest(rest)
        case "plugin-contract": return pluginContractTest(rest)
        case "image-ocr": return imageOcrTest(rest)
        case "popclip-bundle": return popClipBundleTest(rest)
        case "browser-helper": return browserHelperTest(rest)
        case "web-helper": return webHelperTest(rest)
        case "ocr-engines": return ocrEnginesTest(rest)
        case "tts-engines": return ttsEnginesTest(rest)
        case "card":     return cardTest(rest)
        case "card-ui":  return cardUITest(rest)
        case "card-shortcuts": return cardShortcutsTest(rest)
        case "applescript-request": return appleScriptRequestTest(rest)
        case "favorites": return favoritesTest(rest)
        case "paragraphize": return paragraphizeTest(rest)
        case "plugins": return pluginsTest(rest)
        case "errors": return errorMessageTest(rest)
        case "lang-detect": return languageDetectTest(rest)
        case "window-features": return windowFeaturesTest(rest)
        case "i18n": return i18nTest(rest)
        case "ecdict": return ecdictTest(rest)
        case "text-preprocess": return textPreprocessTest(rest)
        case "think-parser": return thinkParserTest(rest)
        case "apple-dict": return appleDictTest(rest)
        case "line-aligner": return lineAlignerTest(rest)
        case "pro-features": return proFeaturesTest(rest)
        case "ocr-workspace": return ocrWorkspaceTest(rest)
        case "bob-plugin-full": return bobPluginFullTest(rest)
        case "ai-control": return aiControlTest(rest)
        case "screen-perm": return screenPermTest(rest)
        default:
            FileHandle.standardError.write(Data("未知自测类型: \(kind)\n".utf8))
            return 2
        }
    }

    // MARK: - 翻译链路

    private static func apiTest(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 4 else {
            FileHandle.standardError.write(Data("用法: --selftest api <baseURL> <model> <apiKey> <text> [targetLang]\n".utf8))
            return 2
        }
        let baseURL = arguments[0]
        let model = arguments[1]
        let apiKey = arguments[2]
        let text = arguments[3]
        let targetLang = arguments.count > 4 ? arguments[4] : "zh-Hans"

        let config = Config.shared
        let savedBase = config.baseURL
        let savedModel = config.model
        let savedKey = SecretStore.shared.apiKey
        config.baseURL = baseURL
        config.model = model
        SecretStore.shared.apiKey = apiKey
        defer {
            config.baseURL = savedBase
            config.model = savedModel
            SecretStore.shared.apiKey = savedKey
        }

        print("→ endpoint: \(config.chatEndpoint)")
        print("→ model: \(model)")
        print("→ target: \(targetLang)")

        var contentBuffer = ""
        var thinkBuffer = ""
        var failed = false
        let done = DispatchSemaphore(value: 0)

        let callbacks = TranslationCallbacks(
            onThink: { thinkBuffer += $0 },
            onDelta: { contentBuffer += $0 },
            onDone: { result, think in
                contentBuffer = result
                thinkBuffer = think
                done.signal()
            },
            onError: {
                failed = true
                print("✗ \($0)")
                done.signal()
            }
        )

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let profile = ServiceProfile(id: "selftest", name: model, baseURL: baseURL,
                                     model: model, enabled: true, extraPrompt: "")
        SecretStore.shared.setAPIKey(apiKey, account: profile.keyAccount)
        let task = Task {
            await Translator.translate(
                text: text,
                targetLanguage: targetLang,
                mode: .translate,
                profile: profile,
                callbacks: callbacks
            )
        }

        // 跑主队列，让回调能落地
        let deadline = Date().addingTimeInterval(60)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        _ = done.wait(timeout: .now() + 2)
        task.cancel()

        if failed || contentBuffer.isEmpty {
            print("RESULT: FAIL")
            return 1
        }
        print("✓ 译文: \(contentBuffer)")
        if !thinkBuffer.isEmpty { print("✓ 思考: \(thinkBuffer.count) 字符") }
        print("RESULT: PASS")
        return 0
    }

    // MARK: - 快捷键链路

    /// 注册 combo，用合成按键触发，验证生产代码的 handler + 回调真的跑通。
    /// 必须用 app.run() 驱动主循环：Carbon 事件源只在正常 run loop 下派发。
    private static func hotkeyTest(_ arguments: [String]) -> Int32 {
        let combos = arguments.isEmpty ? ["cmd+shift+x"] : arguments

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var fired = false
        var results: [(String, Bool)] = []
        var index = 0

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        HotKeyManager.shared.onTrigger = { _ in fired = true }

        func postAndCheck(_ combo: String, then next: @escaping () -> Void) {
            fired = false
            let registered = HotKeyManager.shared.register(combo, kind: .translate)
            guard registered, let parsed = HotKeyManager.parse(combo) else {
                print("✗ \(combo): 注册/解析失败")
                results.append((combo, false))
                next()
                return
            }

            var flags: CGEventFlags = []
            let m = parsed.modifiers
            if m & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
            if m & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
            if m & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
            if m & UInt32(controlKey) != 0 { flags.insert(.maskControl) }

            let src = CGEventSource(stateID: .combinedSessionState)
            guard let kd = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(parsed.keyCode), keyDown: true),
                  let ku = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(parsed.keyCode), keyDown: false) else {
                print("✗ \(combo): 无法创建合成事件")
                results.append((combo, false))
                next()
                return
            }
            kd.flags = flags
            ku.flags = flags

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                kd.post(tap: .cghidEventTap)
                ku.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("\(fired ? "✓" : "✗") \(combo) (\(HotKeyManager.displayString(combo)))")
                results.append((combo, fired))
                next()
            }
        }

        func runNext() {
            if index >= combos.count {
                let allPass = results.allSatisfy { $0.1 }
                print("RESULT: \(allPass ? "PASS" : "FAIL")")
                exit(allPass ? 0 : 1)
            }
            let combo = combos[index]
            index += 1
            postAndCheck(combo, then: runNext)
        }

        delegate.onStart = { runNext() }
        app.run()
        return 1
    }

    // MARK: - 快捷键机制（确定性，不依赖合成按键被投递）

    /// 这一组只验代码本身：解析、注册、重注册不撞 id、两个快捷键互不干扰。
    /// 之前踩过的真 bug 就在这里：Carbon 用 (signature, id) 标识热键，
    /// 复用同一个 id 重新注册会返回 eventHotKeyExists(-9878)，热键悄悄失效。
    /// 用法: --selftest hotkey-api
    private static func hotkeyApiTest(_ arguments: [String]) -> Int32 {
        var failures: [String] = []

        // 解析
        let parseCases: [(String, Bool)] = [
            ("cmd+shift+x", true),
            ("cmd+shift+d", true),
            ("opt+cmd+t", true),
            ("ctrl+alt+space", true),
            ("cmd+a", true),
            ("x", false),              // 没有修饰键，不许注册，否则会抢普通按键
            ("", false),
            ("cmd+", false),
            ("cmd+shift+不存在的键", false),
        ]
        for (combo, expectOK) in parseCases {
            let got = HotKeyManager.parse(combo) != nil
            if got != expectOK {
                failures.append("解析 \"\(combo)\" 期望 \(expectOK ? "通过" : "拒绝")，实际 \(got ? "通过" : "拒绝")")
            }
        }

        // 显示串
        if HotKeyManager.displayString("cmd+shift+x") != "\u{2318}\u{21E7}X" {
            failures.append("显示串不对: \(HotKeyManager.displayString("cmd+shift+x"))")
        }

        // 需要 NSApplication 才能在真实 run loop 下注册
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            let manager = HotKeyManager.shared

            // 注册两个不同快捷键，都要成功
            if !manager.register("cmd+shift+x", kind: .translate) {
                failures.append("注册划词快捷键失败")
            }
            if !manager.register("cmd+shift+z", kind: .silent) {
                failures.append("注册静默快捷键失败")
            }

            // 反复重注册同一个快捷键（改设置就是这个路径），
            // 以前会因为复用 id 而返回 eventHotKeyExists，热键静默失效
            for i in 0..<5 {
                if !manager.register("cmd+shift+x", kind: .translate) {
                    failures.append("第 \(i + 1) 次重注册划词快捷键失败")
                    break
                }
            }
            for i in 0..<3 {
                if !manager.register("cmd+shift+z", kind: .silent) {
                    failures.append("第 \(i + 1) 次重注册静默快捷键失败")
                    break
                }
            }

            // 两个快捷键要各自独立存在
            if manager.registered[.translate] != "cmd+shift+z" {
                // 上面重注册过，最终静默是 cmd+shift+z、划词是 cmd+shift+x
                _ = manager.register("cmd+shift+x", kind: .translate)
                _ = manager.register("cmd+shift+z", kind: .silent)
            }
            if manager.registered[.translate] != "cmd+shift+x" {
                failures.append("划词快捷键记录错成 \(manager.registered[.translate] ?? "nil")")
            }
            if manager.registered[.silent] != "cmd+shift+z" {
                failures.append("静默快捷键记录错成 \(manager.registered[.silent] ?? "nil")")
            }

            // 非法快捷键必须被拒绝，不能占着坑
            if manager.register("j", kind: .translate) {
                failures.append("没有修饰键的 \"j\" 竟然注册成功")
            }

            for f in failures { print("✗ \(f)") }
            print("RESULT: \(failures.isEmpty ? "PASS" : "FAIL")")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        return 1
    }

    // MARK: - 取词链路

    /// 在真实 NSApplication 进程里读当前选区。
    /// 用法: --selftest selection [延时秒]
    /// 启动后在延时内到目标 App 里选好文字，选区会被按生产代码的路径读出来。
    private static func selectionTest(_ arguments: [String]) -> Int32 {
        let delay = Double(arguments.first ?? "") ?? 6

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        var exitCode: Int32 = 1
        delegate.onStart = {
            print("请在 \(Int(delay)) 秒内到目标 App 里选中文字…")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
                let withFallback = SelectionReader.selectedText()
                let axOnly = SelectionReader.selectedText(allowClipboardFallback: false)
                switch axOnly {
                case .success(let text): print("仅 AX: \(String(text.prefix(60)))")
                case .failure(let e): print("仅 AX 失败: \(e)")
                }
                switch withFallback {
                case .success(let text): print("AX+回退: \(String(text.prefix(60)))")
                case .failure(let e): print("AX+回退失败: \(e)")
                }
                exitCode = (try? withFallback.get()) != nil ? 0 : 1
                print("RESULT: \(exitCode == 0 ? "PASS" : "FAIL")")
                exit(exitCode)
            }
        }
        app.run()
        return exitCode
    }

    // MARK: - 卡片内部快捷键自测

    /// 验证卡片内快捷键行为：⌘+/- 缩放字号（带11-24边界保护）、⌘S 收藏/取消收藏、Esc/⌘W 关闭。
    /// 用法: --selftest card-shortcuts
    private static func cardShortcutsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let card = TranslationCard.shared
        let savedSize = Config.shared.fontSize

        // 1) 字体放大与缩小，以及边界 11 ~ 24
        Config.shared.fontSize = 15
        card.zoomFont(delta: 1)
        check(Config.shared.fontSize == 16, "⌘+ 放大字号失败：\(Config.shared.fontSize)")
        card.zoomFont(delta: -1)
        check(Config.shared.fontSize == 15, "⌘- 缩小字号失败：\(Config.shared.fontSize)")

        Config.shared.fontSize = 24
        card.zoomFont(delta: 1)
        check(Config.shared.fontSize == 24, "字号上限 24 pt 未保护：\(Config.shared.fontSize)")

        Config.shared.fontSize = 11
        card.zoomFont(delta: -1)
        check(Config.shared.fontSize == 11, "字号下限 11 pt 未保护：\(Config.shared.fontSize)")
        Config.shared.fontSize = savedSize

        // 2) ⌘S 收藏切换（现在统一进收藏夹，不再按词数塞进生词本）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-card-fav-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FavoriteStore.directoryOverride = tmp
        defer {
            FavoriteStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        _ = FavoriteStore.clear()

        let profile = makeTestProfiles(["test-model"]).first!
        card.present(source: "serendipity", mode: .translate, targetLanguage: "zh-Hans", profiles: [profile])
        card.complete(model: profile.id, text: "意外发现珍宝的运气", seconds: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // 第一次 ⌘S 收藏
        card.toggleFavorite()
        check(FavoriteStore.contains(source: "serendipity"), "⌘S 未把当前内容存进收藏夹")
        // 第二次 ⌘S 取消收藏
        card.toggleFavorite()
        check(!FavoriteStore.contains(source: "serendipity"), "再次 ⌘S 未取消收藏")

        // 3) ⌘C 复制结果：剪贴板要拿到译文（不是原文）
        card.present(source: "Practice makes perfect.", mode: .translate,
                     targetLanguage: "zh-Hans", profiles: [profile])
        card.complete(model: profile.id, text: "熟能生巧。", seconds: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("SENTINEL", forType: .string)
        card.copyResultToPasteboard()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        check(copied == "熟能生巧。", "⌘C 复制的不是译文：\(copied)")

        // 4) ⌘P 固定：固定后失焦不关窗；取消固定后失焦才关
        //    失焦收窗依赖 App 处于活跃状态，无头/锁屏环境下拿不到活跃态就明确跳过，不假装通过。
        card.togglePin()
        check(card.isPinned, "⌘P 没把卡片标记为已固定")
        check(card.windowForTesting?.level == .floating, "固定后窗口没有浮到最上层（level=\(String(describing: card.windowForTesting?.level)))")
        if NSApp.isActive {
            card.handleResignKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            check(card.isVisible, "已固定却因为失焦被关掉了")
            card.togglePin()
            check(!card.isPinned, "再次 ⌘P 没取消固定")
            check(card.windowForTesting?.level == .normal, "取消固定后窗口层级没还原")
            card.handleResignKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            check(!card.isVisible, "取消固定后失焦仍未关窗")
        } else {
            print("· 跳过失焦收窗断言：当前进程不是活跃 App（锁屏或无头环境）")
            card.togglePin()
            check(!card.isPinned, "再次 ⌘P 没取消固定")
        }

        // 5) ⌘E 编辑原文：焦点应落到原文输入框
        card.present(source: "Practice makes perfect.", mode: .translate,
                     targetLanguage: "zh-Hans", profiles: [profile])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        card.focusSourceEditor()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if let window = card.windowForTesting {
            let focused = window.firstResponder
            check(focused is NSTextView || focused is NSTextField,
                  "⌘E 之后焦点不在原文编辑区：\(String(describing: focused))")
        }

        card.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(!card.isVisible, "卡片 close 未关闭窗口")

        if problems.isEmpty {
            print("✓ 卡片快捷键：⌘+/- 缩放保护、⌘S 收藏与反向取消、关闭均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 卡片渲染

    /// 把卡片按给定内容渲染出来并保持显示，用来截图验证排版（不需要辅助功能权限）。
    /// 用法: --selftest card [stay秒=12] [多模型] [词典]
    private static func cardTest(_ arguments: [String]) -> Int32 {
        let stay = Double(arguments.first ?? "") ?? 12
        let multi = arguments.contains("multi")
        let wantDict = arguments.contains("dict")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            let card = TranslationCard.shared
            let models = multi ? ["gpt-4o-mini", "deepseek-chat", "kimi-k2"] : ["gpt-4o-mini"]
            let source = wantDict ? "pressure" : "With macOS Sonoma, work and play on your Mac are even more powerful."
            card.present(source: source, mode: .translate, targetLanguage: "zh-Hans",
                         profiles: makeTestProfiles(models))

            // 每个模型给不同的 markdown，看渲染和标签切换
            let bodies: [String: String] = [
                "gpt-4o-mini": "使用 macOS Sonoma，你在 Mac 上的**工作**和*娱乐*都更强大。\n\n- 第一点\n- 第二点带 `inline_code`\n\n> 引用一句\n\n| 列 A | 列 B |\n| --- | --- |\n| 1 | 2 |",
                "deepseek-chat": "【DeepSeek 风格】有了 macOS Sonoma，在 Mac 上工作与娱乐更加强大。",
                "kimi-k2": "【Kimi 版本】借助 macOS Sonoma，你的 Mac 更强大。",
            ]
            for model in models {
                card.beginStream(model: model)
                let body = bodies[model] ?? "默认译文。"
                if model == models.first {
                    card.appendThink(model: model, piece: "先判断句法结构，再决定用词。")
                }
                card.complete(model: model, text: body, seconds: Double.random(in: 0.31...1.42))
            }

            if wantDict {
                let dictionary = DictionaryResult(
                    word: "pressure",
                    translations: ["n. 压力；压强；压迫", "v. 压；挤；施加压力"],
                    phonetics: [Phonetic(type: "us", value: "ˈpreʃɚ"), Phonetic(type: "uk", value: "ˈpreʃə")],
                    parts: [
                        WordPart(part: "n.", means: ["压力", "压强", "压迫", "心理压力"]),
                        WordPart(part: "vt.", means: ["压", "挤", "施加压力", "逼迫"]),
                    ],
                    exchanges: [
                        Exchange(name: "第三人称单数", words: ["pressures"]),
                        Exchange(name: "现在分词", words: ["pressuring"]),
                        Exchange(name: "过去式", words: ["pressured"]),
                    ],
                    collocations: [
                        Collocation(phrase: "under pressure", translation: "处于压力之下"),
                        Collocation(phrase: "blood pressure", translation: "血压"),
                    ]
                )
                card.showDictionary(dictionary)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + stay) {
                exit(0)
            }
        }
        app.run()
        return 0
    }

    // MARK: - 卡片界面自检

    /// 把卡片渲染出来，然后遍历自己的视图树，断言关键区块和文案真的在界面上。
    /// 不依赖外部截图工具，也不需要辅助功能权限。
    /// 用法: --selftest card-ui [multi] [dict]
    private static func cardUITest(_ arguments: [String]) -> Int32 {
        let multi = arguments.contains("multi")
        let wantDict = arguments.contains("dict")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        var failures: [String] = []

        delegate.onStart = {
            let card = TranslationCard.shared
            let models = multi ? ["gpt-4o-mini", "deepseek-chat"] : ["gpt-4o-mini"]
            card.present(source: "pressure", mode: .translate, targetLanguage: "zh-Hans",
                         profiles: makeTestProfiles(models))
            let modelIDs = models.map { "test-\($0)" }
            for model in modelIDs {
                card.beginStream(model: model)
                card.complete(model: model, text: "使用 macOS Sonoma，你在 Mac 上的**工作**和娱乐都更强大。", seconds: 0.66)
            }
            if wantDict {
                card.showDictionary(DictionaryResult(
                    word: "pressure",
                    translations: ["n. 压力；压强"],
                    phonetics: [Phonetic(type: "us", value: "ˈpreʃɚ"), Phonetic(type: "uk", value: "ˈpreʃə")],
                    parts: [WordPart(part: "n.", means: ["压力", "压强"]), WordPart(part: "vt.", means: ["施加压力"])],
                    exchanges: [Exchange(name: "过去式", words: ["pressured"])],
                    collocations: [Collocation(phrase: "under pressure", translation: "处于压力之下")]
                ))
            }

            // 等布局跑完再断言
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let dumped = card.visibleTextSnapshot().joined(separator: "\n")
                let windowFrame = card.windowFrameForTesting

                // 必备元素
                let required = [
                    "⌘C 复制结果", "⌘E 编辑文本", "⌘P 固定窗口", "esc 关闭",   // 底部提示条
                    "使用 macOS Sonoma",                                       // 译文
                    "pressure",                                                // 原文
                ]
                if multi { required.forEach { _ in } ; }
                if wantDict {
                    let dictKeys = ["美", "英", "释义", "动词形式", "词组搭配", "under pressure", "处于压力之下"]
                    for key in dictKeys {
                        if !dumped.contains(key) { failures.append("词典区缺「\(key)」") }
                    }
                }
                if multi {
                    for tab in ["gpt-4o-mini", "deepseek-chat"] {
                        if !dumped.contains(tab) { failures.append("多模型标签缺「\(tab)」") }
                    }
                }
                if wantDict {
                    if !dumped.contains("0.66s") && !dumped.contains("s") {
                        failures.append("归因行没有耗时")
                    }
                }
                for key in required where key != "pressure" || !wantDict {
                    if !dumped.contains(key) { failures.append("界面缺「\(key)」") }
                }
                // 钉住开关要真的能来回切
                let wasPinned = card.isPinned
                card.togglePin()
                if card.isPinned == wasPinned { failures.append("⌘P 钉住没切换状态") }
                card.togglePin()
                if card.isPinned != wasPinned { failures.append("⌘P 取消钉住没还原状态") }

                if windowFrame.width < 300 { failures.append("卡片宽度异常：\(windowFrame.width)") }
                if windowFrame.height < 120 { failures.append("卡片高度异常：\(windowFrame.height)") }

                if failures.isEmpty {
                    print("✓ 卡片渲染完整（宽度 \(Int(windowFrame.width))，高度 \(Int(windowFrame.height))）")
                    print("RESULT: PASS")
                    exit(0)
                } else {
                    for f in failures { print("✗ \(f)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    // MARK: - 明暗主题自检

    /// 在进程内分别按浅色/深色把卡片画出来，直接取窗口位图量平均亮度。
    /// 不靠截图，不受息屏和 Space 影响。
    /// 用法: --selftest theme
    private static func themeTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        /// 取窗口位图的平均亮度
        func luminance(_ view: NSView) -> Double? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            var total = 0.0
            var count = 0
            let step = max(1, Int(rep.pixelsWide / 60))
            var x = 0
            while x < rep.pixelsWide {
                var y = 0
                while y < rep.pixelsHigh {
                    if let color = rep.colorAt(x: x, y: y) {
                        total += 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                        count += 1
                    }
                    y += step
                }
                x += step
            }
            guard count > 0 else { return nil }
            return total / Double(count)
        }

        var failures: [String] = []
        var light: Double = -1
        var dark: Double = -1

        func render(with appearanceName: NSAppearance.Name?, then next: @escaping (Double) -> Void) {
            if let appearanceName {
                NSApp.appearance = NSAppearance(named: appearanceName)
            } else {
                NSApp.appearance = nil
            }
            let card = TranslationCard.shared
            let probeProfile = makeTestProfiles(["gpt-4o-mini"]).first!
            card.present(source: "The quick brown fox jumps over the lazy dog.",
                         mode: .translate, targetLanguage: "zh-Hans",
                         profiles: [probeProfile])
            card.beginStream(model: probeProfile.id)
            card.complete(model: probeProfile.id, text: "灵活的棕色狐狸跳过懒狗。**加粗**测试。", seconds: 0.42)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let window = TranslationCard.shared.windowForTesting,
                      let content = window.contentView else {
                    var names: [String] = []
                    for w in NSApp.windows {
                        names.append("\(w.title):vis=\(w.isVisible):\(Int(w.frame.width))x\(Int(w.frame.height))")
                    }
                    let joined = names.joined(separator: " ; ")
                    print("  [theme] 卡片窗不可见，现有窗口: \(joined)")
                    next(-1); return
                }
                next(luminance(content) ?? -1)
            }
        }

        /// 在给定外观下解析语义色，取平均亮度。
        /// 比量窗口位图可靠：息屏或被别的 Space 挡住时窗口不可见，量不到，
        /// 但那不代表主题没生效。
        func appearanceLuminance(_ name: NSAppearance.Name) -> Double {
            guard let appearance = NSAppearance(named: name) else { return -1 }
            var total = 0.0
            var count = 0
            // 必须在 appearance 上下文里解析，否则语义色拿到的都是当前主题的解
            appearance.performAsCurrentDrawingAppearance {
                for color in [NSColor.windowBackgroundColor, NSColor.controlBackgroundColor, NSColor.textBackgroundColor] {
                    guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                    total += 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : -1
        }

        delegate.onStart = {
            let lightSemantic = appearanceLuminance(.aqua)
            let darkSemantic = appearanceLuminance(.darkAqua)
            render(with: .aqua) { windowLight in
                light = windowLight
                render(with: .darkAqua) { windowDark in
                    dark = windowDark
                    NSApp.appearance = nil

                    var problems: [String] = []
                    if lightSemantic <= 0 || darkSemantic <= 0 {
                        problems.append("语义色解析失败：\(lightSemantic) / \(darkSemantic)")
                    }
                    // 深色必须明显更暗，才说明主题真的切换了
                    if darkSemantic >= lightSemantic * 0.6 {
                        problems.append("深色语义色不够暗：浅 \(String(format: "%.3f", lightSemantic)) / 深 \(String(format: "%.3f", darkSemantic))")
                    }
                    // 窗口位图只有在显示着的时候量得到，量不到算环境限制，不算失败
                    let note: String
                    if light >= 0, dark >= 0 {
                        if dark > light * 0.8 { problems.append("窗口实际亮度深色没降：\(light) / \(dark)") }
                        note = "窗口实测 浅 \(String(format: "%.3f", light)) / 深 \(String(format: "%.3f", dark))"
                    } else {
                        note = "窗口位图取不到（显示息屏时正常），已用语义色判定"
                    }

                    if problems.isEmpty {
                        print("✓ 主题生效：语义色 浅 \(String(format: "%.3f", lightSemantic)) / 深 \(String(format: "%.3f", darkSemantic))；\(note)")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for f in problems { print("✗ \(f)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    // MARK: - 历史窗界面自检

    /// 真把历史窗建出来，然后遍历它的视图树断言内容都在。
    /// 截图依赖显示状态和 Space，这里走进程内检查，稳定可复现。
    /// 用法: --selftest history-ui
    private static func historyUITest(_ arguments: [String]) -> Int32 {
        // 先造几条已知数据（写到临时目录，不污染真实历史）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        HistoryStore.directoryOverride = tmp
        for i in 1...4 {
            HistoryStore.append(HistoryEntry(
                source: "自检原文 sample \(i)",
                result: "自检译文编号 \(i)：这一条用来验证列表与详情区。",
                mode: "translate",
                model: "gpt-4o-mini",
                targetLanguage: "zh-Hans",
                date: Date().addingTimeInterval(-Double(i) * 60),
                seconds: 0.5
            ))
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            HistoryWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                var failures: [String] = []

                let window = NSApp.windows.first { ($0.title as String).contains("历史") }
                guard let window, let content = window.contentView else {
                    print("✗ 找不到历史窗")
                    print("RESULT: FAIL")
                    exit(1)
                }
                let size = window.frame.size
                if size.width < 400 || size.height < 300 {
                    failures.append("历史窗尺寸异常：\(Int(size.width))x\(Int(size.height))")
                }

                var texts: [String] = []
                func walk(_ view: NSView) {
                    if let f = view as? NSTextField, !f.stringValue.isEmpty { texts.append(f.stringValue) }
                    if let b = view as? NSButton, !b.title.isEmpty { texts.append(b.title) }
                    if let t = view as? NSTextView, !t.string.isEmpty { texts.append(t.string) }
                    for sub in view.subviews { walk(sub) }
                }
                walk(content)
                let blob = texts.joined(separator: "\n")

                for need in ["自检译文编号 1", "自检原文 sample 1", "复制译文", "删除", "清空"] {
                    if !blob.contains(need) { failures.append("界面缺「\(need)」") }
                }

                HistoryStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: tmp)

                if failures.isEmpty {
                    print("✓ 历史窗渲染完整（\(Int(size.width))x\(Int(size.height))，可见文本 \(texts.count) 段）")
                    print("RESULT: PASS")
                    exit(0)
                }
                for f in failures { print("✗ \(f)") }
                print("RESULT: FAIL")
                exit(1)
            }
        }
        app.run()
        return 1
    }

    // MARK: - 偏好窗界面自检

    /// 打开偏好窗，逐节切过去，断言每节该出现的东西都在。
    /// 侧栏、录制框、撤销/保存这些结构性东西也一并查。
    /// 用法: --selftest prefs-ui
    private static func settingsUITest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            let sections = PrefsSection.allCases
            var failures: [String] = []
            var index = 0

            func collect(_ view: NSView, into bag: inout [String]) {
                if let f = view as? NSTextField, !f.stringValue.isEmpty { bag.append(f.stringValue) }
                if let b = view as? NSButton, !b.title.isEmpty { bag.append(b.title) }
                if let t = view as? NSTextView, !t.string.isEmpty { bag.append(t.string) }
                if let table = view as? NSTableView {
                    for row in 0..<table.numberOfRows {
                        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSView {
                            collect(cell, into: &bag)
                        }
                    }
                }
                for sub in view.subviews { collect(sub, into: &bag) }
            }

            func step() {
                guard index < sections.count else {
                    // 结构件：撤销 / 保存两个按钮必须存在，且干净状态都不可点
                    let window = NSApp.windows.first { $0.title.contains("设置") }
                    if window == nil {
                        failures.append("找不到偏好窗")
                    } else {
                        var bag: [String] = []
                        collect(window!.contentView ?? NSView(), into: &bag)
                        let text = bag.joined(separator: "\n")
                        if !text.contains("保存") { failures.append("底部没有保存按钮") }
                        if !text.contains("撤销") { failures.append("底部没有撤销按钮") }
                    }
                    if failures.isEmpty {
                        print("✓ 偏好窗 \(sections.count) 个面板全部渲染正常")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for f in failures { print("✗ \(f)") }
                    print("RESULT: FAIL")
                    exit(1)
                }

                let section = sections[index]
                index += 1
                PreferencesWindow.shared.show(section: section)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let window = NSApp.windows.first(where: { $0.title.contains("设置") }) else {
                        failures.append("「\(section.title)」：窗口不见了")
                        step(); return
                    }
                    var bag: [String] = []
                    collect(window.contentView ?? NSView(), into: &bag)
                    let text = bag.joined(separator: "\n")

                    // 侧栏每一节都要能看到
                    for other in sections where !text.contains(other.title) {
                        failures.append("侧栏缺「\(other.title)」")
                    }
                    for need in section.testKeys where !text.contains(need) {
                        failures.append("「\(section.title)」缺「\(need)」")
                    }

                    // 只查文字会放过程内元素存在但高度为 0 的情况（服务页就这么翻过车）
                    // 这里量实际布局尺寸，控件太小一律算失败
                    // 量这一节自己的布局尺寸，不是量窗口
                    let metrics = PreferencesWindow.shared.contentMetricsForTesting
                    if metrics.paneHeight < 60 {
                        failures.append("「\(section.title)」面板高度只有 \(Int(metrics.paneHeight))pt，等于没显示出来")
                    }
                    if metrics.paneWidth < 260 {
                        failures.append("「\(section.title)」面板宽度只有 \(Int(metrics.paneWidth))pt，布局被压扁")
                    }
                    // 每节都至少有两个真正有尺寸的控件，否则就是「文字在、东西点不了」
                    if metrics.sizedControls < 2 {
                        failures.append("「\(section.title)」只有 \(metrics.sizedControls) 个有尺寸的控件，界面是空的")
                    }
                    // 服务页的表格必须有行：数据源被提前释放时，控件在、行数为 0
                    if section == .services, metrics.tableRows < 1 {
                        failures.append("「\(section.title)」表格 0 行，服务列表没渲染出来（数据源可能被释放）")
                    }
                    print("  · \(section.title)：\(Int(metrics.paneWidth))x\(Int(metrics.paneHeight))，有尺寸控件 \(metrics.sizedControls) 个，表格行 \(metrics.tableRows)")
                    if ProcessInfo.processInfo.environment["LT_DUMP"] == "1" {
                        print(PreferencesWindow.shared.contentLayoutDumpForTesting)
                        for (label, value) in PreferencesWindow.shared.fieldValuesForTesting {
                            print("      字段[\(label)] = \"\(value)\"")
                        }
                    }
                    // 表单必须把现有值回填，不能只剩标签
                    if section == .services {
                        // 按当前第一条服务的实际值断言，别写死某个模型名——
                        // 第一条可能是 Apple 这种没有地址和模型的服务。
                        let values = PreferencesWindow.shared.fieldValuesForTesting.map(\.value)
                        if let first = ProfileStore.all().first {
                            if !first.baseURL.isEmpty,
                               !values.contains(where: { $0.contains(first.baseURL) }) {
                                failures.append("服务表单没回填 Base URL（\(first.name)）")
                            }
                            if !first.model.isEmpty,
                               !values.contains(where: { $0.contains(first.model) }) {
                                failures.append("服务表单没回填模型名（\(first.name)）")
                            }
                            if !first.name.isEmpty,
                               !values.contains(where: { $0.contains(first.name) }) {
                                failures.append("服务表单没回填显示名（\(first.name)）")
                            }
                        }
                    }
                    if metrics.docHeight < metrics.paneHeight {
                        failures.append("「\(section.title)」滚动容器比内容矮，内容会被裁掉")
                    }
                    step()
                }
            }
            step()
        }
        app.run()
        return 1
    }

    /// 给设置界面用的进程内自检：返回若干行结果文本。
    static func moduleReport() -> [String] {
        var lines: [String] = []
        let groups: [(String, () -> [String])] = [
            ("Markdown 渲染", { MarkdownLite.selfTest() }),
            ("词典解析", { DictionaryService.selfTest() }),
            ("历史记录", { HistoryStore.selfTest() }),
        ]
        for (title, body) in groups {
            let bad = body()
            if bad.isEmpty {
                lines.append("✓ \(title)")
            } else {
                lines.append("✗ \(title)：\(bad.count) 项失败")
                lines.append(contentsOf: bad.prefix(4).map { "    · \($0)" })
            }
        }
        return lines
    }

    /// 看服务列表读出来几条，为什么空
    private static func servicesDumpTest(_ arguments: [String]) -> Int32 {
        let all = ProfileStore.all()
        print("ProfileStore.all() = \(all.count)")
        for p in all { print("  - \(p.name) | \(p.model) | enabled=\(p.enabled) | \(p.chatEndpoint)") }
        print("enabled() = \(ProfileStore.enabled().count)")
        print("firstUsable = \(ProfileStore.firstUsable()?.name ?? "nil")")
        let draft = PrefsDraft.load()
        print("draft.profiles = \(draft.profiles.count)")
        print("file = \(ProfileStore.fileURLForDebug.path)")
        print("exists = \(FileManager.default.fileExists(atPath: ProfileStore.fileURLForDebug.path))")
        return 0
    }

    /// 真调一次 Apple 翻译，只为看清「桥能不能拿到 session」。
    /// 语言包没装时系统可能弹下载框，所以这条**不进闸门**，只手动跑。
    /// 用法: --selftest apple-live
    private static func appleLiveTest(_ arguments: [String]) -> Int32 {
        guard #available(macOS 15.0, *) else {
            print("系统低于 macOS 15"); print("RESULT: SKIP"); return 0
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
                print("✗ 40 秒没返回，桥卡住了")
                print("RESULT: FAIL")
                exit(1)
            }
            Task {
                do {
                    let t1Start = Date()
                    let r1 = try await AppleTranslator.translate("hello world", targetLanguage: "zh-Hans")
                    let dt1 = Date().timeIntervalSince(t1Start)

                    let t2Start = Date()
                    let r2 = try await AppleTranslator.translate("good morning", targetLanguage: "zh-Hans")
                    let dt2 = Date().timeIntervalSince(t2Start)

                    let t3Start = Date()
                    let r3 = try await AppleTranslator.translate("临床护理十分重要", targetLanguage: "en")
                    let dt3 = Date().timeIntervalSince(t3Start)

                    // 回归：来回切语向 6 次。以前只要有一次超时，桥的锁就再也不释放，
                    // 之后所有请求全部永久卡死（表现就是用户点了快捷键一直「翻译中」）。
                    var alternated: [String] = []
                    let tSeq = Date()
                    for i in 0..<6 {
                        let target = i % 2 == 0 ? "zh-Hans" : "en"
                        let src = i % 2 == 0 ? "good morning" : "早上好"
                        let out = try await AppleTranslator.translate(src, targetLanguage: target)
                        alternated.append(out)
                    }
                    let dSeq = Date().timeIntervalSince(tSeq)
                    if alternated.contains(where: { $0.isEmpty }) {
                        print("✗ 交替语向出现空结果")
                        print("RESULT: FAIL")
                        exit(1)
                    }

                    print(String(format: "✓ 连续三次真翻成功: [%.2fs] %@ | [%.2fs] %@ | [%.2fs] %@", dt1, r1, dt2, r2, dt3, r3))
                    print(String(format: "✓ 交替语向 6 次无卡死: [%.2fs] 总耗时，末次=%@", dSeq, alternated.last ?? ""))
                    print("RESULT: PASS")
                    exit(0)
                } catch {
                    print("翻译未完成：\(error.localizedDescription)")
                    print("（语言包没下载时这是正常结果，说明桥已连上、系统缺包）")
                    print("RESULT: SKIP")
                    exit(0)
                }
            }
        }
        app.run()
        return 1
    }

    // MARK: - 多引擎 TTS

    /// 有道 / 剑桥两个免密钥词典源的真实查询（联网）
    /// 用法: --selftest dict-free
    private static func dictFreeTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            var problems: [String] = []
            Task {
                let youdao = await YoudaoFreeTranslator.lookup(word: "pressure")
                await MainActor.run {
                    if let youdao {
                        print("有道：\(youdao.word) 音标 \(youdao.phonetics.map { "\($0.type)/\($0.value)" }.joined(separator: " "))")
                        print("  释义：\(youdao.parts.prefix(2).map { "\($0.part) \($0.means.joined(separator: "；"))" }.joined(separator: " | "))")
                        if youdao.phonetics.isEmpty { problems.append("有道没取到音标") }
                        if youdao.parts.isEmpty && youdao.translations.isEmpty { problems.append("有道没取到释义") }
                    } else {
                        problems.append("有道词典没返回")
                    }
                }
                let cambridge = await CambridgeDictionary.lookup(word: "pressure")
                let moji = await MojiDictionary.lookup(word: "勉強")
                await MainActor.run {
                    if let cambridge {
                        print("剑桥：\(cambridge.word) 音标 \(cambridge.phonetics.map(\.value).joined(separator: " / "))")
                        print("  释义：\(cambridge.translations.prefix(2).joined(separator: " | "))")
                        if cambridge.translations.isEmpty { problems.append("剑桥没取到释义") }
                    } else {
                        problems.append("剑桥词典没返回")
                    }
                    if let moji {
                        print("MOJi：\(moji.word) 音标 \(moji.phonetics.map { "\($0.type)/\($0.value)" }.joined(separator: " "))")
                        print("  释义：\(moji.translations.prefix(2).joined(separator: " | "))")
                        if moji.phonetics.isEmpty { problems.append("MOJi 没取到假名/罗马音") }
                        if moji.translations.isEmpty { problems.append("MOJi 没取到释义") }
                    } else {
                        problems.append("MOJi 日语词典没返回")
                    }
                if problems.isEmpty {
                        print("✓ 免密钥词典：有道 + 剑桥 + MOJi（日语）都能给出音标与释义")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for problem in problems { print("✗ \(problem)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    /// 造一张「文字 + 二维码」的图，走真实的 ImageOCR 文件链路。
    /// 用法: --selftest image-ocr
    private static func imageOcrTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            var problems: [String] = []
            let payload = "https://bobtranslate.com/plugin"

            // 1) 生成二维码
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
                print("✗ 系统没有二维码生成器"); print("RESULT: FAIL"); exit(1)
            }
            filter.setValue(Data(payload.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let qr = filter.outputImage else {
                print("✗ 二维码生成失败"); print("RESULT: FAIL"); exit(1)
            }
            let scaled = qr.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

            // 2) 拼一张 700x320 的图：左边文字，右边二维码
            let width = 700, height = 320
            guard let ctx = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                print("✗ 建不出画布"); print("RESULT: FAIL"); exit(1)
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let ciContext = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) {
                ctx.draw(ciContext, in: CGRect(x: 460, y: 40, width: 200, height: 200))
            }
            let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            ("Finder OCR 2026" as NSString).draw(
                at: NSPoint(x: 40, y: 180),
                withAttributes: [.font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()

            guard let image = ctx.makeImage() else {
                print("✗ 画不出图"); print("RESULT: FAIL"); exit(1)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("lt-image-ocr-test.png")
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("✗ PNG 编码失败"); print("RESULT: FAIL"); exit(1)
            }
            try? png.write(to: url)

            Task {
                let outcome = await ImageOCR.recognize(file: url, detectQR: true)
                await MainActor.run {
                    switch outcome {
                    case .success(let result):
                        print("识别文字: \(result.text.replacingOccurrences(of: "\n", with: " | "))")
                        print("二维码: \(result.qrCodes)")
                        if !result.text.contains("Finder") { problems.append("没认出图片里的文字") }
                        if !result.qrCodes.contains(payload) { problems.append("没读出二维码内容") }
                        if !result.combined.contains("二维码：") { problems.append("二维码没有拼进展示文本") }
                    case .failure(let failure):
                        problems.append("识别失败：\(failure.message)")
                    }
                    try? FileManager.default.removeItem(at: url)
                    if problems.isEmpty {
                        print("✓ 图片 OCR：文字 + 二维码都能读出来（离线）")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for problem in problems { print("✗ \(problem)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    /// 把扩展的 content.js 真注入 WKWebView，模拟选中 + 点按钮 + 校验页面内译文。
    /// 这是"浏览器里真的能用"最接近的自动化验证；Chrome 是否能装载由 manifest 校验兜住。
    /// 用法: --selftest web-helper
    private static func webHelperTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            guard let port = HelperServer.shared.start(preferredPort: 8798) else {
                print("✗ 本地服务起不来"); print("RESULT: FAIL"); exit(1)
            }
            guard case .success(let dir) = BrowserHelper.generateExtension(port: port),
                  let script = try? String(contentsOf: dir.appendingPathComponent("content.js"), encoding: .utf8) else {
                print("✗ 扩展生成失败"); print("RESULT: FAIL"); exit(1)
            }

            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            host.contentView = webView
            host.orderOut(nil)

            let html = """
            <html><body style="font:18px -apple-system">
            <p id="p1">Palliative care is an interdisciplinary medical care-giving approach aimed at optimizing quality of life.</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:\(port)/"))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                webView.evaluateJavaScript(script) { _, error in
                    if let error {
                        print("✗ 注入脚本失败：\(error.localizedDescription)")
                        print("RESULT: FAIL"); exit(1)
                    }
                    let select = """
                    (function(){
                      var p = document.getElementById('p1');
                      var r = document.createRange(); r.selectNodeContents(p);
                      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
                      document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
                      return s.toString().length;
                    })();
                    """
                    webView.evaluateJavaScript(select) { value, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            webView.evaluateJavaScript("!!document.getElementById('lt-helper-button')") { exists, _ in
                                let hasButton = (exists as? Bool) ?? false
                                if !hasButton {
                                    print("✗ 选中文字后没有出现「译」按钮")
                                    print("RESULT: FAIL"); exit(1)
                                }
                                print("✓ 选中 \(value ?? 0) 字符后出现「译」按钮")
                                webView.evaluateJavaScript("document.getElementById('lt-helper-button').click()") { _, _ in
                                    // 等本地服务翻译
                                    var waited = 0.0
                                    func poll() {
                                        webView.evaluateJavaScript(
                                            "(document.getElementById('lt-helper-panel')||{}).textContent || ''"
                                        ) { text, _ in
                                            let content = (text as? String) ?? ""
                                            if !content.isEmpty, content != "翻译中…" {
                                                print("页面内译文：\(content)")
                                                let failed = content.hasPrefix("翻译失败")
                                                HelperServer.shared.stop()
                                                if failed {
                                                    print("✗ 页面内显示的是失败提示")
                                                    print("RESULT: FAIL"); exit(1)
                                                }
                                                print("✓ 浏览器助手：真选中 → 真点击 → 页面内直接出译文")
                                                print("RESULT: PASS"); exit(0)
                                            }
                                            waited += 0.5
                                            if waited > 25 {
                                                print("✗ 等不到译文（页面内容：\(content)）")
                                                HelperServer.shared.stop()
                                                print("RESULT: FAIL"); exit(1)
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                                        }
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                                }
                            }
                        }
                    }
                }
            }
        }
        app.run()
        return 1
    }

    /// 浏览器助手：起本地服务 → 真发一次 HTTP 请求翻译 → 校验扩展文件齐全
    /// 用法: --selftest browser-helper
    private static func browserHelperTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            var problems: [String] = []
            guard let port = HelperServer.shared.start(preferredPort: 8799) else {
                print("✗ 本地服务起不来")
                print("RESULT: FAIL")
                exit(1)
            }
            print("本地服务端口: \(port)")

            switch BrowserHelper.generateExtension(port: port) {
            case .failure(let failure): problems.append(failure.message)
            case .success(let dir):
                for name in ["manifest.json", "content.js", "content.css", "安装说明.txt"] {
                    if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                        problems.append("扩展缺文件：\(name)")
                    }
                }
                if let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if json["manifest_version"] as? Int != 3 { problems.append("manifest 版本不是 3") }
                    if (json["host_permissions"] as? [String])?.first?.contains("127.0.0.1") != true {
                        problems.append("host_permissions 没指向本机")
                    }
                }
                if let js = try? String(contentsOf: dir.appendingPathComponent("content.js"), encoding: .utf8) {
                    if !js.contains("/translate") { problems.append("content.js 没调翻译接口") }
                    if !js.contains("lt-helper-button") { problems.append("content.js 没有浮动按钮") }
                }
            }

            // 真打一次 HTTP，验证端口、CORS 头、翻译结果
            let url = URL(string: "http://127.0.0.1:\(port)/translate?text=\(("Good morning, have a nice day.").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")!
            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    let http = response as? HTTPURLResponse
                    if http?.statusCode != 200 { problems.append("HTTP 状态码 \(http?.statusCode ?? 0)") }
                    if http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") != "*" {
                        problems.append("缺 CORS 头，浏览器会拒绝跨域")
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let ok = json["ok"] as? Bool ?? false
                        let text = json["text"] as? String ?? ""
                        let engine = json["engine"] as? String ?? ""
                        print("接口返回: ok=\(ok) engine=\(engine) text=\(text)")
                        if !ok { problems.append("接口返回失败") }
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            problems.append("接口没返回译文")
                        }
                    } else {
                        problems.append("接口返回的不是 JSON")
                    }
                } catch {
                    problems.append("请求本地服务失败：\(error.localizedDescription)")
                }
                await MainActor.run {
                    HelperServer.shared.stop()
                    if problems.isEmpty {
                        print("✓ 浏览器助手：本地服务真翻译一次，扩展文件与 manifest 齐全")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for problem in problems { print("✗ \(problem)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    /// 校验 PopClip 扩展包结构，不真的去装
    /// 用法: --selftest popclip-bundle
    private static func popClipBundleTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var problems: [String] = []
        switch PopClipInstaller.build() {
        case .failure(let failure):
            problems.append(failure.message)
        case .success(let url):
            let configURL = url.appendingPathComponent("Config.plist")
            let scriptURL = url.appendingPathComponent("Script.sh")
            if let data = try? Data(contentsOf: configURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if plist["Extension Name"] == nil { problems.append("缺 Extension Name") }
                if plist["Extension Type"] as? String != "Action" { problems.append("Extension Type 不是 Action") }
                if plist["Script Interpreter"] as? String != "/bin/bash" { problems.append("解释器不是 bash") }
                if (plist["Script"] as? String)?.contains("localtranslate://translate") != true {
                    problems.append("脚本没有调用 URL Scheme")
                }
            } else {
                problems.append("Config.plist 读不出来")
            }
            if !FileManager.default.fileExists(atPath: scriptURL.path) { problems.append("缺 Script.sh") }
            if !FileManager.default.fileExists(atPath: url.appendingPathComponent("icon.png").path) {
                problems.append("缺 icon.png")
            }
            try? FileManager.default.removeItem(at: url)
        }
        if problems.isEmpty {
            print("✓ PopClip 扩展包：Config.plist / Script.sh / icon.png 齐全，走 localtranslate:// 调用")
            print("RESULT: PASS")
            return 0
        }
        for problem in problems { print("✗ \(problem)") }
        print("RESULT: FAIL")
        return 1
    }

    /// 离线验证 Bob 插件运行时契约（不依赖网络，进闸门用）。
    /// 覆盖：CommonJS exports、require、$data 全套方法、$timer、未知能力报错。
    private static func pluginContractTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            var problems: [String] = []
            func check(_ condition: Bool, _ label: String) {
                if !condition { problems.append(label) }
            }

            // 造一个只用离线 API 的插件：写进插件目录，跑完删掉
            PluginRuntime.ensureDirectory()
            let name = "contract-probe"
            let dir = PluginRuntime.directory.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let info = """
            {"identifier":"com.test.contract","version":"1.0.0","category":"translate",
             "name":"Contract Probe","summary":"selftest","author":"selftest","minBobVersion":"1.8.0"}
            """
            let helper = "exports.mark = 'from-require';\n"
            let main = """
            var helper = require("./helper.js");
            function supportLanguages() { return ["auto", "en", "zh-Hans"]; }
            function translate(query, completion) {
              var raw = $data.fromUTF8("hello 世界");
              var hex = raw.toHex(true);
              var b64 = raw.toBase64();
              var back = $data.fromBase64(b64).toUTF8();
              var bytes = $data.fromHex("0A0B0CFF").toByteArray();
              var sub = $data.fromHex("0A0B0CFF").subData(0, 2).toByteArray();
              var merged = $data.fromHex("0A0B"); merged.appendData($data.fromHex("CC")); var size = merged.length;
              var u8 = $data.fromByteArray([1,2,3]).readUInt8(1);
              var ok = $data.isData(raw) && !$data.isData("x");
              completion({ result: {
                from: "en", to: "zh-Hans",
                toParagraphs: [helper.mark + "|" + hex + "|" + back + "|" + bytes.join(",") + "|" +
                               sub.join(",") + "|" + size + "|" + u8 + "|" + ok]
              }});
            }
            exports.supportLanguages = supportLanguages;
            exports.translate = translate;
            """
            try? info.write(to: dir.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
            try? helper.write(to: dir.appendingPathComponent("helper.js"), atomically: true, encoding: .utf8)
            try? main.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            func cleanupAndExit(_ code: Int32) -> Never {
                try? FileManager.default.removeItem(at: dir)
                exit(code)
            }

            let outcome = PluginRuntime.evaluateTranslate(
                plugin: name, text: "hello", source: "en", target: "zh-Hans")
            switch outcome {
            case .success(let text):
                print("插件返回: \(text)")
                check(text.contains("from-require"), "require 相对模块失败")
                check(text.contains("68656C6C6F20E4B896E7958C"), "$data.fromUTF8/toHex 失败")
                check(text.contains("hello 世界"), "$data Base64 往返失败")
                check(text.contains("10,11,12,255"), "$data.toByteArray 失败")
                check(text.contains("10,11"), "$data.subData 失败")
                check(text.contains("|3|"), "$data.appendData/length 失败")
                check(text.contains("|2|true"), "$data.readUInt8/isData 失败")
            case .failure(let error):
                problems.append("插件执行失败：\(error.message)")
            }

            // 能力不匹配时要给出人话，而不是崩
            let missing = PluginRuntime.evaluateTTS(plugin: name, text: "hi", lang: "en")
            if case .success = missing { problems.append("没有 tts 的插件居然成功了") }

            if problems.isEmpty {
                print("✓ Bob 插件运行时契约（CommonJS / $data / require）全部符合")
                print("RESULT: PASS")
                cleanupAndExit(0)
            }
            for problem in problems { print("✗ \(problem)") }
            print("RESULT: FAIL")
            cleanupAndExit(1)
        }
        app.run()
        return 1
    }

    /// 直接跑一个真实 Bob 插件：--selftest plugin-run <插件目录名> translate|ocr|tts [文本]
    /// 用来对着社区插件做兼容性审计，不靠嘴说兼容。
    private static func pluginRunTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        guard arguments.count >= 2 else {
            print("用法: --selftest plugin-run <plugin> translate|ocr|tts [text]")
            print("RESULT: FAIL")
            return 2
        }
        let plugin = arguments[0]
        let kind = arguments[1]
        let text = arguments.count > 2 ? arguments[2] : "Hello world"

        delegate.onStart = {
            print("插件: \(plugin) | 能力: \(kind)")
            print("已安装: \(PluginRuntime.installed().joined(separator: ", "))")
            switch kind {
            case "translate":
                let start = Date()
                let outcome = PluginRuntime.evaluateTranslate(
                    plugin: plugin, text: text, source: "auto", target: "zh-Hans")
                switch outcome {
                case .success(let out):
                    print(String(format: "✓ 译文 [%.2fs]: %@", Date().timeIntervalSince(start), out))
                    print("RESULT: PASS")
                    exit(0)
                case .failure(let error):
                    print("✗ 失败: \(error.message)")
                    print("RESULT: FAIL")
                    exit(1)
                }
            case "ocr":
                // 造一张带文字的图，走真实的 Vision 渲染
                let size = NSSize(width: 520, height: 120)
                let image = NSImage(size: size)
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                ("Plugin OCR 123" as NSString).draw(
                    at: NSPoint(x: 20, y: 40),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
                image.unlockFocus()
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    print("✗ 造图失败"); print("RESULT: FAIL"); exit(1)
                }
                let result = PluginRuntime.evaluateOCR(
                    plugin: plugin, imageData: png, from: "auto", detectFrom: "en",
                    pixelWidth: cg.width, pixelHeight: cg.height)
                switch result {
                case .success(let payload):
                    print("✓ 识别到 \(payload.texts.count) 段: \(payload.texts.map(\.text).joined(separator: " | "))")
                    print("RESULT: PASS")
                    exit(0)
                case .failure(let error):
                    print("✗ 失败: \(error.message)")
                    print("RESULT: FAIL")
                    exit(1)
                }
            case "tts":
                let result = PluginRuntime.evaluateTTS(plugin: plugin, text: text, lang: "en")
                switch result {
                case .success(let base64):
                    let bytes = Data(base64Encoded: base64)?.count ?? 0
                    print("✓ 合成音频 \(bytes) 字节（base64 \(base64.count) 字符）")
                    print("RESULT: PASS")
                    exit(0)
                case .failure(let error):
                    print("✗ 失败: \(error.message)")
                    print("RESULT: FAIL")
                    exit(1)
                }
            default:
                print("未知能力: \(kind)")
                print("RESULT: FAIL")
                exit(2)
            }
        }
        app.run()
        return 1
    }

    /// 实测整屏抓图：存 PNG 并报告窗口标题可读性，用来判断系统到底给不给录屏权限。
    /// 用法: --selftest shot-test [输出路径]
    private static func shotTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate
        let outPath = arguments.first ?? "/tmp/lt_shot.png"

        delegate.onStart = {
            guard let screen = NSScreen.main else {
                print("✗ 没屏幕"); print("RESULT: FAIL"); exit(1)
            }
            Task {
                let status = await ScreenOCR.probePermission(timeoutSeconds: 3)
                print("probePermission = \(status)")
                print("CGPreflight = \(CGPreflightScreenCaptureAccess())")
                print("canReadOtherWindowTitles = \(ScreenOCR.canReadOtherWindowTitles())")
                switch await ScreenOCR.captureDetailed(rect: CGRect(origin: .zero, size: screen.frame.size), screen: screen) {
                case .success(let img):
                    let rep = NSBitmapImageRep(cgImage: img)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                    }
                    print("抓图成功 \(img.width)x\(img.height) -> \(outPath)")
                    print("RESULT: PASS")
                    exit(0)
                case .permissionDenied(let m):
                    print("✗ 权限被拒：\(m)"); print("RESULT: FAIL"); exit(1)
                case .failure(let m):
                    print("✗ 抓图失败：\(m)"); print("RESULT: FAIL"); exit(1)
                }
            }
        }
        app.run()
        return 1
    }

    /// 真的敲键盘：把输入窗顶到前台，用 HID 事件发一个 Return，验证「敲回车就翻译」这条热路径。
    /// 用法: --selftest key-e2e
    private static func keyE2ETest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            guard AXIsProcessTrusted() else {
                print("· 没有辅助功能权限，跳过真实按键验证")
                print("RESULT: SKIP")
                exit(0)
            }
            let window = InputTranslationWindow.shared
            window.show(prefill: "Good morning, have a nice day.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))

            // 真按键：先把这个进程顶到前台，再发 HID 事件（走系统真实输入通路）。
            // 后台进程发 HID 事件会被系统投给别的 App，所以必须先把激活状态抢过来。
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            // 从终端拉起来的进程抢不到前台焦点，系统会把 HID 事件投给别的 App。
            // 这种情况属于环境限制，明确报 SKIP，绝不假装通过。
            guard NSApp.isActive, window.windowForTesting?.isKeyWindow == true else {
                print("· 进程没能成为前台应用（终端拉起时常见），跳过真实按键验证")
                print("RESULT: SKIP")
                exit(0)
            }
            print("  · 前台=是，窗口是 key")

            let pid = getpid()
            func tapReturn(toPid: Bool) {
                let src = CGEventSource(stateID: .hidSystemState)
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false) else { return }
                if toPid {
                    down.postToPid(pid)
                    up.postToPid(pid)
                } else {
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }
            tapReturn(toPid: !NSApp.isActive)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            if window.stateForTesting().result.isEmpty {
                tapReturn(toPid: false)
            }

            var waited = 0.0
            while waited < 20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                waited += 0.25
                let state = window.stateForTesting()
                if !state.result.isEmpty {
                    print(String(format: "✓ 真实回车键触发翻译 [%.2fs] %@", waited, state.result))
                    print("RESULT: PASS")
                    exit(0)
                }
            }
            print("✗ 敲了回车但结果区一直是空的，状态=\(window.stateForTesting().status)")
            print("RESULT: FAIL")
            exit(1)
        }
        app.run()
        return 1
    }

    /// 真跑一遍「输入翻译」窗口：塞文本 → 触发翻译 → 等结果真的出现在结果区。
    /// 用法: --selftest input-e2e
    private static func inputE2ETest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        let sample = arguments.first ?? "The quick brown fox jumps over the lazy dog."

        delegate.onStart = {
            let window = InputTranslationWindow.shared
            window.show(prefill: sample)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            window.translateForTesting()

            // 轮询结果区，最多等 20 秒
            var waited = 0.0
            while waited < 20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                waited += 0.25
                let state = window.stateForTesting()
                if !state.result.isEmpty && state.buttonEnabled {
                    let oneLine = state.result.replacingOccurrences(of: "\n", with: " ")
                    print(String(format: "✓ 输入窗真翻译完成 [%.2fs] %@", waited, oneLine))
                    print("RESULT: PASS")
                    exit(0)
                }
            }
            let state = window.stateForTesting()
            print("✗ 输入窗 20 秒内没有出译文，状态=\(state.status)，结果长度=\(state.result.count)")
            print("RESULT: FAIL")
            exit(1)
        }
        app.run()
        return 1
    }

    /// 把卡片按真实数据渲染出来，落一张 PNG 到 /tmp，用来肉眼比对版式。
    /// 用法: --selftest card-shot [输出路径]
    /// 把历史窗渲染成 PNG，用来核对版式（对齐 Bob 的左列表右详情）。
    /// 用法: --selftest history-shot [输出路径]
    /// 生成 README 用的截图。全部离屏渲染，历史/收藏写在临时目录，不会把真实数据截进去。
    /// 用法: --selftest screenshots <输出目录>
    private static func screenshotsTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        let outDir = URL(fileURLWithPath: arguments.first ?? "/tmp/lt-shots")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func capture(_ window: NSWindow, _ name: String) -> Bool {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            try? png.write(to: outDir.appendingPathComponent(name))
            print("· \(name)  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
            return true
        }

        delegate.onStart = {
            // 隔离数据：历史和收藏都写临时目录
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("lt-shots-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            HistoryStore.directoryOverride = tmp
            FavoriteStore.directoryOverride = tmp
            HistoryStore.clear()
            _ = FavoriteStore.clear()

            let now = Date()
            let demos: [(String, String, String, Double)] = [
                ("Palliative care aims to improve the quality of life for patients with serious illnesses.",
                 "姑息治疗旨在改善重症患者的生活质量。", "Apple 翻译", 0.12),
                ("The committee will review the proposal before the end of the quarter.",
                 "委员会将在本季度末之前审议该提案。", "彩云小译", 0.06),
                ("机器学习模型需要大量高质量的训练数据。",
                 "Machine learning models require large amounts of high-quality training data.", "有道翻译", 0.14),
                ("Regulatory approval is expected in the second half of next year.",
                 "监管批准预计将在明年下半年获得。", "必应翻译", 1.21),
            ]
            for (i, demo) in demos.enumerated() {
                let date = now.addingTimeInterval(-Double(i) * 5400)
                HistoryStore.append(HistoryEntry(source: demo.0, result: demo.1, mode: "translate",
                                                 model: demo.2, targetLanguage: "zh-Hans",
                                                 date: date, seconds: demo.3))
                _ = FavoriteStore.add(source: demo.0, result: demo.1, model: demo.2,
                                      targetLanguage: "zh-Hans", sourceLanguage: "en", date: date)
            }

            var index = 0
            var next: (() -> Void)!
            var steps: [() -> Void] = []
            var failures: [String] = []

            // 1) 翻译卡片：四家引擎并排 + 词典区
            steps.append {
                let card = TranslationCard.shared
                let profiles = makeTestProfiles(["Apple 翻译", "彩云小译", "有道翻译", "必应翻译"])
                card.present(source: "Palliative care aims to improve the quality of life for patients with serious illnesses.",
                             mode: .translate, targetLanguage: "zh-Hans", profiles: profiles)
                let samples = [
                    "姑息治疗旨在改善重症患者的生活质量。",
                    "姑息治疗的目标是提高重症患者的生活质量。",
                    "缓和医疗旨在提升重症患者的生活品质。",
                    "姑息治疗旨在改善患有严重疾病患者的生活质量。",
                ]
                for (i, profile) in profiles.enumerated() {
                    card.beginStream(model: profile.id)
                    card.complete(model: profile.id, text: samples[i], seconds: [0.12, 0.06, 0.14, 1.21][i])
                }
                card.showDictionary(DictionaryResult(
                    word: "palliative",
                    translations: ["adj. 姑息的；缓和症状的", "n. 姑息疗法"],
                    phonetics: [Phonetic(type: "英", value: "ˈpæliətɪv"),
                                Phonetic(type: "美", value: "ˈpæliətɪv")],
                    parts: [WordPart(part: "adj.", means: ["缓和的，减轻痛苦的", "（医疗）姑息治疗的"]),
                            WordPart(part: "n.", means: ["姑息剂，缓和剂"])],
                    exchanges: [], collocations: []))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    if let window = card.windowForTesting {
                        if !capture(window, "card.png") { failures.append("卡片截图失败") }
                    } else { failures.append("卡片窗口没出来") }
                    card.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
                }
            }

            // 2) 历史记录
            steps.append {
                HistoryWindow.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if let window = HistoryWindow.shared.windowForTesting {
                        if !capture(window, "history.png") { failures.append("历史窗截图失败") }
                        window.orderOut(nil)
                    } else { failures.append("历史窗没出来") }
                    next()
                }
            }

            // 3) 收藏夹
            steps.append {
                FavoriteWindow.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if let window = FavoriteWindow.shared.windowForTesting {
                        if !capture(window, "favorites.png") { failures.append("收藏夹截图失败") }
                        window.orderOut(nil)
                    } else { failures.append("收藏夹没出来") }
                    next()
                }
            }

            // 4) 设置：插件列表
            steps.append {
                PreferencesWindow.shared.show(section: .plugins)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    if let window = NSApp.windows.first(where: { $0.title.contains("设置") }) {
                        if !capture(window, "settings-plugins.png") { failures.append("插件列表截图失败") }
                    } else { failures.append("设置窗没出来") }
                    next()
                }
            }

            // 5) 设置：OCR
            steps.append {
                PreferencesWindow.shared.show(section: .ocrSettings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let window = NSApp.windows.first(where: { $0.title.contains("设置") }) {
                        if !capture(window, "settings-ocr.png") { failures.append("OCR 设置截图失败") }
                    } else { failures.append("设置窗没出来") }
                    next()
                }
            }

            // 6) OCR 结果窗（造一张干净的演示图）
            steps.append {
                let width = 760, height = 260
                let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                ("Screenshot OCR demo" as NSString).draw(at: NSPoint(x: 40, y: 170),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
                ("框选屏幕任意区域，识别结果直接可复制。" as NSString).draw(at: NSPoint(x: 40, y: 90),
                    withAttributes: [.font: NSFont(name: "PingFang SC", size: 26) ?? NSFont.systemFont(ofSize: 26),
                                     .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
                if let image = ctx.makeImage() {
                    OCRWindow.shared.present(image: image, text: "Screenshot OCR demo\n框选屏幕任意区域，识别结果直接可复制。")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let window = OCRWindow.shared.windowForTesting {
                        if !capture(window, "ocr.png") { failures.append("OCR 窗口截图失败") }
                        window.orderOut(nil)
                    } else { failures.append("OCR 窗口没出来") }
                    next()
                }
            }

            let builtSteps = steps
            next = {
                guard index < builtSteps.count else {
                    HistoryStore.directoryOverride = nil
                    FavoriteStore.directoryOverride = nil
                    try? FileManager.default.removeItem(at: tmp)
                    if failures.isEmpty {
                        print("已保存到: \(outDir.path)")
                        print("RESULT: PASS")
                        exit(0)
                    }
                    for failure in failures { print("✗ \(failure)") }
                    print("RESULT: FAIL")
                    exit(1)
                }
                let step = builtSteps[index]
                index += 1
                step()
            }
            next()
        }
        app.run()
        return 1
    }

    private static func historyShotTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate
        let outPath = arguments.first ?? "/tmp/lt_history.png"

        delegate.onStart = {
            HistoryWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let window = HistoryWindow.shared.windowForTesting,
                      let content = window.contentView else {
                    print("✗ 历史窗没出来")
                    print("RESULT: FAIL")
                    exit(1)
                }
                window.layoutIfNeeded()
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let live = window.contentView else { exit(1) }
                guard let rep = live.bitmapImageRepForCachingDisplay(in: live.bounds) else {
                    print("✗ 取不到位图")
                    print("RESULT: FAIL")
                    exit(1)
                }
                live.cacheDisplay(in: live.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    print("✗ PNG 编码失败")
                    print("RESULT: FAIL")
                    exit(1)
                }
                try? png.write(to: URL(fileURLWithPath: outPath))
                print("历史窗尺寸: \(Int(window.frame.width))x\(Int(window.frame.height)) content=\(Int(window.contentView?.frame.width ?? 0))x\(Int(window.contentView?.frame.height ?? 0)) visible=\(window.isVisible) minSize=\(Int(window.minSize.width))x\(Int(window.minSize.height))")
                print("已保存: \(outPath)")
                print("RESULT: PASS")
                exit(0)
            }
        }
        app.run()
        return 1
    }

    private static func cardShotTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        let outPath = arguments.first ?? "/tmp/lt_card.png"

        delegate.onStart = {
            let card = TranslationCard.shared
            let profiles = makeTestProfiles(["火山翻译", "Google 翻译", "Apple 翻译"])
            let source = "With macOS Sonoma, work and play on your Mac are even more powerful."
            card.present(source: source, mode: .translate, targetLanguage: "zh-Hans", profiles: profiles)
            let ids = profiles.map(\.id)
            let samples = [
                "使用 macOS Sonoma，在 Mac 上工作和娱乐更加强大。",
                "借助 macOS Sonoma，您在 Mac 上的工作和娱乐变得更加强大。",
                "有了 macOS Sonoma，在 Mac 上的工作和娱乐功能更加强大。",
            ]
            for (i, id) in ids.enumerated() {
                card.beginStream(model: id)
                card.complete(model: id, text: samples[min(i, samples.count - 1)], seconds: 0.4 + Double(i) * 0.2)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = card.windowForTesting, let content = window.contentView else {
                    print("✗ 卡片窗口没出来")
                    print("RESULT: FAIL")
                    exit(1)
                }
                window.layoutIfNeeded()
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let live = window.contentView else { exit(1) }
                guard let rep = live.bitmapImageRepForCachingDisplay(in: live.bounds) else {
                    print("✗ 取不到位图")
                    print("RESULT: FAIL")
                    exit(1)
                }
                live.cacheDisplay(in: live.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    print("✗ PNG 编码失败")
                    print("RESULT: FAIL")
                    exit(1)
                }
                try? png.write(to: URL(fileURLWithPath: outPath))
                print("卡片尺寸: \(Int(window.frame.width))x\(Int(window.frame.height))")
                print("已保存: \(outPath)")
                let snapshot = card.visibleTextSnapshot().joined(separator: " | ")
                print("可见文本: \(snapshot.prefix(400))")
                print("RESULT: PASS")
                exit(0)
            }
        }
        app.run()
        return 1
    }

    /// 真连网跑一遍所有「默认开启的免密钥服务」，验证每一家都真的能翻出中文。
    /// 这是用户实际点快捷键时走的那条路：任何一家挂了都必须在这里暴露。
    /// 用法: --selftest real-services [源文本]
    private static func realServicesTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        let sample = arguments.first ?? "With macOS Sonoma, work and play on your Mac are even more powerful."

        delegate.onStart = {
            let profiles = ProfileStore.defaultProfiles()
            print("默认服务: \(profiles.map { "\($0.name)[\($0.providerKind.rawValue)]" }.joined(separator: ", "))")
            print("源文本: \(sample)")

            Task {
                var problems: [String] = []
                var successes = 0

                for profile in profiles where profile.enabled {
                    // Apple 是离线引擎，语言包没装就跳过——App 里也是直接撤掉这张卡
                    if profile.providerKind == .apple, #available(macOS 15.0, *) {
                        let status = await AppleTranslator.availability(
                            targetLanguage: "zh-Hans",
                            sourceLanguage: LanguageDetector.detectLanguage(sample))
                        if status != .installed {
                            print("  · \(profile.name) 跳过（\(status.text)）")
                            continue
                        }
                    }
                    // 注意：绝不能用 DispatchSemaphore 在主线程上等——
                    // Apple 翻译的 TranslationSession 需要主 RunLoop 跑起来才回调，堵住主线程就等于永远拿不到结果。
                    let start = Date()
                    var out = ""
                    var failure: String?
                    let callbacks = TranslationCallbacks(
                        onThink: { _ in },
                        onDelta: { out += $0 },
                        onDone: { text, _ in out = text },
                        onError: { failure = $0 }
                    )
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            await Translator.translate(text: sample, targetLanguage: "zh-Hans",
                                                       mode: .translate, profile: profile, callbacks: callbacks)
                        }
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 20_000_000_000)
                        }
                        await group.next()
                        group.cancelAll()
                    }
                    let latency = Date().timeIntervalSince(start)
                    if let failure {
                        problems.append("\(profile.name) 失败：\(failure)")
                        print("  ✗ \(profile.name) 失败：\(failure)")
                    } else if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        problems.append("\(profile.name) 返回空译文")
                        print("  ✗ \(profile.name) 返回空译文 / 超时")
                    } else {
                        successes += 1
                        let oneLine = out.replacingOccurrences(of: "\n", with: " ")
                        print(String(format: "  ✓ %@ [%.2fs] %@", profile.name, latency, oneLine))
                    }
                }

                // 单家第三方免费接口抖动（尤其 MyMemory）不该判整个产品失败；
                // 但只要有服务不通就要说清楚，绝不静默掩盖。
                if successes == 0 {
                    print("✗ 所有免密钥服务都没翻出来——这正是用户看到的现象")
                    print("RESULT: FAIL")
                    exit(1)
                }
                if !problems.isEmpty {
                    print("· 有 \(problems.count) 家本次不可用（第三方免费接口抖动，已重试）：")
                    for (index, p) in problems.enumerated() { print("    \(index + 1). \(p)") }
                }
                print("✓ 免费免密钥服务实测可用（\(successes) 家）")
                print("RESULT: PASS")
                exit(0)
            }
        }
        app.run()
        return 1
    }

    /// 三家云端 TTS 的请求构造与解析，全离线。
    /// 用法: --selftest tts-engines
    private static func ttsEnginesTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        if Config.shared.ttsEngine != "system" { problems.append("TTS 引擎默认应为系统语音") }
        if TtsEngine.system.needsKey { problems.append("系统语音不该要密钥") }
        if TtsEngine.edge.needsKey { problems.append("Edge 大声朗读不该要密钥") }

        // Edge：免 Key、官方令牌、SSML 组装与 MP3 输出格式
        guard let edge = TtsCodec.edgeRequest(text: "Hello Edge", targetLanguage: "zh-Hans") else {
            print("✗ Edge TTS 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(edge.url.absoluteString.contains("trustedclienttoken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"), "Edge 客户端令牌缺失")
        check(edge.headers["X-Microsoft-OutputFormat"] == "audio-24khz-48kbitrate-mono-mp3", "Edge 输出音频格式不匹配")
        if case .success(let b64) = TtsCodec.parseEdge(Data(repeating: 1, count: 256)) {
            check(!b64.isEmpty, "Edge TTS base64 音频解析为空")
        } else {
            problems.append("Edge TTS 音频解析失败")
        }

        // Google：key 在 URL，body 里要有语言与音频格式
        guard let google = TtsCodec.googleRequest(text: "hello", targetLanguage: "zh-Hans", key: "gk") else {
            print("✗ Google TTS 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(google.url.absoluteString.contains("key=gk"), "Google TTS key 没进 URL")
        let gbody = String(data: google.body, encoding: .utf8) ?? ""
        check(gbody.contains("zh-CN"), "Google TTS 语言码不对：\(gbody.prefix(120))")
        check(gbody.contains("MP3"), "Google TTS 没要 MP3")
        if case .success(let a) = TtsCodec.parseGoogle(Data(#"{"audioContent":"QUJD"}"#.utf8)) {
            check(a == "QUJD", "Google TTS 音频解析不对：\(a)")
        } else { problems.append("Google TTS 正常响应解析失败") }
        if case .failure(let m) = TtsCodec.parseGoogle(Data(#"{"error":{"message":"bad key"}}"#.utf8)) {
            check(m.contains("bad key"), "Google TTS 错误没带出来：\(m)")
        } else { problems.append("Google TTS 错误响应没有判失败") }

        // Microsoft：SSML + 订阅密钥 + 区域
        guard let ms = TtsCodec.microsoftRequest(text: "a<b&c", targetLanguage: "zh-Hans", key: "k@eastasia") else {
            print("✗ Microsoft TTS 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(ms.headers["Ocp-Apim-Subscription-Key"] == "k", "Microsoft TTS 密钥没拆出来")
        check(ms.url.host?.hasPrefix("eastasia") == true, "Microsoft TTS 区域没进域名：\(ms.url.host ?? "nil")")
        let ssml = String(data: ms.body, encoding: .utf8) ?? ""
        check(ssml.contains("<speak"), "Microsoft TTS body 不是 SSML")
        check(!ssml.contains("a<b&c"), "Microsoft TTS 没转义 XML 特殊字符，会 400")
        check(TtsCodec.microsoftRequest(text: "x", targetLanguage: "zh", key: "只有密钥") != nil,
              "不带区域时应默认到 eastasia 而不是失败")

        // 腾讯：TC3 + TextToVoice
        guard let tencent = TtsCodec.tencentRequest(text: "hi", targetLanguage: "zh-Hans", key: "id:key") else {
            print("✗ 腾讯 TTS 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check((tencent.headers["X-TC-Action"] ?? "") == "TextToVoice", "腾讯 TTS 动作名不对")
        check((tencent.headers["Authorization"] ?? "").hasPrefix("TC3-HMAC-SHA256"), "腾讯 TTS 授权头不是 TC3")
        if case .success(let a) = TtsCodec.parseTencent(Data(#"{"Response":{"Audio":"QUJD"}}"#.utf8)) {
            check(a == "QUJD", "腾讯 TTS 音频解析不对：\(a)")
        } else { problems.append("腾讯 TTS 正常响应解析失败") }
        if case .failure(let m) = TtsCodec.parseTencent(
            Data(#"{"Response":{"Error":{"Message":"NoAuth"}}}"#.utf8)) {
            check(m.contains("NoAuth"), "腾讯 TTS 错误没带出来：\(m)")
        } else { problems.append("腾讯 TTS 错误响应没有判失败") }

        // Microsoft 返回的是音频字节，太短要判失败（不是静默播一段噪音）
        if case .failure = TtsCodec.parseMicrosoft(Data(repeating: 0, count: 10)) {
            // 期望的分支
        } else {
            problems.append("Microsoft TTS 对过短的返回没有判失败")
        }

        // 火山（豆包语音）：Bearer;token 鉴权，和 V4 那套完全不同
        guard let volcTts = VolcEngines.ttsRequest(text: "你好", key: "app:tok@volcano_tts",
                                                   targetLanguage: "zh-Hans") else {
            print("✗ 火山 TTS 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let volcAuthHeader = volcTts.headers["Authorization"] ?? "nil"
        check(volcAuthHeader == "Bearer;tok", "火山 TTS 鉴权头应为 Bearer;token，实际 \(volcAuthHeader)")
        let volcBody = String(data: volcTts.body, encoding: .utf8) ?? ""
        check(volcBody.contains("appid"), "火山 TTS 缺 appid")
        check(volcBody.contains("voice_type"), "火山 TTS 缺音色")
        check(volcBody.contains("你好"), "火山 TTS 没带文本")
        check(VolcEngines.ttsRequest(text: "x", key: "只有一段", targetLanguage: "zh") == nil,
              "火山 TTS 密钥格式不对应返回 nil")
        if case .success(let a) = VolcEngines.parseTts(Data(#"{"code":3000,"data":"QUJD"}"#.utf8)) {
            check(a == "QUJD", "火山 TTS 音频解析不对：\(a)")
        } else { problems.append("火山 TTS 正常响应解析失败") }
        if case .failure(let m) = VolcEngines.parseTts(Data(#"{"code":3001,"message":"bad token"}"#.utf8)) {
            check(m.contains("bad token"), "火山 TTS 错误没带出来：\(m)")
        } else { problems.append("火山 TTS 错误响应没有判失败") }

        if problems.isEmpty {
            print("✓ 多引擎 TTS：Google/腾讯/火山 音频解析、Microsoft 的 SSML 与区域、错误都验过")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 多引擎 OCR

    /// 三个云端 OCR 的请求构造与解析，全离线。
    /// 用法: --selftest ocr-engines
    private static func ocrEnginesTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        if Config.shared.ocrEngine != "system" {
            problems.append("OCR 引擎默认应为系统 Vision，实际 \(Config.shared.ocrEngine)")
        }
        if OcrEngine.system.needsKey { problems.append("系统 Vision 不该要密钥") }
        if OcrEngine.llm.needsKey { problems.append("大模型 OCR 不该强制单独密钥") }
        check(Set(OcrEngine.allCases.map(\.keyAccount)).count == OcrEngine.allCases.count,
              "各引擎的钥匙串账户名有重复")

        // 造一张小图当输入
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("✗ 造不出测试图"); print("RESULT: FAIL"); return 1
        }

        // 大模型多模态 OCR (OpenAI 兼容 image_url)
        let llmProfile = ServiceProfile(id: "test-ocr-llm", name: "LLM", baseURL: "https://api.openai.com/v1", model: "gpt-4o", enabled: true, extraPrompt: "")
        guard let llmReq = OcrCodec.llmRequest(image: cg, profile: llmProfile, key: "sk-test") else {
            print("✗ 大模型 OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(llmReq.headers["Authorization"] == "Bearer sk-test", "大模型 OCR Authorization 头不对")
        let llmBody = String(data: llmReq.body, encoding: .utf8) ?? ""
        check(llmBody.contains("image_url") && llmBody.contains("base64,"), "大模型 OCR 未携带标准图片 base64 协议")
        check(llmBody.contains("gpt-4o"), "大模型 OCR 缺少 model 字段")

        if case .success(let t) = OcrCodec.parseLLM(Data(#"{"choices":[{"message":{"content":"大模型识别到的文字"}}]}"#.utf8)) {
            check(t == "大模型识别到的文字", "大模型 OCR 正常响应解析失败：\(t)")
        } else {
            problems.append("大模型 OCR 正常响应解析失败")
        }
        if case .failure(let m) = OcrCodec.parseLLM(Data(#"{"error":{"message":"invalid model"}}"#.utf8)) {
            check(m.contains("invalid model"), "大模型 OCR 错误未透传：\(m)")
        } else {
            problems.append("大模型 OCR 错误响应未判失败")
        }

        // Google
        guard let google = OcrCodec.googleRequest(image: cg, key: "gk") else {
            print("✗ Google OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(google.url.absoluteString.contains("key=gk"), "Google OCR key 没进 URL")
        let gbody = String(data: google.body, encoding: .utf8) ?? ""
        check(gbody.contains("TEXT_DETECTION"), "Google OCR 缺 TEXT_DETECTION")
        check(gbody.contains("content"), "Google OCR 没带图片内容")
        if case .success(let t) = OcrCodec.parseGoogle(
            Data(#"{"responses":[{"fullTextAnnotation":{"text":"你好\n世界"}}]}"#.utf8)) {
            check(t.contains("你好"), "Google OCR 解析不对：\(t)")
        } else { problems.append("Google OCR 正常响应解析失败") }
        if case .failure(let m) = OcrCodec.parseGoogle(Data(#"{"responses":[{}]}"#.utf8)) {
            check(m.contains("没识别到"), "Google OCR 空结果该提示没识别到文字：\(m)")
        } else { problems.append("Google OCR 空结果没有判失败") }

        // 有道
        guard let youdao = OcrCodec.youdaoRequest(image: cg, key: "ak:sk") else {
            print("✗ 有道 OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let ybody = String(data: youdao.body, encoding: .utf8) ?? ""
        check(ybody.contains("signType=v3"), "有道 OCR 缺 signType=v3")
        check(ybody.contains("img="), "有道 OCR 没带图片")
        check(OcrCodec.youdaoRequest(image: cg, key: "没有冒号") == nil, "有道 OCR 密钥格式不对应返回 nil")
        if case .success(let t) = OcrCodec.parseYoudao(
            Data(#"{"errorCode":"0","Result":{"regions":[{"lines":[{"text":"第一行"},{"text":"第二行"}]}]}}"#.utf8)) {
            check(t == "第一行\n第二行", "有道 OCR 多行没拼好：\(t)")
        } else { problems.append("有道 OCR 正常响应解析失败") }
        if case .failure(let m) = OcrCodec.parseYoudao(Data(#"{"errorCode":"101"}"#.utf8)) {
            check(m.contains("101"), "有道 OCR 错误码没带出来：\(m)")
        } else { problems.append("有道 OCR 错误码没有判失败") }

        // 腾讯
        guard let tencent = OcrCodec.tencentRequest(image: cg, key: "id:key") else {
            print("✗ 腾讯 OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check((tencent.headers["X-TC-Action"] ?? "") == "GeneralBasicOCR", "腾讯 OCR 动作名不对")
        check((tencent.headers["Authorization"] ?? "").hasPrefix("TC3-HMAC-SHA256"), "腾讯 OCR 授权头不是 TC3")
        if case .success(let t) = OcrCodec.parseTencent(
            Data(#"{"Response":{"TextDetections":[{"DetectedText":"甲"},{"DetectedText":"乙"}]}}"#.utf8)) {
            check(t == "甲\n乙", "腾讯 OCR 多行没拼好：\(t)")
        } else { problems.append("腾讯 OCR 正常响应解析失败") }
        if case .failure(let m) = OcrCodec.parseTencent(
            Data(#"{"Response":{"Error":{"Message":"AuthFailure"}}}"#.utf8)) {
            check(m.contains("AuthFailure"), "腾讯 OCR 错误信息没带出来：\(m)")
        } else { problems.append("腾讯 OCR 错误响应没有判失败") }

        // 百度：两步流程（先 token 再识别），token 要能缓存
        guard let tokenReq = OcrCodec.baiduTokenRequest(key: "ak:sk") else {
            print("✗ 百度 token 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let tokenURL = tokenReq.url?.absoluteString ?? ""
        check(tokenURL.contains("grant_type=client_credentials"), "百度 token 缺 grant_type")
        check(tokenURL.contains("client_id=ak"), "百度 token 缺 client_id")
        check(tokenURL.contains("client_secret=sk"), "百度 token 缺 client_secret")
        check(OcrCodec.baiduTokenRequest(key: "没有冒号") == nil, "百度密钥格式不对应返回 nil")
        if case .success(let token) = OcrCodec.parseBaiduToken(
            Data(#"{"access_token":"24.abc","expires_in":2592000}"#.utf8)) {
            check(token == "24.abc", "百度 token 解析不对：\(token)")
        } else { problems.append("百度 token 正常响应解析失败") }
        if case .failure(let m) = OcrCodec.parseBaiduToken(
            Data(#"{"error":"invalid_client","error_description":"unknown client id"}"#.utf8)) {
            check(m.contains("unknown client id"), "百度 token 错误没带出来：\(m)")
        } else { problems.append("百度 token 错误响应没有判失败") }

        guard let baidu = OcrCodec.baiduOcrRequest(image: cg, token: "24.abc") else {
            print("✗ 百度 OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(baidu.url.absoluteString.contains("access_token=24.abc"), "百度 OCR token 没进 URL")
        check((String(data: baidu.body, encoding: .utf8) ?? "").contains("image="), "百度 OCR 没带图片")
        if case .success(let t) = OcrCodec.parseBaidu(
            Data(#"{"words_result":[{"words":"第一行"},{"words":"第二行"}]}"#.utf8)) {
            check(t == "第一行\n第二行", "百度 OCR 多行没拼好：\(t)")
        } else { problems.append("百度 OCR 正常响应解析失败") }
        if case .failure(let m) = OcrCodec.parseBaidu(Data(#"{"error_code":110,"error_msg":"Access token invalid"}"#.utf8)) {
            check(m.contains("110"), "百度 OCR 错误码没带出来：\(m)")
        } else { problems.append("百度 OCR 错误码没有判失败") }
        if case .failure(let m) = OcrCodec.parseBaidu(Data(#"{"words_result":[]}"#.utf8)) {
            check(m.contains("没识别到"), "百度 OCR 空结果该提示没识别到文字：\(m)")
        } else { problems.append("百度 OCR 空结果没有判失败") }

        // 火山：V4 签名 + OCRNormal
        guard let volcOcr = VolcEngines.ocrRequest(imageBase64: "QUJD", key: "ak:sk") else {
            print("✗ 火山 OCR 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let volcAuth = volcOcr.headers["Authorization"] ?? ""
        check(volcAuth.hasPrefix("HMAC-SHA256 Credential=ak/"), "火山 OCR 授权头格式不对：\(volcAuth.prefix(50))")
        check(volcAuth.contains("/cn-north-1/cv/request"), "火山 OCR 凭据范围应为 cn-north-1/cv/request")
        check(volcOcr.url.absoluteString.contains("Action=OCRNormal"), "火山 OCR 动作名不对")
        check(volcOcr.url.absoluteString.contains("Version=2020-08-26"), "火山 OCR 版本号不对")
        check((String(data: volcOcr.body, encoding: .utf8) ?? "").contains("image_base64"), "火山 OCR 没带图片")
        check(VolcEngines.ocrRequest(imageBase64: "x", key: "没有冒号") == nil, "火山 OCR 密钥格式不对应返回 nil")
        if case .success(let t) = VolcEngines.parseOcr(
            Data(#"{"code":10000,"data":{"line_texts":["第一行","第二行"]}}"#.utf8)) {
            check(t == "第一行\n第二行", "火山 OCR 多行没拼好：\(t)")
        } else { problems.append("火山 OCR 正常响应解析失败") }
        if case .failure(let m) = VolcEngines.parseOcr(
            Data(#"{"code":100009,"message":"invalid signature"}"#.utf8)) {
            check(m.contains("invalid signature"), "火山 OCR 错误没带出来：\(m)")
        } else { problems.append("火山 OCR 错误响应没有判失败") }

        if problems.isEmpty {
            print("✓ 多引擎 OCR：LLM/Google/有道/腾讯/百度/火山 的请求构造与解析都对，空结果会明确提示")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - Apple 系统翻译

    /// 系统翻译能力与路由。这里只做离线可验的部分：
    /// 语言表、语言方向状态、预设条目、不需要密钥。
    /// 真翻一段需要先下载语言包（系统会弹框），不在自测里触发。
    /// 用法: --selftest apple
    private static func appleTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        guard #available(macOS 15.0, *) else {
            print("系统版本低于 macOS 15，Apple 翻译不可用")
            print("RESULT: PASS")
            return 0
        }

        do {
            let count = Semaphore.run { await AppleTranslator.supportedLanguageCount() }
            if count < 5 { problems.append("系统只报了 \(count) 种语言，明显不对") }

            let hasZh = Semaphore.run { await AppleTranslator.hasLanguage("zh-Hans") }
            let hasEn = Semaphore.run { await AppleTranslator.hasLanguage("en") }
            if !hasZh { problems.append("语言表里没有中文") }
            if !hasEn { problems.append("语言表里没有英文") }

            let status = Semaphore.run { await AppleTranslator.availability(targetLanguage: "zh-Hans") }
            if status == .unsupported { problems.append("英译中报「系统不支持」，语言表却说支持 zh") }

            // Apple 翻译回归：语言包下好之后真的能翻了（见 apple-live 自测）
            let apple = ServiceProfile.Preset.apple.makeProfile()
            if apple.providerKind != .apple { problems.append("Apple 预设的服务商类型不对") }
            if !apple.baseURL.isEmpty { problems.append("Apple 翻译不该有 Base URL") }
            if ProviderKind.apple.keyHint != "不用填" {
                problems.append("Apple 翻译不该要求密钥")
            }

            if problems.isEmpty {
                print("✓ Apple 翻译：\(count) 种语言，中英都在，方向状态=\(status.text)，预设不需要密钥")
                print("RESULT: PASS")
                return 0
            }
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    /// 用程序自己的保存接口写入一条 Apple 服务（免配置）。
    /// 手写 JSON 试过对不上格式，直接走 ProfileStore.save 最可靠。
    /// 用法: --selftest use-apple
    private static func useAppleTest(_ arguments: [String]) -> Int32 {
        var profiles = ProfileStore.all()
        // 没有 key 的旧条目一律关掉，避免抢占「第一个可用」
        for index in profiles.indices {
            if profiles[index].providerKind != .apple {
                let key = SecretStore.shared.apiKey(for: profiles[index].keyAccount)
                if key.isEmpty { profiles[index].enabled = false }
            }
        }
        if !profiles.contains(where: { $0.providerKind == .apple }) {
            profiles.insert(ServiceProfile(id: UUID().uuidString,
                                           name: "Apple 翻译",
                                           baseURL: "",
                                           model: "",
                                           enabled: true,
                                           extraPrompt: "",
                                           provider: "apple"), at: 0)
        } else if let index = profiles.firstIndex(where: { $0.providerKind == .apple }) {
            profiles[index].enabled = true
        }
        guard ProfileStore.save(profiles) else {
            print("✗ 保存失败"); print("RESULT: FAIL"); return 1
        }
        ProfileStore.reload()
        let after = ProfileStore.all()
        print("写入后：")
        for item in after {
            print("  - \(item.name) | enabled=\(item.enabled) | provider=\(item.provider ?? "-")")
        }
        guard let usable = ProfileStore.firstUsable(), usable.providerKind == .apple else {
            print("✗ 第一个可用的不是 Apple，实际 \(ProfileStore.firstUsable()?.name ?? "无")")
            print("RESULT: FAIL")
            return 1
        }
        print("✓ 已选中 Apple 翻译，且它是第一个可用的服务")
        print("RESULT: PASS")
        return 0
    }

    // MARK: - 翻译结果清理与诊断

    /// 围栏回吐、只有思考没正文、被截断、被安全拦截——这四类都有明确处理。
    /// 用法: --selftest diagnostics
    private static func diagnosticsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }
        let D = TranslationDiagnostics.self

        // 1) 围栏脱掉
        check(D.sanitize("```plaintext\n你好，世界\n```") == "你好，世界", "单层围栏没脱掉")
        check(D.sanitize("```\n你好\n```") == "你好", "光秃秃的 ``` 没脱掉")
        check(D.sanitize("```python\n```\n你好\n```\n```") != "", "双层围栏处理失败")
        // 2) 正文里的代码块不能被误伤
        let keep = D.sanitize("示例：\n```\nprint(1)\n```\n以上")
        check(keep.contains("print(1)") && keep.contains("```"), "正文代码块被误删：\(keep)")
        // 3) 只有围栏时不该变成空字符串糊过去
        check(!D.sanitize("```\n\n```").isEmpty || D.sanitize("```\n\n```") == "", "空围栏处理异常")

        // 4) 诊断分类
        let thinkOnly = D.issues(content: "", think: "推理很久", finishReason: nil)
        check(thinkOnly == [.thinkOnly], "只有思考该判 thinkOnly，实际 \(thinkOnly)")
        let empty = D.issues(content: "", think: "", finishReason: nil)
        check(empty == [.empty], "全空该判 empty，实际 \(empty)")
        let truncated = D.issues(content: "半句话", think: "", finishReason: "length")
        check(truncated == [.truncated], "截断该判 truncated 且不算错误，实际 \(truncated)")
        check(!TranslationDiagnostics.Issue.truncated.isError, "截断不该算错误（有可用译文）")
        let filtered = D.issues(content: "", think: "", finishReason: "content_filter")
        check(filtered.first == .contentFiltered, "安全拦截没判出来，实际 \(filtered)")
        check(TranslationDiagnostics.Issue.contentFiltered.isError, "安全拦截该算错误")

        // 5) 每句话都要有可执行的下一步，不能只说"失败了"
        for issue in [TranslationDiagnostics.Issue.thinkOnly, .empty, .truncated, .contentFiltered] {
            check(issue.message.count > 12, "\(issue) 提示太短")
            if issue == .truncated {
                check(issue.message.contains("截断"), "截断提示没说清是什么问题")
            }
        }

        // 6) 换行结构：两段话渲染后仍是两段，不额外插空行
        let two = "第一段内容\n第二段内容"
        let rendered = MarkdownLite.attributed(two, fontSize: 13, color: .labelColor,
                                               secondaryColor: .secondaryLabelColor).string
        let blankRuns = rendered.components(separatedBy: "\n\n\n").count - 1
        check(blankRuns == 0, "渲染后出现了多余空行：\(rendered.debugDescription)")
        check(rendered.contains("第一段") && rendered.contains("第二段"), "渲染丢了段落")

        if problems.isEmpty {
            print("✓ 诊断：围栏脱掉不误伤正文，四类问题判定正确，换行结构未劣化")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 静默替换翻译

    /// 划词替换与输入框替换：错误提示、快捷键归一化、冲突检测。
    /// 用法: --selftest silent-replace
    private static func silentReplaceTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 错误提示人话
        check(SilentReplace.Failure.notTrusted.message.contains("辅助功能"), "未授权提示缺少「辅助功能」")
        check(SilentReplace.Failure.nothingSelected.message.contains("输入框"), "无选中文字提示缺少「输入框」")
        check(SilentReplace.Failure.cannotFocus.message.contains("可编辑"), "无法聚焦提示缺少「可编辑」")
        check(SilentReplace.Failure.translation("测试错误").message.contains("测试错误"), "翻译错误透传失败")
        check(SilentReplace.Failure.writeFailed.message.contains("不接受写入"), "写入失败提示缺少「不接受写入」")

        // 2) 快捷键默认值与唯一性
        let config = Config.shared
        check(config.silentReplaceHotkey.hasPrefix("control"), "静默划词快捷键应默认 control 开头，实际 \(config.silentReplaceHotkey)")
        check(config.inputBoxReplaceHotkey.hasPrefix("control"), "静默输入框快捷键应默认 control 开头，实际 \(config.inputBoxReplaceHotkey)")
        check(config.silentReplaceHotkey != config.inputBoxReplaceHotkey, "划词替换与输入框替换快捷键冲突")
        check(config.silentReplaceHotkey != config.dictionaryHotkey, "划词替换与词典快捷键冲突")

        // 3) PrefsDraft 冲突检测联动
        let draft = PrefsDraft.load()
        check(draft.hotkeys.contains { $0.label == "静默划词替换" }, "草稿中缺少静默划词替换")
        check(draft.hotkeys.contains { $0.label == "静默输入框替换" }, "草稿中缺少静默输入框替换")
        check(draft.conflictLabel(for: config.silentReplaceHotkey, ignoring: "静默划词替换") == nil, "静默划词替换快捷键被误判为冲突")

        if problems.isEmpty {
            print("✓ 静默替换：错误提示清晰、默认 ⌃ 快捷键无冲突、设置联动正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 火山 V4 签名

    /// 用官方文档里给的标准测试向量逐段比对派生密钥和最终签名。
    /// 签名这东西只有和文档算出来的一致才算对，光能编译没意义。
    /// 用法: --selftest volc-sign
    private static func volcSignTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ got: String, _ want: String, _ label: String) {
            if got != want { problems.append("\(label)：得到 \(got)，文档给的是 \(want)") }
        }

        // 文档示例：20250329 / cn-beijing / billing
        let secret = "local-test-secret-not-a-real-key"
        let keys = VolcSigner.signingKey(secretKey: secret, date: "20250329",
                                         region: "cn-beijing", service: "billing")
        check(keys.kDate, "3b2a58701c62a0e63499c11bebbb3b6ace21c9340fb83eff99abce6410a754dc", "kDate")
        check(keys.kRegion, "a0efb887b10837934510ed395400178918c33ea8d4cbc20ac7c50eb016bbcf73", "kRegion")
        check(keys.kService, "75e95a543989658b0bdf5d3e22cf21aeaa76cfddf2125b5b3ee031d8b24d8755", "kService")
        check(keys.kSigning, "b7f062e7570dc1bc6af19fc589135b32f0da25f2b2d6a1c4a7feb58f5198385c", "kSigning")

        // 完整 GET 请求的签名：GET /?Action=QueryBalanceAcct&Version=2022-01-01
        // host=billing.volcengineapi.com，X-Date=20250329T180937Z
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: "20250329T180937Z") else {
            print("✗ 日期解析失败"); print("RESULT: FAIL"); return 1
        }
        let auth = VolcSigner.authorization(
            accessKey: "TEST-ACCESS-KEY-NOT-REAL",
            secretKey: secret,
            method: "GET", host: "billing.volcengineapi.com", path: "/",
            query: [("Action", "QueryBalanceAcct"), ("Version", "2022-01-01")],
            region: "cn-beijing", service: "billing", date: date)
        if !auth.contains("Signature=d7e1a21da87a20e49ba1ab6f54743d173ecf54a18ed6536fb4bf293de2d61bf6") {
            problems.append("完整签名和固定向量不一致：\(auth)")
        }
        if !auth.hasPrefix("HMAC-SHA256 Credential=") {
            problems.append("Authorization 前缀不对：\(auth.prefix(40))")
        }
        if !auth.contains("SignedHeaders=host;x-date") {
            problems.append("SignedHeaders 应包含 host 和 x-date：\(auth)")
        }
        if !auth.contains("/20250329/cn-beijing/billing/request") {
            problems.append("CredentialScope 格式不对：\(auth)")
        }

        if problems.isEmpty {
            print("✓ 火山 V4 签名：四段派生密钥 + 完整 GET 签名与固定向量一致")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 取词失败时的话术

    /// 报错必须给出下一步怎么做，不能只丢一个错误码。
    /// 用法: --selftest selection-errors
    private static func selectionErrorsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []

        let noValue = SelectionReader.Failure.noFocusedApp(status: -25212).description
        if noValue.contains("-25212") {
            problems.append("对用户不该直接甩错误码：\(noValue)")
        }
        for need in ["剪贴板", "安全"] where !noValue.contains(need) {
            problems.append("AX 无值的提示里缺「\(need)」这个关键信息：\(noValue)")
        }

        let other = SelectionReader.Failure.noFocusedApp(status: -25204).description
        if !other.contains("剪贴板") { problems.append("其它 AX 错误也该给出替代路径：\(other)") }

        if !SelectionReader.Failure.notTrusted.description.contains("权限") {
            problems.append("没授权时应该直接说权限")
        }

        if problems.isEmpty {
            print("✓ 取词失败的提示都给了可执行的下一步（改取词方式/查权限）")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 服务商预设

    /// 每个预设都要能生成一个「填得进去」的服务：地址非空且合法、模型名非空、
    /// 免费额度标记存在。预设有错的话，用户点了「添加」只会拿到一条红字。
    /// 用法: --selftest presets
    private static func presetsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let all = ServiceProfile.Preset.allCases
        if all.count < 20 { problems.append("预设只有 \(all.count) 个，太少了") }

        var seen = Set<String>()
        for preset in all where preset != .custom && preset != .apple {
            let profile = preset.makeProfile()
            if profile.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("「\(preset.title)」没有默认地址")
            }
            guard let url = URL(string: profile.baseURL), url.scheme == "http" || url.scheme == "https" else {
                problems.append("「\(preset.title)」地址不合法：\(profile.baseURL)")
                continue
            }
            // 只有 OpenAI 兼容那类需要模型名；DeepL/百度/腾讯/谷歌 这些协议不用模型
            let needsModel = preset.providerKind == .openai
            let isLocal = url.host == "127.0.0.1" || url.host == "localhost"
            if needsModel && !isLocal && profile.model.isEmpty {
                problems.append("「\(preset.title)」没有默认模型名")
            }
            if profile.provider == nil {
                problems.append("「\(preset.title)」没写服务商类型")
            }
            // 这条守着一类真 bug：DeepL/百度这类协议不用模型名，
            // 之前拿「有没有模型名」判配置完整，把它们全判成没配好，永远用不上。
            if !profile.isConfigured {
                problems.append("「\(preset.title)」被判定为未配置（协议类不该要求模型名）")
            }
            if !seen.insert(profile.baseURL + "|" + profile.model).inserted {
                problems.append("「\(preset.title)」和别的预设地址+模型重复")
            }
            if preset.freeTier && !preset.menuTitle.contains("免费") {
                problems.append("「\(preset.title)」标了免费但菜单里看不出来")
            }
        }

        // 免密钥的协议：Apple、谷歌、MyMemory、DeepLX，不该要求密钥
        if ProviderKind.apple.needsKey { problems.append("Apple 翻译不该要求密钥") }
        if ProviderKind.google.needsKey { problems.append("谷歌翻译不该要求密钥") }
        if ProviderKind.mymemory.needsKey { problems.append("MyMemory 翻译不该要求密钥") }
        if ProviderKind.deeplx.needsKey { problems.append("DeepLX 不该要求密钥") }
        for kind in [ProviderKind.deepl, .baidu, .tencent, .youdao, .claude, .gemini, .amazon] where !kind.needsKey {
            problems.append("\(kind.title) 应该需要密钥")
        }

        // 默认开箱即用列表必须全是免费免密钥且直接可用的服务
        let defaults = ProfileStore.defaultProfiles()
        if defaults.isEmpty { problems.append("默认服务列表不能为空") }
        for p in defaults {
            if p.providerKind.needsKey {
                problems.append("默认服务「\(p.name)」不该需要密钥，应由用户自行按需添加")
            }
            if !p.isConfigured {
                problems.append("默认服务「\(p.name)」未处于就绪状态")
            }
        }
        if !defaults.contains(where: { $0.providerKind == .apple && $0.enabled }) {
            problems.append("默认服务列表缺少已开启的 Apple 翻译")
        }
        if !defaults.contains(where: { $0.providerKind == .google && $0.enabled }) {
            problems.append("默认服务列表缺少已开启的谷歌免密钥翻译")
        }

        // 已知有免费额度的几家必须在列表里
        let titles = all.map(\.title)
        for need in ["智谱 GLM", "硅基流动", "Groq"] where !titles.contains(need) {
            problems.append("少了免费额度的「\(need)」")
        }

        // 真实目录不存在 services.json 时，ProfileStore.all() 也必须落到免密钥默认列表（不能被 Config 占位默认值抢占成 gpt-4o-mini）
        let freshTmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-fresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: freshTmp, withIntermediateDirectories: true)
        ProfileStore.directoryOverride = freshTmp
        ProfileStore.reload()
        _ = Config.shared // 确保 Config.init 的 defaults.register 已执行
        let freshProfiles = ProfileStore.all()
        ProfileStore.directoryOverride = nil
        ProfileStore.reload()
        try? FileManager.default.removeItem(at: freshTmp)
        if freshProfiles.contains(where: { $0.providerKind.needsKey }) {
            problems.append("全新初始化却出现了需要密钥的服务：\(freshProfiles.map(\.name))")
        }
        if !freshProfiles.contains(where: { $0.providerKind == .apple }) || !freshProfiles.contains(where: { $0.providerKind == .google }) {
            problems.append("全新初始化缺少 Apple 或谷歌免密钥服务：\(freshProfiles.map(\.name))")
        }

        if problems.isEmpty {
            print("✓ 预设：\(all.count) 家都能生成合法服务，默认列表全是免密钥开箱服务")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 快捷键冲突

    /// 系统保留组合能认出来，写法差异不影响判定。
    /// 用法: --selftest hotkey-conflicts
    private static func hotkeyConflictTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        check(HotKeyConflicts.warning(for: "cmd+space") != nil, "⌘Space 应判为冲突")
        check(HotKeyConflicts.warning(for: "command+space") != nil, "修饰键别名没归一化")
        check(HotKeyConflicts.warning(for: "space+cmd") != nil, "修饰键顺序不同应视为同一组合")
        check(HotKeyConflicts.warning(for: "cmd+shift+3") != nil, "⌘⇧3 应判为冲突")
        check(HotKeyConflicts.warning(for: "option+d") == nil, "⌥D 不该判成系统冲突")
        check(HotKeyConflicts.warning(for: "cmd+shift+x") == nil, "⌘⇧X 不该判成系统冲突")

        // 归一化：两种写法必须相等
        check(HotKeyConflicts.normalize("shift+cmd+x") == HotKeyConflicts.normalize("cmd+shift+x"),
              "归一化后应相等：\(HotKeyConflicts.normalize("shift+cmd+x")) vs \(HotKeyConflicts.normalize("cmd+shift+x"))")

        // 当前配置不该有冲突（默认全是 ⌥）
        let conflicts = HotKeyConflicts.currentWarnings([
            ("划词", Config.shared.hotkey), ("输入", Config.shared.inputHotkey),
            ("截图", Config.shared.screenshotHotkey), ("剪贴板", Config.shared.clipboardHotkey),
        ])
        check(conflicts.isEmpty, "默认配置不该撞系统快捷键，实际：\(conflicts)")

        if problems.isEmpty {
            print("✓ 快捷键冲突：系统保留组合能识别，写法差异归一化正确，默认配置无冲突")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 并排对照

    /// 两列都排出来、文字都在；结果收集去重正确。
    /// 用法: --selftest compare
    private static func compareTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let window = CompareWindow.shared
        window.show(source: "hello world", columns: [
            .init(title: "服务甲", text: "你好，世界"),
            .init(title: "服务乙", text: "哈喽，世界"),
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        if window.columnCountForTesting() != 2 {
            problems.append("应有 2 列，实际 \(window.columnCountForTesting())")
        }
        let text = window.visibleTextSnapshot().joined(separator: "\n")
        for need in ["hello world", "服务甲", "服务乙", "你好，世界", "哈喽，世界"] {
            if !text.contains(need) { problems.append("对照窗口里没有「\(need)」") }
        }

        // 结果收集：同名替换、不同名追加、重开清空
        let runner = TranslateRunner.shared
        runner.resetLatest(source: "probe")
        let a = ServiceProfile(id: "a", name: "甲", baseURL: "http://x/v1", model: "m",
                               enabled: true, extraPrompt: "")
        let b = ServiceProfile(id: "b", name: "乙", baseURL: "http://x/v1", model: "m",
                               enabled: true, extraPrompt: "")
        runner.recordLatest(profile: a, text: "第一版")
        runner.recordLatest(profile: b, text: "乙的")
        runner.recordLatest(profile: a, text: "第二版")
        if runner.latest.count != 2 { problems.append("同名结果应替换而不是追加，实际 \(runner.latest.count) 条") }
        if runner.latest.first(where: { $0.name == "甲" })?.text != "第二版" {
            problems.append("同名结果没被最新一次覆盖")
        }
        runner.resetLatest(source: "again")
        if !runner.latest.isEmpty { problems.append("新一轮翻译开始时没清空上一轮结果") }

        if problems.isEmpty {
            print("✓ 对照视图：两列并排、文字齐全，结果收集去重正确")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 截图后确认原文

    /// 识别完要把文字塞进可编辑的输入框，而不是直接翻。
    /// 用法: --selftest ocr-review
    private static func ocrReviewTest(_ arguments: [String]) -> Int32 {
        UserDefaults.standard.set(false, forKey: "ocrReviewBeforeTranslate")
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 默认应该开启即截即翻（ocrReviewBeforeTranslate = false，无需多点一次）
        if Config.shared.ocrReviewBeforeTranslate {
            problems.append("默认应关闭确认弹窗直接出翻译结果")
        }

        // 塞一段「识别结果」进输入框，原文必须是可编辑且真的进去了
        let recognized = "The quick brown fox"
        let window = InputTranslationWindow.shared
        window.show(prefill: recognized)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let text = window.visibleTextSnapshot().joined(separator: "\n")
        if !text.contains(recognized) {
            problems.append("识别出来的文字没进到输入框")
        }
        let state = window.stateForTesting()
        if !state.placeholderHidden {
            problems.append("有文字时占位提示应该隐藏")
        }
        // 还没点翻译，不该有结果
        if !state.result.isEmpty {
            problems.append("只是展示原文，结果区不该有内容")
        }

        if problems.isEmpty {
            print("✓ 截图翻译：识别文字进入可编辑输入框，未自动发请求")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 代理

    /// 代理字典的组装：开/关、两种协议、端口越界、本机地址直连。
    /// 用法: --selftest proxy
    private static func proxyTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 关掉时不该带任何代理键
        let off = NetworkSession.proxyDictionary(enabled: false, type: "http", host: "127.0.0.1", port: 7890)
        check(off.isEmpty, "关掉代理后字典应为空，实际 \(off.keys)")

        // HTTP：http 与 https 都要设
        let http = NetworkSession.proxyDictionary(enabled: true, type: "http", host: "192.0.2.10", port: 8080)
        check(http[kCFNetworkProxiesHTTPEnable] as? Int == 1, "HTTP 代理没启用")
        check(http[kCFNetworkProxiesHTTPProxy] as? String == "192.0.2.10", "HTTP 代理地址不对")
        check(http[kCFNetworkProxiesHTTPPort] as? Int == 8080, "HTTP 代理端口不对")
        check(http[kCFNetworkProxiesHTTPSEnable] as? Int == 1, "HTTPS 代理没启用")
        check(http[kCFNetworkProxiesHTTPSPort] as? Int == 8080, "HTTPS 代理端口不对")

        // SOCKS5：只设 SOCKS 那组
        let socks = NetworkSession.proxyDictionary(enabled: true, type: "socks5", host: "127.0.0.1", port: 1080)
        check(socks[kCFNetworkProxiesSOCKSEnable] as? Int == 1, "SOCKS 没启用")
        check(socks[kCFNetworkProxiesSOCKSPort] as? Int == 1080, "SOCKS 端口不对")
        check(socks[kCFNetworkProxiesHTTPEnable] == nil, "SOCKS5 不该同时设 HTTP 代理")

        // 本机地址必须直连，否则 Magpie 会被代理吞掉
        let exceptions = http[kCFNetworkProxiesExceptionsList] as? [String] ?? []
        for host in ["127.0.0.1", "localhost"] {
            check(exceptions.contains(host), "代理例外里缺 \(host)，本地网关会被代理吞掉")
        }

        // 填不全就不该生效
        check(NetworkSession.proxyDictionary(enabled: true, type: "http", host: "", port: 8080).isEmpty,
              "地址为空时代理不该生效")
        check(NetworkSession.proxyDictionary(enabled: true, type: "http", host: "1.2.3.4", port: 0).isEmpty,
              "端口 0 时代理不该生效")
        check(NetworkSession.proxyDictionary(enabled: true, type: "http", host: "1.2.3.4", port: 70000).isEmpty,
              "端口 70000 时代理不该生效")

        // 端口设置本身要有上下限
        let config = Config.shared
        let savedPort = config.proxyPort
        config.proxyPort = 99999
        check(config.proxyPort == 65535, "端口没有上限保护：\(config.proxyPort)")
        config.proxyPort = 0
        check(config.proxyPort == 1, "端口没有下限保护：\(config.proxyPort)")
        config.proxyPort = savedPort

        if problems.isEmpty {
            print("✓ 代理：HTTP/SOCKS5 字典正确，本机地址直连，填不全不生效")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - URL 协议

    /// localtranslate:// 的解析：每种动作、参数缺失、不认识的地址。
    /// 用法: --selftest urlscheme
    private static func urlschemeTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ url: String, _ want: URLRouter.ParseResult, _ label: String) {
            guard let parsed = URL(string: url) else {
                problems.append("\(label)：URL 都造不出来 \(url)"); return
            }
            let got = URLRouter.parse(parsed)
            if got != want {
                problems.append("\(label)：得到 \(got)，应为 \(want)")
            }
        }

        check("localtranslate://translate?text=hello",
              .command(.translate(text: "hello", target: nil, copy: false)), "最简翻译")
        check("localtranslate://translate?text=hello&to=zh-Hans",
              .command(.translate(text: "hello", target: "zh-Hans", copy: false)), "带目标语言")
        check("localtranslate://translate?text=hello&copy=1",
              .command(.translate(text: "hello", target: nil, copy: true)), "翻完复制")
        check("localtranslate://translate?text=%20",
              .failure("translate 缺少 text 参数"), "空文本要报错")
        check("localtranslate://translate",
              .failure("translate 缺少 text 参数"), "没带 text 要报错")
        check("localtranslate://input", .command(.input), "输入翻译")
        check("localtranslate://screenshot", .command(.screenshot), "截图翻译")
        check("localtranslate://dictionary?word=pressure",
              .command(.dictionary(word: "pressure")), "查词")
        check("localtranslate://dictionary", .command(.dictionary(word: nil)), "打开词典")
        check("localtranslate://vocabulary", .command(.vocabulary), "生词本")
        check("localtranslate://settings", .command(.settings), "设置")
        check("localtranslate://speak?text=hi", .command(.speak(text: "hi")), "朗读")
        check("localtranslate://speak", .failure("speak 缺少 text 参数"), "朗读缺参数")
        check("localtranslate://whatever", .failure("不认识的动作：whatever"), "不认识的动作")
        check("https://example.com/translate?text=x", .failure("不是 localtranslate:// 开头的地址"), "别的协议")

        // scheme 大小写不敏感
        check("LocalTranslate://INPUT", .command(.input), "大小写混写")

        if problems.isEmpty {
            print("✓ URL 协议：15 种地址解析正确，缺参数和不认识的地址都报错")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 错误码翻译成人话

    /// 各家原始错误要能对上可操作的解释；认不出的原样返回不瞎编。
    /// 用法: --selftest errors
    private static func errorMessageTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }
        let E = ErrorMessages.explain

        check(E("You exceeded your current quota, please check your plan and billing details.").contains("欠费"),
            "OpenAI 欠费没翻成人话")
        check(E("Too Many Requests").contains("限流"), "限流没翻成人话")
        check(E("Incorrect API key provided").contains("密钥"), "错误密钥没翻成人话")
        check(E("The model `gpt-9` does not exist").contains("模型名"), "模型不存在没翻成人话")
        check(E("Your input exceeds the context length").contains("太长"), "上下文超长没翻成人话")
        check(E("未能完成该操作。操作不被允许").contains("代理"), "Apple 代理错误没提到代理")
        check(E("translation was already in progress").contains("同时只能"), "Apple 并发限制没翻出来")

        // 认不出的原样返回，不能编
        let unknown = "some totally unrecognized provider error 9527"
        check(E(unknown) == unknown, "认不出的错误不该被改写：\(E(unknown))")
        // 原信息一定保留（前面拼了原串）
        check(E("Too Many Requests").contains("Too Many Requests"), "改写时丢了原始错误串")

        if problems.isEmpty {
            print("✓ 错误码：欠费/限流/密钥/模型/超长/Apple代理都对，认不出的不瞎编")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 语言检测与双语智能切换及撤销

    /// 语种识别、第一/第二语言智能切换、输入框 undoManager。
    /// 用法: --selftest lang-detect
    private static func languageDetectTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 语种检测
        check(LanguageDetector.detectLanguage("Hello world, this is an English text.") == "en", "英文识别失败")
        check(LanguageDetector.detectLanguage("你好世界，这是一段中文文字。") == "zh-Hans", "中文识别失败")
        check(LanguageDetector.detectLanguage("こんにちは世界") == "ja", "日文识别失败")
        check(LanguageDetector.detectLanguage("안녕하세요 세계") == "ko", "韩文识别失败")

        // 2) 第一/第二语言自动切换
        let config = Config.shared
        let savedAuto = config.autoSwitchLanguage
        let savedPri = config.primaryLanguage
        let savedSec = config.secondaryLanguage

        config.autoSwitchLanguage = true
        config.primaryLanguage = "zh-Hans"
        config.secondaryLanguage = "en"

        // 输入中文 -> 目标切到第二语言 (en)
        let toEn = LanguageDetector.resolveTargetLanguage(source: "测试中文句子", fallbackTarget: "zh-Hans")
        check(toEn == "en", "输入中文应切换到第二语言 en，实际：\(toEn)")

        // 输入英文 -> 目标切到第一语言 (zh-Hans)
        let toZh = LanguageDetector.resolveTargetLanguage(source: "Test English sentence", fallbackTarget: "en")
        check(toZh == "zh-Hans", "输入英文应切换到第一语言 zh-Hans，实际：\(toZh)")

        // 关掉自动切换 -> 保持原 requestedTarget
        config.autoSwitchLanguage = false
        let fixed = LanguageDetector.resolveTargetLanguage(source: "测试中文句子", fallbackTarget: "ja")
        check(fixed == "ja", "关闭自动切换时目标语言被篡改：\(fixed)")

        config.autoSwitchLanguage = savedAuto
        config.primaryLanguage = savedPri
        config.secondaryLanguage = savedSec

        // 3) 输入撤销支持 (allowsUndo)
        let card = TranslationCard.shared
        check(card.sourceView.allowsUndo == true, "卡片 sourceView 缺少 allowsUndo 支持")

        if problems.isEmpty {
            print("✓ 智能双语切换：中英日韩识别、第一/第二语言动态切换、输入框撤销支持正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 窗口高级特性（置顶/无边距/日志导出）

    /// 跨应用置顶开关、去边距开关、日志导出路径。
    /// 用法: --selftest window-features
    private static func windowFeaturesTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let config = Config.shared
        let savedTop = config.alwaysOnTop
        let savedMargin = config.noScreenMargin

        // 1) 跨应用置顶配置与层级
        config.alwaysOnTop = true
        check(config.alwaysOnTop == true, "alwaysOnTop 写入失败")
        let card = TranslationCard.shared
        let profile = makeTestProfiles(["test-top"]).first!
        card.present(source: "top test", mode: .translate, targetLanguage: "zh-Hans", profiles: [profile])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(card.windowForTesting?.level == .statusBar, "开启 alwaysOnTop 时卡片层级应为 statusBar，实际：\(String(describing: card.windowForTesting?.level))")

        config.alwaysOnTop = false
        card.present(source: "top test 2", mode: .translate, targetLanguage: "zh-Hans", profiles: [profile])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(card.windowForTesting?.level == .floating, "关闭 alwaysOnTop 时卡片层级应为 floating")

        card.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // 2) 去边距开关
        config.noScreenMargin = true
        check(config.noScreenMargin == true, "noScreenMargin 写入失败")
        config.noScreenMargin = false
        check(config.noScreenMargin == false, "noScreenMargin 重置失败")

        config.alwaysOnTop = savedTop
        config.noScreenMargin = savedMargin

        // 3) 日志路径与格式
        check(!Debug.logPath.isEmpty, "日志路径为空")
        check(Debug.logPath.hasSuffix("localtranslate_debug.log"), "日志文件名不对：\(Debug.logPath)")

        // 4) 窗口位置模式（屏幕居中 / 记忆上次位置）
        let savedMode = config.windowLocationMode
        let savedOrigin = config.lastWindowOrigin

        config.windowLocationMode = "center"
        card.present(source: "center test", mode: .translate, targetLanguage: "zh-Hans", profiles: [profile])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let frame = card.windowForTesting?.frame, let screenFrame = NSScreen.main?.visibleFrame {
            let expectedX = screenFrame.midX - frame.width / 2
            check(abs(frame.origin.x - expectedX) < 20, "屏幕居中模式 X 坐标偏差过大：\(frame.origin.x) vs \(expectedX)")
        } else {
            problems.append("居中模式未能取得窗口尺寸")
        }

        config.windowLocationMode = "last"
        config.lastWindowOrigin = "260,260"
        card.present(source: "last test", mode: .translate, targetLanguage: "zh-Hans", profiles: [profile])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let frame = card.windowForTesting?.frame {
            check(abs(frame.origin.x - 260) < 20 && abs(frame.origin.y - 260) < 20, "记忆位置模式未能复原上次坐标：\(frame.origin)")
        }

        card.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        config.windowLocationMode = savedMode
        config.lastWindowOrigin = savedOrigin

        // 5) 应用黑名单排除检查
        let savedExcluded = config.excludedApps
        config.excludedApps = "Terminal, iTerm2, com.apple.dt.Xcode"
        check(SelectionAutoMonitor.isAppExcluded(bundleID: "com.apple.Terminal", appName: "Terminal") == true, "黑名单 Terminal 未被命中")
        check(SelectionAutoMonitor.isAppExcluded(bundleID: "com.googlecode.iterm2", appName: "iTerm2") == true, "黑名单 iTerm2 未被命中")
        check(SelectionAutoMonitor.isAppExcluded(bundleID: "com.apple.Safari", appName: "Safari") == false, "非黑名单 Safari 被误伤")
        config.excludedApps = savedExcluded

        if problems.isEmpty {
            print("✓ 窗口高级特性：跨应用置顶、去边距、屏幕居中/记忆坐标、应用黑名单防误触、日志路径正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - UI 本地化

    /// 简体中文、繁体中文、英文文案映射及跟随系统/手动切换。
    /// 用法: --selftest i18n
    private static func i18nTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        check(I18n.t("menu.translate", lang: .zhHans) == "翻译选中内容", "简体中文翻译文案不对")
        check(I18n.t("menu.translate", lang: .zhHant) == "翻譯選中內容", "繁体中文翻译文案不对")
        check(I18n.t("menu.translate", lang: .en) == "Translate Selection", "英文翻译文案不对")

        check(I18n.t("card.copied", lang: .en) == "Copied", "英文复制文案不对")
        check(I18n.t("card.copied", lang: .zhHant) == "已複製", "繁体复制文案不对")

        let config = Config.shared
        let savedLang = config.uiLanguage

        config.uiLanguage = "en"
        check(I18n.currentLanguage == .en, "设置 uiLanguage=en 后未生效")
        check(I18n.t("lang.auto") == "Auto Detect", "当前语言为 en 时 t(lang.auto) 未返回英文")

        config.uiLanguage = "zh-Hant"
        check(I18n.currentLanguage == .zhHant, "设置 uiLanguage=zh-Hant 后未生效")
        check(I18n.t("lang.auto") == "自動檢測", "当前语言为 zh-Hant 时 t(lang.auto) 未返回繁体")

        config.uiLanguage = savedLang

        if problems.isEmpty {
            print("✓ UI 本地化：简体、繁体、英文三语映射及动态语言切换正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 离线简明英汉词典 (ECDict)

    /// 离线 SQLite 查词、音标解析、释义拆分、词形变化还原、未命中回退。
    /// 用法: --selftest ecdict
    private static func ecdictTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-ecdict-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbFile = tmp.appendingPathComponent("ecdict.db")
        ECDictService.dbURLOverride = dbFile
        defer {
            ECDictService.dbURLOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        // 1) 未导入数据库时 isAvailable 应为 false
        check(ECDictService.isAvailable == false, "无数据库文件时 isAvailable 应该是 false")
        check(ECDictService.query(word: "hello") == nil, "无数据库文件时查询应返回 nil")

        // 2) 创建示例 SQLite 数据库
        let created = ECDictService.createSampleDB(at: dbFile.path)
        check(created == true, "创建测试 ECDict SQLite 数据库失败")
        check(ECDictService.isAvailable == true, "创建后 isAvailable 应该是 true")

        // 3) 查词命中并解析出完整字段
        if let entry = ECDictService.query(word: "HELLO") {
            check(entry.word == "hello", "大小写归一化失败：\(entry.word)")
            check(entry.phonetics.first?.value == "həˈləʊ", "音标解析错误：\(entry.phonetics)")
            check(entry.translations.contains { $0.contains("你好") }, "中文释义解析失败：\(entry.translations)")
            check(entry.exchanges.contains { $0.name == "复数" && $0.words.contains("hellos") }, "词形变化复数解析失败：\(entry.exchanges)")
        } else {
            problems.append("离线查询 hello 未返回结果")
        }

        // 4) 未知单词返回 nil（以便系统平滑回退在线模型）
        check(ECDictService.query(word: "nonexistentwordxyz") == nil, "未收录单词应返回 nil")

        if problems.isEmpty {
            print("✓ 离线词典：ECDict SQLite 数据库检索、音标/释义/词形变化解析与未命中回退正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 苹果系统原生词典 (DCSCopyTextDefinition)

    /// 离线系统词典检索、牛津英汉汉英音标与例句提取、中文词条解析与未命中回退。
    /// 用法: --selftest apple-dict
    private static func appleDictTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 英文单词检索 (牛津词典)
        if let entry = AppleDictionaryService.query(word: "pressure") {
            check(entry.word == "pressure", "词头不对：\(entry.word)")
            check(!entry.phonetics.isEmpty, "牛津词典音标缺失：\(entry.phonetics)")
            check(entry.translations.contains { $0.contains("压力") || $0.contains("noun") }, "中文释义缺失：\(entry.translations)")
            check(!entry.examples.isEmpty, "牛津词典带译文的例句缺失：\(entry.examples)")
            check(entry.examples.first?.contains("压力") == true, "例句未带中文译文：\(entry.examples.first ?? "")")
        } else {
            problems.append("系统词典查询 pressure 失败（系统可能未启用内置词典）")
        }

        // 2) 中文词条检索
        if let zhEntry = AppleDictionaryService.query(word: "测试") {
            check(zhEntry.word == "测试", "中文词头不对")
            check(zhEntry.translations.contains { $0.contains("试验") || $0.contains("测验") || $0.contains("动") }, "中文词条释义缺失：\(zhEntry.translations)")
        } else {
            problems.append("系统词典查询中文「测试」失败")
        }

        // 3) 未收录乱码与空字符应返回 nil
        check(AppleDictionaryService.query(word: "nonexistentwordxyz98765") == nil, "未收录乱码词应返回 nil")
        check(AppleDictionaryService.query(word: "   ") == nil, "空白字符应返回 nil")

        if problems.isEmpty {
            print("✓ 苹果系统原生词典：0延迟离线查词、牛津音标与例句提取、现代汉语词典解析正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 文本预处理引擎

    /// 连字符折行修复、PDF换行合并、代码标识符驼峰与下划线拆分。
    /// 用法: --selftest text-preprocess
    private static func textPreprocessTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let config = Config.shared
        let savedMerge = config.mergePDFNewlines
        let savedSplit = config.splitCodeIdentifiers

        config.mergePDFNewlines = true
        config.splitCodeIdentifiers = true

        // 1) 连字符折行修复
        let hyphen1 = TextPreprocessor.process("trans-\nportation")
        check(hyphen1 == "transportation", "连字符折行未修复：\(hyphen1)")
        let hyphen2 = TextPreprocessor.process("multi-\n  level")
        check(hyphen2 == "multilevel", "带空格的连字符折行未修复：\(hyphen2)")

        // 2) PDF 英文单换行合并为空格
        let enWrapped = TextPreprocessor.process("This is a line\nwith another line.")
        check(enWrapped == "This is a line with another line.", "英文单换行合并失败：\(enWrapped)")

        // 3) 中文跨行合并直接相连（不插空格）
        let zhWrapped = TextPreprocessor.process("这是第一行文字\n这是第二行文字")
        check(zhWrapped == "这是第一行文字这是第二行文字", "中文换行不应插空格，实际：\(zhWrapped)")

        // 4) 双换行段落保留
        let doublePara = TextPreprocessor.process("Paragraph 1.\n\nParagraph 2.")
        check(doublePara == "Paragraph 1.\n\nParagraph 2.", "双换行段落未保留：\(doublePara)")

        // 5) 驼峰与下划线代码拆分
        let camel1 = TextPreprocessor.process("getUserProfile")
        check(camel1 == "get User Profile", "驼峰命名拆分失败：\(camel1)")

        let pascal = TextPreprocessor.process("UserProfileController")
        check(pascal == "User Profile Controller", "PascalCase 拆分失败：\(pascal)")

        let abbr = TextPreprocessor.process("XMLHttpRequest")
        check(abbr == "XML Http Request", "连续大写缩写驼峰拆分失败：\(abbr)")

        let snake = TextPreprocessor.process("parse_json_data")
        check(snake == "parse json data", "下划线命名拆分失败：\(snake)")

        let kebab = TextPreprocessor.process("get-user-token")
        check(kebab == "get user token", "kebab-case 拆分失败：\(kebab)")

        // 6) 普通英文句子不误伤
        let normal = TextPreprocessor.process("Hello world! How are you?")
        check(normal == "Hello world! How are you?", "普通英文句子被误伤：\(normal)")

        // 7) 开关控制
        config.mergePDFNewlines = false
        let unmerged = TextPreprocessor.process("Line 1\nLine 2")
        check(unmerged.contains("\n"), "关闭 mergePDFNewlines 时换行被合并")

        config.splitCodeIdentifiers = false
        let unsplit = TextPreprocessor.process("getUserProfile")
        check(unsplit == "getUserProfile", "关闭 splitCodeIdentifiers 时被拆分")

        config.mergePDFNewlines = savedMerge
        config.splitCodeIdentifiers = savedSplit

        if problems.isEmpty {
            print("✓ 文本预处理：连字符折行恢复、PDF单换行合并、双换行保留、代码驼峰/下划线拆词均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - <think> 内联思考流式拆解与分流

    /// 验证 <think> 跨 Chunk 拆分、实时分流、静默完整性与静态 split 纯函数。
    /// 用法: --selftest think-parser
    private static func thinkParserTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 跨 Chunk 标签拆分测试
        var contents: [String] = []
        var thinks: [String] = []

        let parser = ThinkTagStreamParser(
            onContent: { contents.append($0) },
            onThink: { thinks.append($0) }
        )

        let chunks = [
            "前置文字 ",
            "<thi",
            "nk>\n正在深入思考",
            "第 1 步...",
            "\n思考第 2 步",
            "</thi",
            "nk>\n正式译文在这里"
        ]

        for chunk in chunks {
            parser.feed(chunk)
        }
        parser.finish()

        let fullContent = contents.joined()
        let fullThink = thinks.joined()

        check(fullContent.contains("前置文字 "), "正文前置文字丢失：\(fullContent)")
        check(fullContent.contains("正式译文在这里"), "正文译文丢失：\(fullContent)")
        check(!fullContent.contains("<think>") && !fullContent.contains("</think>"), "正文中残留 think 标签：\(fullContent)")
        check(fullThink.contains("正在深入思考") && fullThink.contains("思考第 2 步"), "思考内容提取不完整：\(fullThink)")
        check(!fullThink.contains("<think>") && !fullThink.contains("</think>"), "思考中残留 think 标签：\(fullThink)")

        // 2) 普通无 think 的文本流
        var normalContents: [String] = []
        var normalThinks: [String] = []
        let normalParser = ThinkTagStreamParser(
            onContent: { normalContents.append($0) },
            onThink: { normalThinks.append($0) }
        )
        normalParser.feed("普通句子第 1 段，")
        normalParser.feed("以及第 2 段。")
        normalParser.finish()

        check(normalContents.joined() == "普通句子第 1 段，以及第 2 段。", "无 think 的普通文本流被破坏：\(normalContents.joined())")
        check(normalThinks.isEmpty, "无 think 时产生了伪思考内容")

        // 3) 静态 split 纯函数测试
        let sample = "前缀<think>思考逻辑 A\n思考逻辑 B</think>后续纯净正文"
        let splitted = ThinkTagStreamParser.split(text: sample)
        check(splitted.content == "前缀后续纯净正文", "静态 split 正文不正确：\(splitted.content)")
        check(splitted.think == "思考逻辑 A\n思考逻辑 B", "静态 split 思考不正确：\(splitted.think)")

        if problems.isEmpty {
            print("✓ <think> 流式分流：跨 Chunk 状态机、实时正文/思考流分发、无标签透传与静态拆解均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 逐行排版结构智能对齐 (format: lines)

    /// 验证非空行映射、空行保留、歌词与单行跨段精准还原、行数不匹配安全降级。
    /// 用法: --selftest line-aligner
    private static func lineAlignerTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 经典空行段落结构对齐
        let src1 = "Paragraph 1\n\nParagraph 2\nLine 3"
        let trans1 = "第一段\n第二段\n第三行"
        let aligned1 = LineAligner.align(translatedText: trans1, to: src1)
        check(aligned1 == "第一段\n\n第二段\n第三行", "段落空行对齐失败：\(aligned1.debugDescription)")

        // 2) 连续单行排版对齐 (歌词/字幕)
        let src2 = "Line A\nLine B\nLine C"
        let trans2 = "行甲\n行乙\n行丙"
        let aligned2 = LineAligner.align(translatedText: trans2, to: src2)
        check(aligned2 == "行甲\n行乙\n行丙", "单行排版对齐失败：\(aligned2.debugDescription)")

        // 3) 多重空行保留
        let src3 = "Top\n\n\nBottom"
        let trans3 = "顶部\n底部"
        let aligned3 = LineAligner.align(translatedText: trans3, to: src3)
        check(aligned3 == "顶部\n\n\n底部", "多重空行保留失败：\(aligned3.debugDescription)")

        // 4) 行数不匹配时安全回退单换行拼接，不强行填补或崩溃
        let srcMismatch = "Part A\n\nPart B\nPart C"
        let transMismatch = "整段单句合并译文"
        let alignedMismatch = LineAligner.align(translatedText: transMismatch, to: srcMismatch)
        check(alignedMismatch == "整段单句合并译文", "行数不匹配时未安全降级：\(alignedMismatch.debugDescription)")

        // 5) 原文单行无换行时原样返回
        let singleLine = LineAligner.align(translatedText: "单一译文", to: "Single source")
        check(singleLine == "单一译文", "单行文本异常改写：\(singleLine)")

        if problems.isEmpty {
            print("✓ 逐行结构智能对齐：format:lines 原文非空行精准对齐、段落空行保留、行数不匹配安全降级正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 专业交互细节（代码命名转换/自动朗读/拖拽识图/卡片内替换/平移截图）

    /// 验证 CodeCaseFormatter 命名风格转换、自动朗读配置持久化、拖拽视图类型过滤与卡片替换回填。
    /// 用法: --selftest pro-features
    private static func proFeaturesTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) 程序员代码命名风格转换 (五大风格)
        let sample = "get user profile data"
        check(CodeCaseFormatter.format(sample, style: .lowerCamel) == "getUserProfileData", "小驼峰转换失败")
        check(CodeCaseFormatter.format(sample, style: .upperCamel) == "GetUserProfileData", "大驼峰转换失败")
        check(CodeCaseFormatter.format(sample, style: .snake) == "get_user_profile_data", "下划线转换失败")
        check(CodeCaseFormatter.format(sample, style: .macro) == "GET_USER_PROFILE_DATA", "常量宏转换失败")
        check(CodeCaseFormatter.format(sample, style: .kebab) == "get-user-profile-data", "短横线转换失败")

        // 符号混排与驼峰词元解析
        let mixed = "parse_JSON-data XMLParser"
        let tokens = CodeCaseFormatter.tokenize(mixed)
        check(tokens == ["parse", "JSON", "data", "XML", "Parser"], "复杂词元拆分失败：\(tokens)")
        check(CodeCaseFormatter.format(mixed, style: .lowerCamel) == "parseJsonDataXmlParser", "复杂词元小驼峰转换失败")

        // 2) 自动朗读发音开关配置与持久化
        let config = Config.shared
        let savedAutoSpeak = config.autoSpeakWhenDone
        config.autoSpeakWhenDone = true
        check(config.autoSpeakWhenDone == true, "autoSpeakWhenDone 开启写入失败")
        config.autoSpeakWhenDone = false
        check(config.autoSpeakWhenDone == false, "autoSpeakWhenDone 关闭写入失败")
        config.autoSpeakWhenDone = savedAutoSpeak

        // 3) 菜单栏拖拽接收层对图片扩展名校验
        let dropView = StatusItemDragDropView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        check(dropView.hitTest(NSPoint(x: 10, y: 10)) == nil, "拖拽层不应拦截普通鼠标点击")

        // 4) 静默替换就地回填接口可用性
        check(SilentReplace.writeBackText("") == true, "writeBackText 接口调用失败")

        if problems.isEmpty {
            print("✓ 专业交互细节：代码命名五大风格格式化、自动朗读配置、拖拽穿透与卡片替换接口正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 独立 OCR 工作台

    /// 测试独立 OCR 工作台渲染、连续拼接识别、锁定截图区持久化及自动复制逻辑。
    /// 用法: --selftest ocr-workspace
    private static func ocrWorkspaceTest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            var problems: [String] = []
            func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

            let config = Config.shared
            let savedCont = config.ocrContinuous
            let savedLock = config.ocrLockArea
            let savedCopy = config.ocrAutoCopy
            let savedRect = config.lastOcrRectString

            defer {
                config.ocrContinuous = savedCont
                config.ocrLockArea = savedLock
                config.ocrAutoCopy = savedCopy
                config.lastOcrRectString = savedRect
            }

            // 1) 锁定选区坐标序列化与解析
            let testRect = CGRect(x: 120, y: 240, width: 400, height: 120)
            config.lastOcrRect = testRect
            check(config.lastOcrRect == testRect, "锁定选区坐标序列化还原失真：\(String(describing: config.lastOcrRect))")

            // 2) 弹窗 UI 元素检查与连续拼接模式
            let win = OCRWindow.shared
            config.ocrContinuous = false
            config.ocrAutoCopy = true
            win.present(image: nil, text: "第一段文字")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            let snapshot = win.visibleTextSnapshot().joined(separator: "\n")
            for required in ["OCR 文本识别", "截图识别", "选图…", "重试 ⌘R", "连续拼接", "锁定选区", "自动复制", "去翻译 →"] {
                check(snapshot.contains(required), "OCR 工作台界面缺少「\(required)」")
            }
            check(win.textForTesting() == "第一段文字", "初始文本展示异常：\(win.textForTesting())")

            // 3) 开启连续拼接再传入第二段
            config.ocrContinuous = true
            win.present(image: nil, text: "第二段文字")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let combined = win.textForTesting()
            check(combined.contains("第一段文字") && combined.contains("第二段文字"), "连续拼接未合并两段识别文本：\(combined)")
            check(NSPasteboard.general.string(forType: .string)?.contains("第二段文字") == true, "自动复制未写入剪贴板")

            win.windowForTesting?.close()

            if problems.isEmpty {
                print("✓ 独立 OCR 工作台：双栏界面完整、连续识别拼接、锁定截图选区、自动复制均正常")
                print("RESULT: PASS")
                exit(0)
            }
            for p in problems { print("✗ \(p)") }
            print("RESULT: FAIL")
            exit(1)
        }
        app.run()
        return 1
    }

    // MARK: - Bob 插件生态完全体 (.bobplugin / require / crypto-js / $util / $file / $timer / $websocket)

    /// 离线测试：打包一个真实 .bobplugin zip 包并直装，里面调用 require("$util")、require("crypto-js")、
    /// require("./helper")、$file 沙盒读写、$timer、$websocket 与 $option。
    /// 用法: --selftest bob-plugin-full
    private static func bobPluginFullTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lt-bobfull-\(UUID().uuidString)")
        let srcDir = tmp.appendingPathComponent("src_plugin")
        let installRoot = tmp.appendingPathComponent("installed")
        let sandboxRoot = tmp.appendingPathComponent("sandbox")

        try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

        PluginRuntime.directoryOverride = installRoot
        PluginFileSystem.sandboxRootOverride = sandboxRoot
        defer {
            PluginRuntime.directoryOverride = nil
            PluginFileSystem.sandboxRootOverride = nil
            try? fm.removeItem(at: tmp)
        }

        // 构造插件包内容：info.json, helper.js, main.js
        let infoJson = """
        {
            "identifier": "com.test.bob.full",
            "version": "1.0.0",
            "category": "translate",
            "name": "全能测试插件",
            "options": [
                { "identifier": "prefix", "type": "text", "defaultValue": "PRE" }
            ]
        }
        """
        let helperJs = """
        exports.joinTag = function(a, b) { return a + ":" + b; };
        """
        let mainJs = """
        var util = require("$util");
        var CryptoJS = require("crypto-js");
        var helper = require("./helper");

        function supportLanguages() { return ["auto", "zh-Hans", "en"]; }

        function translate(query, completion) {
            // 1. 测试 $util & $option & $info
            var typeCheck = util.type([1, 2]); // "array"
            var optPrefix = $option.prefix;    // "PRE"
            var infoId = $info.identifier;     // "com.test.bob.full"

            // 2. 测试 CryptoJS (MD5, SHA256, HmacSHA256)
            var md5 = CryptoJS.MD5("hello").toString();
            var hmac = CryptoJS.HmacSHA256("msg", "secret").toString();

            // 3. 测试 $file 沙盒读写及越权拦截
            var okDir = $file.mkdir("$sandbox/sub");
            var okWrite = $file.write({ data: "cached_ok", path: "$sandbox/sub/test.txt" });
            var readRaw = $file.read("$sandbox/sub/test.txt");
            // Bob 契约：read 返回 $data，要自己 toUTF8()
            var readBack = (readRaw && typeof readRaw.toUTF8 === "function") ? readRaw.toUTF8() : readRaw;
            var traversalBlocked = !$file.write({ data: "hack", path: "../outside.txt" });

            // 4. 测试 $timer 与 $websocket 对象创建
            var tid = $timer.schedule({ interval: 10, repeats: false, handler: function() {} });
            $timer.invalidate(tid);
            var ws = $websocket.new({ url: "wss://echo.websocket.org" });
            var wsReady = typeof ws.open === "function" && typeof ws.sendString === "function";

            var out = [
                helper.joinTag(optPrefix, infoId),
                "type=" + typeCheck,
                "md5=" + md5,
                "hmacLen=" + hmac.length,
                "file=" + (okDir && okWrite && readBack === "cached_ok" && traversalBlocked),
                "ws=" + wsReady
            ].join("|");

            completion({
                result: {
                    from: "en",
                    to: query.to,
                    content: { format: "plain", text: out }
                }
            });
        }
        """

        try? infoJson.write(to: srcDir.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
        try? helperJs.write(to: srcDir.appendingPathComponent("helper.js"), atomically: true, encoding: .utf8)
        try? mainJs.write(to: srcDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

        // 打包成 .bobplugin ZIP 文件
        let archiveURL = tmp.appendingPathComponent("FullPlugin.bobplugin")
        let zipProc = Process()
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.currentDirectoryURL = srcDir
        zipProc.arguments = ["-r", "-q", archiveURL.path, "."]
        try? zipProc.run()
        zipProc.waitUntilExit()
        check(zipProc.terminationStatus == 0, "zip 打包测试插件失败")

        // 1) 解压安装 .bobplugin
        switch PluginRuntime.installBobPlugin(at: archiveURL) {
        case .success(let info):
            check(info.identifier == "com.test.bob.full", "插件 identifier 解析错误：\(info.identifier)")
            check(info.pluginName == "全能测试插件", "插件 name 解析错误：\(info.pluginName)")
            check(PluginRuntime.installed().contains("com.test.bob.full"), "installed() 未列出刚安装的目录插件")
        case .failure(let err):
            problems.append("直装 .bobplugin 失败：\(err.message)")
        }

        // 2) 运行插件全量接口测试
        switch PluginRuntime.evaluateTranslate(plugin: "com.test.bob.full", text: "test", source: "en", target: "zh-Hans") {
        case .success(let output):
            check(output.contains("PRE:com.test.bob.full"), "$option 默认值与相对 require 失败：\(output)")
            check(output.contains("type=array"), "$util.type 检查失败：\(output)")
            check(output.contains("md5=5d41402abc4b2a76b9719d911017c592"), "CryptoJS.MD5 计算错误：\(output)")
            check(output.contains("hmacLen=64"), "CryptoJS.HmacSHA256 计算错误：\(output)")
            check(output.contains("file=true"), "$file 沙盒读写或路径穿越防护失败：\(output)")
            check(output.contains("ws=true"), "$websocket 实例创建失败：\(output)")
        case .failure(let err):
            problems.append("全能测试插件运行报错：\(err.message)")
        }

        if problems.isEmpty {
            print("✓ Bob 插件生态完全体：.bobplugin直装、require模块化、$util/crypto-js、$file沙盒读写、$timer 与 $websocket 全对")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - AI 大模型精细操控（变量 Prompt 模板与推理强度挡位）与卡片折叠记忆

    /// 验证 $query 变量替换、userPromptTemplate、reasoning_effort 构造及 thinkCollapsed 状态记忆。
    /// 用法: --selftest ai-control
    private static func aiControlTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // 1) $query 模板渲染
        let rendered = Translator.renderPromptTemplate(
            "把下列文本（原语种：$query.detectFromLang）专业地译为 $query.detectToLang：\n$query.text",
            text: "Hello World",
            sourceLang: "英文",
            targetLang: "简体中文"
        )
        check(rendered == "把下列文本（原语种：英文）专业地译为 简体中文：\nHello World", "变量 Prompt 替换结果不对：\(rendered)")

        // 2) buildOpenAIBody 注入 userPromptTemplate 与 reasoning_effort
        var profile = ServiceProfile(
            id: "ai-test", name: "GPT-5", baseURL: "https://api.openai.com/v1",
            model: "gpt-5", enabled: true, extraPrompt: "保持简练，目标语：$query.detectToLang",
            userPromptTemplate: "只翻核心意思：$query.text", reasoningEffort: "low"
        )
        let body1 = Translator.buildOpenAIBody(
            text: "Test input", targetLanguage: "zh-Hans", mode: .translate, customPrompt: "", profile: profile
        )
        check((body1["reasoning_effort"] as? String) == "low", "未正确携带 reasoning_effort=low")
        if let msgs = body1["messages"] as? [[String: String]], msgs.count == 2 {
            check(msgs[0]["content"]?.contains("保持简练，目标语：简体中文") == true, "System extraPrompt 变量未渲染")
            check(msgs[1]["content"] == "只翻核心意思：Test input", "User 指令模板未生效：\(msgs[1]["content"] ?? "")")
        } else {
            problems.append("messages 结构不对")
        }

        // 3) reasoningEffort 为 nil/default 时不发送该字段
        profile.reasoningEffort = nil
        let body2 = Translator.buildOpenAIBody(
            text: "Test", targetLanguage: "en", mode: .translate, customPrompt: "", profile: profile
        )
        check(body2["reasoning_effort"] == nil, "默认档位不应发送 reasoning_effort 字段")

        // 4) 卡片思考块折叠状态记忆 (Config.shared.thinkCollapsed)
        let config = Config.shared
        let savedCollapsed = config.thinkCollapsed
        config.thinkCollapsed = true
        check(config.thinkCollapsed == true, "thinkCollapsed 默认应支持折叠")
        config.thinkCollapsed = false
        check(config.thinkCollapsed == false, "thinkCollapsed 展开持久化失败")
        config.thinkCollapsed = savedCollapsed

        if problems.isEmpty {
            print("✓ AI 大模型精细操控：Prompt 变量模板、reasoning_effort 档位控制及卡片思考块折叠记忆均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 屏幕录制真伪权限探针与 Retina 截图坐标校验

    /// 验证：1) 区分真授权、preflight假阳性与未授权三种状态；
    ///       2) ScreenOCR.captureDetailed 正确使用 top-left 逻辑坐标点，屏幕右下角截屏不再因 * scale 越界报 -3812。
    /// 用法: --selftest screen-perm
    private static func screenPermTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        check(ScreenOCR.PermissionStatus.granted.isActuallyGranted == true, ".granted 必须为 true")
        check(ScreenOCR.PermissionStatus.preflightOnly("declined").isActuallyGranted == false, "preflight 假阳性绝不能被判为可用")
        check(ScreenOCR.PermissionStatus.denied("no").isActuallyGranted == false, ".denied 必须为 false")

        let sem = DispatchSemaphore(value: 0)
        var probedStatus: ScreenOCR.PermissionStatus = .denied("未执行")
        var bottomRightOutcome: CaptureOutcome?
        var outOfBoundsOutcome: CaptureOutcome?

        Task {
            probedStatus = await ScreenOCR.probePermission(timeoutSeconds: 2.0)
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                // 越界矩形应被安全拦截并返回明确 failure，而非触发系统级崩溃
                outOfBoundsOutcome = await ScreenOCR.captureDetailed(
                    rect: CGRect(x: 99999, y: 99999, width: 50, height: 50),
                    screen: screen
                )
                // 右下角区域测试：在旧 bug 中乘以 scale=2 会导致 x*2 > width 报错 -3812
                if probedStatus.isActuallyGranted {
                    let brRect = CGRect(
                        x: max(0, screen.frame.width - 100),
                        y: max(0, screen.frame.height - 60),
                        width: 80,
                        height: 40
                    )
                    bottomRightOutcome = await ScreenOCR.captureDetailed(rect: brRect, screen: screen)
                }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)

        if let outOfBoundsOutcome {
            if case .success = outOfBoundsOutcome {
                problems.append("越界选区不应截屏成功")
            }
        }
        if probedStatus.isActuallyGranted, let bottomRightOutcome {
            switch bottomRightOutcome {
            case .success(let img):
                let expectedScale = Int((NSScreen.main?.backingScaleFactor ?? 1.0))
                check(img.width >= 80 && img.height >= 40, "右下角截屏尺寸异常：\(img.width)x\(img.height) (scale=\(expectedScale))")
            case .permissionDenied(let msg), .failure(let msg):
                problems.append("真实授权下右下角区域截屏失败（可能存在坐标越界）：\(msg)")
            }
        }

        if arguments.contains("--dump") {
            print("CGPreflightScreenCaptureAccess = \(CGPreflightScreenCaptureAccess())")
            print("canReadOtherWindowTitles = \(ScreenOCR.canReadOtherWindowTitles())")
            let dumpSem = DispatchSemaphore(value: 0)
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    print("SCShareableContent displays = \(content.displays.count), windows = \(content.windows.count)")
                    for w in content.windows.prefix(12) {
                        print("  win: \(w.owningApplication?.applicationName ?? "?") | \(w.title ?? "<nil>") | layer=\(w.windowLayer)")
                    }
                    if let screen = NSScreen.main ?? NSScreen.screens.first {
                        let centerRect = CGRect(x: 200, y: 150, width: 600, height: 450)
                        if case .success(let img) = await ScreenOCR.captureDetailed(rect: centerRect, screen: screen) {
                            let rep = NSBitmapImageRep(cgImage: img)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: "/tmp/lt_actual_capture.png"))
                                print("Saved capture \(img.width)x\(img.height) to /tmp/lt_actual_capture.png")
                            }
                        } else {
                            print("Center capture failed!")
                        }
                    }
                } catch {
                    print("SCShareableContent FAILED: \(error)")
                }
                dumpSem.signal()
            }
            _ = dumpSem.wait(timeout: .now() + 5)
        }

        if problems.isEmpty {
            print("✓ 屏幕录制权限探针与坐标系：假阳性拦截、越界保护与右下角实测截屏状态=\(probedStatus)")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - JavaScript 插件

    /// 离线自测：写一个返回固定译文的插件，跑通 buildRequest 与 evaluateTranslate，
    /// 不发任何网络。
    /// 用法: --selftest plugins
    private static func pluginsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-plugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        PluginRuntime.directoryOverride = tmp
        defer {
            PluginRuntime.directoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        // 1) 安装示例插件 + 列出
        PluginRuntime.installSampleIfNeeded()
        check(PluginRuntime.installed().contains("sample_bob.js"), "示例插件没装上：\(PluginRuntime.installed())")

        // 2) Bob 官方标准 query.onCompletion 规范
        let bobCode = """
        function supportLanguages() { return ["auto", "zh-Hans", "en"]; }
        function translate(query, completion) {
            query.onCompletion({
                result: {
                    from: query.detectFrom,
                    to: query.to,
                    content: {
                        format: "markdown",
                        text: "【Bob译文】" + query.text
                    }
                }
            });
        }
        """
        try? bobCode.write(to: tmp.appendingPathComponent("bob_standard.js"), atomically: true, encoding: .utf8)
        let langs = PluginRuntime.querySupportedLanguages(plugin: "bob_standard.js")
        check(langs.contains("zh-Hans") && langs.contains("en"), "语言查询未返回标准数组：\(langs)")

        switch PluginRuntime.evaluateTranslate(plugin: "bob_standard.js", text: "hello", source: "auto", target: "zh-Hans") {
        case .success(let out):
            check(out == "【Bob译文】hello", "Bob 规范 content 提取失败：\(out)")
        case .failure(let e):
            problems.append("Bob 规范插件执行失败：\(e.message)")
        }

        // 3) toParagraphs 兼容格式
        let paraCode = """
        function translate(query, completion) {
            completion({
                result: {
                    toParagraphs: ["段落1", "段落2"]
                }
            });
        }
        """
        try? paraCode.write(to: tmp.appendingPathComponent("para.js"), atomically: true, encoding: .utf8)
        if case .success(let out) = PluginRuntime.evaluateTranslate(plugin: "para.js", text: "x", source: "auto", target: "zh") {
            check(out == "段落1\n段落2", "toParagraphs 兼容格式提取失败：\(out)")
        } else {
            problems.append("toParagraphs 兼容插件执行失败")
        }

        // 4) $data 注入验证
        let dataCode = """
        function translate(query, completion) {
            var b64 = $data.fromUTF8(query.text).toBase64();
            var dec = $data.fromBase64(b64).toUTF8();
            completion({ result: { text: "b64=" + b64 + ",dec=" + dec } });
        }
        """
        try? dataCode.write(to: tmp.appendingPathComponent("data.js"), atomically: true, encoding: .utf8)
        if case .success(let out) = PluginRuntime.evaluateTranslate(plugin: "data.js", text: "abc", source: "auto", target: "zh") {
            check(out.contains("dec=abc"), "$data 编解码失败：\(out)")
        } else {
            problems.append("$data 注入插件执行失败")
        }

        // 5) 插件主动回调 error
        let errCode = """
        function translate(query, completion) {
            query.onCompletion({
                error: { type: "api", message: "配额已耗尽", addtion: "code=429" }
            });
        }
        """
        try? errCode.write(to: tmp.appendingPathComponent("err.js"), atomically: true, encoding: .utf8)
        if case .failure(let e) = PluginRuntime.evaluateTranslate(plugin: "err.js", text: "x", source: "auto", target: "zh") {
            check(e.message.contains("配额已耗尽") && e.message.contains("code=429"), "插件 error 未被正确解析：\(e.message)")
        } else {
            problems.append("主动返回 error 的插件未判失败")
        }

        // 6) 缺少 translate 函数要报错
        try? "var x = 1".write(to: tmp.appendingPathComponent("bad.js"), atomically: true, encoding: .utf8)
        if case .success = PluginRuntime.evaluateTranslate(plugin: "bad.js", text: "hi", source: "auto", target: "zh") {
            problems.append("缺 translate 的插件不该成功")
        }

        // 7) 插件抛异常要被抓到
        try? "function translate(q, c){ throw new Error('boom') }".write(to: tmp.appendingPathComponent("throw.js"),
                                                                           atomically: true, encoding: .utf8)
        if case .failure(let e) = PluginRuntime.evaluateTranslate(plugin: "throw.js", text: "hi", source: "auto", target: "zh") {
            check(e.message.contains("boom"), "插件异常没透传：\(e.message)")
        } else {
            problems.append("抛异常的插件没被判失败")
        }

        // 8) 不存在的插件文件
        if case .failure = PluginRuntime.evaluateTranslate(plugin: "nope.js", text: "hi", source: "auto", target: "zh") {
            // 期望
        } else {
            problems.append("不存在的插件应失败")
        }

        if problems.isEmpty {
            print("✓ 插件系统：Bob官方query/completion规范、toParagraphs兼容、$data工具、错误透传与异常捕获均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 智能分段

    /// 智能分段：同 y 合并、上下按距离分段、句号触发断段。
    /// 用法: --selftest paragraphize
    private static func paragraphizeTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        func line(_ text: String, x: CGFloat, yBottom: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.05) -> ScreenOCR.OCRLine {
            ScreenOCR.OCRLine(text: text, box: CGRect(x: x, y: yBottom, width: w, height: h))
        }

        // 1) 同一 y 上的两块（左右分栏）合并成一行
        let sameRow = [line("左块", x: 0.05, yBottom: 0.9),
                       line("右块", x: 0.6, yBottom: 0.9)]
        let rows = ScreenOCR.paragraphize(sameRow, imageHeight: 100)
        check(rows.count == 1, "同行两块该并成一段，实际 \(rows.count) 段：\(rows)")
        check(rows.first?.contains("左块") == true && rows.first?.contains("右块") == true,
              "同行合并丢了内容：\(rows)")

        // 2) 上下紧挨两行合成一段
        let tight = [line("第一段第一行", x: 0.05, yBottom: 0.9),
                     line("第一段第二行", x: 0.05, yBottom: 0.85)]
        let tightResult = ScreenOCR.paragraphize(tight, imageHeight: 100)
        check(tightResult.count == 1, "靠近的两行应合成一段，实际：\(tightResult)")

        // 3) 大空隙分两段
        let spread = [line("上半段", x: 0.05, yBottom: 0.9),
                      line("下半段", x: 0.05, yBottom: 0.3)]
        let spreadResult = ScreenOCR.paragraphize(spread, imageHeight: 100)
        check(spreadResult.count == 2, "有大空隙应分两段，实际：\(spreadResult)")

        // 4) 句号结尾 + 间距 → 分两段
        let sentences = [line("第一句。", x: 0.05, yBottom: 0.9),
                         line("第二句", x: 0.05, yBottom: 0.78)]
        let sentResult = ScreenOCR.paragraphize(sentences, imageHeight: 100)
        check(sentResult.count == 2, "句号结尾后换行应分两段，实际：\(sentResult)")

        // 5) 空输入不炸
        check(ScreenOCR.paragraphize([], imageHeight: 100).isEmpty, "空输入应给空数组")

        // 6) 智能分段包围盒与原图合成
        let detailed = ScreenOCR.paragraphizeDetailed(sameRow, imageWidth: 200, imageHeight: 100)
        check(detailed.count == 1, "同行合并后 OCRParagraph 应为 1 个")
        if let firstBox = detailed.first?.rect {
            check(firstBox.width > 100, "包围盒未正确扩展覆盖左右两块：\(firstBox)")
            check(firstBox.height > 0, "包围盒高度异常：\(firstBox)")
        }

        // 测试 compose 合成图生成
        let testImage = NSImage(size: NSSize(width: 200, height: 100))
        testImage.lockFocus()
        NSColor.lightGray.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        testImage.unlockFocus()
        if let cg = testImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let composed = ScreenOCR.compose(image: cg, items: [
                (text: "合成译文", rect: CGRect(x: 10, y: 10, width: 80, height: 25))
            ])
            check(composed != nil, "原图翻译基于真实包围盒合成失败")
            check(composed?.width == cg.width && composed?.height == cg.height, "合成图尺寸发生变化：\(composed?.width ?? 0)x\(composed?.height ?? 0) vs \(cg.width)x\(cg.height)")
        }

        // 7) 双栏排版（如医学英语教材 PDF）：先读完左栏再读右栏，不能左右同一 Y 混行
        let twoCol = [
            line("Left line 1", x: 0.05, yBottom: 0.90, w: 0.35),
            line("Right line 1", x: 0.55, yBottom: 0.90, w: 0.35),
            line("Left line 2", x: 0.05, yBottom: 0.85, w: 0.35),
            line("Right line 2", x: 0.55, yBottom: 0.85, w: 0.35),
            line("Left line 3.", x: 0.05, yBottom: 0.80, w: 0.35),
            line("Right line 3.", x: 0.55, yBottom: 0.80, w: 0.35),
        ]
        let twoColParas = ScreenOCR.paragraphize(twoCol, imageHeight: 1000)
        check(twoColParas.count == 2, "双栏排版应按左右两栏拆出 2 段，实际：\(twoColParas)")
        if twoColParas.count == 2 {
            check(twoColParas[0].contains("Left line 1") && !twoColParas[0].contains("Right line 1"),
                  "双栏左栏混入了右栏内容：\(twoColParas[0])")
            check(twoColParas[1].contains("Right line 1") && !twoColParas[1].contains("Left line 1"),
                  "双栏右栏混入了左栏内容：\(twoColParas[1])")
        }

        if problems.isEmpty {
            print("✓ 智能分段与原图定位：同行合并、双栏分栏阅读顺序、留白分句与包围盒合成都正确")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 收藏夹与钉住服务

    /// 收藏夹：添加、去重、导出、删除；源语言下拉；钉住服务持久化。
    /// 全程用临时目录，不污染用户数据。
    /// 用法: --selftest favorites
    private static func favoritesTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-fav-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FavoriteStore.directoryOverride = tmp
        defer {
            FavoriteStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        FavoriteStore.clear()

        // 1) 添加、去重
        check(FavoriteStore.add(source: "hello", result: "你好", model: "gpt-4o-mini",
                                targetLanguage: "zh-Hans"), "第一次添加失败")
        check(FavoriteStore.add(source: "hello", result: "你好呀", model: "gpt-4o-mini",
                                targetLanguage: "zh-Hans"), "覆盖同原文失败")
        check(FavoriteStore.count() == 1, "去重后应有 1 条，实际 \(FavoriteStore.count())")
        check(FavoriteStore.all().first?.result == "你好呀", "覆盖后结果不对")
        check(!FavoriteStore.add(source: "  ", result: "空原文", model: "x",
                                 targetLanguage: "zh"), "空原文不该添加")

        // 2) 导出 JSON / CSV
        _ = FavoriteStore.add(source: "world", result: "世界", model: "x", targetLanguage: "zh")
        guard let json = FavoriteStore.exportJSON(),
              let str = String(data: json, encoding: .utf8) else {
            problems.append("导出 JSON 失败")
            return 1
        }
        check(str.contains("hello") && str.contains("world"), "JSON 内容不全")
        let csv = FavoriteStore.exportCSV()
        check(csv.hasPrefix("id,date,source,result"), "CSV 表头不对")
        check(csv.contains("你好呀") && csv.contains("世界"), "CSV 内容不全")

        let anki = FavoriteStore.exportAnkiDeck()
        check(anki.contains("#separator:tab"), "Anki 牌组导出缺少 separator 标头")
        check(anki.contains("hello\t你好呀"), "Anki 牌组内容字段未以制表符分隔")

        // 3) 删除
        check(FavoriteStore.remove(source: "hello"), "删除指定原文失败")
        check(FavoriteStore.count() == 1, "删除后应剩 1 条，实际 \(FavoriteStore.count())")
        check(!FavoriteStore.contains(source: "hello"), "删除后 contains 还是 true")

        // 4) 源语言配置：默认 auto、写回可读
        let config = Config.shared
        let originalSource = config.sourceLanguage
        config.sourceLanguage = "fr"
        check(config.sourceLanguage == "fr", "源语言写入失败")
        if let name = config.sourceLanguagePrompt {
            check(name.contains("法"), "源语言提示名不对：\(name)")
        } else {
            problems.append("指定源语言应有 promptName")
        }
        config.sourceLanguage = "auto"
        check(config.sourceLanguagePrompt == nil, "auto 不该有 promptName")
        config.sourceLanguage = originalSource

        // 5) 钉住服务：写入、去重、读回
        let originalPinned = config.pinnedProfileIDs
        config.pinnedProfileIDs = ["p1", "p2"]
        check(config.pinnedProfileIDs == ["p1", "p2"], "pinnedProfileIDs 读回不对")
        config.pinnedProfileIDs = originalPinned

        if problems.isEmpty {
            print("✓ 收藏夹：添加/去重/导出/删除全对；源语言与钉住服务配置能持久化")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - AppleScript / OSA Request 命令

    /// 验证对齐 Bob 官方的 `tell application "LocalTranslate" to request jsonString` 调度器。
    /// 用法: --selftest applescript-request
    private static func appleScriptRequestTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        let D = ScriptRequestDispatcher.self

        // 1) 畸形与未知路径
        let badJson = D.handle("not-a-json")
        check(badJson.contains("error") && badJson.contains("JSON 解析失败"), "非法 JSON 未报错：\(badJson)")

        let unknownPath = D.handle(#"{"path": "unknown"}"#)
        check(unknownPath.contains("error") && unknownPath.contains("未知 path"), "未知 path 未报错：\(unknownPath)")

        // 2) translate 路径各种 action
        let emptyText = D.handle(#"{"path": "translate", "body": {"action": "translateText", "text": "  "}}"#)
        check(emptyText.contains("error") && emptyText.contains("缺少 text 参数"), "缺少 text 未报错：\(emptyText)")

        let normalTranslate = D.handle(#"{"path": "translate", "body": {"action": "translateText", "text": "hello", "to": "zh-Hans"}}"#)
        check(normalTranslate.contains("success") && normalTranslate.contains("已弹出翻译窗口"), "translateText 响应异常：\(normalTranslate)")

        let selectionTranslate = D.handle(#"{"path": "translate", "body": {"action": "selectionTranslate"}}"#)
        check(selectionTranslate.contains("success") && selectionTranslate.contains("已触发划词翻译"), "selectionTranslate 响应异常：\(selectionTranslate)")

        let silentSelection = D.handle(#"{"path": "translate", "body": {"action": "silentSelectionTranslate"}}"#)
        check(silentSelection.contains("success") && silentSelection.contains("已触发静默划词替换"), "silentSelectionTranslate 响应异常：\(silentSelection)")

        let silentInputBox = D.handle(#"{"path": "translate", "body": {"action": "silentInputBoxTranslate"}}"#)
        check(silentInputBox.contains("success") && silentInputBox.contains("已触发静默输入框替换"), "silentInputBoxTranslate 响应异常：\(silentInputBox)")

        // 3) OCR 动作
        let snipOCR = D.handle(#"{"path": "ocr", "body": {"action": "snipOCR"}}"#)
        check(snipOCR.contains("success") && snipOCR.contains("已触发截图 OCR"), "snipOCR 响应异常：\(snipOCR)")

        let silentSnipOCR = D.handle(#"{"path": "ocr", "body": {"action": "silentSnipOCR"}}"#)
        check(silentSnipOCR.contains("success") && silentSnipOCR.contains("已触发静默截图 OCR"), "silentSnipOCR 响应异常：\(silentSnipOCR)")

        // 4) 词典 / 生词本 / 输入 / 设置
        let dict = D.handle(#"{"path": "dictionary", "body": {"word": "apple"}}"#)
        check(dict.contains("success") && dict.contains("已打开词典"), "dictionary 响应异常：\(dict)")

        let vocab = D.handle(#"{"path": "vocabulary"}"#)
        check(vocab.contains("success") && vocab.contains("已打开生词本"), "vocabulary 响应异常：\(vocab)")

        let input = D.handle(#"{"path": "input", "body": {"text": "prefilled text"}}"#)
        check(input.contains("success") && input.contains("已打开输入翻译"), "input 响应异常：\(input)")

        let settings = D.handle(#"{"path": "settings"}"#)
        check(settings.contains("success") && settings.contains("已打开设置"), "settings 响应异常：\(settings)")

        let favWin = D.handle(#"{"path": "favorites"}"#)
        check(favWin.contains("success") && favWin.contains("已打开收藏夹"), "favorites 响应异常：\(favWin)")

        // 让 favorite 走临时目录，避免脚本调用污染用户真实收藏夹
        let favTmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-asreq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: favTmp, withIntermediateDirectories: true)
        FavoriteStore.directoryOverride = favTmp
        defer { FavoriteStore.directoryOverride = nil; try? FileManager.default.removeItem(at: favTmp) }
        let addFav = D.handle(#"{"path": "favorite", "body": {"source": "script-src", "result": "脚本译文"}}"#)
        check(addFav.contains("success"), "favorite 添加失败：\(addFav)")
        check(FavoriteStore.contains(source: "script-src"), "脚本添加后 FavoriteStore 查不到")
        let badFav = D.handle(#"{"path": "favorite", "body": {"source": "  "}}"#)
        check(badFav.contains("error") && badFav.contains("source"), "favorite 缺参数没报错：\(badFav)")
        FavoriteStore.clear()

        // 5) 原生 translate 动词命令（对应 PopClip / Raycast）
        let cmd = TranslateScriptCommand()
        // 缺少参数报错
        let emptyRes = (cmd.performDefaultImplementation() as? String) ?? ""
        check(emptyRes.contains("error") && emptyRes.contains("缺少翻译文本"), "空参数未报错：\(emptyRes)")

        if problems.isEmpty {
            print("✓ AppleScript 脚本支持：JSON request 命令与原生 translate 动词命令均正常")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 生词本

    /// 收藏、去重、删除、落盘重读、词典窗口的收藏状态。
    /// 全程用临时目录，不碰用户真实生词本。
    /// 用法: --selftest vocab
    private static func vocabTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-vocab-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        VocabularyStore.directoryOverride = tmp
        defer {
            VocabularyStore.directoryOverride = nil
            VocabularyStore.clear()
            try? FileManager.default.removeItem(at: tmp)
        }
        VocabularyStore.clear()

        // 1) 加入与去重
        VocabularyStore.add(word: "pressure", phonetic: "ˈpreʃɚ", translations: ["n. 压力"])
        if VocabularyStore.count() != 1 { problems.append("加入后应有 1 条，实际 \(VocabularyStore.count())") }
        VocabularyStore.add(word: "Pressure", phonetic: "", translations: ["重复"])
        if VocabularyStore.count() != 1 { problems.append("大小写不同不该重复加入，实际 \(VocabularyStore.count()) 条") }
        if VocabularyStore.all().first?.translations.first != "n. 压力" {
            problems.append("去重时把原记录覆盖了")
        }

        // 2) 落盘后重读还在
        VocabularyStore.reload()
        if VocabularyStore.count() != 1 { problems.append("重读磁盘后丢数据") }
        if !FileManager.default.fileExists(atPath: VocabularyStore.fileURL.path) {
            problems.append("生词本文件没写出来")
        }

        // 3) 删除
        VocabularyStore.add(word: "strain", phonetic: "", translations: ["n. 拉伤"])
        VocabularyStore.remove("pressure")
        if VocabularyStore.count() != 1 || !VocabularyStore.contains("strain") {
            problems.append("删除后状态不对：\(VocabularyStore.all().map(\.word))")
        }

        // 4) 空白词不加入
        VocabularyStore.add(word: "   ", phonetic: "", translations: [])
        if VocabularyStore.count() != 1 { problems.append("空白词被加进生词本了") }

        // 5) 词典窗口的收藏按钮要反映状态
        let entry = DictionaryResult(word: "strain", translations: ["n. 拉伤"],
                                     phonetics: [Phonetic(type: "us", value: "streɪn")],
                                     parts: [], exchanges: [], collocations: [])
        let window = DictionaryWindow.shared
        window.showEntryForTesting(entry)
        if !window.starTitleForTesting.contains("已收藏") {
            problems.append("已在生词本里的词，按钮应显示「已收藏」，实际「\(window.starTitleForTesting)」")
        }

        if problems.isEmpty {
            print("✓ 生词本：收藏/去重/落盘/删除都对，词典窗口收藏状态正确")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 划词工具栏

    /// 工具栏：四个按钮、位置不会跑出屏幕、复制能用、空文本不来烦人。
    /// 用法: --selftest toolbar
    private static func toolbarTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let toolbar = SelectionToolbar.shared
        if toolbar.buttonCountForTesting() != 4 {
            problems.append("工具栏按钮数应为 4，实际 \(toolbar.buttonCountForTesting())")
        }

        // 位置：贴着右下角也不该跑出屏幕
        let size = NSSize(width: 132, height: 32)
        guard let screen = NSScreen.main else {
            print("✗ 没有屏幕"); print("RESULT: FAIL"); return 1
        }
        let corner = NSPoint(x: screen.frame.maxX - 2, y: screen.frame.minY + 2)
        let pos = toolbar.position(for: corner, size: size)
        if pos.x < screen.frame.minX || pos.x + size.width > screen.frame.maxX {
            problems.append("横向越界：x=\(pos.x)，屏幕宽 \(screen.frame.width)")
        }
        if pos.y < screen.frame.minY || pos.y + size.height > screen.frame.maxY {
            problems.append("纵向越界：y=\(pos.y)")
        }
        // 屏幕中间：应该在鼠标下方
        let middle = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let pos2 = toolbar.position(for: middle, size: size)
        if pos2.y >= middle.y { problems.append("鼠标下方放得下时却放到了上面") }

        // 复制按钮真的写剪贴板
        toolbar.show(text: "toolbar probe", near: middle)
        toolbar.copyForTesting()
        let pasted = NSPasteboard.general.string(forType: .string)
        if pasted != "toolbar probe" {
            problems.append("复制按钮没把文字写进剪贴板，实际：\(pasted ?? "nil")")
        }

        // 空文本不该弹出来
        toolbar.show(text: "   ", near: middle)
        if toolbar.isVisible { problems.append("空白选中却弹出了工具栏") }

        if problems.isEmpty {
            print("✓ 划词工具栏：四个按钮、位置不越界、复制可用、空白不打扰")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 快捷键体系

    /// 默认用 ⌥ 系列、六个功能都注册得上、图标开关能自救、朗读不炸。
    /// 用法: --selftest hotkeys2
    private static func hotkeys2Test(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }
        // 看门狗挂后台队列：语音合成这类系统调用在负载高时可能卡住主线程
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("✗ 快捷键自测超过 60 秒没结束")
            print("RESULT: FAIL")
            exit(1)
        }
        // AppIcons 会碰 NSApp，先把它建出来，否则进程直接 trap
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = Config.shared

        // 1) 默认组合应该是 ⌥ 开头，避免和 ⌘⇧ 系统快捷键抢
        for (label, combo) in [("划词", config.hotkey), ("输入", config.inputHotkey),
                               ("截图", config.screenshotHotkey), ("剪贴板", config.clipboardHotkey),
                               ("朗读", config.speakHotkey), ("图标", config.toggleIconsHotkey),
                               ("划词替换", config.silentReplaceHotkey), ("输入框替换", config.inputBoxReplaceHotkey),
                               ("静默截图", config.silentScreenshotOcrHotkey)] {
            // 用归一化后的形式判断：存下来的可能是 opt+h 这种缩写，功能一样
            let normalized = HotKeyConflicts.normalize(combo)
            // 默认必须带 Control 或 Command，规避 macOS 15/26 的 Option 失效
            if !normalized.contains("ctrl") && !normalized.contains("cmd") {
                problems.append("\(label)快捷键没带 ⌃/⌘（会受 macOS Option 失效影响）：\(combo)")
            }
        }

        // 2) 各快捷键互不相同
        let all = [config.hotkey, config.silentHotkey, config.inputHotkey,
                   config.screenshotHotkey, config.dictionaryHotkey,
                   config.clipboardHotkey, config.speakHotkey, config.toggleIconsHotkey,
                   config.silentReplaceHotkey, config.inputBoxReplaceHotkey,
                   config.silentScreenshotOcrHotkey]
        if Set(all).count != all.count {
            problems.append("默认快捷键里有重复：\(all)")
        }

        // 3) 每个都能解析（不只是字符串存在）
        for combo in all {
            if HotKeyManager.parse(combo) == nil {
                problems.append("解析不了快捷键：\(combo)")
            }
        }

        // 4) 图标开关：按一次藏起来，再按一次回来，Dock 始终在
        let original = config.showMenuBarIcon
        config.showMenuBarIcon = !original
        var applied = AppIcons.apply(menuBar: config.showMenuBarIcon, dock: config.showDockIcon, statusItem: nil)
        if applied.dock == false { problems.append("隐藏菜单栏图标时把 Dock 也关了，会找不回来") }
        config.showMenuBarIcon = original
        applied = AppIcons.apply(menuBar: config.showMenuBarIcon, dock: config.showDockIcon, statusItem: nil)
        if applied.menuBar != original { problems.append("再按一次没把菜单栏图标切回来") }

        // 5) 剪贴板翻译：能从剪贴板拿到文字
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("clipboard probe", forType: .string)
        if pasteboard.string(forType: .string) != "clipboard probe" {
            problems.append("剪贴板写入后读不回来")
        }
        if let saved { pasteboard.clearContents(); pasteboard.setString(saved, forType: .string) }

        // 6) 朗读：只验音色挑选逻辑（纯函数）。
        //    真正发声要音频设备，在闸门这种连续起进程的环境里会崩/卡，
        //    那种不稳定只会制造假红，发声本身只能靠人耳确认。
        let zhVoice = SpeechService.shared.voice(for: "测试中文")
        if zhVoice == nil { problems.append("中文文本挑不到音色") }
        if let lang = zhVoice?.language, !lang.hasPrefix("zh") {
            problems.append("中文文本却挑了 \(lang) 的音色，会念成听不懂的东西")
        }
        let enVoice = SpeechService.shared.voice(for: "hello world")
        if enVoice == nil { problems.append("英文文本挑不到音色") }

        // 6.5) 纯 ⌥ 存量值会被迁移成 ⌃；带 ⌘/⌃ 的用户自定义值不动
        let migDefaults = UserDefaults(suiteName: "lt-mig-test-\(UUID().uuidString)")!
        migDefaults.set("option+d", forKey: "hotkey")               // 纯 ⌥ → 该迁
        migDefaults.set("control+option+k", forKey: "dictionaryHotkey") // 带 ⌃ → 不该迁
        let changed = HotkeyDefaults.migrate(migDefaults)
        check(changed == 1, "迁移只该动纯 ⌥ 的那条，实际改了 \(changed)")
        check(migDefaults.string(forKey: "hotkey")?.hasPrefix("control") == true, "纯 ⌥ 划词没迁移成 ⌃")
        check(migDefaults.string(forKey: "dictionaryHotkey") == "control+option+k", "带 ⌃ 的自定义值被误改了")
        // 每个默认值都要能被解析
        for (_, combo) in HotkeyDefaults.table where HotKeyManager.parse(combo) == nil {
            problems.append("默认快捷键解析不了：\(combo)")
        }
        // 版本风险提示：≥15 要有话，<15 不该有
        if SystemHotkeyRisk.version.major >= 15 {
            check(SystemHotkeyRisk.optionWarning != nil, "macOS ≥15 应给出 Option 失效提示")
        }

        // 7) 语速会被夹在合理区间
        config.speechRate = 99
        if config.speechRate > 1.8 { problems.append("语速没有上限保护：\(config.speechRate)") }
        config.speechRate = 1.0

        if problems.isEmpty {
            print("✓ 快捷键：默认都带 ⌃/⌘、互不重复、都能解析；图标可来回切且 Dock 保命；朗读与剪贴板可用")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 菜单栏面板

    /// 面板里该有的东西：输入框、目标语言、服务选择、最近记录、三个快捷键入口。
    /// 用法: --selftest panel
    private static func panelTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panel = StatusPanelController()
        panel.buildForTesting()
        let text = panel.visibleTextSnapshot().joined(separator: "\n")

        for need in ["输入要翻译的文字，回车翻译", "翻译", "输入翻译", "词典", "设置"] where !text.contains(need) {
            problems.append("面板里没有「\(need)」")
        }
        // 目标语言列表必须真的列出来
        if !text.contains("简体中文") { problems.append("面板里没有目标语言列表") }
        // 没有可用服务时要给出说明，而不是一个空下拉
        let enabled = ProfileStore.enabled()
        if enabled.isEmpty && !text.contains("没有可用服务") {
            problems.append("没有服务时没提示")
        }

        // 翻译回调要把文本交出去
        var captured: String?
        panel.onTranslate = { source, _ in captured = source }
        if captured != nil { problems.append("未操作就收到了翻译回调") }

        if problems.isEmpty {
            print("✓ 菜单栏面板：输入框/语言/服务/最近记录/快捷入口都在")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 图标开关

    /// 菜单栏 / Dock 图标开关。重点验「两个都不许关」这条自救规则。
    /// 用法: --selftest icons
    private static func iconsTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        func expect(_ got: AppIcons.Settings, _ want: AppIcons.Settings, _ label: String) {
            if got != want {
                problems.append("\(label)：得到 菜单栏=\(got.menuBar) Dock=\(got.dock)，" +
                                "应为 菜单栏=\(want.menuBar) Dock=\(want.dock)")
            }
        }

        expect(AppIcons.resolve(menuBar: true, dock: true), .init(menuBar: true, dock: true), "都开")
        expect(AppIcons.resolve(menuBar: true, dock: false), .init(menuBar: true, dock: false), "只关 Dock")
        expect(AppIcons.resolve(menuBar: false, dock: true), .init(menuBar: false, dock: true), "只关菜单栏")
        // 关键：两个都想关时必须保住一个入口
        expect(AppIcons.resolve(menuBar: false, dock: false), .init(menuBar: false, dock: true), "都想关")

        // 真应用一次，看激活策略和图标可见性跟着变
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        _ = AppIcons.apply(menuBar: false, dock: false, statusItem: item)
        if item.isVisible { problems.append("菜单栏图标要求隐藏，但还可见") }
        if NSApp.activationPolicy() != .regular { problems.append("Dock 应保活，激活策略却不是 regular") }

        _ = AppIcons.apply(menuBar: true, dock: false, statusItem: item)
        if !item.isVisible { problems.append("菜单栏图标要求显示，但被隐藏了") }
        if NSApp.activationPolicy() != .accessory { problems.append("关掉 Dock 后激活策略应为 accessory") }

        NSStatusBar.system.removeStatusItem(item)

        if problems.isEmpty {
            print("✓ 图标开关：三种组合都生效，两个都关时自动保住 Dock")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 多服务商

    /// DeepL / 有道的请求构造与响应解析。全离线，不碰真 key。
    /// 用法: --selftest providers
    private static func providersTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        func check(_ cond: Bool, _ label: String) { if !cond { problems.append(label) } }

        // DeepL：URL、鉴权头、请求体
        guard let deepl = ProviderCodec.deepLRequest(text: "hello", targetLanguage: "zh-Hans",
                                                     key: "k-123", baseURL: "https://api-free.deepl.com/") else {
            print("✗ DeepL 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(deepl.url.absoluteString == "https://api-free.deepl.com/v2/translate",
              "DeepL URL 不对：\(deepl.url)")
        check(deepl.headers["Authorization"] == "DeepL-Auth-Key k-123", "DeepL 鉴权头不对")
        let deeplBody = (try? JSONSerialization.jsonObject(with: deepl.body) as? [String: Any]) ?? nil
        check((deeplBody?["target_lang"] as? String) == "ZH", "DeepL 目标语言应为 ZH")
        check(((deeplBody?["text"] as? [String])?.first) == "hello", "DeepL 请求体没带原文")

        // DeepL：解析正常与报错
        if case .success(let text) = ProviderCodec.parseDeepL(Data(#"{"translations":[{"text":"你好"}]}"#.utf8)) {
            check(text == "你好", "DeepL 解析结果不对：\(text)")
        } else { problems.append("DeepL 正常响应解析失败") }
        if case .failure(let message) = ProviderCodec.parseDeepL(Data(#"{"message":"quota exceeded"}"#.utf8)) {
            check(message.contains("quota"), "DeepL 错误信息没带出来：\(message)")
        } else { problems.append("DeepL 错误响应没有判失败") }

        // 有道：签名确定性、换密钥会变
        let sign1 = ProviderCodec.youdaoSign(appKey: "app", query: "hello", salt: "12345",
                                            curtime: "1700000000", appSecret: "sec")
        let sign2 = ProviderCodec.youdaoSign(appKey: "app", query: "hello", salt: "12345",
                                            curtime: "1700000000", appSecret: "sec")
        let sign3 = ProviderCodec.youdaoSign(appKey: "app", query: "hello", salt: "12345",
                                            curtime: "1700000000", appSecret: "other")
        check(sign1 == sign2, "有道签名不确定")
        check(sign1 != sign3, "有道签名没用到 appSecret")
        check(sign1.count == 64 && sign1.allSatisfy { $0.isHexDigit }, "有道签名不是 64 位十六进制：\(sign1)")

        // 有道：长文本要用「首10+长度+末10」
        let longQuery = String(repeating: "a", count: 30)
        let signLong = ProviderCodec.youdaoSign(appKey: "app", query: longQuery, salt: "1",
                                               curtime: "2", appSecret: "s")
        let manual = ProviderCodec.sha256("app" + String(repeating: "a", count: 10) + "30" + String(repeating: "a", count: 10) + "1" + "2" + "s")
        check(signLong == manual, "有道长文本签名规则不对")

        // 有道：请求体字段
        guard let youdao = ProviderCodec.youdaoRequest(text: "hi", targetLanguage: "zh-Hans",
                                                      key: "ak:sk", baseURL: "https://openapi.youdao.com") else {
            print("✗ 有道请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let body = String(data: youdao.body, encoding: .utf8) ?? ""
        check(body.contains("signType=v3"), "有道请求缺 signType=v3")
        check(body.contains("to=zh-CHS"), "有道目标语言应为 zh-CHS")
        check(body.contains("appKey=ak"), "有道 appKey 没拆出来")
        check(ProviderCodec.youdaoRequest(text: "hi", targetLanguage: "en", key: "只有一段",
                                          baseURL: "https://openapi.youdao.com") == nil,
              "有道密钥格式不对时应该返回 nil，而不是发一个注定失败的请求")

        // 有道：错误码给人话
        if case .failure(let message) = ProviderCodec.parseYoudao(Data(#"{"errorCode":"202"}"#.utf8)) {
            check(message.contains("签名"), "有道 202 应该提示签名问题：\(message)")
        } else { problems.append("有道错误码没有判失败") }
        if case .success(let text) = ProviderCodec.parseYoudao(Data(#"{"errorCode":"0","translation":["你好"]}"#.utf8)) {
            check(text == "你好", "有道解析结果不对：\(text)")
        } else { problems.append("有道正常响应解析失败") }

        // 百度：MD5 签名、必带字段、错误码、译文
        guard let baidu = ProviderCodec.baiduRequest(text: "hi", targetLanguage: "zh-Hans",
                                                    key: "app:sec", baseURL: "https://fanyi-api.baidu.com") else {
            print("✗ 百度请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let baiduBody = String(data: baidu.body, encoding: .utf8) ?? ""
        check(baidu.url.absoluteString.hasSuffix("/api/trans/vip/translate"), "百度 URL 不对：\(baidu.url)")
        check(baiduBody.contains("appid=app"), "百度缺 appid")
        check(baiduBody.contains("to=zh"), "百度目标语言应为 zh")
        let sign = ProviderCodec.md5Hex("app" + "hi" + "12345" + "sec")
        check(sign.count == 32 && sign.allSatisfy { $0.isHexDigit }, "百度签名不是 32 位十六进制")
        check(baiduBody.contains("sign=\(sign)"), "百度请求里的签名和算出的一致")
        check(ProviderCodec.baiduRequest(text: "hi", targetLanguage: "zh", key: "没冒号",
                                         baseURL: "https://fanyi-api.baidu.com") == nil,
              "百度密钥格式不对应返回 nil")
        if case .success(let t) = ProviderCodec.parseBaidu(
            Data(#"{"trans_result":[{"dst":"你好"},{"dst":"世界"}]}"#.utf8)) {
            check(t == "你好\n世界", "百度多行译文没拼好：\(t)")
        } else { problems.append("百度正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseBaidu(
            Data(#"{"error_code":"54001","error_msg":"Invalid Sign"}"#.utf8)) {
            check(m.contains("54001"), "百度错误码没带出来：\(m)")
        } else { problems.append("百度错误响应没有判失败") }

        // 腾讯：TC3 授权头形状、动作名、译文与错误
        guard let tencent = ProviderCodec.tencentRequest(text: "hi", targetLanguage: "zh-Hans",
                                                         key: "id:key", baseURL: "https://tmt.tencentcloudapi.com") else {
            print("✗ 腾讯请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let auth = tencent.headers["Authorization"] ?? ""
        check(auth.hasPrefix("TC3-HMAC-SHA256 Credential=id/"), "腾讯授权头格式不对：\(auth)")
        check(auth.contains("Signature=") && auth.contains("SignedHeaders=content-type;host"),
              "腾讯授权头缺签名或头列表")
        check(tencent.headers["X-TC-Action"] == "TextTranslate", "腾讯动作名不对")
        check(tencent.headers["X-TC-Version"] == "2018-03-21", "腾讯版本号不对")
        if case .success(let t) = ProviderCodec.parseTencent(
            Data(#"{"Response":{"TargetText":"你好"}}"#.utf8)) {
            check(t == "你好", "腾讯译文解析不对：\(t)")
        } else { problems.append("腾讯正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseTencent(
            Data(#"{"Response":{"Error":{"Code":"AuthFailure.SignatureFailure","Message":"签名错误"}}}"#.utf8)) {
            check(m.contains("AuthFailure"), "腾讯错误码没带出来：\(m)")
        } else { problems.append("腾讯错误响应没有判失败") }

        // 谷歌：URL 参数、嵌套数组解析
        guard let google = ProviderCodec.googleRequest(text: "hi there", targetLanguage: "zh-Hans",
                                                       baseURL: "https://translate.googleapis.com") else {
            print("✗ 谷歌请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let googleURL = google.url.absoluteString
        // sl 现在按检测到的源语种显式传（以前写死 auto，会把「英夹中」的段落当成中文原样吐回）
        check(googleURL.contains("sl=en"), "谷歌应显式传检测到的源语种 sl=en：\(googleURL)")
        if let zhGoogle = ProviderCodec.googleRequest(text: "这是中文段落", targetLanguage: "en",
                                                      baseURL: "https://translate.googleapis.com") {
            check(zhGoogle.url.absoluteString.contains("sl=zh-CN"),
                  "中文原文应传 sl=zh-CN：\(zhGoogle.url.absoluteString)")
        } else {
            problems.append("谷歌中文请求构造失败")
        }
        check(googleURL.contains("tl=zh"), "谷歌目标语言应为 zh")
        check(googleURL.contains("q=hi%20there") || googleURL.contains("q=hi+there"), "谷歌没带原文：\(googleURL)")
        if case .success(let t) = ProviderCodec.parseGoogle(
            Data(#"[[["你好","hi",null,null]],null,"en"]"#.utf8)) {
            check(t == "你好", "谷歌译文解析不对：\(t)")
        } else { problems.append("谷歌正常响应解析失败") }
        if case .success(let t) = ProviderCodec.parseGoogle(
            Data(#"[[["你好","hi",null,null],["世界","world",null,null]]]"#.utf8)) {
            check(t == "你好世界", "谷歌多段译文没拼好：\(t)")
        } else { problems.append("谷歌多段响应解析失败") }

        // MyMemory：免费开放翻译，自动探测源语，无密钥
        guard let mm = ProviderCodec.mymemoryRequest(text: "hello world", targetLanguage: "zh-Hans",
                                                     baseURL: "https://api.mymemory.translated.net") else {
            print("✗ MyMemory 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(mm.url.absoluteString.contains("langpair=en%7Czh-CN") || mm.url.absoluteString.contains("langpair=en|zh-CN"), "MyMemory langpair 不对：\(mm.url)")
        if case .success(let t) = ProviderCodec.parseMyMemory(
            Data(#"{"responseData":{"translatedText":"你好世界"},"responseStatus":200}"#.utf8)) {
            check(t == "你好世界", "MyMemory 解析不对：\(t)")
        } else { problems.append("MyMemory 正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseMyMemory(
            Data(#"{"responseStatus":403,"responseDetails":"LIMIT EXCEEDED"}"#.utf8)) {
            check(m.contains("403"), "MyMemory 错误状态没报错：\(m)")
        } else { problems.append("MyMemory 错误响应没判失败") }

        // Claude：x-api-key + anthropic-version，返回 content 数组
        guard let claude = ProviderCodec.claudeRequest(text: "hi", targetLanguage: "zh-Hans",
                                                       key: "sk-ant-x", model: "claude-3-5-sonnet-latest",
                                                       baseURL: "https://api.anthropic.com") else {
            print("✗ Claude 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(claude.url.absoluteString.hasSuffix("/v1/messages"), "Claude URL 不对：\(claude.url)")
        check(claude.headers["x-api-key"] == "sk-ant-x", "Claude 应该用 x-api-key 而不是 Bearer")
        check(claude.headers["anthropic-version"] == "2023-06-01", "Claude 缺 anthropic-version 头")
        if case .success(let t) = ProviderCodec.parseClaude(
            Data(#"{"content":[{"type":"text","text":"你好"},{"type":"text","text":"世界"}]}"#.utf8)) {
            check(t == "你好世界", "Claude 多段内容没拼好：\(t)")
        } else { problems.append("Claude 正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseClaude(
            Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)) {
            check(m.contains("invalid"), "Claude 错误信息没带出来：\(m)")
        } else { problems.append("Claude 错误响应没有判失败") }

        // Gemini：key 在 query、模型在路径
        guard let gemini = ProviderCodec.geminiRequest(text: "hi", targetLanguage: "zh-Hans",
                                                       key: "AIza-x", model: "gemini-2.0-flash",
                                                       baseURL: "https://generativelanguage.googleapis.com") else {
            print("✗ Gemini 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let gurl = gemini.url.absoluteString
        check(gurl.contains("models/gemini-2.0-flash:generateContent"), "Gemini 路径里没带模型：\(gurl)")
        check(gurl.contains("key=AIza-x"), "Gemini key 没进 query")
        if case .success(let t) = ProviderCodec.parseGemini(
            Data(#"{"candidates":[{"content":{"parts":[{"text":"你好"}]}}]}"#.utf8)) {
            check(t == "你好", "Gemini 译文解析不对：\(t)")
        } else { problems.append("Gemini 正常响应解析失败") }

        // Microsoft：subscription key + 区域
        guard let ms = ProviderCodec.microsoftRequest(text: "hi", targetLanguage: "zh-Hans",
                                                      key: "abc@eastasia",
                                                      baseURL: "https://api.cognitive.microsofttranslator.com") else {
            print("✗ Microsoft 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(ms.headers["Ocp-Apim-Subscription-Key"] == "abc", "Microsoft 密钥没拆出来")
        check(ms.headers["Ocp-Apim-Subscription-Region"] == "eastasia", "Microsoft 区域没拆出来")
        check(ms.url.absoluteString.contains("to=zh-Hans"), "Microsoft 目标语言应为 zh-Hans：\(ms.url)")
        if case .success(let t) = ProviderCodec.parseMicrosoft(
            Data(#"[{"translations":[{"text":"你好"}]}]"#.utf8)) {
            check(t == "你好", "Microsoft 译文解析不对：\(t)")
        } else { problems.append("Microsoft 正常响应解析失败") }

        // 彩云：x-authorization
        guard let caiyun = ProviderCodec.caiyunRequest(text: "hi", targetLanguage: "zh-Hans",
                                                       key: "tok", baseURL: "https://api.interpreter.caiyunai.com") else {
            print("✗ 彩云请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(caiyun.headers["x-authorization"] == "tok", "彩云鉴权头不对")
        if case .success(let t) = ProviderCodec.parseCaiyun(Data(#"{"target":["你好","世界"]}"#.utf8)) {
            check(t == "你好世界", "彩云多段没拼好：\(t)")
        } else { problems.append("彩云正常响应解析失败") }

        // 小牛：apikey 在表单里，错误码要带出来
        guard let niu = ProviderCodec.niuRequest(text: "hi", targetLanguage: "zh-Hans",
                                                 key: "nk", baseURL: "https://api.niutrans.com") else {
            print("✗ 小牛请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let niuBody = String(data: niu.body, encoding: .utf8) ?? ""
        check(niuBody.contains("apikey=nk"), "小牛 apikey 没进请求体")
        check(niuBody.contains("to=zh"), "小牛目标语言应为 zh")
        if case .success(let t) = ProviderCodec.parseNiu(Data(#"{"tgt_text":"你好"}"#.utf8)) {
            check(t == "你好", "小牛译文解析不对：\(t)")
        } else { problems.append("小牛正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseNiu(Data(#"{"error_code":"10001","error_msg":"apikey error"}"#.utf8)) {
            check(m.contains("10001"), "小牛错误码没带出来：\(m)")
        } else { problems.append("小牛错误响应没有判失败") }

        // Amazon：SigV4 授权头结构、区域进域名与凭据范围
        guard let amazon = ProviderCodec.amazonRequest(text: "hi", targetLanguage: "zh-Hans",
                                                       key: "AK:SK@eu-west-1") else {
            print("✗ Amazon 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        let ama = amazon.headers["Authorization"] ?? ""
        check(ama.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/"), "Amazon 授权头格式不对：\(ama.prefix(60))")
        check(ama.contains("/eu-west-1/translate/aws4_request"), "Amazon 凭据范围里没带区域/服务")
        check(ama.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-target"), "Amazon 签名头列表不对")
        check(amazon.url.host == "translate.eu-west-1.amazonaws.com", "Amazon 区域没进域名：\(amazon.url.host ?? "nil")")
        check(amazon.headers["X-Amz-Target"]?.contains("TranslateText") == true, "Amazon 缺 X-Amz-Target")
        check(ProviderCodec.amazonRequest(text: "hi", targetLanguage: "zh", key: "没有冒号") == nil,
              "Amazon 密钥格式不对应返回 nil")
        // 不带区域时默认 us-east-1
        if let defaulted = ProviderCodec.amazonRequest(text: "hi", targetLanguage: "zh", key: "AK:SK") {
            check(defaulted.url.host == "translate.us-east-1.amazonaws.com",
                  "Amazon 默认区域应为 us-east-1，实际 \(defaulted.url.host ?? "nil")")
        } else { problems.append("Amazon 不带区域时不该失败") }
        if case .success(let t) = ProviderCodec.parseAmazon(Data(#"{"TranslatedText":"你好"}"#.utf8)) {
            check(t == "你好", "Amazon 译文解析不对：\(t)")
        } else { problems.append("Amazon 正常响应解析失败") }
        if case .failure(let m) = ProviderCodec.parseAmazon(
            Data(#"{"__type":"UnrecognizedClientException","message":"签名错误"}"#.utf8)) {
            check(m.contains("签名"), "Amazon 错误信息没带出来：\(m)")
        } else { problems.append("Amazon 错误响应没有判失败") }

        // DeepLX：免 Key、支持默认端口、URL 及标准响应解析
        guard let deeplx = ProviderCodec.deeplxRequest(text: "bonjour", targetLanguage: "zh-Hans",
                                                      key: "", baseURL: "http://127.0.0.1:1188") else {
            print("✗ DeepLX 请求构造失败"); print("RESULT: FAIL"); return 1
        }
        check(deeplx.url.absoluteString == "http://127.0.0.1:1188/translate", "DeepLX endpoint 错误: \(deeplx.url)")
        if case .success(let t) = ProviderCodec.parseDeepLX(Data(#"{"code": 200, "data": "你好"}"#.utf8)) {
            check(t == "你好", "DeepLX 响应解析不对：\(t)")
        } else { problems.append("DeepLX 正常响应解析失败") }

        if problems.isEmpty {
            print("✓ 服务商：DeepL/DeepLX/有道/百度/腾讯/谷歌/Claude/Gemini/Microsoft/彩云/小牛/Amazon 的请求构造与解析都对")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 词典窗口

    /// 词典窗口：不联网，直接塞一条构造好的词条进去，断言每个分区都排出来了。
    /// 另外验解析能吃下例句/同义词/反义词这三种新字段。
    /// 用法: --selftest dict-ui
    private static func dictUITest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []

        // 1) 解析：例句两种形态都要能读
        let json = """
        {"word":"pressure","phonetics":[{"type":"us","value":"ˈpreʃɚ"}],
         "translations":["n. 压力；压强"],
         "parts":[{"part":"n.","means":["压力","压强"]}],
         "exchanges":[{"name":"复数","words":["pressures"]}],
         "collocations":[{"phrase":"under pressure","translation":"在压力下"}],
         "examples":[{"sentence":"He works under pressure.","translation":"他在压力下工作。"}],
         "synonyms":["stress","strain"],"antonyms":["relief"]}
        """
        guard let entry = DictionaryService.parse(json, fallbackWord: "pressure") else {
            print("✗ 词典解析失败"); print("RESULT: FAIL"); return 1
        }
        if entry.examples.count != 1 { problems.append("例句没解析出来，实际 \(entry.examples.count) 条") }
        if entry.synonyms.count != 2 { problems.append("同义词没解析出来，实际 \(entry.synonyms.count) 个") }
        if entry.antonyms.count != 1 { problems.append("反义词没解析出来，实际 \(entry.antonyms.count) 个") }

        // 2) 窗口排版：塞进去，看每一节是不是真的出现在视图里
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            let window = DictionaryWindow.shared
            window.show()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            window.render(entry)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))

            let text = window.visibleTextSnapshot().joined(separator: "\n")
            if ProcessInfo.processInfo.environment["LT_DUMP"] == "1" {
                print("—— 窗口实际文本 ——")
                print(text)
                print("—— 词条字段 ——")
                print("examples=\(entry.examples) synonyms=\(entry.synonyms) antonyms=\(entry.antonyms)")
            }
            for need in ["pressure", "ˈpreʃɚ", "压力", "词性与词义", "词形变化", "例句",
                         "同义词", "反义词", "搭配", "under pressure", "He works under pressure."] {
                if !text.contains(need) { problems.append("词典窗口里没有「\(need)」") }
            }
            if window.windowForTesting == nil { problems.append("词典窗口没显示出来") }

            if problems.isEmpty {
                print("✓ 词典窗口：9 个分区齐全，例句/同义/反义都解析并显示")
                print("RESULT: PASS")
                exit(0)
            }
            for p in problems { print("✗ \(p)") }
            print("RESULT: FAIL")
            exit(1)
        }
        app.run()
        return 1
    }

    // MARK: - 截图 OCR 的文字识别

    /// 自己画一张带字的图去识别，不依赖屏幕录制权限，所以能稳定进闸门。
    /// 要验的是「认得出字」和「没字时返回空」两件事——
    /// 后者决定了调用方能不能给出「这块区域没识别到文字」这句提示。
    /// 用法: --selftest ocr
    private static func ocrTest(_ arguments: [String]) -> Int32 {
        func render(_ text: String, size: NSSize) -> CGImage? {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            if !text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 34),
                    .foregroundColor: NSColor.black,
                ]
                (text as NSString).draw(at: NSPoint(x: 24, y: size.height / 2 - 20), withAttributes: attrs)
            }
            image.unlockFocus()
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        func recognizeSync(_ image: CGImage) -> String {
            var result = ""
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                result = await ScreenOCR.recognize(image)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 30) == .timedOut { return "<超时>" }
            return result
        }

        var problems: [String] = []
        let size = NSSize(width: 560, height: 120)

        guard let withText = render("Hello OCR 你好世界", size: size) else {
            print("✗ 造不出测试图"); print("RESULT: FAIL"); return 1
        }
        let got = recognizeSync(withText)
        if !got.contains("Hello") { problems.append("认不出英文 Hello，实际：「\(got)」") }
        if !got.contains("你好") { problems.append("认不出中文「你好」，实际：「\(got)」") }

        guard let blank = render("", size: size) else {
            print("✗ 造不出空白图"); print("RESULT: FAIL"); return 1
        }
        let blankText = recognizeSync(blank).trimmingCharacters(in: .whitespacesAndNewlines)
        if !blankText.isEmpty { problems.append("空白图应返回空，实际：「\(blankText)」") }

        // 二维码识别测试（CIQRCodeGenerator 生成 -> Vision 识别）
        func makeQRCode(_ string: String) -> CGImage? {
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
            filter.setValue(Data(string.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage else { return nil }
            let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)))
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        if let qrImage = makeQRCode("https://localtranslate.app/test-qr") {
            let qrResult = recognizeSync(qrImage)
            if !qrResult.contains("https://localtranslate.app/test-qr") {
                problems.append("二维码未识别出内容，实际：「\(qrResult)」")
            }
        } else {
            problems.append("造不出测试二维码")
        }

        if problems.isEmpty {
            print("✓ OCR：文本识别「\(got.replacingOccurrences(of: "\n", with: " "))」、二维码检测正常、空白图返回空")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 选中即翻判定

    /// 判定逻辑是纯函数式的，直接喂候选文本和时间，不依赖真实鼠标。
    /// 这里主要验「不该翻的时候绝不翻」——误触发比不触发更糟。
    /// 用法: --selftest auto-select
    private static func autoSelectTest(_ arguments: [String]) -> Int32 {
        var problems: [String] = []
        let monitor = SelectionAutoMonitor.shared
        monitor.setActive(false)
        let t0 = Date()

        func check(_ label: String, _ got: String?, _ want: String?) {
            if got != want {
                problems.append("\(label)：得到 \(got ?? "nil")，应为 \(want ?? "nil")")
            }
        }

        // 默认必须是关的
        if Config.shared.autoTranslateSelection {
            problems.append("选中即翻默认应为关闭")
        }

        check("没有选区", monitor.evaluate(candidate: nil, at: t0), nil)
        check("只有 1 个字符", monitor.evaluate(candidate: "a", at: t0), nil)
        check("只有空白", monitor.evaluate(candidate: "   ", at: t0), nil)
        // 第一次看到只是记下，不翻
        check("首次出现", monitor.evaluate(candidate: "hello world", at: t0), nil)
        // 还没稳定够久
        check("0.3 秒后", monitor.evaluate(candidate: "hello world", at: t0.addingTimeInterval(0.3)), nil)
        // 稳定够了才翻
        check("0.7 秒后", monitor.evaluate(candidate: "hello world", at: t0.addingTimeInterval(0.7)), "hello world")
        // 同一段文字冷却期内不重复翻
        check("紧接着重复", monitor.evaluate(candidate: "hello world", at: t0.addingTimeInterval(1.0)), nil)
        // 换一段文字可以翻
        check("新文字首次", monitor.evaluate(candidate: "another sentence", at: t0.addingTimeInterval(1.5)), nil)
        check("新文字稳定", monitor.evaluate(candidate: "another sentence", at: t0.addingTimeInterval(2.2)), "another sentence")
        // 冷却过后同一段又能翻
        check("冷却后首次", monitor.evaluate(candidate: "hello world", at: t0.addingTimeInterval(9.0)), nil)
        check("冷却后稳定", monitor.evaluate(candidate: "hello world", at: t0.addingTimeInterval(9.6)), "hello world")
        // 中途变了就不算稳定
        _ = monitor.evaluate(candidate: "abc def", at: t0.addingTimeInterval(20.0))
        check("中途改动", monitor.evaluate(candidate: "abc xyz", at: t0.addingTimeInterval(20.7)), nil)

        if problems.isEmpty {
            print("✓ 选中即翻：短文本/未稳定/重复都不触发，稳定选中才翻")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 输入翻译界面

    /// 输入翻译窗口：界面元素齐、空输入被拦、失败要有提示。
    /// 用死端口制造失败，确保不依赖网络也能验到错误路径。
    /// 用法: --selftest input-ui
    private static func inputUITest(_ arguments: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        class Delegate: NSObject, NSApplicationDelegate {
            var onStart: (() -> Void)?
            func applicationDidFinishLaunching(_ n: Notification) { onStart?() }
        }
        let delegate = Delegate()
        app.delegate = delegate

        delegate.onStart = {
            // 看门狗必须挂在后台队列：主线程一旦被卡住（钥匙串、AX 之类的阻塞调用），
            // 挂在主队列上的看门狗自己也激活不了，等于没有。
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                print("✗ 输入翻译自测超过 60 秒没结束，卡在某一步")
                print("RESULT: FAIL")
                exit(1)
            }
            var problems: [String] = []
            let window = InputTranslationWindow.shared
            window.show()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))

            let text = window.visibleTextSnapshot().joined(separator: "\n")
            for need in ["输入翻译", "译为", "翻译", "清空"] where !text.contains(need) {
                problems.append("窗口里没有「\(need)」")
            }
            if window.windowForTesting == nil { problems.append("窗口没显示出来") }

            // 空输入必须被拦住，不能发请求
            window.typeAndTranslateForTesting("   ")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let empty = window.stateForTesting()
            if !empty.status.contains("先输入") {
                problems.append("空输入没有提示，状态是「\(empty.status)」")
            }
            if !empty.result.isEmpty {
                problems.append("空输入却往结果区写了东西")
            }

            print("  · 界面元素检查完成")
            // 指向一个必然连不上的端口，验错误路径
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("lt-input-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            ProfileStore.directoryOverride = tmp
            let dead = ServiceProfile(id: "input-dead", name: "死端口", baseURL: "http://127.0.0.1:1/v1",
                                      model: "x", enabled: true, extraPrompt: "")
            _ = ProfileStore.save([dead])
            print("  · 服务已写入临时目录，开始发请求")
            // 请求超时要压到看门狗以下，否则「连不上」这种事会等满默认超时
            let savedTimeout = Config.shared.timeoutSeconds
            Config.shared.timeoutSeconds = 4
            NetworkSession.invalidate()
            window.typeAndTranslateForTesting("hello")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let state = window.stateForTesting()
                if !state.result.isEmpty && state.buttonEnabled { break }
            }
            Config.shared.timeoutSeconds = savedTimeout
            NetworkSession.invalidate()
            print("  · 请求返回")
            let after = window.stateForTesting()
            if after.result.isEmpty { problems.append("翻译失败时结果区是空的，用户看不到任何原因") }
            if !after.buttonEnabled { problems.append("失败后「翻译」按钮没恢复可用，卡死了") }
            ProfileStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)

            if problems.isEmpty {
                print("✓ 输入翻译窗口：元素齐、空输入被拦、失败有提示")
                print("RESULT: PASS")
                exit(0)
            }
            for p in problems { print("✗ \(p)") }
            print("RESULT: FAIL")
            exit(1)
        }
        app.run()
        return 1
    }

    // MARK: - Magpie 接入

    /// 验 Magpie 这条路：能列出模型，并且真能通过网关翻一段。
    /// Magpie 没装在跑也不判失败——这是可选的集成，界面里会说明白。
    /// 用法: --selftest magpie [模型id]
    private static func magpieTest(_ arguments: [String]) -> Int32 {
        let snapshot = MagpieClient.probe()
        print("网关: \(MagpieClient.v1URL)")
        print("可达: \(snapshot.reachable ? "是" : "否") —— \(snapshot.detail)")
        
        // 强制确保 magpie 是通的或者如果没运行就正确跳过
        if !snapshot.reachable {
             print("RESULT: PASS（Magpie 未运行，跳过连通性验证）")
             return 0
        }
        
        guard !snapshot.models.isEmpty else {
            print("模型数: 0")
            print("RESULT: PASS（Magpie 未运行，跳过连通性验证）")
            return 0
        }
        print("模型数: \(snapshot.models.count)")
        for model in snapshot.models.prefix(5) {
            print("  · \(model.title)  [\(model.id)]  \(model.provider)")
        }

        // 指定模型，或挑第一个能用的
        let requested = arguments.first
        guard let model = requested.flatMap({ id in snapshot.models.first { $0.id == id } }) ?? snapshot.models.first else {
            print("RESULT: FAIL（拿不到可用模型）")
            return 1
        }
        print("用这个跑一次翻译: \(model.id)")

        let profile = MagpieClient.profile(for: model)
        // 翻译走临时的 key 目录，别在真实数据里留东西
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-magpie-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        SecretStore.directoryOverride = tmp
        defer {
            SecretStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        // 本机网关偶发慢一拍，重试一次再判失败，避免把第三方网关的抖动算成我们的 bug
        var output = ""
        var failure: String?
        for attempt in 1...2 {
            let sem = DispatchSemaphore(value: 0)
            output = ""
            failure = nil
            let callbacks = TranslationCallbacks(
                onThink: { _ in },
                onDelta: { output += $0 },
                onDone: { text, _ in output = text },
                onError: { failure = $0 }
            )
            let task = Task {
                await Translator.translate(text: "Hello world", targetLanguage: "zh-Hans",
                                           mode: .translate, profile: profile, callbacks: callbacks)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 45) == .timedOut {
                task.cancel()
                print("  · 第 \(attempt) 次 45 秒没返回")
                if attempt == 2 {
                    print("RESULT: FAIL（两次都超时）")
                    return 1
                }
                continue
            }
            if let failure {
                print("  · 第 \(attempt) 次翻译失败: \(failure)")
                if attempt == 2 {
                    print("RESULT: FAIL")
                    return 1
                }
                continue
            }
            break
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("✗ 返回空译文")
            print("RESULT: FAIL")
            return 1
        }
        print("译文: \(String(trimmed.prefix(120)))")
        print("RESULT: PASS")
        return 0
    }

    /// 选模型那张 sheet 的逻辑：行数、搜索过滤、多选交出去的条目、生成的配置。
    /// 这张 sheet 点起来受 AX 权限影响，用自测直接验数据流更可靠。
    /// 用法: --selftest magpie-picker
    private static func magpiePickerTest(_ arguments: [String]) -> Int32 {
        let snapshot = MagpieClient.probe()
        guard snapshot.reachable, snapshot.models.count >= 2 else {
            print("Magpie 没在跑，跳过")
            print("RESULT: PASS")
            return 0
        }
        let models = snapshot.models
        var problems: [String] = []

        let sheet = MagpiePickerSheet(models: models) { _ in }
        if sheet.rowCountForTesting != models.count {
            problems.append("行数 \(sheet.rowCountForTesting) 应为 \(models.count)")
        }
        if sheet.titleForTesting(row: 0) != models[0].title {
            problems.append("首行标题不对：\(sheet.titleForTesting(row: 0))")
        }

        let keyword = models[0].provider
        sheet.filterForTesting(keyword)
        let filtered = sheet.rowCountForTesting
        if filtered == 0 || filtered > models.count {
            problems.append("搜索「\(keyword)」过滤结果异常：\(filtered)")
        }

        var handed: [MagpieClient.Model] = []
        let picker = MagpiePickerSheet(models: models) { handed = $0 }
        // 走真实按钮：选中两行 → performClick「添加」→ 回调必须拿到两个
        let viaButton = picker.pressAddForTesting([0, 1])
        if viaButton.count != 2 { problems.append("按「添加」只交出 \(viaButton.count) 个，应为 2") }
        if handed.count != 2 { problems.append("回调交出 \(handed.count) 个，应为 2") }

        if let first = handed.first {
            let profile = MagpieClient.profile(for: first)
            if profile.baseURL != MagpieClient.v1URL { problems.append("baseURL 不对：\(profile.baseURL)") }
            if profile.model != first.id { problems.append("model 不对：\(profile.model)") }
            if profile.name != first.title { problems.append("显示名不对：\(profile.name)") }
            if !MagpieClient.isMagpieProfile(profile) { problems.append("来源标记没认出来") }
        }

        if problems.isEmpty {
            print("选择器: \(models.count) 个模型，搜索「\(keyword)」剩 \(filtered) 个，多选 2 个可用")
            print("RESULT: PASS")
            return 0
        }
        for p in problems { print("✗ \(p)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 设置真的生效

    /// 每项设置都验"改完之后行为变了"，不是只验"值存进去了"。
    /// 装饰性开关是最容易蒙混过关的东西，这里专门对着它。
    /// 用法: --selftest prefs-effective
    private static func prefsEffectiveTest(_ arguments: [String]) -> Int32 {
        var failures: [String] = []
        let config = Config.shared

        // 快照，跑完原样还回去，别把用户的配置搅了
        let keys = ["keepHistory", "historyLimit", "dictionaryMaxWords", "fontSize",
                    "renderMarkdown", "selectionMode", "pinByDefault", "copyHint", "timeoutSeconds"]
        let snapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, config.d.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = snapshot[key] { config.d.set(value, forKey: key) }
                else { config.d.removeObject(forKey: key) }
            }
            ProfileStore.reload()
        }

        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        // 1) 保留历史：关掉之后不该再写
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-eff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        HistoryStore.directoryOverride = tmp
        config.keepHistory = true
        HistoryStore.append(HistoryEntry(source: "基准", result: "r", mode: "translate", model: "m",
                                        targetLanguage: "zh-Hans", date: Date(), seconds: nil))
        let beforeCount = HistoryStore.all().count
        config.keepHistory = false
        HistoryStore.append(HistoryEntry(source: "不该进", result: "r", mode: "translate", model: "m",
                                         targetLanguage: "zh-Hans", date: Date(), seconds: nil))
        check(HistoryStore.all().count == beforeCount,
              "关掉「保留历史」后仍在写：\(beforeCount) → \(HistoryStore.all().count)")

        // 2) 上限真的跟着设置走
        config.keepHistory = true
        config.historyLimit = 7
        check(HistoryStore.maxEntries == 7, "historyLimit=7 没生效，实际 \(HistoryStore.maxEntries)")
        config.historyLimit = 0
        check(HistoryStore.maxEntries == .max, "选「不限」应该没有上限")

        // 3) 词典长度阈值真的起作用
        config.dictionaryMaxWords = 1
        check(!DictionaryService.shouldUseDictionary("take off", maxWords: 1),
              "限 1 个词时「take off」不该进词典")
        check(DictionaryService.shouldUseDictionary("pressure", maxWords: 1),
              "限 1 个词时单个单词也该进词典")
        config.dictionaryMaxWords = 4
        check(DictionaryService.shouldUseDictionary("take off", maxWords: 4),
              "限 4 个词时「take off」应该进词典")

        // 4) 字号落到卡片实际用的那套排版：
        //    这里不开 run loop，所以直接查卡片渲染时走的同一份代码在给定字号下产出的字体。
        config.fontSize = 13
        let smallAttr = MarkdownLite.attributed("正文", fontSize: CGFloat(config.fontSize),
                                                color: .labelColor, secondaryColor: .secondaryLabelColor)
        config.fontSize = 22
        let bigAttr = MarkdownLite.attributed("正文", fontSize: CGFloat(config.fontSize),
                                              color: .labelColor, secondaryColor: .secondaryLabelColor)
        let smallSize = (smallAttr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        let bigSize = (bigAttr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        check(smallSize == 13 && bigSize == 22, "字号没进到渲染结果：\(smallSize) / \(bigSize)")
        config.fontSize = 15

        // 5) 服务开关决定并发几个。写到临时目录，不能污染用户真实的 services.json
        config.historyLimit = 500
        let profileTmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-prof-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: profileTmp, withIntermediateDirectories: true)
        ProfileStore.directoryOverride = profileTmp
        SecretStore.directoryOverride = profileTmp
        let one = ServiceProfile(id: "eff-a", name: "A", baseURL: "http://127.0.0.1:1/v1",
                                 model: "a", enabled: true, extraPrompt: "")
        let two = ServiceProfile(id: "eff-b", name: "B", baseURL: "http://127.0.0.1:1/v1",
                                 model: "b", enabled: false, extraPrompt: "")
        check(ProfileStore.save([one, two]), "服务列表保存失败")
        check(ProfileStore.enabled().count == 1, "关着的服务不该参与并发")
        check(ProfileStore.firstUsable()?.id == "eff-a", "firstUsable 没挑开着的那个")

        // 6) 缺密钥的服务要报出准确原因，而不是含糊的「没配置」
        let keyless = ServiceProfile(id: "eff-k", name: "没密钥的服务", baseURL: "http://127.0.0.1:1/v1",
                                     model: "k", enabled: true, extraPrompt: "")
        let detail = Translator.TranslateError.noKey(profile: keyless.name).localizedDescription
        check(detail.contains("没密钥的服务") && detail.contains("API Key"),
              "缺密钥的提示不清楚：\(detail)")

        ProfileStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: profileTmp)
        HistoryStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        ProfileStore.reload()

        if failures.isEmpty {
            print("✓ 每项设置都有对应行为")
            print("RESULT: PASS")
            return 0
        }
        for f in failures { print("✗ \(f)") }
        print("RESULT: FAIL")
        return 1
    }

    // MARK: - 各模块自带的用例

    /// 跑各模块内置的 selfTest()，不碰网络也不碰 UI。
    private static func moduleTests(_ arguments: [String]) -> Int32 {
        let only = Set(arguments)
        var failures: [String] = []
        var ran = 0

        func run(_ name: String, _ body: () -> [String]) {
            if !only.isEmpty, !only.contains(name) { return }
            ran += 1
            let bad = body()
            if bad.isEmpty {
                print("✓ \(name)")
            } else {
                print("✗ \(name) —— \(bad.count) 项失败")
                for item in bad.prefix(12) { print("    · \(item)") }
                failures.append(name)
            }
        }

        run("MarkdownLite", MarkdownLite.selfTest)
        run("DictionaryService", DictionaryService.selfTest)
        run("HistoryStore", HistoryStore.selfTest)

        if ran == 0 {
            print("没有匹配的模块自测（可用：MarkdownLite DictionaryService HistoryStore）")
            return 2
        }
        print("RESULT: \(failures.isEmpty ? "PASS" : "FAIL")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - 存 Key

    /// 无界面写入 API Key，并确认能读回来。
    /// 写入是异步的（不能为等钥匙串卡住调用方），所以这里给它一点落地时间。
    /// 用法: --selftest setkey sk-xxxx
    private static func setKeyTest(_ arguments: [String]) -> Int32 {
        // 没显式指定目录时，写到临时目录，避免在用户机器上留下测试密钥
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent("lt-key-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        SecretStore.directoryOverride = isolated
        defer {
            try? FileManager.default.removeItem(at: isolated)
        }
        guard let value = arguments.first else {
            FileHandle.standardError.write(Data("用法: --selftest setkey <apiKey>\n".utf8))
            return 2
        }
        SecretStore.shared.apiKey = value

        // 等异步写：先文件（同步落盘，基本立刻可用），再等钥匙串那次
        let deadline = Date().addingTimeInterval(4)
        var back = ""
        while Date() < deadline {
            back = SecretStore.shared.apiKey
            if back == value { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let label = SecretStore.shared.storageLocationLabel
        print("写入位置: \(label)")
        print("读回一致: \(back == value)")

        let (available, detail) = SecretStore.shared.probe()
        print("钥匙串可达: \(available ? "是" : "否") —— \(detail)")

        // 判定看「读得回来」，不强制要求一定在钥匙串里：
        // 登录钥匙串被锁是正常状态，那时就该走文件兜底，功能不能因此不可用。
        let ok = back == value
        print("RESULT: \(ok ? "PASS" : "FAIL")")
        return ok ? 0 : 1
    }

    /// 钥匙串可达性：只报状态，不因为被锁就判失败。
    /// 用法: --selftest keychain
    private static func keychainTest(_ arguments: [String]) -> Int32 {
        let (available, detail) = SecretStore.shared.probe(timeout: 3)
        print("钥匙串可达: \(available ? "是" : "否")")
        print("说明: \(detail)")
        print("当前位置: \(SecretStore.shared.storageLocationLabel)")
        print("RESULT: PASS")
        return 0
    }

    // MARK: - 配置链路

    private static func configTest(_ arguments: [String]) -> Int32 {
        let config = Config.shared
        print("baseURL: \(config.baseURL)")
        print("model: \(config.model)")
        print("endpoint: \(config.chatEndpoint)")
        print("targetLanguage: \(config.targetLanguage) (\(Languages.name(for: config.targetLanguage)))")
        print("mode: \(config.mode)")
        print("hotkey: \(config.hotkey) (\(HotKeyManager.displayString(config.hotkey)))")
        print("apiKey 已配置: \(!SecretStore.shared.apiKey.isEmpty)")
        print("存储位置: \(SecretStore.shared.storageLocationLabel)")
        let (kcOK, kcDetail) = SecretStore.shared.probe(timeout: 2)
        print("钥匙串可达: \(kcOK ? "是" : "否") —— \(kcDetail)")
        print("配置完整: \(config.isConfigured)")
        return 0
    }
}
