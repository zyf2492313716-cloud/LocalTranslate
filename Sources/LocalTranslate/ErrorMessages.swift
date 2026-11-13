import Foundation

/// 把各家服务的原始错误翻成一句人话 + 下一步。
///
/// 用户看到 "You exceeded your current quota" 或 "未能完成该操作。操作不被允许"
/// 是没法行动的。这里按关键词匹配给可操作的解释。匹配不到就原样返回，
/// 绝不编一个可能误导人的解释。
enum ErrorMessages {

    /// 服务商把整页 HTML 当错误体返回时，卡片上会糊一大坨标签。
    /// 这里剥掉标签、压成一行、截断到 160 字。
    static func stripHTML(_ raw: String) -> String {
        var text = raw
        // <title>xxx</title> 里的标题往往就是最有用的一句话
        if let range = text.range(of: "<title>"),
           let end = text.range(of: "</title>") {
            let title = String(text[range.upperBound..<end.lowerBound])
            if !title.isEmpty { text = title }
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        return text
    }

    /// 输入原始错误串，返回「原信息 + 建议」。原信息一定保留，建议叠加在后面。
    static func explain(_ raw: String) -> String {
        let lower = raw.lowercased()
        func has(_ subs: [String]) -> Bool { subs.contains { lower.contains($0) } }
        var hint: String?

        // OpenAI / 兼容端点常见
        if has(["exceeded your current quota", "insufficient_quota", "billing", "your credit"]) {
            hint = "账号欠费或免费额度用完了。去服务商后台看用量/绑卡，或换个模型。"
        } else if has(["account is not active", "payment", "billing details"]) {
            hint = "账号支付信息没通过，先去服务商后台处理付款。"
        } else if has(["too many requests", "rate limit", "429", "requests per"]) {
            hint = "请求太频繁被限流，等一会儿再试；持续如此说明额度太低。"
        } else if has(["invalid api key", "incorrect api key", "unauthorized", "401", "invalid_authentication"]) {
            hint = "API Key 不对或没权限，核对设置里的密钥。"
        } else if has(["model not found", "does not exist", "invalid model", "unknown model"]) {
            hint = "模型名不存在，检查服务页里的模型名（有的服务需要单独开通该模型）。"
        } else if has(["content policy", "content_filter", "safety", "flagged", "responsible aipolicy", "responsible ai"]) {
            hint = "被内容安全策略拦截，换个说法再试。"
        } else if has(["context length", "maximum context", "too many tokens", "input is too long"]) {
            hint = "文本太长超过模型上下文，截短或分段再翻。"
        } else if has(["timeout", "timed out", "deadline"]) {
            hint = "超时。可在设置里把请求超时调大，或换更快的服务。"
        } else if has(["connection", "network", "couldn't be communicated", "offline", "couldn't connect", "failed to connect"]) {
            hint = "连不上服务器，检查网络和设置里的 Base URL；国内服务可能需要代理。"
        }

        // Apple 系统翻译特有的代理 / 权限错误
        if has(["operation not permitted", "未能完成该操作", "operation couldn't be completed", "not permitted"]) {
            hint = "系统翻译被拦住了。最常见是代理/抓包工具干扰——「设置→通用→网络→代理」里临时关掉，"
                 + "或让 sequoia.apple.com、seed-sequoia.siri.apple.com 完全不走代理（分流规则无效）。"
        } else if has(["translation was already in progress", "语音翻译已在进行中", "frequency"]) {
            hint = "系统翻译同时只能跑一个任务，稍等一下再试。"
        } else if has(["language pack", "languagecode", "not installed"]) {
            hint = "系统翻译语言包没下。去「系统设置→通用→语言与地区→翻译语言」添加目标语言。"
        }

        guard let hint else { return raw }
        return "\(raw)\n\(hint)"
    }
}
