import Foundation

/// 模型返回内容的清理与异常判定。
///
/// 这几条都是从真实使用里最容易踩的坑：
/// - 模型把提示词里的 ``` 围栏原样回吐，直接渲染会变成一大块代码
/// - 推理模型只返回思考、没有正文，界面会一片空白
/// - 输出被 max token 截断，半句话看着像正常结果
/// - 被安全策略拦截，返回空但状态码 200
enum TranslationDiagnostics {

    /// 去掉模型回吐的代码围栏。只在「首行是 ```xxx 且末行是 ```」时脱掉，
    /// 避免把用户本来就想显示的代码块拆了。
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {   // 有的模型会套两层
            var lines = text.components(separatedBy: "\n")
            guard lines.count >= 2,
                  isFence(lines[0]),
                  lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { break }
            lines.removeFirst()
            lines.removeLast()
            let inner = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { break }
            text = inner
        }
        return text
    }

    /// 首行是否只是围栏，比如 "```" 或 "```plaintext"
    private static func isFence(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return false }
        let rest = t.dropFirst(3)
        return rest.allSatisfy { $0.isLetter || $0.isNumber }
    }

    enum Issue: Equatable {
        case thinkOnly          // 只有思考，没有正文
        case empty              // 什么都没有
        case truncated          // 输出被 max token 切断
        case contentFiltered    // 被安全策略拦截

        var message: String {
            switch self {
            case .thinkOnly:
                return "模型只返回了思考过程，没有给出译文。多半是输出长度限制太小或模型异常，换个模型或再试一次。"
            case .empty:
                return "模型没有返回任何内容，检查一下模型名是否可用（有些服务需要单独开通模型权限）。"
            case .truncated:
                return "译文可能被长度限制截断了，句子没说完。可以调大超时/长度，或把长文拆短发。"
            case .contentFiltered:
                return "这次请求被模型的安全策略拦下来了，没有返回译文。换个说法再试。"
            }
        }

        /// 出错类问题（没有可用译文）
        var isError: Bool { self == .thinkOnly || self == .empty || self == .contentFiltered }
    }

    /// 综合判定：给出问题列表。content 为清理后的正文。
    static func issues(content: String, think: String, finishReason: String?) -> [Issue] {
        var list: [Issue] = []
        if content.isEmpty {
            list.append(think.isEmpty ? .empty : .thinkOnly)
        }
        if finishReason == "length", !content.isEmpty { list.append(.truncated) }
        if finishReason == "content_filter" || finishReason == "Sensitivity" {
            if content.isEmpty { list = [.contentFiltered] }
            else { list.append(.contentFiltered) }
        }
        return list
    }
}
