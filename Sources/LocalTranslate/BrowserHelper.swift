import AppKit

/// 浏览器助手（对标 BobHelper）。
///
/// 做法：本地起一个只监听 127.0.0.1 的小服务（`HelperServer`），
/// 再生成一个 Chromium 扩展。扩展在页面上选中文字时弹一个小按钮，
/// 点一下就把文字发到本地服务，把译文显示在页面里——不切窗口、不动剪贴板。
///
/// Safari 的扩展必须用 Xcode 打包签名，命令行装不了，所以这里先做
/// Chrome / Edge / Brave 这类 Chromium 浏览器（覆盖面和实现成本最划算）。
enum BrowserHelper {

    struct Failure: Error { var message: String }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalTranslate", isDirectory: true)
        return base.appendingPathComponent("BrowserHelper", isDirectory: true)
    }

    /// 生成扩展目录（覆盖写），返回目录
    @discardableResult
    static func generateExtension(port: UInt16) -> Result<URL, Failure> {
        let fm = FileManager.default
        let dir = supportDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: "建目录失败：\(error.localizedDescription)"))
        }

        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "LocalTranslate Helper",
            "version": "1.0.0",
            "description": "选中网页文字，点一下就地翻译（由本机 LocalTranslate 提供翻译）",
            "permissions": ["storage"],
            "host_permissions": ["http://127.0.0.1:\(port)/*"],
            "content_scripts": [[
                "matches": ["<all_urls>"],
                "js": ["content.js"],
                "css": ["content.css"],
                "run_at": "document_idle",
            ]],
            "action": ["default_title": "LocalTranslate"],
        ]

        let contentJS = """
        // ==LocalTranslate Helper==
        (function () {
          const ENDPOINT = "http://127.0.0.1:\(port)/translate";
          let button = null;
          let panel = null;

          function removeUI() {
            if (button) { button.remove(); button = null; }
            if (panel) { panel.remove(); panel = null; }
          }

          function selectionRect() {
            const sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
            const text = sel.toString().trim();
            if (!text) return null;
            const range = sel.getRangeAt(0);
            const rect = range.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) return null;
            return { rect, text };
          }

          function showButton(rect) {
            removeUI();
            button = document.createElement("div");
            button.id = "lt-helper-button";
            button.textContent = "译";
            button.title = "用 LocalTranslate 翻译";
            button.style.left = (window.scrollX + rect.right + 6) + "px";
            button.style.top = (window.scrollY + rect.top - 2) + "px";
            button.addEventListener("mousedown", (e) => e.preventDefault());
            button.addEventListener("click", onTranslate);
            document.documentElement.appendChild(button);
          }

          async function onTranslate() {
            const sel = selectionRect();
            if (!sel) return;
            const rect = sel.rect;
            const text = sel.text;
            removeUI();
            panel = document.createElement("div");
            panel.id = "lt-helper-panel";
            panel.textContent = "翻译中…";
            panel.style.left = (window.scrollX + Math.max(8, rect.left)) + "px";
            panel.style.top = (window.scrollY + rect.bottom + 8) + "px";
            document.documentElement.appendChild(panel);
            try {
              const url = ENDPOINT + "?text=" + encodeURIComponent(text);
              const resp = await fetch(url, { cache: "no-store" });
              const data = await resp.json();
              if (!panel) return;
              if (!data.ok) throw new Error(data.error || "翻译失败");
              panel.textContent = data.text;
              panel.dataset.engine = data.engine || "";
            } catch (err) {
              if (!panel) return;
              panel.textContent = "翻译失败：" + err.message + "（确认 LocalTranslate 正在运行）";
              panel.classList.add("lt-helper-error");
            }
          }

          document.addEventListener("mouseup", () => {
            setTimeout(() => {
              const sel = selectionRect();
              if (sel) showButton(sel.rect); else removeUI();
            }, 10);
          });
          document.addEventListener("mousedown", (e) => {
            if (e.target && e.target.id === "lt-helper-button") return;
            if (e.target && e.target.id === "lt-helper-panel") return;
            removeUI();
          });
          document.addEventListener("keydown", (e) => {
            if (e.key === "Escape") removeUI();
          });
        })();
        """

        let contentCSS = """
        #lt-helper-button {
          position: absolute;
          z-index: 2147483647;
          width: 22px; height: 22px;
          line-height: 22px;
          text-align: center;
          font-size: 13px;
          font-family: -apple-system, "PingFang SC", sans-serif;
          color: #fff;
          background: #0b57d0;
          border-radius: 6px;
          cursor: pointer;
          box-shadow: 0 2px 8px rgba(0,0,0,.25);
          user-select: none;
        }
        #lt-helper-panel {
          position: absolute;
          z-index: 2147483647;
          max-width: 420px;
          padding: 8px 10px;
          font-size: 13px;
          line-height: 1.5;
          font-family: -apple-system, "PingFang SC", sans-serif;
          color: #202124;
          background: #fff;
          border: 1px solid rgba(0,0,0,.12);
          border-radius: 8px;
          box-shadow: 0 6px 24px rgba(0,0,0,.18);
          white-space: pre-wrap;
        }
        #lt-helper-panel.lt-helper-error { color: #b3261e; }
        """

        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try data.write(to: dir.appendingPathComponent("manifest.json"))
            try Data(contentJS.utf8).write(to: dir.appendingPathComponent("content.js"))
            try Data(contentCSS.utf8).write(to: dir.appendingPathComponent("content.css"))
        } catch {
            return .failure(Failure(message: "写扩展文件失败：\(error.localizedDescription)"))
        }

        // 图标：16/48/128 三档，直接缩 App 图标
        if let appIcon = NSApp.applicationIconImage {
            for size in [16, 48, 128] {
                let resized = NSImage(size: NSSize(width: size, height: size))
                resized.lockFocus()
                appIcon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                resized.unlockFocus()
                if let tiff = resized.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("icon\(size).png"))
                }
            }
        }

        let readme = """
        LocalTranslate 浏览器助手

        用法（Chrome / Edge / Brave / Arc）：
        1. 打开 chrome://extensions （Edge 是 edge://extensions）
        2. 右上角打开「开发者模式」
        3. 点「加载已解压的扩展程序」，选中这个文件夹：
           \(dir.path)
        4. 在任意网页选中文字，右侧会出现蓝色「译」按钮，点一下就地显示译文。

        注意：
        · 需要 LocalTranslate 正在运行（菜单栏有图标）。
        · 翻译走本机 127.0.0.1:\(port)，不经过任何第三方服务器。
        · Safari 需要 Xcode 打包签名，暂不支持。
        """
        try? Data(readme.utf8).write(to: dir.appendingPathComponent("安装说明.txt"))
        return .success(dir)
    }
}
