import Foundation

/// 调试开关。env 变量走不通 `open -a`，所以也读 UserDefaults。
/// 日志同时写 /tmp/localtranslate_debug.log —— 从 LaunchServices 启动时
/// NSLog 在统一日志里不好捞，落到文件最直接。
enum Debug {
    static let logPath = "/tmp/localtranslate_debug.log"

    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["LT_DEBUG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "debugLog")
    }

    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[\(Self.stamp())] \(message)\n"
        NSLog("[LocalTranslate] %@", message)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
        }
    }

    private static func stamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }
}
