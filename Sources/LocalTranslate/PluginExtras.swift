import Foundation
import CryptoKit
import JavaScriptCore

// MARK: - 1. .bobplugin ZIP 安装器

enum BobPluginInstaller {

    struct InstallResult {
        var pluginName: String
        var identifier: String
        var targetDirectory: URL
    }

    /// 将一个 .bobplugin 压缩包解压安装到插件目录，并读取 info.json 元数据
    static func install(archiveURL: URL) -> Result<InstallResult, PluginRuntime.PluginError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            return .failure(PluginRuntime.PluginError(message: "找不到插件文件：\(archiveURL.lastPathComponent)"))
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("lt-unpack-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 使用系统自带 unzip 解压 .bobplugin
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", archiveURL.path, "-d", tmp.path]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failure(PluginRuntime.PluginError(message: "解压启动失败：\(error.localizedDescription)"))
        }

        guard proc.terminationStatus == 0 else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(PluginRuntime.PluginError(message: "解压 .bobplugin 失败：\(errText)"))
        }

        // 查找根目录或唯一子目录里的 main.js 与 info.json
        var sourceDir = tmp
        if !fm.fileExists(atPath: tmp.appendingPathComponent("main.js").path) {
            if let children = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
                for child in children where !child.lastPathComponent.hasPrefix("__MACOSX") {
                    if fm.fileExists(atPath: child.appendingPathComponent("main.js").path) {
                        sourceDir = child
                        break
                    }
                }
            }
        }

        guard fm.fileExists(atPath: sourceDir.appendingPathComponent("main.js").path) else {
            return .failure(PluginRuntime.PluginError(message: "无效的 Bob 插件包：缺少 main.js"))
        }

        var identifier = archiveURL.deletingPathExtension().lastPathComponent
        var pluginName = identifier
        let infoURL = sourceDir.appendingPathComponent("info.json")
        if let data = try? Data(contentsOf: infoURL),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = info["identifier"] as? String, !id.isEmpty { identifier = id }
            if let name = info["name"] as? String, !name.isEmpty { pluginName = name }
        }

        // 目标目录名称（清理非法字符）
        let safeFolderName = identifier.replacingOccurrences(of: "/", with: "_")
        PluginRuntime.ensureDirectory()
        let destDir = PluginRuntime.directory.appendingPathComponent(safeFolderName, isDirectory: true)
        try? fm.removeItem(at: destDir)

        do {
            try fm.copyItem(at: sourceDir, to: destDir)
            return .success(InstallResult(pluginName: pluginName, identifier: safeFolderName, targetDirectory: destDir))
        } catch {
            return .failure(PluginRuntime.PluginError(message: "写入插件目录失败：\(error.localizedDescription)"))
        }
    }
}

// MARK: - 2. 内置 $util 与 crypto-js 兼容层（JS 源码注入 + 原生 CryptoKit 加速）

enum PluginBuiltins {

    /// 官方文档原版 $util 模块 JS 实现
    static let utilModuleSource = """
    var __tagMap = new Map([
        ['[object String]', 'string'],
        ['[object Number]', 'number'],
        ['[object Boolean]', 'boolean'],
        ['[object Symbol]', 'symbol'],
        ['[object Function]', 'function'],
        ['[object Array]', 'array'],
        ['[object Date]', 'date'],
        ['[object Set]', 'set'],
        ['[object Map]', 'map'],
        ['[object WeakSet]', 'weakset'],
        ['[object WeakMap]', 'weakmap'],
        ['[object RegExp]', 'regexp'],
        ['[object Error]', 'error']
    ]);
    function type(x) {
        if (x === undefined) return 'undefined';
        if (x === null) return 'null';
        var tv = typeof x;
        if (tv !== 'object') return tv;
        var tagVal = Object.prototype.toString.call(x);
        return __tagMap.get(tagVal) || 'object';
    }
    function tag(x) {
        if (x === undefined) return '[object Undefined]';
        if (x === null) return '[object Null]';
        return Object.prototype.toString.call(x);
    }
    function desc(x) {
        try {
            var tv = type(x);
            if (tv === 'object' || tv === 'array') return JSON.stringify(x, null, 4);
            if (tv === 'map' || tv === 'set') return JSON.stringify(Array.from(x), null, 4);
            if (tv === 'symbol') return x.toString();
            return '' + x;
        } catch (e) { return 'Desc Error: ' + e; }
    }
    function detail(x) { return '[type]: ' + type(x) + ',\\n[tag]: ' + tag(x) + ',\\n[desc]: ' + desc(x); }
    function props(obj) {
        var r = [];
        for (; obj != null; obj = Object.getPrototypeOf(obj)) {
            var names = Object.getOwnPropertyNames(obj);
            for (var i = 0; i < names.length; i++) if (r.indexOf(names[i]) === -1) r.push(names[i]);
        }
        return r;
    }
    function propsFiltered(obj) {
        var skip = ["toString","toLocaleString","valueOf","hasOwnProperty","propertyIsEnumerable","isPrototypeOf","__defineGetter__","__defineSetter__","__lookupGetter__","__lookupSetter__","__proto__","constructor"];
        return props(obj).filter(function(k) { return skip.indexOf(k) === -1; });
    }
    function isNil(x) { return x === undefined || x === null; }
    function get(obj, path, defaultValue) {
        if (isNil(obj) || typeof obj !== 'object') return defaultValue;
        var arr = type(path) === 'string' ? [path] : (type(path) === 'array' ? path : null);
        if (!arr) return defaultValue;
        var cur = obj;
        for (var i = 0; i < arr.length; i++) {
            if (typeof cur !== 'object' || typeof arr[i] !== 'string') return defaultValue;
            cur = cur[arr[i]];
            if (isNil(cur)) return defaultValue;
        }
        return cur;
    }
    module.exports = { type: type, tag: tag, desc: desc, detail: detail, props: props, propsFiltered: propsFiltered, isNil: isNil, get: get };
    """

    /// 将原生 CryptoKit 计算能力注册为 JS 原生桥，再包装成标准 CryptoJS 对象接口
    static func registerCryptoBridge(in ctx: JSContext) {
        let md5Fn: @convention(block) (String) -> String = { str in
            let digest = Insecure.MD5.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let sha1Fn: @convention(block) (String) -> String = { str in
            let digest = Insecure.SHA1.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let sha256Fn: @convention(block) (String) -> String = { str in
            let digest = SHA256.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let hmacSha1Fn: @convention(block) (String, String) -> String = { msg, key in
            let symKey = SymmetricKey(data: Data(key.utf8))
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(msg.utf8), using: symKey)
            return mac.map { String(format: "%02x", $0) }.joined()
        }
        let hmacSha256Fn: @convention(block) (String, String) -> String = { msg, key in
            let symKey = SymmetricKey(data: Data(key.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: symKey)
            return mac.map { String(format: "%02x", $0) }.joined()
        }
        let hexToBase64Fn: @convention(block) (String) -> String = { hex in
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let nextIdx = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                if let byte = UInt8(hex[idx..<nextIdx], radix: 16) {
                    bytes.append(byte)
                }
                idx = nextIdx
            }
            return Data(bytes).base64EncodedString()
        }

        let bridge = JSValue(newObjectIn: ctx)!
        bridge.setValue(unsafeBitCast(md5Fn, to: AnyObject.self), forProperty: "md5")
        bridge.setValue(unsafeBitCast(sha1Fn, to: AnyObject.self), forProperty: "sha1")
        bridge.setValue(unsafeBitCast(sha256Fn, to: AnyObject.self), forProperty: "sha256")
        bridge.setValue(unsafeBitCast(hmacSha1Fn, to: AnyObject.self), forProperty: "hmacSha1")
        bridge.setValue(unsafeBitCast(hmacSha256Fn, to: AnyObject.self), forProperty: "hmacSha256")
        bridge.setValue(unsafeBitCast(hexToBase64Fn, to: AnyObject.self), forProperty: "hexToBase64")
        ctx.setObject(bridge, forKeyedSubscript: "__ltCryptoBridge" as NSString)
    }

    static let cryptoJSModuleSource = """
    function __WordArray(hexStr) {
        this._hex = hexStr || "";
    }
    __WordArray.prototype.toString = function(encoder) {
        if (encoder === CryptoJS.enc.Base64) {
            return __ltCryptoBridge.hexToBase64(this._hex);
        }
        return this._hex;
    };
    var CryptoJS = {
        MD5: function(s) { return new __WordArray(__ltCryptoBridge.md5("" + s)); },
        SHA1: function(s) { return new __WordArray(__ltCryptoBridge.sha1("" + s)); },
        SHA256: function(s) { return new __WordArray(__ltCryptoBridge.sha256("" + s)); },
        HmacSHA1: function(m, k) { return new __WordArray(__ltCryptoBridge.hmacSha1("" + m, "" + k)); },
        HmacSHA256: function(m, k) { return new __WordArray(__ltCryptoBridge.hmacSha256("" + m, "" + k)); },
        enc: {
            Hex: {
                stringify: function(wa) { return wa._hex || ("" + wa); }
            },
            Base64: {
                stringify: function(wa) {
                    if (wa && wa._hex !== undefined) return __ltCryptoBridge.hexToBase64(wa._hex);
                    return $data.fromUTF8("" + wa).toBase64();
                },
                parse: function(b64) {
                    var text = $data.fromBase64(b64).toUTF8();
                    return { _utf8: text, toString: function() { return this._utf8; } };
                }
            },
            Utf8: {
                parse: function(s) { return "" + s; },
                stringify: function(wa) { return wa._utf8 || ("" + wa); }
            }
        }
    };
    module.exports = CryptoJS;
    """
}

// MARK: - 3. $file 插件沙盒文件系统

enum PluginFileSystem {

    static var sandboxRootOverride: URL?

    static func sandboxDirectory(for pluginID: String) -> URL {
        let base = sandboxRootOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LocalTranslate/PluginSandbox", isDirectory: true)
        let dir = base.appendingPathComponent(pluginID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func resolve(virtualPath: String, pluginDir: URL, sandboxDir: URL) -> (url: URL, writable: Bool)? {
        // 阻止路径穿越
        if virtualPath.contains("..") { return nil }
        if virtualPath.hasPrefix("$sandbox/") {
            let rel = String(virtualPath.dropFirst("$sandbox/".count))
            return (sandboxDir.appendingPathComponent(rel), true)
        } else if virtualPath == "$sandbox" {
            return (sandboxDir, true)
        } else if virtualPath.hasPrefix("/") {
            let rel = String(virtualPath.dropFirst(1))
            return (rel.isEmpty ? pluginDir : pluginDir.appendingPathComponent(rel), false)
        }
        return nil
    }

    static func inject(in ctx: JSContext, pluginDir: URL, pluginID: String,
                       store: PluginHostKit.DataStore?? = nil) {
        let sandboxDir = sandboxDirectory(for: pluginID)
        let fm = FileManager.default

        let fileObj = JSValue(newObjectIn: ctx)!

        // Bob 的 $file.read 返回 $data；很多插件直接在上面调 .toUTF8()。
        // 我们之前返回字符串，Cambridge 这类插件就会报 "toUTF8 is not a function"。
        let readFn: @convention(block) (String) -> JSValue? = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  let data = try? Data(contentsOf: resolved.url),
                  let store = store ?? PluginHostKit.lastStore else { return nil }
            let handle = store.create(data)
            return ctx.evaluateScript("__wrapData")?.call(withArguments: [handle])
        }

        let writeFn: @convention(block) (JSValue) -> Bool = { opts in
            guard opts.isObject,
                  let path = opts.objectForKeyedSubscript("path")?.toString(),
                  let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  resolved.writable else { return false }
            let payload = opts.objectForKeyedSubscript("data")
            var bytes: Data?
            if let payload, let handle = ctx.evaluateScript("__dataHandle")?.call(withArguments: [payload])?.toNumber() {
                bytes = (store ?? PluginHostKit.lastStore)?.copy(handle.intValue)
            }
            if bytes == nil, let text = payload?.toString() { bytes = Data(text.utf8) }
            guard let bytes else { return false }
            try? fm.createDirectory(at: resolved.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? bytes.write(to: resolved.url, options: .atomic)) != nil
        }

        let deleteFn: @convention(block) (String) -> Bool = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  resolved.writable else { return false }
            return (try? fm.removeItem(at: resolved.url)) != nil
        }

        let listFn: @convention(block) (String) -> [String] = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir) else { return [] }
            return (try? fm.contentsOfDirectory(atPath: resolved.url.path)) ?? []
        }

        let existsFn: @convention(block) (String) -> Bool = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir) else { return false }
            return fm.fileExists(atPath: resolved.url.path)
        }

        let isDirFn: @convention(block) (String) -> Bool = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir) else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: resolved.url.path, isDirectory: &isDir) && isDir.boolValue
        }

        let mkdirFn: @convention(block) (String) -> Bool = { path in
            guard let resolved = resolve(virtualPath: path, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  resolved.writable else { return false }
            return (try? fm.createDirectory(at: resolved.url, withIntermediateDirectories: true)) != nil
        }

        let copyFn: @convention(block) (JSValue) -> Bool = { opts in
            guard opts.isObject,
                  let src = opts.objectForKeyedSubscript("src")?.toString(),
                  let dst = opts.objectForKeyedSubscript("dst")?.toString(),
                  let rSrc = resolve(virtualPath: src, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  let rDst = resolve(virtualPath: dst, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  rDst.writable else { return false }
            try? fm.createDirectory(at: rDst.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: rDst.url)
            return (try? fm.copyItem(at: rSrc.url, to: rDst.url)) != nil
        }

        let moveFn: @convention(block) (JSValue) -> Bool = { opts in
            guard opts.isObject,
                  let src = opts.objectForKeyedSubscript("src")?.toString(),
                  let dst = opts.objectForKeyedSubscript("dst")?.toString(),
                  let rSrc = resolve(virtualPath: src, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  let rDst = resolve(virtualPath: dst, pluginDir: pluginDir, sandboxDir: sandboxDir),
                  rSrc.writable, rDst.writable else { return false }
            try? fm.createDirectory(at: rDst.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: rDst.url)
            return (try? fm.moveItem(at: rSrc.url, to: rDst.url)) != nil
        }

        fileObj.setValue(unsafeBitCast(readFn, to: AnyObject.self), forProperty: "read")
        fileObj.setValue(unsafeBitCast(writeFn, to: AnyObject.self), forProperty: "write")
        fileObj.setValue(unsafeBitCast(deleteFn, to: AnyObject.self), forProperty: "delete")
        fileObj.setValue(unsafeBitCast(listFn, to: AnyObject.self), forProperty: "list")
        fileObj.setValue(unsafeBitCast(existsFn, to: AnyObject.self), forProperty: "exists")
        fileObj.setValue(unsafeBitCast(isDirFn, to: AnyObject.self), forProperty: "isDirectory")
        fileObj.setValue(unsafeBitCast(mkdirFn, to: AnyObject.self), forProperty: "mkdir")
        fileObj.setValue(unsafeBitCast(copyFn, to: AnyObject.self), forProperty: "copy")
        fileObj.setValue(unsafeBitCast(moveFn, to: AnyObject.self), forProperty: "move")
        ctx.setObject(fileObj, forKeyedSubscript: "$file" as NSString)
    }
}

// MARK: - 4. $timer 定时器管理

final class PluginTimerManager {
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextID = 1
    private let lock = NSLock()

    func inject(in ctx: JSContext) {
        let timerObj = JSValue(newObjectIn: ctx)!

        let scheduleFn: @convention(block) (JSValue) -> Int = { [weak self] opts in
            guard let self, opts.isObject else { return 0 }
            let interval = max(0.01, opts.objectForKeyedSubscript("interval")?.toDouble() ?? 1.0)
            let repeats = opts.objectForKeyedSubscript("repeats")?.toBool() ?? false
            guard let handler = opts.objectForKeyedSubscript("handler"), !handler.isUndefined else { return 0 }

            // 必须用强引用的 JSValue：JSManagedValue 依赖 JS 侧可达性，
            // 而这个回调只被 Swift 持有，GC 一跑就变 nil，定时器会无声失效。
            let retained = handler

            self.lock.lock()
            let id = self.nextID
            self.nextID += 1
            self.lock.unlock()

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
            if repeats {
                timer.schedule(deadline: .now() + interval, repeating: interval)
            } else {
                timer.schedule(deadline: .now() + interval)
            }
            timer.setEventHandler { [weak self] in
                retained.call(withArguments: [])
                if !repeats {
                    self?.invalidate(id: id)
                }
            }
            self.lock.lock()
            self.timers[id] = timer
            self.lock.unlock()
            timer.resume()
            return id
        }

        let invalidateFn: @convention(block) (Int) -> Void = { [weak self] id in
            self?.invalidate(id: id)
        }

        timerObj.setValue(unsafeBitCast(scheduleFn, to: AnyObject.self), forProperty: "schedule")
        timerObj.setValue(unsafeBitCast(invalidateFn, to: AnyObject.self), forProperty: "invalidate")
        ctx.setObject(timerObj, forKeyedSubscript: "$timer" as NSString)
    }

    func invalidate(id: Int) {
        lock.lock()
        let timer = timers.removeValue(forKey: id)
        lock.unlock()
        timer?.cancel()
    }

    func invalidateAll() {
        lock.lock()
        let all = timers.values
        timers.removeAll()
        lock.unlock()
        for t in all { t.cancel() }
    }

    deinit {
        invalidateAll()
    }
}

// MARK: - 5. $websocket WebSocket 客户端

enum PluginWebSocketBridge {

    static func inject(in ctx: JSContext, store: PluginHostKit.DataStore) {
        let wsFactory = JSValue(newObjectIn: ctx)!

        let newFn: @convention(block) (JSValue) -> JSValue? = { opts in
            guard opts.isObject,
                  let urlStr = opts.objectForKeyedSubscript("url")?.toString(),
                  let url = URL(string: urlStr) else {
                return nil
            }

            var req = URLRequest(url: url)
            let timeout = opts.objectForKeyedSubscript("timeoutInterval")?.toDouble() ?? 60
            req.timeoutInterval = timeout > 0 ? timeout : 60
            if let headerDict = opts.objectForKeyedSubscript("header")?.toDictionary() as? [String: Any] {
                for (k, v) in headerDict { req.setValue("\(v)", forHTTPHeaderField: k) }
            }

            let session = NetworkSession.shared
            let task = session.webSocketTask(with: req)
            let jsSock = JSValue(newObjectIn: ctx)!
            jsSock.setValue(0, forProperty: "readyState") // connecting

            // 这些回调只被 Swift 侧持有；用 JSManagedValue 会在 JSC 回收后变 nil，
            // 表现就是"收到几帧音频以后，turn.end 再也喂不进插件"。
            var onOpen: JSValue?
            var onClose: JSValue?
            var onError: JSValue?
            var onRecvStr: JSValue?
            var onRecvData: JSValue?

            func receiveLoop() {
                task.receive { result in
                    // 关键：**立刻**在回调线程上续上接收，别等主线程。
                    // 以前把 receiveLoop() 放在 DispatchQueue.main.async 里，主线程一忙
                    // （插件里的同步循环、RunLoop 切换）就会出现"没有挂着 receive"的空窗，
                    // 服务端在这期间发来的 turn.end 就永远收不到了——表现正是"收到音频却永远不结束"。
                    switch result {
                    case .success(let message):
                        switch message {
                        case .string(let s):
                            Debug.log("[ws text \(s.count)] \(s.prefix(80))")
                            DispatchQueue.main.async {
                                onRecvStr?.call(withArguments: [jsSock, s])
                            }
                        case .data(let d):
                            DispatchQueue.main.async {
                                guard let wrapped = ctx.evaluateScript("__wrapData")?
                                    .call(withArguments: [store.create(d)]) else { return }
                                onRecvData?.call(withArguments: [jsSock, wrapped])
                            }
                        @unknown default: break
                        }
                        receiveLoop()
                    case .failure(let err):
                        Debug.log("[ws fail] \(err.localizedDescription)")
                        DispatchQueue.main.async {
                            jsSock.setValue(3, forProperty: "readyState")
                            let errObj = JSValue(newObjectIn: ctx)!
                            errObj.setValue(err.localizedDescription, forProperty: "message")
                            onError?.call(withArguments: [jsSock, errObj])
                        }
                    }
                }
            }

            let openFn: @convention(block) () -> Void = {
                DispatchQueue.main.async {
                    Debug.log("[ws open] resume")
                    task.resume()
                    jsSock.setValue(1, forProperty: "readyState")
                    onOpen?.call(withArguments: [jsSock])
                    receiveLoop()
                }
            }

            let closeFn: @convention(block) (JSValue?) -> Void = { opts in
                jsSock.setValue(2, forProperty: "readyState")
                let codeNum = opts?.objectForKeyedSubscript("code")?.toInt32() ?? 1000
                let code = URLSessionWebSocketTask.CloseCode(rawValue: Int(codeNum)) ?? .normalClosure
                task.cancel(with: code, reason: nil)
                jsSock.setValue(3, forProperty: "readyState")
                DispatchQueue.main.async {
                    onClose?.call(withArguments: [jsSock, code.rawValue, ""])
                }
            }

            let sendStrFn: @convention(block) (String) -> Void = { str in
                task.send(.string(str)) { _ in }
            }

            let sendDataFn: @convention(block) (JSValue) -> Void = { payload in
                var bytes = Data()
                if let handle = ctx.evaluateScript("__dataHandle")?.call(withArguments: [payload])?.toNumber() {
                    bytes = store.copy(handle.intValue) ?? Data()
                } else if let text = payload.toString() {
                    bytes = Data(text.utf8)
                }
                task.send(.data(bytes)) { _ in }
            }

            let listenOpenFn: @convention(block) (JSValue) -> Void = { fn in
                onOpen = fn
            }
            let listenCloseFn: @convention(block) (JSValue) -> Void = { fn in
                onClose = fn
            }
            let listenErrorFn: @convention(block) (JSValue) -> Void = { fn in
                onError = fn
            }
            let listenRecvStrFn: @convention(block) (JSValue) -> Void = { fn in
                onRecvStr = fn
            }
            let listenRecvDataFn: @convention(block) (JSValue) -> Void = { fn in
                onRecvData = fn
            }

            jsSock.setValue(unsafeBitCast(openFn, to: AnyObject.self), forProperty: "open")
            jsSock.setValue(unsafeBitCast(closeFn, to: AnyObject.self), forProperty: "close")
            jsSock.setValue(unsafeBitCast(sendStrFn, to: AnyObject.self), forProperty: "sendString")
            jsSock.setValue(unsafeBitCast(sendDataFn, to: AnyObject.self), forProperty: "sendData")
            jsSock.setValue(unsafeBitCast(listenOpenFn, to: AnyObject.self), forProperty: "listenOpen")
            jsSock.setValue(unsafeBitCast(listenCloseFn, to: AnyObject.self), forProperty: "listenClose")
            jsSock.setValue(unsafeBitCast(listenErrorFn, to: AnyObject.self), forProperty: "listenError")
            jsSock.setValue(unsafeBitCast(listenRecvStrFn, to: AnyObject.self), forProperty: "listenReceiveString")
            jsSock.setValue(unsafeBitCast(listenRecvDataFn, to: AnyObject.self), forProperty: "listenReceiveData")

            return jsSock
        }

        wsFactory.setValue(unsafeBitCast(newFn, to: AnyObject.self), forProperty: "new")
        ctx.setObject(wsFactory, forKeyedSubscript: "$websocket" as NSString)
    }
}
