# 架构说明

这份文档写给想看代码的人。按数据流从上到下讲：一次翻译/OCR 请求进来，经过哪些模块，最后怎么显示。

## 目录

- [一次翻译的完整链路](#一次翻译的完整链路)
- [多引擎并发与降级](#多引擎并发与降级)
- [OCR 管线](#ocr-管线)
- [词典链路](#词典链路)
- [Bob 插件运行时](#bob-插件运行时)
- [浏览器助手](#浏览器助手)
- [窗口与焦点策略](#窗口与焦点策略)
- [自测体系](#自测体系)

## 一次翻译的完整链路

```
全局快捷键（Carbon RegisterEventHotKey）
  → AppDelegate 分发
  → SelectionReader 读选中文字（AX API，失败退回模拟 ⌘C）
  → TranslateRunner.run(...)
      ├─ 为每个启用的服务建一张卡片
      ├─ Translator.translate(...) 并发请求
      └─ TranslationCard 流式渲染
```

关键点：

- **快捷键用 Carbon 注册**，不需要辅助功能权限；只有"读选中文字"需要。
- **选区读取有三级兜底**：AX `kAXSelectedText` → AX `kAXValue` 里取选区 → 模拟 `⌘C` 读剪贴板（读完还原剪贴板）。
- **UI 只在主线程动**。网络回调统一 `DispatchQueue.main.async`，包括插件 JS 回调和 WebSocket 帧。

## 多引擎并发与降级

`TranslateRunner` 对每个启用服务起一个 `Task`，各自独立更新自己的卡片。一家失败不影响其它家。

失败处理分三档：

1. **可重试错误**（429/503）：退避重试两次；
2. **限流/人机验证**：把这家写进 `ProviderCooldown`，冷却 10～15 分钟，冷却期内直接不建这张卡；
3. **Apple 缺语言包**：先查 `LanguageAvailability`，缺包就跳过这家，不弹系统下载框。

这样用户看到的永远是"其它家正常出译文"，而不是一屏红色报错。

## OCR 管线

```
ScreenSelectionWindow（非激活透明面板，全屏选区）
  → 截图（CGImage）
  → OcrEngine 分发：
      ├─ system: Vision VNRecognizeTextRequest（离线）
      ├─ llm: 多模态模型
      └─ 云服务: 各家 HTTP 接口
  → ScreenOCR.paragraphize（按行高/缩进聚类还原段落）
  → OCRWindow / 剪贴板 / 翻译卡片
```

`ScreenSelectionWindow` 有个坑：它是 `.nonactivatingPanel` + `.screenSaver` 层级，不能调用 `NSApp.activate`，否则会把用户正在看的窗口顶掉。选区绘制用 `bounds.fill` 而不是 `dirtyRect.fill`——后者在这个合成层级下不显示。

## 词典链路

```
DictionaryService.lookup(word)
  ├─ ECDictService        离线 SQLite/CSV，毫秒级
  ├─ AppleDictionaryService  DCSCopyTextDefinition，离线
  ├─ MojiDictionary       日语优先（含假名/罗马音/例句）
  ├─ YoudaoFreeTranslator.lookup  英美音标 + 词性 + 词形变化
  ├─ CambridgeDictionary  抓英汉页，正则抽音标/词性/释义
  └─ 大模型 JSON（需要配置对话模型）
```

前三级任何一级命中就直接返回，不会继续往下打网络请求。

## Bob 插件运行时

用 `JavaScriptCore` 实现 Bob 的插件协议：

- 入口按 CommonJS 包装（`module.exports` 和全局函数两种写法都吃）；
- 注入 `$http`（回调 + Promise + 二进制 body + stream）、`$data`（完整二进制对象）、`$file`（沙盒路径）、`$timer`、`$websocket`、`$option`、`$log`；
- `require()` 支持相对路径模块和内置 `crypto-js`；
- 插件回调（`completion`）转成 `Result`，主线程回灌。

两个容易踩的坑，代码里都有注释：

1. **`JSManagedValue` 会被 GC 回收**：插件回调只被 Swift 持有，必须用强引用 `JSValue`；
2. **`JSContext` 不是线程安全的**：所有回调必须回主线程，否则会静默丢帧（WebSocket TTS 就栽在这）。

## 浏览器助手

```
Chromium 扩展 content script
  → 选中文字 → 浮动「译」按钮
  → fetch http://127.0.0.1:8765/translate?text=...
  → HelperServer（NWListener，只监听回环）
  → 复用 TranslateRunner 的引擎选择逻辑
  → JSON 返回页面内渲染
```

没有中间服务器，也不经过任何第三方；扩展只是把文字发给本机进程。

## 窗口与焦点策略

- 翻译卡片：`.nonactivatingPanel`，从别的 App 唤起时不抢前台；但 `makeKey` 之后 `esc`/`⌘C` 要能收到，所以会先激活自己并把自家其它窗口 `orderBack`。
- 输入/词典窗口：普通 `NSWindow`，必须真正激活，否则键盘输入会掉到别的 App。
- 固定（⌘P）：卡片升到 `.floating` 层级并 `hidesOnDeactivate = false`，切到别的 App 也浮在最上面。

## 自测体系

`--selftest` 下挂了 30 多个测试入口，`scripts/verify.sh` 串起其中 82 项检查：

- **纯离线**：签名算法、请求构造、JSON 解析、段落聚类、URL Scheme 解析；
- **真实网络**：`real-services` 真打各家免密钥接口，断言返回中文；
- **真实 UI**：`screenshots` 离屏渲染六个主界面，任何布局塌陷都会失败；
- **真实按键**：`key-e2e` 用 `CGEvent` 发快捷键，验证全局热键真的触发；
- **插件**：`plugin-run` 真下载真跑社区插件，`plugin-contract` 校验运行时契约。

闸门用退出码判定，失败项会打印具体原因。不允许"看起来过了"。
