import AppKit
import AVFoundation

/// 朗读。用系统的语音合成，音色和语速走设置。
///
/// 不需要额外权限，也不联网。中文文本会自动挑中文音色——
/// 用英文音色念中文会变成一串谁也听不懂的东西。
final class SpeechService: NSObject {

    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var lastSpokenText: String?

    private override init() { super.init() }

    /// 当前可用音色（给设置页列出来）
    static var availableVoices: [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices().map {
            (id: $0.identifier, name: $0.name, language: $0.language)
        }
    }

    /// 挑音色：设置里指定了就用指定的，否则按文本语言挑一个
    func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let configured = Config.shared.speechVoiceID
        if !configured.isEmpty, let picked = AVSpeechSynthesisVoice(identifier: configured) {
            return picked
        }
        // 含汉字就优先中文音色
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let wanted = hasChinese ? "zh-CN" : "en-US"
        return AVSpeechSynthesisVoice(language: wanted)
            ?? AVSpeechSynthesisVoice.speechVoices().first
    }

    private var player: AVAudioPlayer?

    /// 云端合成：拿到 base64 音频后播放。失败就退回系统合成，别让用户点了没反应。
    private func speakViaCloud(_ text: String, engine: TtsEngine) {
        let key = SecretStore.shared.apiKey(for: engine.keyAccount)
        if engine.needsKey && key.isEmpty {
            HUD.show("「\(engine.title)」还没填密钥，先用系统语音")
            fallbackSystemSpeak(text)
            return
        }
        let request: TtsRequest?
        let parse: (Data) -> ProviderOutcome
        switch engine {
        case .edge:
            request = TtsCodec.edgeRequest(text: text, targetLanguage: Config.shared.targetLanguage)
            parse = TtsCodec.parseEdge
        case .google:
            request = TtsCodec.googleRequest(text: text, targetLanguage: Config.shared.targetLanguage, key: key)
            parse = TtsCodec.parseGoogle
        case .microsoft:
            request = TtsCodec.microsoftRequest(text: text, targetLanguage: Config.shared.targetLanguage, key: key)
            parse = TtsCodec.parseMicrosoft
        case .tencent:
            request = TtsCodec.tencentRequest(text: text, targetLanguage: Config.shared.targetLanguage, key: key)
            parse = TtsCodec.parseTencent
        case .volcengine:
            request = VolcEngines.ttsRequest(text: text, key: key,
                                             targetLanguage: Config.shared.targetLanguage)
            parse = VolcEngines.parseTts
        case .system:
            fallbackSystemSpeak(text)
            return
        }
        guard let request else {
            HUD.show("密钥格式不对，先用系统语音")
            fallbackSystemSpeak(text)
            return
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        Task.detached { [weak self] in
            do {
                let (data, response) = try await NetworkSession.shared.data(for: urlRequest)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    await MainActor.run {
                        HUD.show("\(engine.title) 返回 \(http.statusCode)，改用系统语音")
                        self?.fallbackSystemSpeak(text)
                    }
                    return
                }
                guard case .success(let base64) = parse(data),
                      let audio = Data(base64Encoded: base64) else {
                    await MainActor.run {
                        HUD.show("云端语音失败，改用系统语音")
                        self?.fallbackSystemSpeak(text)
                    }
                    return
                }
                await MainActor.run {
                    do {
                        let player = try AVAudioPlayer(data: audio)
                        self?.player = player
                        player.play()
                    } catch {
                        self?.fallbackSystemSpeak(text)
                    }
                }
            } catch {
                await MainActor.run {
                    HUD.show("云端语音失败，改用系统语音")
                    self?.fallbackSystemSpeak(text)
                }
            }
        }
    }

    private func fallbackSystemSpeak(_ text: String) {
        synthesizer.speak(makeUtterance(text))
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.2, min(2.0, Config.shared.speechRate)))
        return utterance
    }

    func speak(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            HUD.show("没有可朗读的内容")
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        lastSpokenText = text

        let engine = TtsEngine(rawValue: Config.shared.ttsEngine) ?? .system
        if engine != .system {
            Debug.log("朗读 \(text.count) 字（\(engine.title)）")
            speakViaCloud(text, engine: engine)
            return
        }
        synthesizer.speak(makeUtterance(text))
        Debug.log("朗读 \(text.count) 字（系统语音）")
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
