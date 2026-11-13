# Bob 社区插件兼容性清单

实测环境：macOS 26.1（Apple Silicon）+ LocalTranslate 内置插件运行时。
每一行都是「真实下载 → 安装 → 真跑一次请求」的结果，不是看代码猜的。

运行方式：

```bash
LocalTranslate.app/Contents/MacOS/LocalTranslate --selftest plugin-run <插件目录名> translate|ocr|tts "测试文本"
```

## 通了的（可以直接用）

| 插件 | 类型 | 实测结果 | 说明 |
|---|---|---|---|
| `bob-plugin-free-bing-translate` | 翻译 | ✅ 1.4s | 免密钥必应，已作为默认服务之一 |
| `bob-plugin-akl-youdao-free-translate` | 翻译 | ✅ 0.16s | 免密钥有道，句子/单词都行 |
| `bob-plugin-cambridge-dictionary` | 词典 | ✅ 0.81s | 词条进卡片词典区：英美音标 + 名词/动词分义项 |
| `bob-plugin-akl-microsoft-free-tts` | 语音 | ✅ 291 字节 | 免密钥微软 TTS（短句音频较短属正常） |
| `bob-plugin-edge-tts` | 语音 | ✅ 15120 字节 / 1.14s | Edge「大声朗读」，10 次连测全过 |
| `bob-plugin-mac-ocr` | OCR | ✅ 协议通 | 需自行运行 mac-ocr-http 服务；无服务时给出可读报错 |
| `bob-plugin-akl-caiyunxiaoyi-free-translate` | 翻译 | ✅ **已吸纳为原生**（0.05～0.66s） | 免密钥彩云小译 |
| `bob-plugin-akl-volcengine-free-translate` | 翻译 | ✅ **已吸纳为原生**（0.49s） | 免密钥火山翻译 |
| `bob-plugin-MOJiBobPlugin` | 词典 | ✅ **已吸纳为原生**（0.30s） | 日语词典：假名/罗马音/音调 + 词性释义 + 例句 |
| `roojay/bobplugin-google-translate` | 翻译 | ◻️ 可运行 | 代码不再报错，但本机 IP 被谷歌限流，返回「请求频率过快」 |

## 需要配置才能用的

| 插件 | 类型 | 状态 | 说明 |
|---|---|---|---|
| `bob-plugin-openai-translator` | 翻译 | ⚙️ 需要 API Key | 插件声明了 `$option`，现在「服务」页会自动渲染插件设置并可保存 |
| `bob-plugin-akl-chatgpt-free-translate` | 翻译 | ⚠️ 请求通了但译文为空 | 免密钥接口返回的不是它期望的 SSE 格式，属上游变更 |

## 上游失效的（不是我们的问题）

| 插件 | 现象 |
|---|---|
| `bob-plugin-akl-deepl-free-translate` | DeepL 直接返回「您使用的是旧版 DeepL，请更新」的提示页 |

## 为兼容这批插件补的运行时能力

| 能力 | 之前 | 现在 |
|---|---|---|
| CommonJS 入口 | 只认全局函数 | `exports.xxx =` 与老式全局两种写法都吃 |
| `$http` | 只有回调式 | 回调 / Promise / 二进制 body / multipart / streamRequest 全支持 |
| `$http` 响应 | 流式失败时没有 `response` | 永远给 `response`（statusCode 0），插件不会因读 `.statusCode` 崩掉 |
| `$data` | 字符串冒充 | 完整二进制对象（13 个方法），OCR 传图 / TTS 收音频都靠它 |
| `$file.read` | 返回字符串 | 返回 `$data`（Bob 契约），Cambridge 这类直接 `.toUTF8()` 的插件才跑得通 |
| `$file.write` | 只收字符串 | 收 `$data` 或字符串 |
| `query.detectFrom` | 原样传 `auto` | 传真实检测结果，否则词典插件第一步就判定「查不到」 |
| `result.toDict` | 丢弃 | 转成卡片词典区（音标 + 分义项） |
| `$option` | 只有默认值 | 设置页渲染 text/menu/switch 并持久化，需要 Key 的插件终于能配 |
| 回调线程 | 后台线程直接进 JSContext | 统一回主线程（JSC 非线程安全，会静默丢帧） |
| 回调存活 | `JSManagedValue` 被 GC 回收 | 强引用 `JSValue`，WebSocket/TTS 不再「收到几帧就断」 |
| `global` | 未定义，webpack 打包的插件直接崩 | 注入 `global` / `globalThis` 指向全局，Google 插件因此才跑起来 |

## 已吸纳为原生能力（不再依赖插件）

| 来源插件 | 吸纳为 | 实现 | 实测 |
|---|---|---|---|
| `bob-plugin-akl-youdao-free-translate` | **有道翻译（免密钥）** 引擎 | `YoudaoFreeTranslator`：句子走 `aidemo.youdao.com/trans`，按 900 字切块 | 0.14～0.22s，已进默认服务列表 |
| 同上（词典接口） | **有道词典** | `dict.youdao.com/jsonapi_s` + MD5 签名，解析英美音标/词性/词形变化 | `pressure`：us/ˈpreʃər、uk/ˈpreʃə(r)、n./v. 全义项 |
| `bob-plugin-cambridge-dictionary` | **剑桥词典** | `CambridgeDictionary`：抓英汉页，正则抽音标 + 词性 + 中文释义 | `pressure`：ˈpreʃ.ə / ˈpreʃ.ɚ + noun 释义 |
| `bob-plugin-akl-caiyunxiaoyi-free-translate` | **彩云小译（免密钥）** 引擎 | `CaiyunTranslator`：POST `interpreter.cyapi.cn/v1/translator` | 0.05～0.66s，已进默认列表 |
| `bob-plugin-akl-volcengine-free-translate` | **火山翻译（免密钥）** 引擎 | `VolcengineTranslator`：POST `translate.volcengine.com/crx/translate/v1/`（**结尾斜杠必须带**） | 0.49s，已进默认列表 |
| `bob-plugin-MOJiBobPlugin` | **MOJi 日语词典** | `MojiDictionary`：search-all 拿 id → ui-union-apis-word 拿详情 | `勉強`：べんきょう / benkyou / ⓪ + 「名·自他动·サ变 用功学习…」 |

词典查询链路现在是四级兜底：

```
ECDict（离线，最快）
  → 苹果系统词典（离线）
  → 有道词典（免密钥，音标+词性+词形）
  → 剑桥词典（免密钥，英汉释义）
  → 大模型 JSON（需要配置）
```

这两个插件仍然可以装，但已经不需要了——原生实现更快也更稳。

## 结论

免密钥可用：**必应、有道、剑桥词典、微软 TTS、Edge TTS**——这五个已经能直接当服务用。
需要密钥：**OpenAI 系插件**，现在有配置界面了。
插件图标/分类/简介会显示在「设置 → 插件列表」里，装完还会主动问要不要加成服务。
