import AppKit

/// PopClip 扩展的本地生成与安装。
///
/// 思路：不预置二进制包，而是根据当前 App 的路径现场写一个 `.popclipext` 目录，
/// 里面只有一个 shell 脚本，用我们的 `localtranslate://` URL Scheme 把选中文字送进来。
/// 好处是：用户换电脑、换安装路径都不会失效。
enum PopClipInstaller {

    struct Failure: Error { var message: String }

    /// 生成到临时目录，返回 .popclipext 的路径
    static func build() -> Result<URL, Failure> {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalTranslate.popclipext")
        try? fm.removeItem(at: root)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: "创建目录失败：\(error.localizedDescription)"))
        }

        let script = """
        #!/bin/bash
        # PopClip 选中文字 → LocalTranslate 翻译
        ENCODED=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$POPCLIP_TEXT")
        open "localtranslate://translate?text=${ENCODED}&copy=1"
        """

        let config: [String: Any] = [
            "Extension Name": "翻译（LocalTranslate）",
            "Extension Identifier": "com.localtranslate.popclip.translate",
            "Extension Description": "用 LocalTranslate 翻译选中的文字（支持多家免费引擎）",
            "Extension Image": "icon.png",
            "Extension Type": "Action",
            "Regular Expression": "(?s).+",
            "Requirements": ["text"],
            "Script Interpreter": "/bin/bash",
            "Script": script,
            "Stay Visible": false,
            "Pass Text": true,
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            try data.write(to: root.appendingPathComponent("Config.plist"))
            try Data(script.utf8).write(to: root.appendingPathComponent("Script.sh"))
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: root.appendingPathComponent("Script.sh").path)
        } catch {
            return .failure(Failure(message: "写入扩展文件失败：\(error.localizedDescription)"))
        }

        // 图标：直接用 App 自己的图标
        if let appIcon = NSApp.applicationIconImage,
           let tiff = appIcon.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: root.appendingPathComponent("icon.png"))
        }

        return .success(root)
    }

    /// 生成并在 Finder 里打开，让 PopClip 自己接管安装
    static func install() -> Result<Void, Failure> {
        switch build() {
        case .failure(let failure): return .failure(failure)
        case .success(let url):
            NSWorkspace.shared.open(url)
            return .success(())
        }
    }
}
