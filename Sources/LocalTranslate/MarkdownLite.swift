import AppKit

/// 轻量 Markdown → NSAttributedString 渲染，专给翻译结果卡片用。
///
/// 设计约束：
/// - 只依赖 AppKit / Foundation，块级 + 行内解析都是自己写的，不引第三方库。
/// - 认不出的语法一律原样当纯文本吐出来：成对标记找不到配对就把标记本身打印出来，不崩、不吞字。
/// - 段内单个 `\n` 保留成真实换行（大模型逐行输出不能被并成一行），空行才做段落分隔。
/// - 行内标记（粗体/斜体/删除线/行内代码/链接）可嵌在标题、列表项、表格单元格、引用里。
///
/// 支持：`#`~`######` 标题、`**`/`__` 粗体、`*`/`_` 斜体、`***` 粗斜体、`` ` `` 行内代码、
/// `~~` 删除线、围栏代码块、`-`/`*`/`+` 与 `1.`/`1)` 列表（含多级嵌套与续行的真悬挂缩进）、
/// `>` 引用（可嵌套）、`---` 分割线、`[text](url)` 链接、GFM 表格。
///
/// 故意降级：HTML 标签与 `<br>` 按纯文本处理；图片 `![alt](src)` 只保留 alt 文字（卡片不联网拉图）；
/// 表格用「按行输出 + 制表位等宽列」而不是 NSTextTable；未闭合的围栏代码块会把 ``` 行一起输出，
/// 优先保证不丢字；4 个以上连续标记（`****`、`~~~~`）当装饰文本原样保留；
/// setext 标题（下一行 `---`）按分割线处理；裸 URL 不做自动链接。
///
/// 调用前提：`selfTest()` 要在 `NSApplication` 已初始化后、主线程上跑（字体和动态色需要 App 上下文）。
enum MarkdownLite {

    // MARK: - 常量

    /// 行内标记配对的最大搜索窗口（字符数）。超窗就降级成纯文本、标记原样保留：
    /// 既保证长标记串不会退化成二次方，也不会让正文被逐层误配吞掉。
    private static let emphasisScanWindow = 800

    /// 单行行内解析的长度上限，超过则整行按纯文本输出。
    private static let inlineParseLineLimit = 20_000

    // MARK: - 对外接口

    /// 把 markdown 渲染成 attributed string。
    /// - Parameters:
    ///   - fontSize: 正文号；标题按层级在上面缩放。
    ///   - color: 主文字色。
    ///   - secondaryColor: 次要色，用于引用、分割线、链接、列表符号、表头等弱化的地方。
    static func attributed(_ markdown: String,
                           fontSize: CGFloat,
                           color: NSColor,
                           secondaryColor: NSColor) -> NSAttributedString {
        let size = clampedFontSize(fontSize)
        let ctx = Ctx(fontSize: size, color: color, secondaryColor: secondaryColor, indent: 0)
        let out = NSMutableAttributedString()
        var state = RenderState()
        renderBlocks(lines: normalizedLines(markdown), into: out, ctx: ctx, state: &state)
        return out
    }

    /// 估算渲染后在给定宽度下需要多高，用于卡片自适应高度。
    ///
    /// 走真实排版：NSTextStorage + NSLayoutManager + NSTextContainer，量完再补上最后一段的
    /// 段后距/行距（`usedRect` 不含这两项，不补会矮一截），不乘任何经验系数。
    /// 结果只会偏高不会偏低：实测与真 NSTextView 排版逐档对齐，差值恒为那一份尾部留白
    /// （13pt 正文 ≤ 12pt）。
    /// `width` 传文本容器的宽度（按 `lineFragmentPadding = 0` 计）：调用方如果保留 NSTextView
    /// 默认的 5pt padding，请传 `可用宽度 - 10`；`textContainerInset` 由调用方自己加。
    static func predictedHeight(_ markdown: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard width.isFinite, width > 1 else { return 0 }
        let size = clampedFontSize(fontSize)
        let text = attributed(markdown,
                              fontSize: size,
                              color: .labelColor,
                              secondaryColor: .secondaryLabelColor)
        return measuredHeight(of: text, width: width)
    }

    // MARK: - 排版测量

    /// 同一份 attributed string 在指定宽度下的真实排版高度。
    private static func measuredHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width.isFinite, width > 1 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let glyphRange = layout.glyphRange(for: container)
        guard glyphRange.length > 0 else { return 0 }
        let used = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        // usedRect 不含最后一段的 paragraphSpacing / lineSpacing，补上以免卡片差一截。
        let last = text.attribute(.paragraphStyle,
                                  at: text.length - 1,
                                  effectiveRange: nil) as? NSParagraphStyle
        let tail = (last?.paragraphSpacing ?? 0) + (last?.lineSpacing ?? 0)
        let height = ceil(used.height + tail)
        return height.isFinite && height > 0 ? height : 0
    }

    /// 每一行的文本起始 x（真实排版结果），用来验证悬挂缩进确实生效。
    /// 注意：`lineFragmentRect` 的 minX 恒等于容器左边界（0），量不到缩进；
    /// 要用 `lineFragmentUsedRect`——它才是这一段真正被文字占用的矩形。
    private static func lineFragmentOriginXs(_ text: NSAttributedString, width: CGFloat) -> [CGFloat] {
        guard text.length > 0, width.isFinite, width > 1 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let range = layout.glyphRange(for: container)
        var result: [CGFloat] = []
        var index = range.location
        let limit = NSMaxRange(range)
        while index < limit {
            var effective = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &effective)
            result.append(used.minX)
            let next = NSMaxRange(effective)
            if next <= index { break }
            index = next
        }
        return result
    }

    // MARK: - 参数与预处理

    private static func clampedFontSize(_ fontSize: CGFloat) -> CGFloat {
        guard fontSize.isFinite, fontSize > 0 else { return 13 }
        return min(max(fontSize, 6), 72)
    }

    /// 统一换行符：`\r\n` / `\r` → `\n`；去 BOM；只清行尾半角空白（全角空格 U+3000 原样保留）。
    private static func normalizedLines(_ markdown: String) -> [String] {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.contains("\r") { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        if text.contains("\r") { text = text.replacingOccurrences(of: "\r", with: "\n") }
        return text.components(separatedBy: "\n").map { trimTrailingSpaces($0) }
    }

    private static let spaceSet = CharacterSet(charactersIn: " \t")

    private static func trimTrailingSpaces(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    // MARK: - 上下文

    private struct Ctx {
        var fontSize: CGFloat
        var color: NSColor
        var secondaryColor: NSColor
        /// 块级左边界缩进。
        var indent: CGFloat
        /// 标题这类整块加粗的语境。
        var boldByDefault: Bool = false
        /// 行内代码 / 代码块 / 表头的淡背景。
        var codeBackground: NSColor = .quaternaryLabelColor
    }

    private struct Style {
        var bold = false
        var italic = false
        var strike = false
        var code = false
    }

    /// 跨块状态：块之间只插一个换行，连续空行不会堆出大空隙。
    private struct RenderState {
        var hasBlock = false
    }

    // MARK: - 字号阶梯

    private static func headingSpec(level: Int, body: CGFloat) -> (size: CGFloat, secondary: Bool) {
        func half(_ value: CGFloat) -> CGFloat { round(value * 2) / 2 }
        switch level {
        case 1: return (half(body * 1.30), false)
        case 2: return (half(body * 1.16), false)
        case 3: return (half(body * 1.06), false)
        case 4: return (body, false)
        case 5: return (half(body * 0.92), false)
        default: return (half(body * 0.85), true)
        }
    }

    // MARK: - 块级解析

    private static func renderBlocks(lines: [String],
                                     into out: NSMutableAttributedString,
                                     ctx: Ctx,
                                     state: inout RenderState) {
        let unit = ctx.fontSize / 13.0
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: spaceSet)
            if trimmed.isEmpty { i += 1; continue }

            // 围栏代码块
            if let fence = fenceMarker(trimmed) {
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: spaceSet)
                    if isFenceClose(t, opener: fence) { closed = true; i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                if closed {
                    // 闭合围栏：吞掉的只有 ``` 标记行和语言标识，正文全在。
                    if !body.isEmpty {
                        appendCodeBlock(text: body.joined(separator: "\n"), into: out, ctx: ctx, state: &state)
                    }
                } else {
                    // 未闭合（流式输出还没写完 ```，或模型少写一个）：
                    // 整块仍按代码排版，但把 ``` 行一起输出，一个字都不丢。
                    appendCodeBlock(text: ([trimmed] + body).joined(separator: "\n"),
                                    into: out, ctx: ctx, state: &state)
                }
                continue
            }

            // 分割线
            if isHorizontalRule(trimmed) {
                appendHorizontalRule(into: out, ctx: ctx, state: &state)
                i += 1
                continue
            }

            // 标题
            if let heading = headingParts(trimmed) {
                appendHeading(level: heading.level, text: heading.text,
                              into: out, ctx: ctx, state: &state, unit: unit)
                i += 1
                continue
            }

            // 引用（可嵌套）
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: spaceSet)
                    guard t.hasPrefix(">") else { break }
                    var content = String(t.dropFirst())
                    while content.hasPrefix(" ") || content.hasPrefix("\t") {
                        content.removeFirst()
                    }
                    inner.append(content)
                    i += 1
                }
                appendBlockquote(inner: inner, into: out, ctx: ctx, state: &state, unit: unit)
                continue
            }

            // 表格（GFM：本行含 | 且下一行是分隔行）
            if i + 1 < lines.count,
               trimmed.contains("|"),
               isTableDelimiter(lines[i + 1].trimmingCharacters(in: spaceSet)) {
                let consumed = appendTable(from: lines, start: i, into: out, ctx: ctx, state: &state, unit: unit)
                if consumed > 0 { i += consumed; continue }
            }

            // 列表
            if listItem(in: line) != nil {
                i = appendList(from: lines, start: i, into: out, ctx: ctx, state: &state, unit: unit)
                continue
            }

            // 普通段落：连续非空行合成一段，段内单个换行原样保留
            var para: [String] = []
            while i < lines.count, !startsNewBlock(lines, i) {
                para.append(lines[i])
                i += 1
            }
            if para.isEmpty { para.append(line); i += 1 }
            appendParagraph(text: para.joined(separator: "\n"), into: out, ctx: ctx, state: &state, unit: unit)
        }
    }

    /// 段落收集时判断 lines[index] 是否该另起一个块。
    private static func startsNewBlock(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: spaceSet)
        if trimmed.isEmpty { return true }
        if fenceMarker(trimmed) != nil { return true }
        if isHorizontalRule(trimmed) { return true }
        if headingParts(trimmed) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if index + 1 < lines.count,
           trimmed.contains("|"),
           isTableDelimiter(lines[index + 1].trimmingCharacters(in: spaceSet)) { return true }
        if listItem(in: line) != nil { return true }
        return false
    }

    // MARK: - 块级识别

    private static func fenceMarker(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        guard let head = trimmed.first else { return nil }
        var count = 0
        for ch in trimmed { if ch == head { count += 1 } else { break } }
        guard count >= 3 else { return nil }
        let fence = String(repeating: String(head), count: count)
        // 围栏行的剩余部分只可能是语言标识（```swift / ``` json）。一旦出现别的符号，
        // 说明这行其实是正文，整行按普通段落输出——否则未闭合的围栏会把这一行整个吞掉。
        let info = String(Array(trimmed).dropFirst(count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if info.isEmpty { return fence }
        // 语言标识实际只会是 ASCII（swift / json / c++），出现中文就当正文，别把中文吞掉。
        for ch in info where !(ch.isASCII && (ch.isLetter || ch.isNumber)
            || ch == "-" || ch == "_" || ch == "." || ch == "+") {
            return nil
        }
        return fence
    }

    private static func isFenceClose(_ trimmed: String, opener: String) -> Bool {
        guard let first = trimmed.first, opener.hasPrefix(String(first)) else { return false }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { return false }
        }
        return count >= opener.count
    }

    /// `---` / `***` / `___`（允许中间空格）。
    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let chars = Array(trimmed)
        guard chars.count >= 3 else { return false }
        for candidate: Character in ["-", "*", "_"] {
            guard chars.first == candidate else { continue }
            let filler = chars.filter { $0 != candidate }
            if filler.allSatisfy({ $0 == " " || $0 == "\t" }),
               chars.filter({ $0 == candidate }).count >= 3 {
                return true
            }
        }
        return false
    }

    /// `#`~`######`；空格可选（大模型常写 `#标题`，中文紧跟时也当标题）。
    private static func headingParts(_ trimmed: String) -> (level: Int, text: String)? {
        let chars = Array(trimmed)
        guard chars.first == "#" else { return nil }
        var level = 0
        while level < chars.count, chars[level] == "#" { level += 1 }
        guard level >= 1, level <= 6 else { return nil }
        if level < chars.count {
            let next = chars[level]
            if next != " ", next != "\t" {
                // 紧跟 ASCII 可见字符（`#1 问题`、`#HASHTAG`）不当标题，避免误吞正文。
                guard let scalar = next.unicodeScalars.first, scalar.value > 0x7F else { return nil }
            }
        }
        var text = level < chars.count ? String(chars[level...]) : ""
        text = text.trimmingCharacters(in: spaceSet)
        // 闭合式 ATX：`## 标题 ##`
        if text.hasSuffix("#") {
            var stripped = Array(text)
            var hashes = 0
            while let last = stripped.last, last == "#" { stripped.removeLast(); hashes += 1 }
            if hashes <= level + 1 {
                text = String(stripped).trimmingCharacters(in: spaceSet)
            }
        }
        return (level, text)
    }

    /// 列表项标记：`-` / `*` / `+` / `1.` / `1)`，标记后必须跟空白。
    private static func listItem(in line: String)
        -> (ordered: Bool, marker: String, text: String, level: Int)? {
        let chars = Array(line)
        var i = 0
        var width = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" {
            width += chars[i] == "\t" ? 4 : 1
            i += 1
        }
        guard i < chars.count else { return nil }
        let level = min(3, width / 2)
        let ch = chars[i]
        let next = i + 1
        let followedBySpace = next >= chars.count || chars[next] == " " || chars[next] == "\t"

        if ch == "-" || ch == "*" || ch == "+" {
            guard followedBySpace else { return nil }
            guard !isHorizontalRule(String(chars[i...])) else { return nil }
            var j = next
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            let text = String(chars[j...]).trimmingCharacters(in: spaceSet)
            // 空条目（单独一行 "-" / "*"）不转成圆点，标记原样留在正文里。
            guard !text.isEmpty else { return nil }
            return (false, "•", text, level)
        }

        if ch.isASCII, ch.isNumber {
            var j = i
            var digits = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber, digits.count < 9 {
                digits.append(chars[j]); j += 1
            }
            guard j < chars.count, chars[j] == "." || chars[j] == ")" else { return nil }
            j += 1
            guard j >= chars.count || chars[j] == " " || chars[j] == "\t" else { return nil }
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            let marker = digits + "."
            let text = String(chars[j...]).trimmingCharacters(in: spaceSet)
            guard !text.isEmpty else { return nil }
            return (true, marker, text, level)
        }
        return nil
    }

    // MARK: - 块级落笔

    private static func beginBlock(_ out: NSMutableAttributedString, state: inout RenderState) {
        if state.hasBlock { out.append(NSAttributedString(string: "\n")) }
        state.hasBlock = true
    }

    private static func appendHeading(level: Int,
                                      text: String,
                                      into out: NSMutableAttributedString,
                                      ctx: Ctx,
                                      state: inout RenderState,
                                      unit: CGFloat) {
        let spec = headingSpec(level: level, body: ctx.fontSize)
        var blockCtx = ctx
        blockCtx.fontSize = spec.size
        blockCtx.boldByDefault = true
        if spec.secondary { blockCtx.color = ctx.secondaryColor }
        let ps = paragraphStyle(first: ctx.indent,
                                head: ctx.indent,
                                before: 12 * unit,
                                after: 6 * unit,
                                lineSpacing: 2 * unit)
        beginBlock(out, state: &state)
        let start = out.length
        appendInline(text, into: out, ctx: blockCtx, style: Style())
        apply(ps, to: out, from: start)
    }

    private static func appendParagraph(text: String,
                                        into out: NSMutableAttributedString,
                                        ctx: Ctx,
                                        state: inout RenderState,
                                        unit: CGFloat) {
        let ps = paragraphStyle(first: ctx.indent,
                                head: ctx.indent,
                                before: ctx.indent > 0 ? 2 * unit : 0,
                                after: 8 * unit,
                                lineSpacing: 4 * unit)
        beginBlock(out, state: &state)
        let start = out.length
        appendInline(text, into: out, ctx: ctx, style: Style())
        apply(ps, to: out, from: start)
    }

    private static func appendCodeBlock(text: String,
                                        into out: NSMutableAttributedString,
                                        ctx: Ctx,
                                        state: inout RenderState) {
        let unit = ctx.fontSize / 13.0
        let inset = 8 * unit
        let ps = paragraphStyle(first: ctx.indent + inset,
                                head: ctx.indent + inset,
                                before: 8 * unit,
                                after: 8 * unit,
                                lineSpacing: 3 * unit)
        beginBlock(out, state: &state)
        let start = out.length
        let size = max(round(ctx.fontSize * 0.92 * 2) / 2, 8)
        out.append(NSAttributedString(string: text, attributes: [
            .font: font(size: size, bold: false, italic: false, mono: true),
            .foregroundColor: ctx.color,
            .backgroundColor: ctx.codeBackground,
        ]))
        apply(ps, to: out, from: start)
    }

    /// 分割线：一长条横线字符 + `.byClipping`。
    /// 不管卡片多宽都铺满一行，多余部分被裁掉，不折行、不出省略号、不留 `---`。
    private static func appendHorizontalRule(into out: NSMutableAttributedString,
                                             ctx: Ctx,
                                             state: inout RenderState) {
        let unit = ctx.fontSize / 13.0
        let ps = paragraphStyle(first: ctx.indent,
                                head: ctx.indent,
                                before: 9 * unit,
                                after: 9 * unit,
                                lineSpacing: 0,
                                breakMode: .byClipping)
        beginBlock(out, state: &state)
        let start = out.length
        out.append(NSAttributedString(string: String(repeating: "─", count: 160), attributes: [
            .font: font(size: max(round(ctx.fontSize * 0.7 * 2) / 2, 8),
                        bold: false, italic: false, mono: false),
            .foregroundColor: ctx.secondaryColor,
        ]))
        apply(ps, to: out, from: start)
    }

    /// 引用：左侧留白 + 整块次要色，内部继续走块级解析（列表/代码/嵌套引用都能生效）。
    private static func appendBlockquote(inner: [String],
                                         into out: NSMutableAttributedString,
                                         ctx: Ctx,
                                         state: inout RenderState,
                                         unit: CGFloat) {
        var sub = ctx
        sub.indent = ctx.indent + 12 * unit
        sub.color = ctx.secondaryColor
        sub.secondaryColor = ctx.secondaryColor
        sub.boldByDefault = false

        beginBlock(out, state: &state)
        var subState = RenderState()
        renderBlocks(lines: inner, into: out, ctx: sub, state: &subState)
    }

    private static func appendList(from lines: [String],
                                   start: Int,
                                   into out: NSMutableAttributedString,
                                   ctx: Ctx,
                                   state: inout RenderState,
                                   unit: CGFloat) -> Int {
        struct Item { var ordered: Bool; var marker: String; var text: String; var level: Int }
        var i = start
        var items: [Item] = []
        var loose = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: spaceSet)
            if trimmed.isEmpty {
                // 空行后还能接上列表项 → 松散列表（条目间距加大）
                var k = i + 1
                while k < lines.count, lines[k].trimmingCharacters(in: spaceSet).isEmpty { k += 1 }
                if k < lines.count, listItem(in: lines[k]) != nil { loose = true; i = k; continue }
                break
            }
            guard let item = listItem(in: line) else { break }
            var body = item.text
            i += 1
            // 续行：缩进的非空行、且不是新块 → 归进当前条目，保留换行
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: spaceSet)
                if t.isEmpty { break }
                if listItem(in: lines[i]) != nil { break }
                if fenceMarker(t) != nil || headingParts(t) != nil
                    || isHorizontalRule(t) || t.hasPrefix(">") { break }
                if leadingWidth(lines[i]) < 2 { break }
                body += "\n" + t
                i += 1
            }
            items.append(Item(ordered: item.ordered, marker: item.marker, text: body, level: item.level))
        }

        let step = max(ctx.fontSize * 2.0, 18)
        let markerFont = font(size: ctx.fontSize, bold: false, italic: false, mono: false)
        for item in items {
            let base = ctx.indent + CGFloat(item.level) * step
            let markerWidth = (item.marker as NSString).size(withAttributes: [.font: markerFont]).width
            let head = base + max(step, markerWidth + 8)
            let gap = (loose ? 7 : 2) * unit
            // 首行：圆点/编号在 base，正文在 head。
            let firstPS = paragraphStyle(first: base,
                                         head: head,
                                         before: 2 * unit,
                                         after: gap,
                                         lineSpacing: 4 * unit,
                                         tabs: [NSTextTab(textAlignment: .left, location: head, options: [:])],
                                         defaultTabInterval: head - base)
            // 条目内的软换行（大模型逐行输出）：整段直接缩到 head，
            // 不靠插 tab 字符——tab 会让复制出来的文本多个制表符，也会被排版测量算成行首。
            let contPS = paragraphStyle(first: head,
                                        head: head,
                                        before: 0,
                                        after: gap,
                                        lineSpacing: 4 * unit)
            beginBlock(out, state: &state)

            let segments = item.text.components(separatedBy: "\n")
            for (index, segment) in segments.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
                let segmentStart = out.length
                if index == 0 {
                    out.append(NSAttributedString(string: item.marker + "\t", attributes: [
                        .font: markerFont,
                        .foregroundColor: ctx.secondaryColor,
                    ]))
                }
                appendInline(segment, into: out, ctx: ctx, style: Style())
                apply(index == 0 ? firstPS : contPS, to: out, from: segmentStart)
            }
        }
        return i
    }

    private static func leadingWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    // MARK: - 表格

    /// 分隔行：`| --- | :-: |` 之类。
    private static func isTableDelimiter(_ trimmed: String) -> Bool {
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            var body = cell.replacingOccurrences(of: " ", with: "")
            guard !body.isEmpty else { return false }
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    /// 拆 `| a | b |`：支持 `\|` 转义，去掉首尾空壳。
    private static func tableCells(_ line: String) -> [String] {
        let sentinel = "\u{1E}"
        let safe = line.replacingOccurrences(of: "\\|", with: sentinel)
        var cells = safe.components(separatedBy: "|").map { cell in
            cell.replacingOccurrences(of: sentinel, with: "|").trimmingCharacters(in: spaceSet)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// 表格方案：整表按行输出，用制表位对齐成等宽列。
    /// 列宽 = 该列所有单元格（表头按粗体）的实测字宽 + 间隙；左对齐靠制表位天然生效，
    /// 居中/右对齐按空格补位（近似，误差小于一个空格宽）；表头加粗并带淡背景。
    private static func appendTable(from lines: [String],
                                    start: Int,
                                    into out: NSMutableAttributedString,
                                    ctx: Ctx,
                                    state: inout RenderState,
                                    unit: CGFloat) -> Int {
        let headerCells = tableCells(lines[start].trimmingCharacters(in: spaceSet))
        let alignmentCells = tableCells(lines[start + 1].trimmingCharacters(in: spaceSet))
        var i = start + 2
        var rows: [[String]] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: spaceSet)
            if trimmed.isEmpty || !trimmed.contains("|") { break }
            rows.append(tableCells(trimmed))
            i += 1
        }

        let columnCount = max(headerCells.count, rows.map { $0.count }.max() ?? 0)
        guard columnCount > 0 else { return 0 }
        let alignments = delimiterAlignments(alignmentCells, columnCount: columnCount)

        let bodyFont = font(size: ctx.fontSize, bold: false, italic: false, mono: false)
        let headerFont = font(size: ctx.fontSize, bold: true, italic: false, mono: false)

        func fragment(_ raw: String, header: Bool) -> NSAttributedString {
            var local = ctx
            local.boldByDefault = header
            local.fontSize = ctx.fontSize
            let piece = NSMutableAttributedString()
            appendInline(raw, into: piece, ctx: local, style: Style())
            if piece.length == 0 {
                piece.append(NSAttributedString(string: " ", attributes: [
                    .font: header ? headerFont : bodyFont,
                    .foregroundColor: local.color,
                ]))
            }
            return piece
        }

        var headerFragments: [NSAttributedString] = []
        var rowFragments: [[NSAttributedString]] = []
        var widths = [CGFloat](repeating: 0, count: columnCount)

        for k in 0..<columnCount {
            let f = fragment(k < headerCells.count ? headerCells[k] : "", header: true)
            headerFragments.append(f)
            widths[k] = max(widths[k], f.size().width)
        }
        for row in rows {
            var frags: [NSAttributedString] = []
            for k in 0..<columnCount {
                let f = fragment(k < row.count ? row[k] : "", header: false)
                frags.append(f)
                widths[k] = max(widths[k], f.size().width)
            }
            rowFragments.append(frags)
        }

        let gap = max(10 * unit, 8)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
        var stops: [NSTextTab] = []
        var x = ctx.indent
        for k in 0..<columnCount {
            stops.append(NSTextTab(textAlignment: .left, location: x, options: [:]))
            x += widths[k] + gap
        }

        func padded(_ cell: NSAttributedString, column: Int) -> NSAttributedString {
            let align = alignments[min(column, alignments.count - 1)]
            guard align != 0, spaceWidth > 0.5 else { return cell }
            let free = widths[column] - cell.size().width
            guard free > spaceWidth else { return cell }
            let total = max(Int(floor(free / spaceWidth)), 0)
            let pad = NSMutableAttributedString(string: "", attributes: [
                .font: bodyFont, .foregroundColor: ctx.color,
            ])
            func spaces(_ count: Int) -> NSAttributedString {
                NSAttributedString(string: String(repeating: " ", count: count), attributes: [
                    .font: bodyFont, .foregroundColor: ctx.color,
                ])
            }
            if align == 2 {                              // 右对齐：空格全补在左边
                pad.append(spaces(total))
                pad.append(cell)
            } else {                                     // 居中：两边均分
                pad.append(spaces(total / 2))
                pad.append(cell)
                pad.append(spaces(total - total / 2))
            }
            return pad
        }

        let ps = paragraphStyle(first: ctx.indent,
                                head: ctx.indent + gap,
                                before: 8 * unit,
                                after: 2 * unit,
                                lineSpacing: 3 * unit,
                                tabs: stops,
                                defaultTabInterval: gap)

        func emitRow(_ frags: [NSAttributedString], header: Bool) {
            beginBlock(out, state: &state)
            let rowStart = out.length
            for (k, frag) in frags.enumerated() {
                let piece = padded(frag, column: k)
                out.append(piece)
                if header, piece.length > 0 {
                    out.addAttribute(.backgroundColor,
                                     value: ctx.codeBackground,
                                     range: NSRange(location: out.length - piece.length, length: piece.length))
                }
                if k < frags.count - 1 { out.append(NSAttributedString(string: "\t")) }
            }
            apply(ps, to: out, from: rowStart)
        }

        emitRow(headerFragments, header: true)
        for frags in rowFragments { emitRow(frags, header: false) }
        // 表格结束后补一点下间距，避免和后面的正文黏在一起。
        if let last = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle,
           let mutable = last.mutableCopy() as? NSMutableParagraphStyle {
            mutable.paragraphSpacing = max(mutable.paragraphSpacing, 6 * unit)
            out.addAttribute(.paragraphStyle,
                             value: mutable,
                             range: NSRange(location: out.length - 1, length: 1))
        }
        return i - start
    }

    /// 0 = 左，1 = 居中，2 = 右。
    private static func delimiterAlignments(_ cells: [String], columnCount: Int) -> [Int] {
        var result: [Int] = []
        for k in 0..<max(columnCount, cells.count) {
            let raw = k < cells.count ? cells[k].replacingOccurrences(of: " ", with: "") : ""
            let left = raw.hasPrefix(":")
            let right = raw.hasSuffix(":") && raw.count > 1
            if left, right { result.append(1) }
            else if right { result.append(2) }
            else { result.append(0) }
        }
        return result
    }

    // MARK: - 行内解析

    private static func appendInline(_ text: String,
                                     into out: NSMutableAttributedString,
                                     ctx: Ctx,
                                     style: Style) {
        guard !text.isEmpty else { return }
        guard text.contains("\n") else {
            appendInlineLine(text, into: out, ctx: ctx, style: style)
            return
        }
        for (index, part) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            appendInlineLine(part, into: out, ctx: ctx, style: style)
        }
    }

    /// 单行行内扫描。找不到配对就把标记原样输出，绝不吞字。
    private static func appendInlineLine(_ text: String,
                                         into out: NSMutableAttributedString,
                                         ctx: Ctx,
                                         style: Style) {
        // 病态超长行不再做行内解析，整行按纯文本输出，保证线性复杂度。
        guard text.count <= inlineParseLineLimit else {
            appendRun(text, into: out, ctx: ctx, style: style)
            return
        }
        let chars = Array(text)
        var buffer = ""
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            appendRun(buffer, into: out, ctx: ctx, style: style)
            buffer = ""
        }

        while i < chars.count {
            let ch = chars[i]

            // 反斜杠转义：\* \\ \[ 等
            if ch == "\\", i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != "\t" {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }

            // 行内代码（内容按字面输出，内部不再解析标记）
            if ch == "`" {
                var count = 0
                while i + count < chars.count, chars[i + count] == "`" { count += 1 }
                let marker = String(repeating: "`", count: count)
                if let close = findRun(chars, from: i + count, marker: marker), close > i + count {
                    var inner = String(chars[(i + count)..<close])
                    if inner.hasPrefix(" "), inner.hasSuffix(" "), inner.count > 1 {
                        inner = String(inner.dropFirst().dropLast())
                    }
                    // 内容为空的 `` `` 不算代码段，两个反引号原样留着。
                    if !inner.isEmpty {
                        flush()
                        var codeStyle = style
                        codeStyle.code = true
                        appendRun(inner, into: out, ctx: ctx, style: codeStyle)
                        i = close + count
                        continue
                    }
                }
                flush()
                appendRun(marker, into: out, ctx: ctx, style: style)
                i += count
                continue
            }

            // 粗体 / 斜体 / 删除线
            if ch == "*" || ch == "_" || ch == "~" {
                var count = 0
                while i + count < chars.count, chars[i + count] == ch { count += 1 }

                // 4 个及以上连续标记（`~` 从 3 个起）当装饰串原样输出：不逐层误配、不吞字、不退化。
                if count >= 4 || (ch == "~" && count >= 3) {
                    flush()
                    appendRun(String(repeating: String(ch), count: count), into: out, ctx: ctx, style: style)
                    i += count
                    continue
                }

                // ***粗斜体***
                if ch != "~", count >= 3,
                   let close = findEmphasisClose(chars,
                                                 marker: String(repeating: ch, count: 3),
                                                 openerEnd: i + 3,
                                                 intraWord: ch == "*") {
                    flush()
                    var bothStyle = style
                    bothStyle.bold = true
                    bothStyle.italic = true
                    appendInline(String(chars[(i + 3)..<close]), into: out, ctx: ctx, style: bothStyle)
                    i = close + 3
                    continue
                }

                // ~~删除线~~
                if ch == "~", count >= 2,
                   let close = findEmphasisClose(chars, marker: "~~", openerEnd: i + 2, intraWord: true) {
                    flush()
                    var strikeStyle = style
                    strikeStyle.strike = true
                    appendInline(String(chars[(i + 2)..<close]), into: out, ctx: ctx, style: strikeStyle)
                    i = close + 2
                    continue
                }

                // **粗体** / __粗体__
                if count >= 2,
                   let close = findEmphasisClose(chars,
                                                 marker: String(repeating: ch, count: 2),
                                                 openerEnd: i + 2,
                                                 intraWord: ch == "*") {
                    flush()
                    var boldStyle = style
                    boldStyle.bold = true
                    appendInline(String(chars[(i + 2)..<close]), into: out, ctx: ctx, style: boldStyle)
                    i = close + 2
                    continue
                }

                // *斜体* / _斜体_
                if let close = findEmphasisClose(chars,
                                                 marker: String(ch),
                                                 openerEnd: i + 1,
                                                 intraWord: ch == "*") {
                    flush()
                    var italicStyle = style
                    italicStyle.italic = true
                    appendInline(String(chars[(i + 1)..<close]), into: out, ctx: ctx, style: italicStyle)
                    i = close + 1
                    continue
                }

                flush()
                appendRun(String(repeating: String(ch), count: count), into: out, ctx: ctx, style: style)
                i += count
                continue
            }

            // 链接 [text](url) / 图片 ![alt](src)
            if ch == "[", let link = scanLink(chars, open: i) {
                flush()
                appendLinkLabel(link.label, url: link.target, into: out, ctx: ctx, style: style)
                i = link.next
                continue
            }
            if ch == "!", i + 1 < chars.count, chars[i + 1] == "[", let link = scanLink(chars, open: i + 1) {
                flush()
                // 卡片里不联网加载图片，降级成次要色的 alt 文本，不留 `![...]()` 噪音。
                appendRun(link.label.isEmpty ? "图片" : link.label,
                          into: out, ctx: ctx, style: style, overrideColor: ctx.secondaryColor)
                i = link.next
                continue
            }

            buffer.append(ch)
            i += 1
        }
        flush()
    }

    /// 找与 marker 等长且不带同种相邻字符的一次出现。
    private static func findRun(_ chars: [Character], from: Int, marker: String) -> Int? {
        let m = Array(marker)
        guard !m.isEmpty else { return nil }
        var i = from
        while i + m.count <= chars.count {
            if Array(chars[i..<(i + m.count)]) == m {
                let beforeClean = (i == from) || chars[i - 1] != m[0]
                let afterClean = (i + m.count == chars.count) || chars[i + m.count] != m[0]
                if beforeClean, afterClean { return i }
            }
            i += 1
        }
        return nil
    }

    /// 闭合标记：内容必须非空（闭标记要严格在开标记之后）；开标记后不能是空格、闭标记前不能是空格；
    /// 闭标记必须是一整段同种字符（前后不接同种字符）——否则 `***x***` 这类串会被逐层误配，
    /// 长标记串还会把配对扫描拖成二次方并吞字。搜索限定在窗口内，超窗按纯文本保留。
    /// `_` 只在词边界生效，保护 snake_case / A_B_C 这类标识符。
    private static func findEmphasisClose(_ chars: [Character],
                                          marker: String,
                                          openerEnd: Int,
                                          intraWord: Bool) -> Int? {
        let m = Array(marker)
        guard openerEnd < chars.count, chars[openerEnd] != " ", chars[openerEnd] != "\t" else { return nil }
        let limit = min(chars.count, openerEnd + emphasisScanWindow)
        var i = openerEnd + 1
        while i + m.count <= limit {
            if Array(chars[i..<(i + m.count)]) == m {
                let before = chars[i - 1]
                let after = i + m.count < chars.count ? chars[i + m.count] : nil
                let exactRun = (before != m[0]) && (after != m[0])
                if exactRun, before != " ", before != "\t" {
                    if intraWord { return i }
                    let openerPrev = openerEnd - m.count - 1
                    let prevIsWord = openerPrev >= 0 ? isWordChar(chars[openerPrev]) : false
                    let beforeIsWord = isWordChar(before)
                    let nextIsWord = after.map { isWordChar($0) } ?? false
                    if !prevIsWord, !(beforeIsWord && nextIsWord) { return i }
                }
            }
            i += 1
        }
        return nil
    }

    private static func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber }

    /// `[label](target)`。返回 label、target、下一个待处理下标。
    private static func scanLink(_ chars: [Character], open: Int) -> (label: String, target: String, next: Int)? {
        guard open < chars.count, chars[open] == "[" else { return nil }
        var depth = 0
        var i = open
        var labelEnd: Int?
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { labelEnd = i; break }
            } else if c == "\n" { return nil }
            i += 1
        }
        guard let close = labelEnd else { return nil }
        let label = String(chars[(open + 1)..<close])
        var j = close + 1
        guard j < chars.count, chars[j] == "(" else { return nil }
        j += 1
        var paren = 1
        var target = ""
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count { target.append(chars[j + 1]); j += 2; continue }
            if c == "(" { paren += 1 }
            else if c == ")" {
                paren -= 1
                if paren == 0 { j += 1; break }
            } else if c == "\n" { return nil }
            target.append(c)
            j += 1
        }
        guard paren == 0 else { return nil }
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if target.hasPrefix("<"), target.hasSuffix(">"), target.count >= 2 {
            target = String(target.dropFirst().dropLast())
        } else if let space = target.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            // 带 title 的形式：只取 URL 部分
            target = String(target[..<space])
        }
        return (label, target, j)
    }

    /// 链接：显示 label，下划线 + 次要色，并挂 NSAttributedString.Key.link。
    private static func appendLinkLabel(_ label: String,
                                        url: String,
                                        into out: NSMutableAttributedString,
                                        ctx: Ctx,
                                        style: Style) {
        let start = out.length
        appendInline(label, into: out, ctx: ctx, style: style)
        let length = out.length - start
        guard length > 0 else { return }
        let range = NSRange(location: start, length: length)
        out.addAttribute(.foregroundColor, value: ctx.secondaryColor, range: range)
        out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        out.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
        if let resolved = resolvedURL(url) {
            out.addAttribute(.link, value: resolved, range: range)
        }
    }

    /// 只挂能直接打开的 http/https/mailto/tel，其余（如 javascript:）当纯文本，不给系统留坏链接。
    private static func resolvedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, !raw.contains("\n") else { return nil }
        if raw.rangeOfCharacter(from: CharacterSet(charactersIn: "\"<> \t")) != nil { return nil }
        let lower = raw.lowercased()
        let direct = ["http://", "https://", "mailto:", "tel:"]
        if direct.contains(where: { lower.hasPrefix($0) }) { return URL(string: raw) }
        if lower.hasPrefix("www.") { return URL(string: "https://" + raw) }
        return nil
    }

    // MARK: - 落笔与字体

    private static func apply(_ style: NSParagraphStyle,
                              to out: NSMutableAttributedString,
                              from start: Int) {
        let length = out.length - start
        guard length > 0 else { return }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: length))
    }

    private static func appendRun(_ string: String,
                                  into out: NSMutableAttributedString,
                                  ctx: Ctx,
                                  style: Style,
                                  overrideColor: NSColor? = nil) {
        guard !string.isEmpty else { return }
        let size = style.code ? max(round(ctx.fontSize * 0.92 * 2) / 2, 8) : ctx.fontSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: size,
                        bold: ctx.boldByDefault || style.bold,
                        italic: style.italic,
                        mono: style.code),
            .foregroundColor: overrideColor ?? ctx.color,
        ]
        if style.code { attributes[.backgroundColor] = ctx.codeBackground }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        out.append(NSAttributedString(string: string, attributes: attributes))
    }

    /// 字体：正文走系统字体（CJK 自动级联 PingFang），代码走等宽；斜体取 italic 面，取不到就退回原字。
    private static func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var result: NSFont
        if mono {
            result = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        } else {
            result = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        guard italic else { return result }
        let candidate = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        if candidate.fontName != result.fontName { result = candidate }
        return result
    }

    private static func paragraphStyle(first: CGFloat,
                                       head: CGFloat,
                                       before: CGFloat,
                                       after: CGFloat,
                                       lineSpacing: CGFloat,
                                       tabs: [NSTextTab]? = nil,
                                       defaultTabInterval: CGFloat? = nil,
                                       breakMode: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = max(first, 0)
        ps.headIndent = max(head, max(first, 0))
        ps.paragraphSpacing = max(after, 0)
        ps.paragraphSpacingBefore = max(before, 0)
        ps.lineSpacing = max(lineSpacing, 0)
        ps.lineBreakMode = breakMode
        ps.alignment = .left
        if let tabs = tabs { ps.tabStops = tabs }
        if let interval = defaultTabInterval { ps.defaultTabInterval = max(interval, 4) }
        return ps
    }

    // MARK: - 自测

    /// 硬编码样例跑一遍 attributed() 与 predictedHeight()。
    /// 断言：不崩、正文内容不丢（归一化后比对）、关键属性挂上、预测高度在合理区间。
    /// 返回失败描述数组，全对返回空数组。
    static func selfTest() -> [String] {
        var failures: [String] = []
        let body: CGFloat = 13
        let main = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }
        func render(_ markdown: String) -> NSAttributedString {
            attributed(markdown, fontSize: body, color: main, secondaryColor: secondary)
        }

        struct Sample {
            let name: String
            let markdown: String
            let expected: String
            let verify: (NSAttributedString) -> [String]
        }

        func sample(_ name: String, _ lines: [String], _ expected: String,
                    _ verify: @escaping (NSAttributedString) -> [String] = { _ in [] }) -> Sample {
            Sample(name: name, markdown: lines.joined(separator: "\n"), expected: expected, verify: verify)
        }

        let samples: [Sample] = [
            sample("纯文本段落", ["这是纯文本，没有任何标记。"], "这是纯文本，没有任何标记。") { out in
                var bad: [String] = []
                require(out.string == "这是纯文本，没有任何标记。",
                        "纯文本样例应逐字原样输出，实测「\(preview(out.string))」", into: &bad)
                return bad
            },

            sample("空字符串", [""], "") { out in
                var bad: [String] = []
                require(out.length == 0, "空输入应产出空 attributed string", into: &bad)
                return bad
            },

            sample("标题 1~6 与标题内嵌套粗体",
                   ["# 一级标题 **重点**", "## 二级标题", "### 三级标题",
                    "#### 四级标题", "##### 五级标题", "###### 六级标题"],
                   "一级标题重点二级标题三级标题四级标题五级标题六级标题") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                var sizes: [String: CGFloat] = [:]
                for key in ["一级标题", "二级标题", "三级标题", "四级标题", "六级标题"] {
                    if let f = font(of: out, ns, key) { sizes[key] = f.pointSize }
                    else { bad.append("标题「\(key)」字号取不到") }
                }
                if let h1 = sizes["一级标题"], let h2 = sizes["二级标题"], let h3 = sizes["三级标题"],
                   let h4 = sizes["四级标题"], let h6 = sizes["六级标题"] {
                    require(h1 > h2, "h1(\(h1)) 应大于 h2(\(h2))", into: &bad)
                    require(h2 > h3, "h2(\(h2)) 应大于 h3(\(h3))", into: &bad)
                    require(h3 > h4, "h3(\(h3)) 应大于 h4(\(h4))", into: &bad)
                    require(h4 > h6, "h4(\(h4)) 应大于 h6(\(h6))", into: &bad)
                    require(h1 > 13, "h1 相对正文 13 应放大，实测 \(h1)", into: &bad)
                    require(h2 > 13, "h2 相对正文 13 应放大，实测 \(h2)", into: &bad)
                    require(h4 == 13, "h4 应与正文同号靠加粗区分，实测 \(h4)", into: &bad)
                    require(h6 < 13, "h6 应略小于正文，实测 \(h6)", into: &bad)
                }
                require(!out.string.contains("**"), "标题里的粗体标记 ** 没解析掉", into: &bad)
                if let f = font(of: out, ns, "重点") {
                    require(isBoldFont(f), "标题内的 **重点** 应是粗体字重", into: &bad)
                } else { bad.append("标题内的粗体文字丢失") }
                return bad
            },

            sample("粗体斜体行内代码删除线混排",
                   ["普通 **粗体** *斜体* ***粗斜体*** `inline_code` ~~删除~~ 收尾"],
                   "普通粗体斜体粗斜体inline_code删除收尾") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                if let f = font(of: out, ns, "粗体") {
                    require(isBoldFont(f), "粗体字重要为 bold，实测 \(f.fontName)", into: &bad)
                } else { bad.append("粗体文字丢失") }
                if let f = font(of: out, ns, "斜体"), let plain = font(of: out, ns, "普通") {
                    require(f.fontName != plain.fontName || isItalic(f),
                            "斜体没有换成可区分的字体，实测 \(f.fontName) / \(plain.fontName)", into: &bad)
                } else { bad.append("斜体或参照文字丢失") }
                if let f = font(of: out, ns, "粗斜体") {
                    require(isBoldFont(f), "***粗斜体*** 的粗体没生效，实测 \(f.fontName)", into: &bad)
                    require(isItalicFont(f) || f.fontName != (font(of: out, ns, "斜体")?.fontName ?? ""),
                            "***粗斜体*** 的斜体没生效，实测 \(f.fontName)", into: &bad)
                } else { bad.append("***粗斜体*** 文字丢失或被拆碎") }
                require(!out.string.contains("***"), "*** 标记没解析掉", into: &bad)
                if let f = font(of: out, ns, "inline_code") {
                    require(isMono(f), "行内代码要用等宽字体，实测 \(f.fontName)", into: &bad)
                } else { bad.append("行内代码文字丢失") }
                let codeRange = ns.range(of: "inline_code")
                if codeRange.location != NSNotFound {
                    let bg = out.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
                    require(bg != nil, "行内代码缺少淡背景", into: &bad)
                }
                let strikeRange = ns.range(of: "删除")
                if strikeRange.location != NSNotFound {
                    let s = out.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int
                    require((s ?? 0) != 0, "删除线没有生效", into: &bad)
                } else { bad.append("删除线文字丢失") }
                require(!out.string.contains("`"), "行内代码的反引号没清掉", into: &bad)
                require(!out.string.contains("~~"), "删除线标记没清掉", into: &bad)
                return bad
            },

            sample("围栏代码块",
                   ["```swift", "let x = 1   // 注释", "print(\"你好 \\(x)\")", "```"],
                   "letx=1//注释print(\"你好\\(x)\")") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                if let f = font(of: out, ns, "print") {
                    require(isMono(f), "代码块要用等宽字体，实测 \(f.fontName)", into: &bad)
                } else { bad.append("代码块内容丢失") }
                require(out.string.contains("let x = 1"), "代码块第一行丢失", into: &bad)
                require(out.string.contains("你好"), "代码块里的中文丢失", into: &bad)
                require(out.string.contains("\\(x)"), "代码块里的反斜杠被吞", into: &bad)
                require(!out.string.contains("```"), "围栏标记 ``` 没清掉", into: &bad)
                require(!out.string.contains("swift"), "代码块语言标识不该显示出来", into: &bad)
                let ps = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                require(ps != nil && ps!.firstLineHeadIndent > 0, "代码块应有整块缩进", into: &bad)
                let bg = out.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                require(bg != nil, "代码块缺少淡背景", into: &bad)
                return bad
            },

            sample("无序 + 有序列表（含行内代码与粗体嵌套、续行、子列表）",
                   ["- 第一项 `code1`",
                    "- 第二项 **加粗**",
                    "  这是同一条目的第二行",
                    "* 星号项",
                    "+ 加号项",
                    "1. 有序一",
                    "2. 有序二 `code2`",
                    "10. 有序十",
                    "    - 嵌套子项"],
                   "•第一项code1•第二项加粗这是同一条目的第二行•星号项•加号项1.有序一2.有序二code210.有序十•嵌套子项") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                require(out.string.contains("•"), "无序列表要渲染出实心圆点", into: &bad)
                require(out.string.contains("1."), "有序列表编号 1. 丢失", into: &bad)
                require(out.string.contains("10."), "有序列表编号 10. 丢失", into: &bad)
                require(!out.string.contains("`"), "列表项里的行内代码反引号没清掉", into: &bad)
                if let f = font(of: out, ns, "code1") {
                    require(isMono(f), "列表项内的行内代码不是等宽字体", into: &bad)
                } else { bad.append("列表项内的行内代码文字丢失") }
                if let f = font(of: out, ns, "加粗") {
                    require(isBoldFont(f), "列表项内的粗体失效", into: &bad)
                } else { bad.append("列表项内的粗体文字丢失") }
                if let f = font(of: out, ns, "code2") {
                    require(isMono(f), "有序列表项内的行内代码不是等宽字体", into: &bad)
                }
                let first = ns.range(of: "第一项")
                let nested = ns.range(of: "嵌套子项")
                if first.location != NSNotFound, nested.location != NSNotFound {
                    let a = out.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle
                    let b = out.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle
                    if let a = a, let b = b {
                        require(b.firstLineHeadIndent > a.firstLineHeadIndent,
                                "嵌套列表没有更深的缩进：\(a.firstLineHeadIndent) → \(b.firstLineHeadIndent)", into: &bad)
                    }
                } else { bad.append("嵌套子项或首项文字丢失") }

                // 真实排版验悬挂缩进：窄宽度强制换行，续行的文本起点必须落在「标记宽 + 间隔」那一列。
                let hanging = render("- " + String(repeating: "很长", count: 40))
                let xs = lineFragmentOriginXs(hanging, width: 120)
                require(xs.count >= 3, "悬挂缩进用例至少该排到 3 行，实测 \(xs.count) 行", into: &bad)
                let hangingPS = hanging.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                let markerWidth = ("•" as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13)]).width
                if let h = hangingPS?.headIndent, let f = hangingPS?.firstLineHeadIndent {
                    require(f == 0, "首行头标应贴左边，实测 \(f)", into: &bad)
                    require(h > markerWidth,
                            "headIndent(\(h)) 应大于标记宽度(\(markerWidth))，否则正文会黏在圆点上", into: &bad)
                    require(h <= markerWidth + 26,
                            "headIndent(\(h)) 离标记太远，白留一大块空白", into: &bad)
                } else { bad.append("列表项没有段落样式，悬挂缩进无从谈起") }
                if xs.count >= 3 {
                    require(xs[0] == 0, "首行（圆点）应贴在 x=0，实测 \(xs[0])", into: &bad)
                    for k in 1..<xs.count {
                        require(abs(xs[k] - (hangingPS?.headIndent ?? -1)) < 0.6,
                                "第 \(k + 1) 行没有对齐到正文列：实测 x=\(xs[k])，应为 \(hangingPS?.headIndent ?? -1)",
                                into: &bad)
                    }
                }
                // 条目内软换行的续行也要对齐到正文列（不是贴回行首，也不是贴到圆点列）。
                let cont = render("- 第二项\n  这是同一条目的第二行")
                let contLines = cont.string.components(separatedBy: "\n")
                require(contLines.count == 2, "条目续行被拆开，实测 \(contLines.count) 段", into: &bad)
                let contXs = lineFragmentOriginXs(cont, width: 120)
                require(contXs.count >= 2, "条目续行排版行数不足：\(contXs)", into: &bad)
                if contXs.count >= 2,
                   let cps = cont.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    require(contXs[1] > contXs[0] + 2, "条目续行贴回行首：\(contXs)", into: &bad)
                    require(abs(contXs[1] - cps.headIndent) < 0.6,
                            "条目续行没对齐到正文列：实测 x=\(contXs[1])，正文列 \(cps.headIndent)", into: &bad)
                }
                // 有序列表同样要悬挂：编号比圆点宽，续行不能压回编号下面。
                let ordered = render("10. " + String(repeating: "很长", count: 40))
                let orderedXs = lineFragmentOriginXs(ordered, width: 120)
                if orderedXs.count >= 2,
                   let oPS = ordered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    let numberWidth = ("10." as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13)]).width
                    require(orderedXs[1] > oPS.firstLineHeadIndent + 4,
                            "有序列表续行没有悬挂：\(orderedXs)", into: &bad)
                    require(orderedXs[1] >= numberWidth,
                            "有序列表续行压回了编号下面：x=\(orderedXs[1]) < 编号宽 \(numberWidth)", into: &bad)
                } else { bad.append("有序列表用例没排到两行") }
                return bad
            },

            sample("引用与分割线",
                   ["前文", "", "> 引用第一行", "> 引用第二行 **强调**", ">> 嵌套引用", "", "---", "", "后文"],
                   "前文引用第一行引用第二行强调嵌套引用后文") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                require(out.string.contains("─"), "分割线没有渲染成横线", into: &bad)
                require(!out.string.contains(">"), "引用的 > 标记没清掉", into: &bad)
                require(!out.string.contains("---"), "分割线的 --- 没被转换", into: &bad)
                if let r = locate(ns, "引用第一行") {
                    let c = out.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor
                    require(sameColor(c, secondary), "引用应使用 secondaryColor，实测 \(String(describing: c))", into: &bad)
                    let ps = out.attribute(.paragraphStyle, at: r, effectiveRange: nil) as? NSParagraphStyle
                    require(ps != nil && ps!.firstLineHeadIndent > 0, "引用左侧没有留白", into: &bad)
                } else { bad.append("引用正文丢失") }
                if let r = locate(ns, "嵌套引用") {
                    let ps = out.attribute(.paragraphStyle, at: r, effectiveRange: nil) as? NSParagraphStyle
                    let outer = locate(ns, "引用第一行").flatMap {
                        out.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle
                    }
                    if let ps = ps, let outer = outer {
                        require(ps.firstLineHeadIndent > outer.firstLineHeadIndent,
                                "嵌套引用没有更深留白", into: &bad)
                    }
                } else { bad.append("嵌套引用正文丢失") }
                if let f = font(of: out, ns, "强调") {
                    require(isBoldFont(f), "引用内的粗体失效", into: &bad)
                } else { bad.append("引用内的粗体文字丢失") }
                if let r = locate(ns, "前文") {
                    let ps = out.attribute(.paragraphStyle, at: r, effectiveRange: nil) as? NSParagraphStyle
                    require(ps != nil && ps!.firstLineHeadIndent == 0, "引用外的段落不该有缩进", into: &bad)
                }
                return bad
            },

            sample("链接",
                   ["详情看 [百度](https://www.example.com/path?a=1&b=2) 和 [另一个](https://other.example.com) 结束。"],
                   "详情看百度和另一个结束。") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                for (key, prefix) in [("百度", "https://www.example.com"), ("另一个", "https://other.example.com")] {
                    if let r = locate(ns, key) {
                        let link = out.attribute(.link, at: r, effectiveRange: nil)
                        let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                        require(url.hasPrefix(prefix), "链接「\(key)」URL 挂错或没挂上：\(url)", into: &bad)
                        let underline = out.attribute(.underlineStyle, at: r, effectiveRange: nil) as? Int
                        require((underline ?? 0) != 0, "链接「\(key)」没有下划线", into: &bad)
                        let c = out.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor
                        require(sameColor(c, secondary), "链接「\(key)」应该用次要色，实测 \(String(describing: c))", into: &bad)
                    } else { bad.append("链接文字「\(key)」丢失") }
                }
                require(!out.string.contains("]("), "链接语法没解析，残留 ](", into: &bad)
                require(!out.string.contains("https://www.example.com/path"), "URL 不该以明文出现在正文里", into: &bad)
                return bad
            },

            sample("GFM 表格（含行内代码/斜体/粗体单元格）",
                   ["| 词义 | 例句 | 频率 |",
                    "| :--- | :---: | ---: |",
                    "| pressure | 压 | 高 |",
                    "| `code_cell` | *ital* | **b** |"],
                   "词义例句频率pressure压高code_cellitalb") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                require(!out.string.contains("|"), "表格里残留竖线噪音", into: &bad)
                require(out.string.contains("\t"), "表格没有用制表位分列", into: &bad)
                for key in ["词义", "例句", "频率", "pressure", "压", "高", "code_cell", "ital", "b"] {
                    if ns.range(of: key).location == NSNotFound { bad.append("表格单元格「\(key)」丢失") }
                }
                if let f = font(of: out, ns, "词义") {
                    require(isBoldFont(f), "表头应该加粗", into: &bad)
                }
                if let f = font(of: out, ns, "code_cell") {
                    require(isMono(f), "表格单元格里的行内代码不是等宽字体", into: &bad)
                }
                if let f = font(of: out, ns, "ital") {
                    require(isItalic(f) || f.fontName != (font(of: out, ns, "词义")?.fontName ?? ""),
                            "表格单元格里的斜体没生效", into: &bad)
                }
                let ps = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                require(ps != nil && !ps!.tabStops.isEmpty, "表格列缺少制表位", into: &bad)
                if let ps = ps { require(ps.tabStops.count >= 3, "表格只建了 \(ps.tabStops.count) 个制表位", into: &bad) }
                // 同一行各列的列起点必须一致（等宽列真的对齐了）
                let xs = lineFragmentOriginXs(out, width: 400)
                require(xs.count >= 2, "表格没排到两行以上，实测 \(xs.count)", into: &bad)
                return bad
            },

            sample("段内单换行必须保留",
                   ["第一行", "第二行", "第三行"],
                   "第一行第二行第三行") { out in
                var bad: [String] = []
                let newlines = out.string.filter { $0 == "\n" }.count
                require(newlines == 2, "段内两个单换行应保留 2 个换行符，实测 \(newlines)", into: &bad)
                let three = predictedHeight("第一行\n第二行\n第三行", width: 400, fontSize: 13)
                let one = predictedHeight("第一行第二行第三行", width: 400, fontSize: 13)
                require(three > one * 1.7, "三行高度(\(three))没有明显大于一行(\(one))", into: &bad)
                return bad
            },

            sample("超长单行",
                   ["这是一个很长的单行" + String(repeating: "填充内容", count: 400) + "结尾"],
                   "这是一个很长的单行" + String(repeating: "填充内容", count: 400) + "结尾") { out in
                var bad: [String] = []
                let h = measuredHeight(of: out, width: 300)
                require(h > 13, "超长单行高度过小：\(h)", into: &bad)
                require(h < 13 * 600, "超长单行高度过大：\(h)", into: &bad)
                let lines = lineFragmentOriginXs(out, width: 300).count
                require(lines > 3, "超长单行应该折成多行，实测 \(lines) 行", into: &bad)
                return bad
            },

            sample("连续多个空行",
                   ["上段", "", "", "", "", "下段", "", "", "", "", "再下段"],
                   "上段下段再下段") { out in
                var bad: [String] = []
                let breaks = out.string.filter { $0 == "\n" }.count
                require(breaks <= 4, "连续空行应被压缩，实测输出 \(breaks) 个换行", into: &bad)
                require(out.string.hasPrefix("上段"), "首段前不该有空白", into: &bad)
                require(!out.string.hasSuffix("\n"), "末尾不该留空行", into: &bad)
                let flat = predictedHeight("上段\n下段\n再下段", width: 300, fontSize: 13)
                let spaced = predictedHeight("上段\n\n\n\n\n下段\n\n\n\n\n再下段", width: 300, fontSize: 13)
                require(abs(flat - spaced) < 1, "多空行和单空行的高度应一致：\(flat) vs \(spaced)", into: &bad)
                return bad
            },

            sample("CRLF 换行",
                   ["甲行\r乙行\r\r丙段\r- 项一\r- 项二\r"],
                   "甲行乙行丙段•项一•项二") { out in
                var bad: [String] = []
                require(!out.string.contains("\r"), "\\r 没有归一化掉", into: &bad)
                let breaks = out.string.filter { $0 == "\n" }.count
                require(breaks >= 3, "CRLF 样例的换行丢了，实测 \(breaks)", into: &bad)
                require(out.string.contains("•"), "CRLF 样例的列表项没解析", into: &bad)
                return bad
            },

            sample("中文标点与全角空格",
                   ["「完整」，（半角）；：！？……——、·　全角空格　结尾 émoji 😀"],
                   "「完整」，（半角）；：！？……——、·全角空格结尾émoji😀") { out in
                var bad: [String] = []
                require(out.string.contains("\u{3000}"), "全角空格 U+3000 被吃掉了", into: &bad)
                require(out.string.contains("……"), "中文省略号丢失", into: &bad)
                require(out.string.contains("、"), "顿号丢失", into: &bad)
                require(out.string.contains("😀"), "emoji 丢失或被拆坏", into: &bad)
                require(out.string.contains("é"), "带音标的拉丁字母被拆坏", into: &bad)
                require(out.string.contains("——"), "中文破折号丢失", into: &bad)
                return bad
            },

            sample("不成对标记与标识符原样保留",
                   ["a * b ** c ` d [ e ( f ~~ g >>  h", "snake_case_name 和 keep_this_value 不该变斜体"],
                   "a*b**c`d[e(f~~g>>hsnake_case_name和keep_this_value不该变斜体") { out in
                var bad: [String] = []
                require(out.string.contains("*"), "单个 * 被吞掉了", into: &bad)
                require(out.string.contains("**"), "不成对的 ** 被当成粗体吞掉了", into: &bad)
                require(out.string.contains("`"), "单个反引号被吞掉了", into: &bad)
                require(out.string.contains("["), "单个方括号被吞掉了", into: &bad)
                require(out.string.contains("~~"), "不成对的 ~~ 被吞掉了", into: &bad)
                require(out.string.contains(">>"), "行内的 >> 被吞掉了", into: &bad)
                require(out.string.contains("snake_case_name"), "下划线标识符被误当斜体吞了字符", into: &bad)
                require(out.string.contains("keep_this_value"), "下划线标识符被误当斜体吞了字符", into: &bad)
                return bad
            },

            sample("未闭合围栏不吞字",
                   ["```swift", "let a = 1", "// 后面没有闭合的 ```"],
                   "```swiftleta=1//后面没有闭合的```") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                require(out.string.contains("```swift"),
                        "未闭合的围栏行被吞了（流式输出半截 ``` 时不能丢字）", into: &bad)
                require(out.string.contains("let a = 1"), "未闭合围栏里的代码正文丢失", into: &bad)
                if let f = font(of: out, ns, "let") {
                    require(isMono(f), "未闭合围栏仍应按代码排版，实测 \(f.fontName)", into: &bad)
                }
                return bad
            },

            sample("空列表标记与非表格竖线原样保留",
                   ["-", "*", "1.", "a|b", "c | d"],
                   "-*1.a|bc|d") { out in
                var bad: [String] = []
                require(out.string.contains("a|b"), "竖线正文被表格分支吞了", into: &bad)
                require(out.string.contains("c | d"), "非表格的竖行被改写", into: &bad)
                require(!out.string.contains("\u{2022}"),
                        "单独一行 \"-\" 不该变成空圆点（等于把标记吞了）", into: &bad)
                return bad
            },

            sample("综合文档",
                   ["## 译文",
                    "",
                    "1. **primary** pressure —— 主语",
                    "   - 详见 [词典](https://dict.example.com)",
                    "   - 代码 `keepAlive()`",
                    "",
                    "> 说明：逐行输出",
                    "> 第二行",
                    "",
                    "| 词 | 释义 |",
                    "|---|---|",
                    "| run | 跑 |",
                    "",
                    "```",
                    "line-one",
                    "line-two",
                    "```",
                    "",
                    "---",
                    "",
                    "结束。"],
                   "译文1.primarypressure——主语•详见词典•代码keepAlive()说明：逐行输出第二行词释义run跑line-oneline-two结束。") { out in
                var bad: [String] = []
                let ns = out.string as NSString
                require(out.string.contains("•"), "综合样例的列表圆点丢失", into: &bad)
                require(out.string.contains("line-one"), "代码块第一行丢失", into: &bad)
                require(out.string.contains("line-two"), "代码块第二行丢失", into: &bad)
                require(out.string.contains("─"), "综合样例的分割线丢失", into: &bad)
                require(out.string.contains("结束。"), "综合样例的尾段丢失", into: &bad)
                require(out.string.contains("\t"), "综合样例的表格没有按列输出", into: &bad)
                if let f = font(of: out, ns, "译文") {
                    require(f.pointSize > 13, "综合样例的 h2 没有放大，实测 \(f.pointSize)", into: &bad)
                }
                if let r = locate(ns, "词典") {
                    let link = out.attribute(.link, at: r, effectiveRange: nil) as? URL
                    require(link != nil, "列表项里的链接没挂上 URL", into: &bad)
                } else { bad.append("列表项里的链接文字丢失") }
                return bad
            },
        ]

        // MARK: 逐样例跑 attributed / predictedHeight

        for item in samples {
            let out = render(item.markdown)
            let rendered = out.string
            let actualKey = collapse(rendered)
            let expectedKey = collapse(item.expected)
            if actualKey != expectedKey {
                failures.append("[\(item.name)] 正文内容不匹配：实际「\(preview(actualKey))」 期望「\(preview(expectedKey))」")
            }
            for problem in item.verify(out) {
                failures.append("[\(item.name)] \(problem)")
            }

            let wide = predictedHeight(item.markdown, width: 600, fontSize: body)
            let narrow = predictedHeight(item.markdown, width: 160, fontSize: body)
            let zero = predictedHeight(item.markdown, width: 0, fontSize: body)
            expect(wide.isFinite && wide >= 0 && wide < 40_000,
                   "[\(item.name)] width=600 高度不在合理区间：\(wide)")
            expect(narrow.isFinite && narrow >= 0 && narrow < 60_000,
                   "[\(item.name)] width=160 高度不在合理区间：\(narrow)")
            expect(zero == 0, "[\(item.name)] width=0 应返回 0，实测 \(zero)")

            if item.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                expect(wide == 0, "[\(item.name)] 空白输入高度应为 0，实测 \(wide)")
            } else {
                expect(wide >= body * 1.2, "[\(item.name)] 有内容时高度过小：\(wide)")
                expect(narrow + 1 >= wide, "[\(item.name)] 窄宽度(\(narrow)) 不该比宽宽度(\(wide)) 矮")
            }

            let small = predictedHeight(item.markdown, width: 300, fontSize: 10)
            let large = predictedHeight(item.markdown, width: 300, fontSize: 18)
            expect(small <= large + 0.01, "[\(item.name)] 10pt(\(small)) 不该比 18pt(\(large)) 高")

            // attributed 自身带的换行数必须和 markdown 的段落到行数对得上（不能出现整段消失）
            let sourceLines = item.markdown.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let outLines = rendered.components(separatedBy: "\n").count
            expect(outLines > 0, "[\(item.name)] 输出没有行")
            expect(outLines >= min(sourceLines, 1),
                   "[\(item.name)] 输出行数 \(outLines) 少于输入有效行 \(sourceLines)")
        }

        // MARK: 退化输入不能崩、不能吞字

        let degraded = ["", "#", "```", "|", "[", "]", "*", "_", "~~", "> ", "\n\n\n",
                        "######", "- ", "1.", "a|b", "[x](", "![]()", "<script>", "\u{3000}",
                        "***", "****", "` `", "~~~", "1) 括号有序", "- [ ] 任务清单"]
        for input in degraded {
            let out = render(input)
            let height = predictedHeight(input, width: 200, fontSize: body)
            expect(height.isFinite && height >= 0, "退化输入「\(preview(input))」高度非法：\(height)")
            // 只看字母数字（跳过排版符号），否则 "a|b" 这种会被竖线挡住比较。
            let words = alnumOnly(input)
            if !words.isEmpty {
                expect(alnumOnly(out.string).contains(words),
                       "退化输入「\(preview(input))」的字母数字内容被吞了：\(preview(out.string))")
            }
        }

        // MARK: 非法字号 / 宽度

        let negative = attributed("x", fontSize: -5, color: main, secondaryColor: secondary)
        expect(negative.length == 1, "负字号下正文被吞")
        expect(predictedHeight("x", width: -100, fontSize: body) == 0, "负宽度高度应为 0")
        expect(predictedHeight("x", width: .nan, fontSize: body) == 0, "NaN 宽度高度应为 0")
        let huge = attributed("x", fontSize: 10_000, color: main, secondaryColor: secondary)
        if let f = huge.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            expect(f.pointSize <= 72, "字号没有被夹到安全区间，实测 \(f.pointSize)")
        }
        let zeroText = attributed("", fontSize: 13, color: main, secondaryColor: secondary)
        expect(zeroText.length == 0, "空串应产出空 attributed string")

        // MARK: predictedHeight 必须等于 attributed() 的真实排版高度

        let doc = samples.last!.markdown
        let laid = attributed(doc, fontSize: 15, color: main, secondaryColor: secondary)
        for width in [140.0, 280.0, 460.0, 800.0] {
            let real = measuredHeight(of: laid, width: CGFloat(width))
            let predicted = predictedHeight(doc, width: CGFloat(width), fontSize: 15)
            // predictedHeight 末尾额外补了最后一段的 spacing，容差按一行给。
            expect(abs(real - predicted) <= body * 1.2,
                   "width=\(width) 时预测高度(\(predicted)) 与实测排版高度(\(real)) 偏差过大")
        }

        // MARK: 颜色注入：主色/次要色必须真的落到属性上

        let tinted = attributed("正文原样\n\n> 引用整块\n> 第二行\n\n- 列表项",
                                fontSize: 13,
                                color: NSColor.red,
                                secondaryColor: NSColor.blue)
        let tintedNS = tinted.string as NSString
        if let r = locate(tintedNS, "正文原样") {
            expect(sameColor(tinted.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor, .red),
                   "正文没有使用传入的 color")
        } else { failures.append("颜色注入用例的正文丢失") }
        if let r = locate(tintedNS, "引用整块") {
            expect(sameColor(tinted.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor, .blue),
                   "引用没有使用传入的 secondaryColor")
        } else { failures.append("颜色注入用例的引用文字丢失（引用行必须以 > 开头）") }
        if let r = locate(tintedNS, "第二行") {
            expect(sameColor(tinted.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor, .blue),
                   "引用第二行没有使用传入的 secondaryColor")
        }
        if let r = locate(tintedNS, "列表项") {
            expect(sameColor(tinted.attribute(.foregroundColor, at: r, effectiveRange: nil) as? NSColor, .red),
                   "列表正文应该用主色，只有条目符号用次要色")
        } else { failures.append("颜色注入用例的列表项丢失") }

        // MARK: 标记浓汤：任何解析分支都不许吞掉字母数字

        let soups = [
            "**|****", "-****>#", "+[(+", "# -  ***(", "*", "|", "]*", "> - -", "[", "[]",
            "- >###", "```)~~(2##pressure__pressure", "~~~~](x***+keepAlive\u{6c49}\u{7ffb}\u{8bd1}",
            "````\u{4e3b}\u{8bed}", "```\u{7ffb}\u{8bd1}]``test``test", "~~~**a**~~~", "|a|b|",
            "\u{4e2d}\u{6587}**\u{7c97}*\u{659c}*`\u{4ee3}`[\u{94fe}](https://a.cn/x)\u{6536}",
            "1) \u{6709}\u{5e8f}\u{53f7}", "- [ ] \u{4efb}\u{52a1}\u{6e05}\u{5355}", "x\\*y\\_z\\`w",
            "![\u{56fe}1](https://x/a.png)", "[a](b)(c)", "`code\u{4e2d}\u{6587}`",
            "\u{6ca1}\u{6709}\u{6807}\u{8bb0}\u{7eaf}\u{6b63}\u{6587}",
        ]
        // 嵌套方括号的图片形态：URL 目标按设计隐藏，正文比较模型不了，只做结构不变量。
        let structuralSoups = ["!!![[a]](b)", "[[a]](b)", "![![c]](d)"]
        for soup in soups + structuralSoups {
            let out = render(soup)
            let height = predictedHeight(soup, width: 240, fontSize: body)
            expect(height.isFinite && height >= 0, "标记浓汤「\(preview(soup))」高度非法：\(height)")
            // 允许合法消失的只有链接/图片的 URL 目标（它本来就该藏在 .link 属性里）；
            // 链接文字本身必须留在正文，所以替换模板保留第 1 组。
            let stripped = soup.replacingOccurrences(
                of: "\\[([^\\]\\n]*)\\]\\([^\\)\\n]*\\)",
                with: "$1", options: .regularExpression)
            if !structuralSoups.contains(soup) {
                let want = alnumOnly(stripped)
                let got = alnumOnly(out.string)
                expect(want.isEmpty || got.contains(want),
                       "标记浓汤「\(preview(soup))」丢了正文：输出「\(preview(out.string))」")
            }
            // 挂上去的链接必须是可打开的 scheme，不能留 javascript: 之类
            let full = NSRange(location: 0, length: out.length)
            out.enumerateAttribute(.link, in: full) { value, _, _ in
                guard let url = value as? URL, let scheme = url.scheme?.lowercased() else { return }
                expect(["http", "https", "mailto", "tel"].contains(scheme),
                       "标记浓汤「\(preview(soup))」挂了非法 scheme 的链接：\(scheme)")
            }
        }

        // MARK: 大文档：内容不丢 + 不退化成二次方

        // 每行都是「有格式的正文」，期望值按渲染后的纯文本逐行拼回去比对。
        let richLine = "**粗体** 和 `code` 混排 *斜体* [链接](https://a.com/x) 尾巴"
        let richPlain = "粗体和code混排斜体链接尾巴"
        let starRun = "前缀" + String(repeating: "*", count: 3000)          // 超长标记串
        let starPlain = starRun                                             // 4+ 连续标记原样保留
        let codeItem = "- 项 " + String(repeating: "`x` ", count: 300)
        let codePlain = "项" + String(repeating: "x", count: 300)
        let tableRows = Array(repeating: "| 1 | 2 |", count: 200)
        let heavy = (0..<400).map { _ in richLine }.joined(separator: "\n") + "\n\n"
            + starRun + "\n\n" + codeItem + "\n\n"
            + "| a | b |\n|---|---|\n" + tableRows.joined(separator: "\n")
        let expectedHeavy = collapse((0..<400).map { _ in richPlain }.joined()
                                    + starPlain + codePlain + "ab"
                                    + tableRows.map { _ in "12" }.joined())
        let begin = Date()
        let heavyOut = attributed(heavy, fontSize: body, color: main, secondaryColor: secondary)
        let heavyHeight = predictedHeight(heavy, width: 320, fontSize: body)
        let cost = Date().timeIntervalSince(begin)
        let actualHeavy = collapse(heavyOut.string)
        expect(actualHeavy == expectedHeavy,
               "大文档正文不匹配：输入 \(heavy.count) 字符 / 输出 \(heavyOut.length) 字符；"
                + "实际尾部「\(preview(String(actualHeavy.suffix(80))))」"
                + " 期望尾部「\(preview(String(expectedHeavy.suffix(80))))」"
                + "（长度 实际\(actualHeavy.count)/期望\(expectedHeavy.count)）")
        expect(heavyHeight.isFinite && heavyHeight > 0, "大文档高度非法：\(heavyHeight)")
        expect(cost < 6, "渲染 + 排版大文档耗时 \(String(format: "%.2f", cost))s，可能有二次方退化")

        // 逐行确认没有被错位搬运：第 1 行和第 400 行都必须是同一内容。
        let heavyLines = heavyOut.string.components(separatedBy: "\n").filter { !$0.isEmpty }
        expect(heavyLines.count >= 400,
               "大文档行数塌了：实测 \(heavyLines.count)")
        if heavyLines.count >= 400 {
            for probe in [0, 199, 399] {
                expect(collapse(heavyLines[probe]) == richPlain,
                       "大文档第 \(probe) 行内容错位：\(preview(heavyLines[probe]))")
            }
        }

        return failures
    }

    // MARK: - 自测辅助

    private static func require(_ condition: Bool,
                                _ message: @autoclosure () -> String,
                                into bad: inout [String]) {
        if !condition { bad.append(message()) }
    }

    private static func locate(_ ns: NSString, _ needle: String) -> Int? {
        let r = ns.range(of: needle)
        return r.location == NSNotFound ? nil : r.location
    }

    /// 判断字体是不是已经带粗体。
    /// 不用 fontDescriptor.symbolicTraits.contains(.traitBold)：不同 SDK 版本把这个 case
    /// 导入成 NSFontDescriptorTraitBold 之类的名字，前缀剥离规则不一致，写死就编不过。
    /// 也不用 CTFontCopyTraits 的数值权重：这几个 key 在本机取不到值。
    /// 这里用两条一起判：和同字号的 regular 同名必然不粗；再要求加粗后名字不变，说明已经有粗体。
    private static func isBoldFont(_ font: NSFont) -> Bool {
        let regular = NSFont.systemFont(ofSize: font.pointSize)
        if font.fontName == regular.fontName { return false }
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask).fontName == font.fontName
    }

    private static func isItalicFont(_ font: NSFont) -> Bool {
        let regular = NSFont.systemFont(ofSize: font.pointSize)
        if font.fontName == regular.fontName { return false }
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask).fontName == font.fontName
    }

    private static func font(of out: NSAttributedString, _ ns: NSString, _ needle: String) -> NSFont? {
        guard let r = locate(ns, needle) else { return nil }
        return out.attribute(.font, at: r, effectiveRange: nil) as? NSFont
    }

    private static func isMono(_ f: NSFont) -> Bool {
        let name = f.fontName.lowercased()
        if name.contains("mono") || name.contains("menlo") || name.contains("courier") { return true }
        return f.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    private static func isItalic(_ f: NSFont) -> Bool {
        let name = f.fontName.lowercased()
        if name.contains("italic") || name.contains("oblique") || name.contains("slant") { return true }
        return f.fontDescriptor.symbolicTraits.contains(.italic)
    }

    private static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a, let b = b,
              let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        func close(_ p: CGFloat, _ q: CGFloat) -> Bool { abs(p - q) < 0.01 }
        return close(x.redComponent, y.redComponent)
            && close(x.greenComponent, y.greenComponent)
            && close(x.blueComponent, y.blueComponent)
            && close(x.alphaComponent, y.alphaComponent)
    }

    /// 退化输入比较用：只留字母和数字（含 CJK），排版符号一律不参与比对。
    private static func alnumOnly(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    /// 正文比较用：剔掉所有空白，以及渲染时新增的项目符号/分割线字符。
    private static func collapse(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "\u{2022}" || scalar == "\u{2500}" || scalar == "\u{00A0}" { continue }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func preview(_ text: String) -> String {
        let limit = 140
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
