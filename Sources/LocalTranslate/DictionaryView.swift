import AppKit
import AVFoundation

/// 词典区块的排版，按 Bob 那张卡片的分区方式来做：
/// 音标（美/英，可点读）→ 词性词义 → 动词形式 → 词组搭配 → 简明释义。
enum DictionaryView {

    /// 生成词典区块。调用方把它插进卡片正文下方。
    static func make(_ result: DictionaryResult) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        if !result.phonetics.isEmpty {
            stack.addArrangedSubview(phoneticRow(result.word, result.phonetics))
        }

        if !result.parts.isEmpty {
            stack.addArrangedSubview(sectionHeader("释义"))
            for part in result.parts {
                stack.addArrangedSubview(partRow(part))
            }
        }

        if !result.exchanges.isEmpty {
            stack.addArrangedSubview(sectionHeader("动词形式"))
            stack.addArrangedSubview(chipRow(result.exchanges))
        }

        if !result.collocations.isEmpty {
            stack.addArrangedSubview(sectionHeader("词组搭配"))
            for collocation in result.collocations {
                stack.addArrangedSubview(collocationRow(collocation))
            }
        }

        if !result.translations.isEmpty, result.parts.isEmpty {
            stack.addArrangedSubview(sectionHeader("简明释义"))
            for line in result.translations {
                stack.addArrangedSubview(wrappingLabel(line, font: CardTheme.resultFont, color: CardTheme.text))
            }
        }

        return stack
    }

    // MARK: - 各分区

    private static func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = CardTheme.metaFont
        label.textColor = CardTheme.tertiary
        return label
    }

    private static func phoneticRow(_ word: String, _ phonetics: [Phonetic]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY

        for phonetic in phonetics {
            let chip = NSStackView()
            chip.orientation = .horizontal
            chip.spacing = 5
            chip.alignment = .centerY

            let tag = NSTextField(labelWithString: phonetic.type == "uk" ? "英" : "美")
            tag.font = NSFont.systemFont(ofSize: 10)
            tag.textColor = CardTheme.tertiary

            let value = NSTextField(labelWithString: "/\(phonetic.value)/")
            value.font = NSFont.systemFont(ofSize: 13)
            value.textColor = CardTheme.secondary

            let speaker = NSButton()
            speaker.bezelStyle = .regularSquare
            speaker.isBordered = false
            speaker.imagePosition = .imageOnly
            speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "朗读")
            speaker.image?.isTemplate = true
            speaker.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            speaker.contentTintColor = CardTheme.secondary
            speaker.focusRingType = .none
            speaker.toolTip = "朗读（\(phonetic.type == "uk" ? "英音" : "美音")）"
            // 用对象持有参数，避免为每个音标新建一套 target 类
            speaker.action = #selector(SpeechTap.fire(_:))
            let tap = SpeechTap.shared
            tap.register(button: speaker, text: word, language: phonetic.type == "uk" ? "en-GB" : "en-US")

            chip.addArrangedSubview(tag)
            chip.addArrangedSubview(value)
            chip.addArrangedSubview(speaker)
            row.addArrangedSubview(chip)
        }
        row.addArrangedSubview(NSView())
        return row
    }

    private static func partRow(_ part: WordPart) -> NSView {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 34
        paragraph.firstLineHeadIndent = 0
        paragraph.lineSpacing = 3

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: part.part, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: CardTheme.secondary,
            .paragraphStyle: paragraph,
        ]))
        attributed.append(NSAttributedString(string: "  " + part.means.joined(separator: "；"), attributes: [
            .font: CardTheme.resultFont,
            .foregroundColor: CardTheme.text,
            .paragraphStyle: paragraph,
        ]))

        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBezeled = false
        field.attributedStringValue = attributed
        return field
    }

    private static func chipRow(_ exchanges: [Exchange]) -> NSView {
        let wrap = NSStackView()
        wrap.orientation = .horizontal
        wrap.spacing = 8
        wrap.alignment = .centerY

        for exchange in exchanges {
            wrap.addArrangedSubview(
                chip("\(exchange.name) \(exchange.words.joined(separator: " "))")
            )
        }
        wrap.addArrangedSubview(NSView())
        return wrap
    }

    /// 带内边距的小圆角标签。NSTextField 没有 edgeInsets，只能拿容器包一层。
    private static func chip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = CardTheme.secondary
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.borderWidth = 1
        container.layer?.borderColor = CardTheme.separator.cgColor
        container.layer?.backgroundColor = CardTheme.hintBarBackground.cgColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        return container
    }

    private static func collocationRow(_ collocation: Collocation) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let phrase = NSTextField(labelWithString: collocation.phrase)
        phrase.font = NSFont.systemFont(ofSize: 13)
        phrase.textColor = CardTheme.text
        phrase.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let translation = NSTextField(labelWithString: collocation.translation)
        translation.font = NSFont.systemFont(ofSize: 13)
        translation.textColor = CardTheme.secondary
        translation.alignment = .right

        row.addArrangedSubview(phrase)
        row.addArrangedSubview(translation)
        return row
    }

    private static func wrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        return label
    }
}

/// 音标发音按钮的公共 target。按钮本身不带参数，靠这张表回查要读什么。
final class SpeechTap: NSObject {
    static let shared = SpeechTap()

    private var jobs: [ObjectIdentifier: (text: String, language: String?)] = [:]
    private let synthesizer = AVSpeechSynthesizer()

    func register(button: NSButton, text: String, language: String?) {
        jobs[ObjectIdentifier(button)] = (text, language)
    }

    @objc func fire(_ sender: NSButton) {
        guard let job = jobs[ObjectIdentifier(sender)], !job.text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: job.text)
        if let language = job.language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }
}

