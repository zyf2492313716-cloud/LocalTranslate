import Foundation
import JavaScriptCore

/// 插件宿主运行时（对齐 Bob 官方 `$data` / `$http` / `$websocket` 契约）。
///
/// 设计取舍：真正的二进制与网络都由 Swift 做，JS 侧只保留一层很薄的壳。
/// 好处是 `$data` 的字节可以原样传给 URLSession（OCR 传图、TTS 收音频都靠这个），
/// 而 Promise 语义交给 JS 自己的 `Promise`，不需要在 Swift 里手搓 thenable。
enum PluginHostKit {

    // MARK: - $data

    /// `$data` 句柄表：JS 侧只拿一个整数，真正的字节在这边。
    final class DataStore {
        private var storage: [Int: NSMutableData] = [:]
        private var next = 1
        private let lock = NSLock()

        func create(_ data: Data) -> Int {
            lock.lock(); defer { lock.unlock() }
            let handle = next
            next += 1
            storage[handle] = NSMutableData(data: data)
            return handle
        }

        func data(_ handle: Int) -> NSMutableData? {
            lock.lock(); defer { lock.unlock() }
            return storage[handle]
        }

        func copy(_ handle: Int) -> Data? {
            guard let value = data(handle) else { return nil }
            return (value.copy() as? NSData).map { $0 as Data }
        }

        func remove(_ handle: Int) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: handle)
        }
    }

    /// `$data` 的 JS 实现（挂在全局，名字就叫 `$data`）
    static let dataShim = """
    (function(g) {
      function JSData(handle) { this.__h = handle; }
      Object.defineProperty(JSData.prototype, 'length', {
        get: function() { return __dataCall(this.__h, 'length', []); }
      });
      JSData.prototype.toUTF8 = function() { return __dataCall(this.__h, 'toUTF8', []); };
      JSData.prototype.toHex = function(upper) { return __dataCall(this.__h, 'toHex', [!!upper]); };
      JSData.prototype.toBase64 = function() { return __dataCall(this.__h, 'toBase64', []); };
      JSData.prototype.toByteArray = function() { return __dataCall(this.__h, 'toByteArray', []); };
      JSData.prototype.readUInt8 = function(i) { return __dataCall(this.__h, 'readUInt8', [i]); };
      JSData.prototype.writeUInt8 = function(v, i) { return __dataCall(this.__h, 'writeUInt8', [v, i]); };
      JSData.prototype.subData = function(s, e) { return __wrapData(__dataCall(this.__h, 'subData', [s, e])); };
      JSData.prototype.appendData = function(d) { return __dataCall(this.__h, 'appendData', [d && d.__h]); };
      g.__JSData = JSData;
      g.__wrapData = function(handle) { return (typeof handle === 'number' && handle > 0) ? new JSData(handle) : undefined; };
      g.__isData = function(o) { return o instanceof JSData; };
      g.__dataHandle = function(o) { return (o instanceof JSData) ? o.__h : undefined; };
      g.$data = {
        fromUTF8: function(s) { return __wrapData(__dataCreate('utf8', String(s))); },
        fromBase64: function(s) { return __wrapData(__dataCreate('base64', String(s))); },
        fromHex: function(s) { return __wrapData(__dataCreate('hex', String(s))); },
        fromByteArray: function(a) { return __wrapData(__dataCreate('bytes', a)); },
        fromData: function(d) { return __wrapData(__dataCreate('copy', d && d.__h)); },
        isData: function(o) { return __isData(o); }
      };
    })(this);
    """

    // MARK: - $http

    /// `$http` 的 JS 壳：有 handler 走回调，没有 handler 返回 Promise（官方契约）。
    static let httpShim = """
    (function(g) {
      function normalize(o) {
        var out = {};
        for (var k in o) { if (k !== 'handler' && k !== 'streamHandler') out[k] = o[k]; }
        if (o.body && __isData(o.body)) { out.__bodyHandle = __dataHandle(o.body); delete out.body; }
        if (o.files) {
          out.files = o.files.map(function(f) {
            return { name: f.name, filename: f.filename, contentType: f['content-type'],
                     handle: f.data ? __dataHandle(f.data) : undefined };
          });
        }
        if (typeof o.streamHandler === 'function') { out.__stream = o.streamHandler; }
        return out;
      }
      function send(o, cb) {
        try { __httpSend(normalize(o), cb); }
        catch (e) { cb({ error: { message: String(e), debugMessage: String(e) } }); }
      }
      function request(o) {
        var handler = o && o.handler;
        if (typeof o.streamHandler === 'function') {
          var streamCb = o.streamHandler;
          var wrapped = {};
          for (var k in o) wrapped[k] = o[k];
          wrapped.streamHandler = streamCb;
          if (typeof handler === 'function') { send(wrapped, handler); return; }
          return new Promise(function(resolve) { send(wrapped, function(r) { resolve(r); }); });
        }
        if (typeof handler === 'function') { send(o, handler); return; }
        return new Promise(function(resolve) { send(o, function(r) { resolve(r); }); });
      }
      g.$http = {
        request: request,
        get: function(o) { var c = {}; for (var k in o) c[k] = o[k]; c.method = 'GET'; return request(c); },
        post: function(o) { var c = {}; for (var k in o) c[k] = o[k]; c.method = 'POST'; return request(c); },
        streamRequest: function(o) { var c = {}; for (var k in o) c[k] = o[k]; return request(c); }
      };
    })(this);
    """

    // MARK: - $data 桥

    static func installDataBridge(in ctx: JSContext, store: DataStore) {
        let create: @convention(block) (String, JSValue) -> Int = { kind, payload in
            switch kind {
            case "utf8":
                return store.create(Data((payload.toString() ?? "").utf8))
            case "base64":
                let raw = payload.toString() ?? ""
                return store.create(Data(base64Encoded: raw, options: .ignoreUnknownCharacters) ?? Data())
            case "hex":
                return store.create(Data(hexString: payload.toString() ?? "") ?? Data())
            case "bytes":
                var bytes: [UInt8] = []
                if let arr = payload.toArray() as? [NSNumber] {
                    bytes = arr.map { UInt8(truncating: $0) }
                }
                return store.create(Data(bytes))
            case "copy":
                guard let handle = payload.toNumber()?.intValue, let copy = store.copy(handle) else { return 0 }
                return store.create(copy)
            default:
                return 0
            }
        }
        ctx.setObject(unsafeBitCast(create, to: AnyObject.self), forKeyedSubscript: "__dataCreate" as NSString)

        let call: @convention(block) (Int, String, JSValue) -> Any? = { handle, method, args in
            guard let buffer = store.data(handle) else { return nil }
            let array = (args.toArray() as? [Any]) ?? []
            func intArg(_ index: Int) -> Int { (array.count > index ? (array[index] as? NSNumber)?.intValue : nil) ?? 0 }
            switch method {
            case "length": return buffer.length
            case "toUTF8": return String(data: buffer as Data, encoding: .utf8)
            case "toHex":
                let upper = (array.first as? Bool) ?? false
                return (buffer as Data).map { String(format: upper ? "%02X" : "%02x", $0) }.joined()
            case "toBase64": return (buffer as Data).base64EncodedString()
            case "toByteArray": return (buffer as Data).map { Int($0) }
            case "readUInt8":
                let index = intArg(0)
                guard index >= 0, index < buffer.length else { return 0 }
                return Int(buffer[index])
            case "writeUInt8":
                let value = intArg(0), index = intArg(1)
                guard index >= 0, index < buffer.length else { return nil }
                var byte = UInt8(clamping: value)
                buffer.replaceBytes(in: NSRange(location: index, length: 1), withBytes: &byte)
                return nil
            case "subData":
                let start = intArg(0), end = intArg(1)
                guard start >= 0, end > start, end <= buffer.length else { return nil }
                return store.create((buffer as Data).subdata(in: start..<end))
            case "appendData":
                let other = intArg(0)
                if let extra = store.data(other) { buffer.append(extra as Data) }
                return nil
            default: return nil
            }
        }
        ctx.setObject(unsafeBitCast(call, to: AnyObject.self), forKeyedSubscript: "__dataCall" as NSString)
        ctx.evaluateScript(dataShim)
    }

    // MARK: - $http 传输

    /// 解析 content-type 决定 body 怎么编码（对齐官方规则）
    static func encodeBody(options: JSValue, ctx: JSContext) -> (Data?, String?) {
        // $data 原样发送
        if let handle = options.objectForKeyedSubscript("__bodyHandle"), !handle.isUndefined,
           let number = handle.toNumber() {
            return (PluginHostKit.lastStore?.copy(number.intValue), nil)
        }
        guard let body = options.objectForKeyedSubscript("body"), !body.isUndefined, !body.isNull else {
            return (nil, nil)
        }
        let header = options.objectForKeyedSubscript("header")
        let contentType = (header?.objectForKeyedSubscript("content-type")?.toString()
                           ?? header?.objectForKeyedSubscript("Content-Type")?.toString() ?? "")
        let method = (options.objectForKeyedSubscript("method")?.toString() ?? "GET").uppercased()

        if contentType.lowercased().contains("application/json") {
            if let data = try? JSONSerialization.data(withJSONObject: body.toDictionary() as Any) {
                return (data, contentType)
            }
        }
        if contentType.lowercased().contains("form-urlencoded") || contentType.isEmpty {
            if let dict = body.toDictionary() as? [String: Any] {
                var parts: [String] = []
                for (key, value) in dict {
                    let v = "\(value)"
                    let encoded = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
                    parts.append("\(key)=\(encoded)")
                }
                let joined = parts.joined(separator: "&")
                if method == "GET" || method == "HEAD" || method == "DELETE" {
                    return (nil, joined)   // 走 query string
                }
                return (Data(joined.utf8), contentType.isEmpty ? "application/x-www-form-urlencoded" : contentType)
            }
        }
        if let string = body.toString(), !string.isEmpty, body.isString {
            return (Data(string.utf8), contentType.isEmpty ? "text/plain" : contentType)
        }
        if let data = try? JSONSerialization.data(withJSONObject: body.toDictionary() as Any) {
            return (data, contentType.isEmpty ? "application/json" : contentType)
        }
        return (nil, nil)
    }

    /// 当前正在使用的句柄表（同一时刻只有一个插件上下文在跑网络）
    nonisolated(unsafe) static var lastStore: DataStore?

    static func installHTTP(in ctx: JSContext, store: DataStore) {
        lastStore = store
        let send: @convention(block) (JSValue, JSValue) -> Void = { options, handler in
            performHTTP(options: options, ctx: ctx, handler: handler)
        }
        ctx.setObject(unsafeBitCast(send, to: AnyObject.self), forKeyedSubscript: "__httpSend" as NSString)
        ctx.evaluateScript(httpShim)
    }

    private static func performHTTP(options: JSValue, ctx: JSContext, handler: JSValue) {
        let method = (options.objectForKeyedSubscript("method")?.toString() ?? "GET").uppercased()
        guard var urlString = options.objectForKeyedSubscript("url")?.toString(),
              var url = URL(string: urlString) else {
            respond(handler: handler, ctx: ctx, errorMessage: "无效的 URL")
            return
        }
        let timeout = options.objectForKeyedSubscript("timeout")?.toDouble() ?? 60

        let (bodyData, extra) = encodeBody(options: options, ctx: ctx)
        if let extra, method == "GET", !extra.isEmpty {
            let separator = urlString.contains("?") ? "&" : "?"
            urlString += separator + extra
            if let rebuilt = URL(string: urlString) { url = rebuilt }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let header = options.objectForKeyedSubscript("header")?.toDictionary() as? [String: Any] {
            for (key, value) in header { request.setValue("\(value)", forHTTPHeaderField: key) }
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil, bodyData != nil {
            request.setValue(extra ?? "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let bodyData { request.httpBody = bodyData }

        // streamHandler：边收边喂
        let streamHandler = options.objectForKeyedSubscript("__stream")
        let hasStream = (streamHandler?.isUndefined == false) && streamHandler != nil

        if hasStream, let streamHandler {
            respondStreaming(request: request, ctx: ctx, streamHandler: streamHandler, handler: handler)
            return
        }

        NetworkSession.shared.dataTask(with: request) { data, response, error in
            respond(handler: handler, ctx: ctx, data: data, response: response as? HTTPURLResponse, error: error)
        }.resume()
    }

    private static func respondStreaming(request: URLRequest, ctx: JSContext,
                                         streamHandler: JSValue, handler: JSValue) {
        let delegate = StreamDelegate(ctx: ctx, streamHandler: streamHandler) { collected, response, error in
            respond(handler: handler, ctx: ctx, data: collected, response: response, error: error)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: request).resume()
    }

    private static func respond(handler: JSValue, ctx: JSContext,
                                data: Data? = nil, response: HTTPURLResponse? = nil,
                                error: Error? = nil, errorMessage: String? = nil) {
        let payload = JSValue(newObjectIn: ctx)!
        if let data {
            // data 优先 JSON，其次 UTF-8，最后原始 $data
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                payload.setValue(obj, forProperty: "data")
            } else if let string = String(data: data, encoding: .utf8) {
                payload.setValue(string, forProperty: "data")
            } else if let store = lastStore {
                payload.setValue(JSValue(object: store.create(data), in: ctx), forProperty: "data")
            }
            if let store = lastStore {
                payload.setValue(ctx.evaluateScript("__wrapData")?.call(withArguments: [store.create(data)]),
                                 forProperty: "rawData")
            }
        }
        // 永远给一个 response 对象：插件普遍会直接读 result.response.statusCode，
        // 流式/连接失败时这里为空就会把插件整个搞崩（ChatGPT free 就是这么挂的）。
        if let response {
            let info = JSValue(newObjectIn: ctx)!
            info.setValue(response.statusCode, forProperty: "statusCode")
            info.setValue(response.url?.absoluteString ?? "", forProperty: "url")
            info.setValue(response.mimeType ?? "", forProperty: "MIMEType")
            info.setValue(response.expectedContentLength, forProperty: "expectedContentLength")
            info.setValue(response.textEncodingName ?? "", forProperty: "textEncodingName")
            info.setValue(response.suggestedFilename ?? "", forProperty: "suggestedFilename")
            info.setValue(response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                acc["\(pair.key)"] = "\(pair.value)"
            }, forProperty: "header")
            payload.setValue(info, forProperty: "response")
        } else {
            let info = JSValue(newObjectIn: ctx)!
            info.setValue(0, forProperty: "statusCode")
            info.setValue("", forProperty: "url")
            info.setValue([:], forProperty: "header")
            payload.setValue(info, forProperty: "response")
        }
        if let error {
            let info = JSValue(newObjectIn: ctx)!
            info.setValue(error.localizedDescription, forProperty: "message")
            info.setValue((error as NSError).domain + " " + String((error as NSError).code), forProperty: "debugMessage")
            payload.setValue(info, forProperty: "error")
        } else if let errorMessage {
            let info = JSValue(newObjectIn: ctx)!
            info.setValue(errorMessage, forProperty: "message")
            info.setValue(errorMessage, forProperty: "debugMessage")
            payload.setValue(info, forProperty: "error")
        }
        // 同样必须回主线程：插件上下文不是线程安全的
        DispatchQueue.main.async { handler.call(withArguments: [payload]) }
    }

    /// 流式请求的 delegate：把 text/rawData 逐个喂给插件
    private final class StreamDelegate: NSObject, URLSessionDataDelegate {
        let ctx: JSContext
        let streamHandler: JSValue
        let completion: (Data, HTTPURLResponse?, Error?) -> Void
        var buffer = Data()
        var response: HTTPURLResponse?
        var session: URLSession?

        init(ctx: JSContext, streamHandler: JSValue,
             completion: @escaping (Data, HTTPURLResponse?, Error?) -> Void) {
            self.ctx = ctx
            self.streamHandler = streamHandler
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffer.append(data)
            DispatchQueue.main.async { [ctx, streamHandler] in
                let payload = JSValue(newObjectIn: ctx)!
                payload.setValue(String(data: data, encoding: .utf8) ?? "", forProperty: "text")
                if let store = PluginHostKit.lastStore {
                    payload.setValue(ctx.evaluateScript("__wrapData")?.call(withArguments: [store.create(data)]),
                                     forProperty: "rawData")
                }
                streamHandler.call(withArguments: [payload])
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completion(buffer, response, error)
            session.finishTasksAndInvalidate()
        }
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
