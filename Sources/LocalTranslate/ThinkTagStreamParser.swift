import Foundation

/// `<think>` 与 `</think>` 标签流式状态机与文本拆解器（对齐 Bob 1.15.0/1.21.0 的 splitThinkTag 特性）。
///
/// 解决痛点：
/// DeepSeek R1、通义千问、豆包等推理模型经常不走独立的 reasoning_content 字段，
/// 而是直接在 content 文本流中输出 `<think>推理思考...</think>正式译文`。
///
/// 如果不进行标签级流式拦截，卡片主译文区会先刷出一大堆思考过程，随后又被正式译文覆盖，
/// 且最终译文区会被 `<think>` 符号污染。
///
/// 本解析器支持：
/// 1. 跨 Chunk 标签拆分（例如 Chunk1 收到 `...<thi`，Chunk2 收到 `nk>...`）；
/// 2. 实时分流回调（思考流送入 onThink，正文流送入 onContent）；
/// 3. 非流式整段文本纯函数拆分。
final class ThinkTagStreamParser {

    private(set) var inThink = false
    private var pendingBuffer = ""

    private let onContent: (String) -> Void
    private let onThink: (String) -> Void

    init(onContent: @escaping (String) -> Void, onThink: @escaping (String) -> Void) {
        self.onContent = onContent
        self.onThink = onThink
    }

    /// 接收流式返回的一小段文本并实时分流
    func feed(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        pendingBuffer += chunk
        processBuffer(isFinishing: false)
    }

    /// 流结束时刷新可能残留的缓冲字符
    func finish() {
        processBuffer(isFinishing: true)
    }

    private func processBuffer(isFinishing: Bool) {
        while !pendingBuffer.isEmpty {
            if !inThink {
                // 寻找 <think>
                guard let openRange = pendingBuffer.range(of: "<think>", options: .caseInsensitive) else {
                    // 没有完整的 <think>。检查末尾是否有可能是未接收完整的标签前缀（如 "<", "<th", "<think"）
                    if !isFinishing, let possiblePrefixIndex = findTagPrefix(pendingBuffer, target: "<think>") {
                        let safeText = String(pendingBuffer[..<possiblePrefixIndex])
                        if !safeText.isEmpty {
                            onContent(safeText)
                        }
                        pendingBuffer = String(pendingBuffer[possiblePrefixIndex...])
                        return
                    } else {
                        // 无前缀或已结束，全部送入 content
                        let all = pendingBuffer
                        pendingBuffer = ""
                        onContent(all)
                        return
                    }
                }

                // 找到了 <think>
                let before = String(pendingBuffer[..<openRange.lowerBound])
                if !before.isEmpty {
                    onContent(before)
                }
                pendingBuffer = String(pendingBuffer[openRange.upperBound...])
                inThink = true
            } else {
                // 当前在 think 内部，寻找 </think>
                guard let closeRange = pendingBuffer.range(of: "</think>", options: .caseInsensitive) else {
                    // 没有完整的 </think>。检查末尾是否可能是未接收完整的闭合前缀（如 "<", "</", "</th"）
                    if !isFinishing, let possiblePrefixIndex = findTagPrefix(pendingBuffer, target: "</think>") {
                        let safeText = String(pendingBuffer[..<possiblePrefixIndex])
                        if !safeText.isEmpty {
                            onThink(safeText)
                        }
                        pendingBuffer = String(pendingBuffer[possiblePrefixIndex...])
                        return
                    } else {
                        // 无前缀或已结束，全部送入 think
                        let all = pendingBuffer
                        pendingBuffer = ""
                        onThink(all)
                        return
                    }
                }

                // 找到了 </think>
                let thinkText = String(pendingBuffer[..<closeRange.lowerBound])
                if !thinkText.isEmpty {
                    onThink(thinkText)
                }
                pendingBuffer = String(pendingBuffer[closeRange.upperBound...])
                inThink = false
            }
        }
    }

    /// 检查字符串末尾是否是 target 的某个前缀（长度 1 到 target.count - 1）
    private func findTagPrefix(_ text: String, target: String) -> String.Index? {
        let maxPrefixLen = min(text.count, target.count - 1)
        guard maxPrefixLen > 0 else { return nil }
        for len in stride(from: maxPrefixLen, through: 1, by: -1) {
            let index = text.index(text.endIndex, offsetBy: -len)
            let sub = text[index...]
            if target.lowercased().hasPrefix(sub.lowercased()) {
                return index
            }
        }
        return nil
    }

    // MARK: - 静态整段文本拆解工具

    /// 将整段文本中的所有 `<think>...</think>` 提取为 think 字符串，剩余文本为 content 字符串
    static func split(text: String) -> (content: String, think: String) {
        var contents: [String] = []
        var thinks: [String] = []

        let parser = ThinkTagStreamParser(
            onContent: { contents.append($0) },
            onThink: { thinks.append($0) }
        )
        parser.feed(text)
        parser.finish()

        let finalContent = contents.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let finalThink = thinks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (finalContent, finalThink)
    }
}
