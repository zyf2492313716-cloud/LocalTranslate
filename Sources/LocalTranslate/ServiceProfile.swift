import Foundation

/// 一个翻译服务配置条目。
///
/// 界面照 Bob 的「服务」页做成主从列表：左边一列服务，每行一个开关，
/// 选中哪行右边就显示它的 Base URL / 模型 / 密钥。开着的服务一起用，
/// 多个就变成卡片底部的对比标签——所以「开关」这件事必须落在数据层，
/// 不能只画个样式好看。
struct ServiceProfile: Codable, Equatable, Identifiable {
    var id: String
    /// 列表里显示的名字，比如「OpenAI」「DeepSeek」
    var name: String
    /// 不含 /chat/completions 的基础地址
    var baseURL: String
    var model: String
    var enabled: Bool
    /// 自定义 Prompt，追加到系统提示后面；每个服务可以不一样
    var extraPrompt: String
    /// 来自 Magpie 的模型 id（provider/model）。非 Magpie 的服务是 nil。
    /// 用它标记来源，这样换 Magpie 地址时能识别哪些条目跟着走。
    var magpieModel: String?
    /// 服务商：openai / deepl / youdao。老配置没有这个键就是 openai。
    var provider: String?
    /// JavaScript 插件文件名（provider=plugin 时用）
    var pluginFile: String?
    /// 用户指令变量模板（支持 $query.text, $query.detectToLang, $query.detectFromLang）
    var userPromptTemplate: String?
    /// OpenAI / 推理模型推理强度（default / none / minimal / low / medium / high）
    var reasoningEffort: String?

    /// 服务商类型
    var providerKind: ProviderKind { ProviderKind(rawValue: provider ?? "openai") ?? .openai }

    static func == (lhs: ServiceProfile, rhs: ServiceProfile) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.baseURL == rhs.baseURL
            && lhs.model == rhs.model && lhs.enabled == rhs.enabled
            && lhs.extraPrompt == rhs.extraPrompt && lhs.magpieModel == rhs.magpieModel
            && lhs.provider == rhs.provider && lhs.pluginFile == rhs.pluginFile
            && lhs.userPromptTemplate == rhs.userPromptTemplate && lhs.reasoningEffort == rhs.reasoningEffort
    }

    /// 完整 endpoint
    var chatEndpoint: String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return base }
        return base + "/chat/completions"
    }

    /// 能不能拿去发请求。
    /// Apple 系统翻译没有 baseURL 也没有模型名，但它是可用的——不能按 URL 判。
    var isConfigured: Bool {
        switch providerKind {
        case .apple:
            // 系统翻译：没有地址也没有模型，但可用
            return true
        case .plugin:
            return !(pluginFile ?? "").isEmpty
        case .openai:
            // OpenAI 兼容必须有地址和模型名
            return isValidURL && !model.isEmpty
        default:
            // DeepL / 百度 / 腾讯 / 谷歌 / MyMemory / 有道 / 彩云 / 小牛 / Amazon / DeepLX
            return isValidURL
        }
    }

    var isLoopback: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// 地址是否可用。
    /// 之前用「字符串里有点」判断，把 http://localhost:11434 这类本地服务全判成无效——
    /// 本地服务本来就不该有点。改成真正解析 URL。
    var isValidURL: Bool {
        guard let url = URL(string: chatEndpoint), let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// 密钥按服务分开存，account 用 id，这样多个服务各自的 key 互不干扰
    var keyAccount: String { "profile-\(id)" }

    /// 常见服务商预设，新建时给个起点
    enum Preset: String, CaseIterable {
        case apple
        case google
        case bing
        case youdaoFree
        case caiyunFree
        case volcengineFree
        case mymemory
        case deeplx
        case ollama
        case lmstudio
        case zhipu, siliconflow, groq, gemini
        case deepl, youdao, baidu, tencent, niu
        case deepseek, openai, azureLike = "azure", moonshot, minimax, custom
        case grok, openrouter, qwen, ernie, doubao, hunyuan, gitee, ai302, aihubmix, sophnet
        case claude, microsoft, caiyun, amazon

        var title: String {
            switch self {
            case .openai: return "OpenAI"
            case .azureLike: return "Azure OpenAI"
            case .deepseek: return "DeepSeek"
            case .moonshot: return "Moonshot Kimi"
            case .zhipu: return "智谱 GLM"
            case .minimax: return "MiniMax"
            case .siliconflow: return "硅基流动"
            case .ollama: return "本地 Ollama"
            case .custom: return "自定义（OpenAI 兼容）"
            case .deepl: return "DeepL"
            case .youdao: return "有道智云"
            case .baidu: return "百度翻译"
            case .tencent: return "腾讯云翻译"
            case .google: return "谷歌翻译（免密钥）"
            case .bing: return "必应翻译（免密钥）"
            case .youdaoFree: return "有道翻译（免密钥）"
            case .caiyunFree: return "彩云小译（免密钥）"
            case .volcengineFree: return "火山翻译（免密钥）"
            case .mymemory: return "MyMemory 翻译（免密钥）"
            case .groq: return "Groq"
            case .grok: return "Grok (xAI)"
            case .openrouter: return "OpenRouter"
            case .lmstudio: return "本地 LM Studio"
            case .qwen: return "通义千问"
            case .ernie: return "文心一言"
            case .doubao: return "豆包"
            case .hunyuan: return "腾讯混元"
            case .gitee: return "模力方舟"
            case .ai302: return "302.AI"
            case .aihubmix: return "AIHubMix"
            case .sophnet: return "SophNet"
            case .claude: return "Claude"
            case .gemini: return "Gemini"
            case .microsoft: return "Microsoft 翻译"
            case .caiyun: return "彩云小译"
            case .niu: return "小牛翻译"
            case .amazon: return "Amazon 翻译"
            case .apple: return "Apple 翻译（免配置）"
            case .deeplx: return "DeepLX (自建/免费)"
            }
        }

        /// 完全免密钥可直接使用
        var isZeroKey: Bool {
            switch self {
            case .apple, .google, .mymemory, .deeplx, .ollama, .lmstudio: return true
            default: return false
            }
        }

        /// 有没有免费额度（Bob 页面上标 🎁 的那种），本地跑的也算
        var freeTier: Bool {
            switch self {
            case .zhipu, .siliconflow, .groq, .gemini, .deepl, .baidu, .tencent, .niu, .lmstudio, .ollama, .deeplx, .apple, .google, .mymemory: return true
            default: return false
            }
        }

        /// 下拉菜单里显示的文字
        var menuTitle: String {
            if self == .apple { return "Apple 翻译（离线，免费免配置）" }
            if self == .google { return "谷歌翻译（免费免密钥）" }
            if self == .mymemory { return "MyMemory 翻译（免费免密钥）" }
            if self == .ollama || self == .lmstudio { return title + "（本地，免费免密钥）" }
            return freeTier ? title + "（有免费额度）" : title
        }

        /// 这个预设对应哪种协议
        var providerKind: ProviderKind {
            switch self {
            case .deepl: return .deepl
            case .youdao: return .youdao
            case .baidu: return .baidu
            case .tencent: return .tencent
            case .google: return .google
            case .bing: return .bing
            case .youdaoFree: return .youdaoFree
            case .caiyunFree: return .caiyunFree
            case .volcengineFree: return .volcengineFree
            case .mymemory: return .mymemory
            case .claude: return .claude
            case .gemini: return .gemini
            case .microsoft: return .microsoft
            case .caiyun: return .caiyun
            case .niu: return .niu
            case .amazon: return .amazon
            case .apple: return .apple
            case .deeplx: return .deeplx
            default: return .openai
            }
        }

        var baseURL: String {
            switch self {
            case .deepl: return "https://api-free.deepl.com"
            case .youdao: return "https://openapi.youdao.com"
            case .baidu: return "https://fanyi-api.baidu.com"
            case .tencent: return "https://tmt.tencentcloudapi.com"
            case .google: return "https://translate.googleapis.com"
            case .bing: return "https://cn.bing.com"
            case .youdaoFree: return "https://aidemo.youdao.com"
            case .caiyunFree: return "https://interpreter.cyapi.cn"
            case .volcengineFree: return "https://translate.volcengine.com"
            case .mymemory: return "https://api.mymemory.translated.net"
            case .openai: return "https://api.openai.com/v1"
            case .azureLike: return "https://你的资源.openai.azure.com/openai"
            case .deepseek: return "https://api.deepseek.com/v1"
            case .moonshot: return "https://api.moonshot.cn/v1"
            case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
            case .minimax: return "https://api.minimaxi.com/v1"
            case .siliconflow: return "https://api.siliconflow.cn/v1"
            case .ollama: return "http://localhost:11434/v1"
            case .custom: return ""
            case .groq: return "https://api.groq.com/openai/v1"
            case .grok: return "https://api.x.ai/v1"
            case .openrouter: return "https://openrouter.ai/api/v1"
            case .lmstudio: return "http://127.0.0.1:1234/v1"
            case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .ernie: return "https://qianfan.baidubce.com/v2"
            case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
            case .hunyuan: return "https://api.hunyuan.cloud.tencent.com/v1"
            case .gitee: return "https://api.moark.com/v1"
            case .ai302: return "https://api.302.ai/v1"
            case .aihubmix: return "https://aihubmix.com/v1"
            case .sophnet: return "https://www.sophnet.com/api/open-apis/v1"
            case .claude: return "https://api.anthropic.com"
            case .gemini: return "https://generativelanguage.googleapis.com"
            case .microsoft: return "https://api.cognitive.microsofttranslator.com"
            case .caiyun: return "https://api.interpreter.caiyunai.com"
            case .niu: return "https://api.niutrans.com"
            case .amazon: return "https://translate.us-east-1.amazonaws.com"
            case .apple: return ""
            case .bing: return ""
            case .youdaoFree: return ""
            case .caiyunFree: return ""
            case .volcengineFree: return ""
            case .deeplx: return "http://127.0.0.1:1188"
            }
        }

        var model: String {
            switch self {
            case .openai: return "gpt-4o-mini"
            case .azureLike: return "我的部署名"
            case .deepseek: return "deepseek-chat"
            case .moonshot: return "kimi-k2-0711-preview"
            case .zhipu: return "glm-4-flash"
            case .minimax: return "MiniMax-M1"
            case .siliconflow: return "deepseek-ai/DeepSeek-V3"
            case .ollama: return "qwen2.5:7b"
            case .custom: return ""
            case .deepl: return ""
            case .bing: return ""
            case .youdaoFree: return ""
            case .caiyunFree: return ""
            case .volcengineFree: return ""
            case .deeplx: return ""
            case .youdao: return ""
            case .baidu: return ""
            case .tencent: return ""
            case .google: return ""
            case .mymemory: return ""
            case .groq: return "llama-3.3-70b-versatile"
            case .grok: return "grok-beta"
            case .openrouter: return "deepseek/deepseek-chat"
            case .lmstudio: return "local-model"
            case .qwen: return "qwen-plus"
            case .ernie: return "ernie-4.0-8k"
            case .doubao: return "doubao-pro-32k"
            case .hunyuan: return "hunyuan-standard"
            case .gitee: return "DeepSeek-V3"
            case .ai302: return "gpt-4o-mini"
            case .aihubmix: return "gpt-4o-mini"
            case .sophnet: return "DeepSeek-V3"
            case .claude: return "claude-3-5-sonnet-latest"
            case .gemini: return "gemini-2.0-flash"
            case .microsoft: return ""
            case .caiyun: return ""
            case .niu: return ""
            case .amazon: return ""
            case .apple: return ""
            }
        }

        var needsKey: Bool { !isZeroKey }

        func makeProfile(enabled: Bool = true) -> ServiceProfile {
            ServiceProfile(
                id: UUID().uuidString,
                name: title,
                baseURL: baseURL,
                model: model,
                enabled: enabled,
                extraPrompt: "",
                provider: providerKind.rawValue
            )
        }
    }
}

/// 服务列表的读写。存 Application Support 下的 JSON，明文可读、方便导出。
enum ProfileStore {

    private static let fileName = "services.json"
    private static let lock = NSLock()
    private static var memory: [ServiceProfile]?

    static var directoryOverride: URL?

    /// 给诊断用
    static var fileURLForDebug: URL { fileURL }

    private static var fileURL: URL {
        if let override = directoryOverride { return override.appendingPathComponent(fileName) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalTranslate", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    /// 默认开箱即用服务列表：把「全部免密钥免费服务」都默认开启。
    /// 这样任何一家抽风，其它家照样出译文——用户永远能看到结果，而不是一个报错。
    static func defaultProfiles() -> [ServiceProfile] {
        [
            ServiceProfile.Preset.apple.makeProfile(enabled: true),
            ServiceProfile.Preset.bing.makeProfile(enabled: true),
            ServiceProfile.Preset.youdaoFree.makeProfile(enabled: true),
            ServiceProfile.Preset.caiyunFree.makeProfile(enabled: true),
            ServiceProfile.Preset.volcengineFree.makeProfile(enabled: true),
            ServiceProfile.Preset.google.makeProfile(enabled: true),
            ServiceProfile.Preset.mymemory.makeProfile(enabled: true),
        ]
    }

    // MARK: - 读

    static func all() -> [ServiceProfile] {
        lock.lock()
        if let memory {
            lock.unlock()
            return memory
        }
        lock.unlock()

        let loaded = loadFromDisk() ?? migrateFromLegacy() ?? defaultProfiles()
        lock.lock()
        memory = loaded
        lock.unlock()
        return loaded
    }

    /// 开着的服务；一个都没开就退回全部，避免界面看起来"没服务可用"
    static func enabled() -> [ServiceProfile] {
        let on = all().filter { $0.enabled }
        return on.isEmpty ? all() : on
    }

    /// 能跑「对话/JSON」类请求的服务：Apple 翻译、必应、谷歌、MyMemory、插件这些
    /// 只做纯文本翻译，喂给它们 JSON 提示词只会报"Base URL 不合法"。
    static func firstUsable() -> ServiceProfile? {
        enabled().first { $0.isConfigured && $0.providerKind.supportsChat }
    }

    private static func loadFromDisk() -> [ServiceProfile]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ProfileFile.self, from: data)
            return decoded.profiles.isEmpty ? nil : decoded.profiles
        } catch {
            Debug.log("services.json 解析失败，改用旧配置迁移：\(error)")
            return nil
        }
    }

    /// 老版本只有一个 baseURL + 逗号分隔的模型串，这里拆成多个服务条目
    private static func migrateFromLegacy() -> [ServiceProfile]? {
        let defaults = UserDefaults.standard
        let legacyBase = defaults.string(forKey: "baseURL") ?? ""
        let legacyModels = defaults.string(forKey: "model") ?? ""
        guard !legacyBase.isEmpty, !legacyModels.isEmpty else { return nil }

        let models = legacyModels.split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else { return nil }

        let legacyKey = SecretStore.shared.legacyAPIKey
        // 如果只是 Config 注册的占位默认值且从未保存过旧密钥，不算旧配置，直接走开箱即用的免密钥默认列表
        if legacyKey.isEmpty && legacyBase == "https://api.openai.com/v1" && legacyModels == "gpt-4o-mini" {
            return nil
        }
        var profiles: [ServiceProfile] = []
        for model in models {
            let profile = ServiceProfile(
                id: UUID().uuidString,
                name: model,
                baseURL: legacyBase,
                model: model,
                enabled: true,
                extraPrompt: "",
                provider: nil
            )
            // 老版只有一个 key，所有迁移出来的服务共用同一个值
            if !legacyKey.isEmpty {
                SecretStore.shared.setAPIKey(legacyKey, account: profile.keyAccount)
            }
            profiles.append(profile)
        }
        Debug.log("已从旧配置迁移 \(profiles.count) 个服务")
        return profiles
    }

    // MARK: - 写

    @discardableResult
    static func save(_ profiles: [ServiceProfile]) -> Bool {
        let file = ProfileFile(profiles: profiles)
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
            lock.lock()
            memory = profiles
            lock.unlock()
            return true
        } catch {
            Debug.log("services.json 写入失败：\(error)")
            return false
        }
    }

    /// 改内存缓存但先不落盘（配合「撤销 / 保存」两个按钮）
    static func preview(_ profiles: [ServiceProfile]) {
        lock.lock()
        memory = profiles
        lock.unlock()
    }

    static func reload() {
        lock.lock()
        memory = nil
        lock.unlock()
    }

    private struct ProfileFile: Codable {
        var version = 1
        var profiles: [ServiceProfile]
    }
}
