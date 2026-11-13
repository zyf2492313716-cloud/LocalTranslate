# Bob 社区插件全量检索

来源：<https://bobplugin.ripperhe.com>（官方列表每天从 GitHub `bobplugin` topic 抓取），抓取 **2026-11-13**。

原始 179 条 → 去掉 4 个非插件仓库（DLX 服务端、ShellGPT 客户端、两个自建服务）→ **175 个插件**。

## 总览

| 类别 | 数量 | 说明 |
|---|---|---|
| 翻译 | 78 | LLM 翻译、传统引擎、聚合/逆向接口 |
| 词典 | 17 | 英汉/日汉/剑桥/韦氏等词条 |
| OCR | 18 | 截图识字、公式、竖排日文 |
| TTS | 22 | Edge/微软/OpenAI/火山等 |
| 生词本/工具 | 8 | 墨墨/欧路/扇贝/Anki/Notion |
| 其它 | 32 | 时间戳、拼音、假名注音、文本检测 |
| **合计** | **175** | |

## 状态分布

| 状态 | 数量 | 含义 |
|---|---|---|
| ✅ 可用的 | **9** | 真下载、真跑过请求（含 2 个已转成原生） |
| ◻️ 免密钥、未测试 | 75 | 候选池，按 star 排 |
| ⚙️ 需密钥 | 50 | 协议已支持，缺 Key |
| 📱 第三方 App 联动 | 10 | 生词本类 |
| 🔌 需本地服务 | 7 | DeepLX 等自建服务 |
| · 长尾未验证 | 20 | 0 star 个人自用 |
| ⚠️ 请求通但结果异常 | 2 | 上游接口变了 |
| ❌ 上游失效 | 1 | 服务方拒绝旧客户端 |

> 分类是关键词自动判定，**只用于筛选**；确凿结论来自实际下载运行。

## 已实测（11 个）（13）

全部真下载、安装、跑过请求。细节见 COMPATIBILITY.md。

| Star | 仓库 | 描述 | 状态 |
|---:|---|---|---|
| 623 | [akl7777777/bob-plugin-akl-deepl-free-translate](https://github.com/akl7777777/bob-plugin-akl-deepl-free-translate) | **DeepL免秘钥,免启服务**,双击使用,免费无限次使用,(**新增DeepL单词查询功能**)根据网页版JavaScript加密算法逆 | ❌ 上游失效（DeepL 拒绝旧客户端） |
| 398 | [roojay/bobplugin-google-translate](https://github.com/roojay/bobplugin-google-translate) | Bob 的一个Google 翻译插件 | ◻️ 可运行，但受 IP 限流（429/频率过快） |
| 293 | [akl7777777/bob-plugin-akl-chatgpt-free-translate](https://github.com/akl7777777/bob-plugin-akl-chatgpt-free-translate) | **免api_key,免费,免翻,使用OpenAI ChatGPT**,无需apiKey;无需账号密码;无需启动服务; | ⚠️ 请求通但译文为空（上游变更） |
| 79 | [akl7777777/bob-plugin-akl-microsoft-free-tts](https://github.com/akl7777777/bob-plugin-akl-microsoft-free-tts) | **微软语音tts免费免秘钥bob插件,完全无需秘钥** | ✅ 已实测（TTS） |
| 77 | [akl7777777/bob-plugin-akl-youdao-free-translate](https://github.com/akl7777777/bob-plugin-akl-youdao-free-translate) | **重大更新!有道翻译免秘钥免费,可以查单词也可以查句子**;有道插件新增免启动服务本地版,可以不用启动服务了;不过服务启动的方式依然保留. | ✅ 已吸纳为原生 |
| 75 | [yaobinbin333/bob-plugin-cambridge-dictionary](https://github.com/yaobinbin333/bob-plugin-cambridge-dictionary) | 剑桥词典翻译插件，支持例句和英文释义，不用密钥 | ✅ 已吸纳为原生 |
| 51 | [Ukenn2112/MOJiBobPlugin](https://github.com/Ukenn2112/MOJiBobPlugin) | MOJi 辞書 Bob Dictionaries Plugin | ✅ 已实测（日语词典 0.30s） |
| 31 | [akl7777777/bob-plugin-akl-caiyunxiaoyi-free-translate](https://github.com/akl7777777/bob-plugin-akl-caiyunxiaoyi-free-translate) | **免秘钥彩云小译bobplugin(No key Needs)** | ✅ 已实测（彩云小译 0.24s） |
| 31 | [akl7777777/bob-plugin-akl-volcengine-free-translate](https://github.com/akl7777777/bob-plugin-akl-volcengine-free-translate) | **免token火山翻译bob插件**,Token-free Volcano Translation bob plugin; | ✅ 已实测（火山 0.34s） |
| 30 | [xingty/bob-plugin-youdao-dict-enhance](https://github.com/xingty/bob-plugin-youdao-dict-enhance) | Bob插件有道词典增强版,支持单词、词组、例句功能 | ⚠️ 接口返回空（疑似上游限制） |
| 18 | [ayangweb/bob-plugin-free-bing-translate](https://github.com/ayangweb/bob-plugin-free-bing-translate) | 必应翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ✅ 已实测（翻译 1.4s） |
| 1 | [poyih/bob-plugin-edge-tts](https://github.com/poyih/bob-plugin-edge-tts) | Bob 语音合成插件：免 API Key 调用微软 Edge「大声朗读」接口，国内直连，覆盖近 80 种语言 | ✅ 已实测（TTS 15120B） |
| 0 | [Fan-chou/bob-plugin-mac-ocr](https://github.com/Fan-chou/bob-plugin-mac-ocr) | Bob OCR plugin for mac-ocr-http (Apple Vision over HTTP) / Bob 文字识别插件 | ✅ 已实测（OCR，需外部服务） |

## 免密钥、尚未测试（75）

按 star 排序的候选池。

| Star | 仓库 | 描述 | 状态 |
|---:|---|---|---|
| 207 | [geekdada/bob-plugin-deepl-translate](https://github.com/geekdada/bob-plugin-deepl-translate) | Use DeepL translation with Bob | ◻️ 免密钥·未测试 |
| 84 | [BrianShenCC/bob-plugin-gemini-translate](https://github.com/BrianShenCC/bob-plugin-gemini-translate) | 一个让 Bob 翻译可以使用 Google Gemini 的插件，支持翻译 润色 对话三种模式，对比GPT的优势在于目前免费使用，仅需自行申 | ◻️ 免密钥·未测试 |
| 81 | [AgaveTech/bob-plugin-openl-translate](https://github.com/AgaveTech/bob-plugin-openl-translate) | Bob 的 OpenL 聚合翻译插件 | ◻️ 免密钥·未测试 |
| 49 | [tingv/bobplugin-google-translate](https://github.com/tingv/bobplugin-google-translate) | Bob 的 Google 翻译插件，无需申请 API 秘钥 | ◻️ 免密钥·未测试 |
| 49 | [vacuityv/bob-plugin-vac-gptranslate](https://github.com/vacuityv/bob-plugin-vac-gptranslate) | 调用 openai-chatgpt、google-gemini、anthropic-claude、xai-grok、ali-qwen、dee | ◻️ 免密钥·未测试 |
| 43 | [Henry-Jessie/bob-plugin-llm-ocr](https://github.com/Henry-Jessie/bob-plugin-llm-ocr) | 一个可以让 Bob 翻译使用大模型进行OCR的插件 | ◻️ 免密钥·未测试 |
| 27 | [roojay/bobplug-nbnhhsh](https://github.com/roojay/bobplug-nbnhhsh) | 能不能好好好说话 https://github.com/itorr/nbnhhsh 的Bob插件 | ◻️ 免密钥·未测试 |
| 24 | [Ukenn2112/iWhatBobPlugin](https://github.com/Ukenn2112/iWhatBobPlugin) | iWhat 这是什么 Bob Plugin | ◻️ 免密钥·未测试 |
| 21 | [akl7777777/bob-plugin-akl-baidu-free-translate](https://github.com/akl7777777/bob-plugin-akl-baidu-free-translate) | **免秘钥无限次使用百度翻译**,根据网页版JavaScript加密算法开发的bobplugin;所以只要官网的算法不改,理论上就可以无限使 | ◻️ 免密钥·未测试 |
| 19 | [Oops418/bob-plugin-vocabulary.com](https://github.com/Oops418/bob-plugin-vocabulary.com) | 基于 vocabulary.com 的英英词典Bob插件 | ◻️ 免密钥·未测试 |
| 19 | [roojay/bobplug-google-tts](https://github.com/roojay/bobplug-google-tts) | Bob 的一个 Google tts 插件 | ◻️ 免密钥·未测试 |
| 19 | [roojay/bobplug-pinyin](https://github.com/roojay/bobplug-pinyin) | 一个 Bob 插件，支持简繁互转，汉字&gt;拼音，汉字&gt;火星文转换 | ◻️ 免密钥·未测试 |
| 18 | [akl7777777/bob-plugin-akl-transmart-free-translate](https://github.com/akl7777777/bob-plugin-akl-transmart-free-translate) | **腾讯交互翻译插件(免秘钥)** | ◻️ 免密钥·未测试 |
| 18 | [allonli/zdict-bobplug](https://github.com/allonli/zdict-bobplug) | 汉语言字典、辞海、用于查看汉字词语和单字，接入的汉典网站内容。 | ◻️ 免密钥·未测试 |
| 17 | [akl7777777/bob-plugin-akl-moe-tts](https://github.com/akl7777777/bob-plugin-akl-moe-tts) | **二次元老婆文字转语音bob插件tts** | ◻️ 免密钥·未测试 |
| 16 | [akl7777777/bob-plugin-akl-tencent-free-translate](https://github.com/akl7777777/bob-plugin-akl-tencent-free-translate) | **免秘钥腾讯翻译君bobplugin(No key Needs)** | ◻️ 免密钥·未测试 |
| 16 | [thirteenkai/snaptext](https://github.com/thirteenkai/snaptext) | macOS 菜单栏极速本地 OCR 工具 (RapidOCR / 完全离线 / Apple Silicon / Bob 插件支持) | ◻️ 免密钥·未测试 |
| 15 | [HansKing98/bob-plugin-yi-translate](https://github.com/HansKing98/bob-plugin-yi-translate) | Yi 大模型 API 在 bob app 的插件 | ◻️ 免密钥·未测试 |
| 15 | [solywsh/bob-relingo](https://github.com/solywsh/bob-relingo) | bob的relingo联动，可显示relingo个人单词掌握情况 | ◻️ 免密钥·未测试 |
| 15 | [roojay/bob-plug](https://github.com/roojay/bob-plug) | Bob 插件开发工具，包含 cli 项目初始化工具和 Bob 插件核心类型封装 | ◻️ 免密钥·未测试 |
| 14 | [augusl/bobplugin-ipinfo](https://github.com/augusl/bobplugin-ipinfo) | Bob 的一个查询IP信息插件 | ◻️ 免密钥·未测试 |
| 14 | [akl7777777/bob-plugin-akl-cnki-free-translate](https://github.com/akl7777777/bob-plugin-akl-cnki-free-translate) | **免秘钥CNKI学术翻译Bob插件** | ◻️ 免密钥·未测试 |
| 13 | [maybeLab/bob-plugin-volc](https://github.com/maybeLab/bob-plugin-volc) | 火山引擎翻译插件 for [Bob](https://ripperhe.gitee.io/bob) | ◻️ 免密钥·未测试 |
| 13 | [lxlhlp/bob-plugin-chatglm-translate](https://github.com/lxlhlp/bob-plugin-chatglm-translate) | 基于智普大模型[chatglm]实现翻译及语法优化;官方免费API,相信我,用上它,你就会爱上它&lt;(￣︶￣)&gt;.它能化身为你的随 | ◻️ 免密钥·未测试 |
| 12 | [ayangweb/bob-plugin-free-ali-translate](https://github.com/ayangweb/bob-plugin-free-ali-translate) | 阿里翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ◻️ 免密钥·未测试 |
| 12 | [akl7777777/bob-plugin-akl-mojidict-translate](https://github.com/akl7777777/bob-plugin-akl-mojidict-translate) | **只为日语 - MOJi辞書（じしょ）Bob插件** | ◻️ 免密钥·未测试 |
| 12 | [akl7777777/BobTranslateClipboard](https://github.com/akl7777777/BobTranslateClipboard) | **Bob翻译剪切板图片的AlfredWorkflow,以及Apple自动化,社区版Bob也能用** | ◻️ 免密钥·未测试 |
| 11 | [qaz5391450/bob-plugin-aiset-translator](https://github.com/qaz5391450/bob-plugin-aiset-translator) | 致力于做一个 AI 集合的 Bob 插件 | ◻️ 免密钥·未测试 |
| 11 | [xnmeet/voi](https://github.com/xnmeet/voi) | 一个基于 [Bob](https://bobtranslate.com/) 的文本转语音插件，使用 Kokoro 本地部署模型作为语音合成服 | ◻️ 免密钥·未测试 |
| 10 | [zpj80231/bob-plugin-microsoft-tts](https://github.com/zpj80231/bob-plugin-microsoft-tts) | 基于 Microsoft Azure / Edge TTS 的免 API Key 文字转语音【免费 - 微软语音合成 Bob 插件】 | ◻️ 免密钥·未测试 |
| 10 | [YanMiaoW/bobplugin-CNKI-translate](https://github.com/YanMiaoW/bobplugin-CNKI-translate) | Bob英语的CNKI学术翻译接口 | ◻️ 免密钥·未测试 |
| 9 | [ayangweb/bob-plugin-free-baidu-translate](https://github.com/ayangweb/bob-plugin-free-baidu-translate) | 百度翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ◻️ 免密钥·未测试 |
| 8 | [TuRan-H/BobLatex](https://github.com/TuRan-H/BobLatex) | 一个使用LLM api进行Latex公式识别的Bob插件 | ◻️ 免密钥·未测试 |
| 8 | [markvlenvision/BobPlugin-Microsoft-TTS-Service](https://github.com/markvlenvision/BobPlugin-Microsoft-TTS-Service) | Microsoft-TTS-Service-BobPlugin | ◻️ 免密钥·未测试 |
| 8 | [ayangweb/bob-plugin-free-sougou-translate](https://github.com/ayangweb/bob-plugin-free-sougou-translate) | 搜狗翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ◻️ 免密钥·未测试 |
| 7 | [RyuSeongbin/bob-plugin-papago-translate](https://github.com/RyuSeongbin/bob-plugin-papago-translate) | bob papago 韩语翻译插件 | ◻️ 免密钥·未测试 |
| 7 | [ayangweb/bob-plugin-free-iciba-translate](https://github.com/ayangweb/bob-plugin-free-iciba-translate) | 爱词霸翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ◻️ 免密钥·未测试 |
| 7 | [Sugar-Coder/bobplugin-jyut6jyu5](https://github.com/Sugar-Coder/bobplugin-jyut6jyu5) | Bob粤语拼音翻译插件 | ◻️ 免密钥·未测试 |
| 6 | [GravityPoet/Open-LLM-OCR](https://github.com/GravityPoet/Open-LLM-OCR) | Bob 终极 OCR：支持本地隐私模型 + 大模型API云端 OCR 高精度，一键切换。快、免费、隐私好。识别能力更强，可选更多模型 | ◻️ 免密钥·未测试 |
| 6 | [ayangweb/bob-plugin-free-calf-translate](https://github.com/ayangweb/bob-plugin-free-calf-translate) | 小牛翻译，无需秘钥，可以直接在 bob 中进行工作，如果有一天它不工作了，请联系我进行修复！ | ◻️ 免密钥·未测试 |
| 6 | [zo-ly/bob-plugin-ai-dict](https://github.com/zo-ly/bob-plugin-ai-dict) | Bob 翻译插件：句子正常翻译，单词/短语返回 Bob 原生词典卡片（音标、词性词义、变形、例句） | ◻️ 免密钥·未测试 |
| 6 | [EliazTray/bob-plugin-kuroshiro](https://github.com/EliazTray/bob-plugin-kuroshiro) | A Bob Plugin for Ruby Characters(旁注标记). | ◻️ 免密钥·未测试 |
| 5 | [Fuuuuuji/merriam-webster-dictionary](https://github.com/Fuuuuuji/merriam-webster-dictionary) | A bob plugin use merriam-webster api as dictionary | ◻️ 免密钥·未测试 |
| 5 | [silver-ymz/bob-plugin-microsoft-translate](https://github.com/silver-ymz/bob-plugin-microsoft-translate) | Bob plugin for microsoft translation | ◻️ 免密钥·未测试 |
| 5 | [akl7777777/bob-plugin-akl-postman](https://github.com/akl7777777/bob-plugin-akl-postman) | Bob的Postman插件,可以在Bob中调试接口 | ◻️ 免密钥·未测试 |
| 4 | [silver-ymz/bob-plugin-latex-ocr](https://github.com/silver-ymz/bob-plugin-latex-ocr) | bob plugin for latex ocr, using lukas-blecher/LaTeX-OCR | ◻️ 免密钥·未测试 |
| 4 | [wweir/wweir-tools.bobplugin](https://github.com/wweir/wweir-tools.bobplugin) | 自用的一些 bob 小插件 | ◻️ 免密钥·未测试 |
| 4 | [ChenHaoHu/bob-plugin-timestamp-to-time](https://github.com/ChenHaoHu/bob-plugin-timestamp-to-time) | bob-plugin-timestamp-to-time | ◻️ 免密钥·未测试 |
| 4 | [missuo/bob-plugin-raycast](https://github.com/missuo/bob-plugin-raycast) | Raycast AI translation plugin designed for Bob | ◻️ 免密钥·未测试 |
| 3 | [cdpath/bob-plugin-elevenlabs](https://github.com/cdpath/bob-plugin-elevenlabs) | Bob Plugin for ElevenLabs TTS | ◻️ 免密钥·未测试 |
| 3 | [missuo/bob-plugin-wechat-ocr](https://github.com/missuo/bob-plugin-wechat-ocr) | OCR/Text Recognition Plugin for Bob | ◻️ 免密钥·未测试 |
| 3 | [wakewon/bob-plugin-mdict](https://github.com/wakewon/bob-plugin-mdict) | 一个支持在 Bob 中本地查询 MDX 词典，并可播放配套 MDD 文件中发音资源的离线词典插件。 | ◻️ 免密钥·未测试 |
| 3 | [Oops418/bob-plugin-paddle-ocr](https://github.com/Oops418/bob-plugin-paddle-ocr) | 基于 PaddleOCR 的Bob OCR插件 | ◻️ 免密钥·未测试 |
| 2 | [GravityPoet/Bob-DeepThink-Free-ChatGPT-Gemini-Claude](https://github.com/GravityPoet/Bob-DeepThink-Free-ChatGPT-Gemini-Claude) | Bob大模型翻译插件：全品类模型、全AI接口支持！主要是解决内置或者各类翻译异常、翻译失败、接口不对的问题！ | ◻️ 免密钥·未测试 |
| 2 | [thirteenkai/bob-plugin-magpie](https://github.com/thirteenkai/bob-plugin-magpie) | Bob 文本翻译插件：通过 Magpie 网关使用自定义模型或路由组，支持流式输出。 | ◻️ 免密钥·未测试 |
| 2 | [ipfans/bob-plugin-fishaudio-tts](https://github.com/ipfans/bob-plugin-fishaudio-tts) | Fish Audio TTS for Bob Plugin is a tts plugin for bob. You can get a f | ◻️ 免密钥·未测试 |
| 2 | [duo-jian-dan/bobplugin-add-card](https://github.com/duo-jian-dan/bobplugin-add-card) | 多拣蛋微信小程序快速添加卡片 Bob 插件 | ◻️ 免密钥·未测试 |
| 2 | [missuo/bob-plugin-universal](https://github.com/missuo/bob-plugin-universal) | Universal translation plugin for Bob. | ◻️ 免密钥·未测试 |
| 2 | [Jack-Xiao/bob-plugin-google-chirp3-tts](https://github.com/Jack-Xiao/bob-plugin-google-chirp3-tts) | Bob TTS plugin using Google Cloud Chirp 3 HD voices (English &amp; Chi | ◻️ 免密钥·未测试 |
| 2 | [JeremyL691/bob-plugin-opencode-go](https://github.com/JeremyL691/bob-plugin-opencode-go) | 在 Bob 中使用 OpenCode Go 模型翻译文本，支持自动接口和思考等级 | ◻️ 免密钥·未测试 |
| 1 | [wakewon/AiTranslate](https://github.com/wakewon/AiTranslate) | 一个插件，搞定所有大模型。基于请求格式建模的 Bob 通用 AI 翻译插件。 | ◻️ 免密钥·未测试 |
| 1 | [Fan-chou/bob-plugin-paddleocr](https://github.com/Fan-chou/bob-plugin-paddleocr) | 本地 PaddleOCR-VL OCR 插件，支持文字定位与原图翻译。 | ◻️ 免密钥·未测试 |
| 1 | [xianlihuang/bob-plugin-bubei-newword](https://github.com/xianlihuang/bob-plugin-bubei-newword) | bob查词，自动加入不背单词生词本 | ◻️ 免密钥·未测试 |
| 1 | [donaldxdonald/bob-plugin-jisho](https://github.com/donaldxdonald/bob-plugin-jisho) | 基于 Jisho 的日语词典插件，实现在任何软件中即时查看日语单词释义。 | ◻️ 免密钥·未测试 |
| 1 | [love4taylor/bob-plugin-bilibili-index-translate](https://github.com/love4taylor/bob-plugin-bilibili-index-translate) | 在 Bob 中使用 Bilibili 免费公开翻译 API，无需 API Key。 | ◻️ 免密钥·未测试 |
| 1 | [raysry/bob-lowercase-plugin](https://github.com/raysry/bob-lowercase-plugin) | A 'Bob' plugin, convert the original text to lowercase；Bob插件，支持将原文转小写 | ◻️ 免密钥·未测试 |
| 1 | [wong-haha/bob-plugin-connect-dify](https://github.com/wong-haha/bob-plugin-connect-dify) | 把 Bob 接入 Dify 工作流，选中文本即可触发任意 Chatflow/Workflow，拥有无限可能。通过 Dify 可以接到任意大模 | ◻️ 免密钥·未测试 |
| 1 | [AllenYGY/LiveTranslateBobPlugin](https://github.com/AllenYGY/LiveTranslateBobPlugin) | Bob 插件: 提供实时中英文字幕的翻译插件 | ◻️ 免密钥·未测试 |
| 1 | [RyuSeongbin/bob-plugin-codex-translate](https://github.com/RyuSeongbin/bob-plugin-codex-translate) | Codex subscription-powered translation plugin for Bob on macOS | ◻️ 免密钥·未测试 |
| 1 | [lwcrafts/bob-plugin-youdao-tts](https://github.com/lwcrafts/bob-plugin-youdao-tts) | 有道智云 TTS 语音合成 API - Bob插件 | ◻️ 免密钥·未测试 |
| 1 | [zhao-ji/bob-plugin-vertex-polisher](https://github.com/zhao-ji/bob-plugin-vertex-polisher) | 使用 Vertex AI API 给文本进行润色和语法纠错的 Bob 插件！完美代替 Grammarly! | ◻️ 免密钥·未测试 |
| 1 | [wakewon/OCRSpace](https://github.com/wakewon/OCRSpace) | 基于 OCR.space API 的 Bob OCR 插件，专为日文竖排阅读顺序重排优化。A Bob OCR plugin using OC | ◻️ 免密钥·未测试 |
| 1 | [thirteenkai/snaptext-bob-plugin](https://github.com/thirteenkai/snaptext-bob-plugin) | Bob 插件 - 使用 SnapText 作为离线 OCR 服务端 | ◻️ 免密钥·未测试 |
| 1 | [TastyHeadphones/bob-plugin-xfyun-translate.bobplugin](https://github.com/TastyHeadphones/bob-plugin-xfyun-translate.bobplugin) | Xfyun ai translator bob plugin | ◻️ 免密钥·未测试 |
| 1 | [baerwang/bob-translate-ai-plugin](https://github.com/baerwang/bob-translate-ai-plugin) | This is an AI plugin based on Bob that can translate English into Chin | ◻️ 免密钥·未测试 |

## 需要密钥（50）

`$option` 配置界面已就位，填 Key 即可用。

| Star | 仓库 | 描述 | 状态 |
|---:|---|---|---|
| 5652 | [nextai-translator/bob-plugin-openai-translator](https://github.com/nextai-translator/bob-plugin-openai-translator) | 基于 LLM 的文本翻译、文本润色、语法纠错 Bob 插件，让我们一起迎接不需要巴别塔的新时代！Licensed under CC BY-N | ⚙️ 需密钥（配置界面已支持） |
| 661 | [nextai-translator/bob-plugin-openai-polisher](https://github.com/nextai-translator/bob-plugin-openai-polisher) | 使用 OpenAI API 给文本进行润色和语法纠错的 Bob 插件！完美代替 Grammarly！Licensed under CC BY | ⚙️ 需密钥 |
| 92 | [jtsang4/bob-plugin-claude-translator](https://github.com/jtsang4/bob-plugin-claude-translator) | 一个让 Bob 翻译可以使用 Anthropic Claude API 的插件 | ⚙️ 需密钥 |
| 41 | [missuo/bob-plugin-cohere](https://github.com/missuo/bob-plugin-cohere) | Cohere (Command R+) AI translation plugin for Bob. | ⚙️ 需密钥 |
| 34 | [missuo/bob-plugin-copilot](https://github.com/missuo/bob-plugin-copilot) | Copilot AI translation plugin for Bob | ⚙️ 需密钥 |
| 29 | [CaicoLeung/bob-plugin-ollama-translator](https://github.com/CaicoLeung/bob-plugin-ollama-translator) | 支持单词查询（词典卡片、发音）、文本翻译与名词百科解释。支持接入 Ollama/OpenAI/DeepSeek/Grok/Claude/Ge | ⚙️ 需密钥 |
| 17 | [kongds1999/bob-plugin-groq-translate](https://github.com/kongds1999/bob-plugin-groq-translate) | 支持Groq API 的bob-translate插件，目前（10/31/2024）支持llama3/3.1/3.2系列、mixtral-8 | ⚙️ 需密钥 |
| 16 | [Brain777777/bob-plugin-gemini](https://github.com/Brain777777/bob-plugin-gemini) | 基于Gemini API 的文本翻译 | ⚙️ 需密钥 |
| 12 | [n-AChegYag/bob-plugin-grok-translator](https://github.com/n-AChegYag/bob-plugin-grok-translator) | 一个支持xAI、OpenAI、Anthropic、Google、DeepSeek等公司模型的bob插件，自行输入API Key，高效翻译！ | ⚙️ 需密钥 |
| 11 | [wakewon/bob-plugin-simpletex](https://github.com/wakewon/bob-plugin-simpletex) | 调用 SimpleTex 识别 LaTeX 公式和页面，需要申请 API | ⚙️ 需密钥 |
| 9 | [kindtree/bob-plugin-wordtier](https://github.com/kindtree/bob-plugin-wordtier) | 词阶 WordTier — Bob (macOS) 学英语词典插件：英文完整词典 + 中文反查 + 可选 DeepSeek 整句翻译；按 C | ⚙️ 需密钥 |
| 8 | [Mopip77/bob-openai-explainer](https://github.com/Mopip77/bob-openai-explainer) | ChatGPT快速对所选文本进行解释 | ⚙️ 需密钥 |
| 7 | [lhui/bob-plugin-moonshot](https://github.com/lhui/bob-plugin-moonshot) | 一个基于 **moonshot** 的 bob 翻译插件, 翻译速度快，准确度高，价格合适。 | ⚙️ 需密钥 |
| 6 | [zhuiyue132/bob-plugin-gpt-translator](https://github.com/zhuiyue132/bob-plugin-gpt-translator) | 直接调用 ChatGPT 网页端 而非 OpenAI api 的 Bob 翻译插件。 | ⚙️ 需密钥 |
| 6 | [ry-sun/bob-plugin-openai-tts](https://github.com/ry-sun/bob-plugin-openai-tts) | OpenAI TTS for Bob Plugin is a tts plugin for bob, a brilliant transla | ⚙️ 需密钥 |
| 5 | [Layouwen/bob-plugin-openai-enhance](https://github.com/Layouwen/bob-plugin-openai-enhance) | OpenAI Translation Enhancement Bob Plugin. OpenAI 翻译增强 Bob 插件. | ⚙️ 需密钥 |
| 4 | [qdxiao/go-bob](https://github.com/qdxiao/go-bob) | Based on Qwen, this project provides Go developers with an intelligent | ⚙️ 需密钥 |
| 3 | [poyih/bob-plugin-gemini-tts](https://github.com/poyih/bob-plugin-gemini-tts) | Bob 翻译插件 - 使用 Google Gemini TTS API 进行语音合成 | ⚙️ 需密钥 |
| 3 | [thirteenkai/bob-plugin-qwen-tts](https://github.com/thirteenkai/bob-plugin-qwen-tts) | Bob TTS 插件 - 使用阿里云 Qwen3-TTS-Flash 模型进行语音合成，支持 45+ 种语音角色 | ⚙️ 需密钥 |
| 2 | [SimonGino/bob-plugin-qwen-translator](https://github.com/SimonGino/bob-plugin-qwen-translator) | 一个让 Bob 翻译可以使用 QwenAPI 的插件 | ⚙️ 需密钥 |
| 2 | [selaselah/bob-plugin-mathpix](https://github.com/selaselah/bob-plugin-mathpix) | 调用 mathpix 识别 latex 公式，需要申请付费 API | ⚙️ 需密钥 |
| 2 | [gray0128/bob-zhipu-nothink](https://github.com/gray0128/bob-zhipu-nothink) |  | ⚙️ 需密钥 |
| 2 | [rhyspenn/openai-compatible-translate](https://github.com/rhyspenn/openai-compatible-translate) | 这是一个基于 openai compatible api 的 Bob 翻译插件，提供高质量的文本翻译服务。 | ⚙️ 需密钥 |
| 2 | [helloChenLei/bob-plugin-openrouter](https://github.com/helloChenLei/bob-plugin-openrouter) |  | ⚙️ 需密钥 |
| 2 | [rhyspenn/gemini-translate](https://github.com/rhyspenn/gemini-translate) | 这是一个支持 Google Gemini API 格式的 Bob 翻译插件，可使用 Gemini 模型进行高质量文本翻译。 | ⚙️ 需密钥 |
| 2 | [djx30103/bob-plugin-doubao-translate](https://github.com/djx30103/bob-plugin-doubao-translate) | 基于 豆包Doubao API 的文本翻译、文本润色、语法纠错 Bob 插件。 | ⚙️ 需密钥 |
| 2 | [Littlecowherd/bob-plugin-doubao-tts](https://github.com/Littlecowherd/bob-plugin-doubao-tts) | Bob 插件 - 使用火山引擎豆包语音合成大模型进行语音合成 | ⚙️ 需密钥 |
| 1 | [KarasuShin/bob-plugin-qwen-mt-translator](https://github.com/KarasuShin/bob-plugin-qwen-mt-translator) | A Bob plugin for text translation using the Qwen-MT model | ⚙️ 需密钥 |
| 1 | [eigenigma/bob-plugin-urban-dictionary](https://github.com/eigenigma/bob-plugin-urban-dictionary) | Search slang meanings on Urban Dictionary with GPT analysis | ⚙️ 需密钥 |
| 1 | [wongshandev/bob-plugin-openai-tts](https://github.com/wongshandev/bob-plugin-openai-tts) | OpenAI GPT-4o mini TTS plugin for Bob translator | ⚙️ 需密钥 |
| 1 | [rhyspenn/zhipu-ai-translate](https://github.com/rhyspenn/zhipu-ai-translate) | 这是一个基于智谱 AI 大模型的 Bob 翻译插件，提供高质量的文本翻译服务。 | ⚙️ 需密钥 |
| 1 | [haizakura/bob-openai-translate](https://github.com/haizakura/bob-openai-translate) | Bob 的 OpenAI 翻译插件，支持翻译、润色与自定义 Prompt / OpenAI translation, polishing,  | ⚙️ 需密钥 |
| 1 | [HanBangyuan8/OpenAI-Compatible-with-Thinking-Switch-for-Bob](https://github.com/HanBangyuan8/OpenAI-Compatible-with-Thinking-Switch-for-Bob) |  | ⚙️ 需密钥 |
| 1 | [poyih/bob-plugin-openai-tts](https://github.com/poyih/bob-plugin-openai-tts) | Bob 翻译插件 - 使用 OpenAI TTS API 进行语音合成 | ⚙️ 需密钥 |
| 1 | [virtualflase/bob-plugin-custom-request](https://github.com/virtualflase/bob-plugin-custom-request) | OpenAI 兼容的 Bob 文本翻译插件，支持自定义请求头/请求体、流式响应和 Thinking 内容展示 | ⚙️ 需密钥 |
| 1 | [poyih/bob-plugin-openrouter-tts](https://github.com/poyih/bob-plugin-openrouter-tts) | Bob TTS plugin for OpenRouter with Gemini and OpenAI voice selection | ⚙️ 需密钥 |
| 1 | [CuiYuXi/bob-plugin-ollama-translator](https://github.com/CuiYuXi/bob-plugin-ollama-translator) | Bob 翻译插件：基于本地 Ollama 的 Bob 流式翻译插件 | ⚙️ 需密钥 |
| 1 | [junqi-lu/bob-plugin-deepseek-translator](https://github.com/junqi-lu/bob-plugin-deepseek-translator) | Bob 翻译插件，基于 DeepSeek Chat Completions API，支持 DeepSeek V4 思考模式参数。 | ⚙️ 需密钥 |
| 1 | [fl0w1nd/bob-mistral-ocr](https://github.com/fl0w1nd/bob-mistral-ocr) | Mistral OCR plugin for Bob | ⚙️ 需密钥 |
| 1 | [xiaotianxt/bob-plugin-gpt-detector](https://github.com/xiaotianxt/bob-plugin-gpt-detector) | 检测 AI 文本从未如此丝滑。 | ⚙️ 需密钥 |
| 0 | [Tubring25/bob-gemini-agent-platform](https://github.com/Tubring25/bob-gemini-agent-platform) | Bob翻译器插件，通过Vertex AI/Agent Platform调用Gemini。 | ⚙️ 需密钥 |
| 0 | [jiayouzl/bob-newopenai-explainer](https://github.com/jiayouzl/bob-newopenai-explainer) | 基于bob对文本框中的内容进行解释 | ⚙️ 需密钥 |
| 0 | [jiayouzl/bob-deepseek-explainer](https://github.com/jiayouzl/bob-deepseek-explainer) | DeepSeek快速对所选文本进行解释 | ⚙️ 需密钥 |
| 0 | [laohubb/bob-plugin-kimi-translator](https://github.com/laohubb/bob-plugin-kimi-translator) | Kimi API 驱动的 Bob 插件：流式翻译、润色、自定义 System Prompt 和 User Prompt | ⚙️ 需密钥 |
| 0 | [haizakura/bob-openai-ocr](https://github.com/haizakura/bob-openai-ocr) | Bob 的 OpenAI OCR 文本识别插件 / An OpenAI-powered OCR plugin for Bob | ⚙️ 需密钥 |
| 0 | [wuzeyou/bob-plugin-zhipu-translator](https://github.com/wuzeyou/bob-plugin-zhipu-translator) | Bob 翻译插件 - 智谱 AI (Zhipu/GLM)，支持 Coding Plan、自定义模型、Thinking 模式、流式输出、润色模 | ⚙️ 需密钥 |
| 0 | [poyih/bob-plugin-mistral-ocr](https://github.com/poyih/bob-plugin-mistral-ocr) | Bob 翻译插件 - 使用 Mistral AI OCR 进行文本识别 | ⚙️ 需密钥 |
| 0 | [Mojiajun2022/bob-plugin-generic_llm](https://github.com/Mojiajun2022/bob-plugin-generic_llm) | A Bob plugin for Ollama and generic LLM translation. | ⚙️ 需密钥 |
| 0 | [Fowayhq/bob-plugin-ai-translate-universal](https://github.com/Fowayhq/bob-plugin-ai-translate-universal) | Bob 通用 AI 翻译插件，支持 OpenAI Chat Completions、Responses 和 Claude Messages， | ⚙️ 需密钥 |
| 0 | [poyih/bob-plugin-vercel-tts](https://github.com/poyih/bob-plugin-vercel-tts) | Bob 语音合成插件：通过 Vercel AI Gateway 调用 OpenAI / Gemini / Grok / Fish Audio | ⚙️ 需密钥 |

## 第三方 App 联动（10）

本质是导出/导入。

| Star | 仓库 | 描述 | 状态 |
|---:|---|---|---|
| 124 | [yuhaowin/wordbook-bob-plugin](https://github.com/yuhaowin/wordbook-bob-plugin) | 通过 Bob 查询的单词添加至 「有道词典」 、 「欧路词典」、「扇贝单词」 的单词本。 | 📱 第三方 App 联动 |
| 53 | [chriscurrycc/bob-plugin-maimemo-notebook](https://github.com/chriscurrycc/bob-plugin-maimemo-notebook) | Bob 查询的单词导入到墨墨背单词，并支持将单词出现的上下文添加为例句，加强背诵记忆 | 📱 第三方 App 联动 |
| 37 | [robbinhan/bob-anki](https://github.com/robbinhan/bob-anki) | 将bob翻译的内容写入anki卡片 | 📱 第三方 App 联动 |
| 7 | [Fancu1/bob-plugin-momo-voc](https://github.com/Fancu1/bob-plugin-momo-voc) | 墨墨背单词 Bob 插件 ／ Bob Plugin for momo | 📱 第三方 App 联动 |
| 5 | [kaikanwu/bob2anki](https://github.com/kaikanwu/bob2anki) | Memorizing words with Bob and Anki. 自动生成翻译和语音并添加到指定的 Anki 牌组。 | 📱 第三方 App 联动 |
| 3 | [linbuxiao/Bob2Anki](https://github.com/linbuxiao/Bob2Anki) | Memorizing words makes me sad. | 📱 第三方 App 联动 |
| 2 | [klutzoder/allwordbook-bob-plugin](https://github.com/klutzoder/allwordbook-bob-plugin) | 通过 Bob 查询的单词添加至单词本，面向市面上所有的笔记本 | 📱 第三方 App 联动 |
| 1 | [wweir/memo.bobplugin](https://github.com/wweir/memo.bobplugin) | bob plugin for flomo and memos | 📱 第三方 App 联动 |
| 0 | [ruihexianling/bob-plugin-e2notion](https://github.com/ruihexianling/bob-plugin-e2notion) | Bob 划词一键保存到 Notion 知识库插件 (基于 E2notion 服务) | 📱 第三方 App 联动 |
| 0 | [ruihexianling/bob-plugin-memos](https://github.com/ruihexianling/bob-plugin-memos) | Bob 划词一键保存到 Memos 碎片知识库插件 | 📱 第三方 App 联动 |

## 需要本地服务（7）

插件只是客户端。

| Star | 仓库 | 描述 | 状态 |
|---:|---|---|---|
| 351 | [yetone/bob-plugin-rapidapi-deepl-translator](https://github.com/yetone/bob-plugin-rapidapi-deepl-translator) | DeepL RapidAPI 的 Bob 插件，可能是中国 macOS 用户可以无痛使用的相对合法的最便宜的 DeepL 翻译方案。 | 🔌 需本地服务/账号 |
| 291 | [missuo/bob-plugin-deeplx](https://github.com/missuo/bob-plugin-deeplx) | **Free DeepL Plugin for Bob** | 🔌 需本地服务/账号 |
| 50 | [gray0128/bob-plugin-MTranServer](https://github.com/gray0128/bob-plugin-MTranServer) | 一个基于MTranServer 的 bob 翻译插件，让你告别用量焦虑和速度焦虑。 | 🔌 需本地服务/账号 |
| 39 | [BiboyQG/bob-cosyvoice](https://github.com/BiboyQG/bob-cosyvoice) | A Bob plugin that calls self-deployed Cosyvoice service to achieve TTS | 🔌 需本地服务/账号 |
| 9 | [almightyYantao/bob-plugin-deeplx-translator](https://github.com/almightyYantao/bob-plugin-deeplx-translator) | BOB Plugin DeepLx Translator | 🔌 需本地服务/账号 |
| 7 | [ycvk/deeplx-local-bobplugin](https://github.com/ycvk/deeplx-local-bobplugin) | 用于自建deeplx服务的bob翻译插件 | 🔌 需本地服务/账号 |
| 0 | [Sarmay/bob-plugin-deeplx](https://github.com/Sarmay/bob-plugin-deeplx) | 可使用linux.do和其他网站deeplx翻译bob插件 | 🔌 需本地服务/账号 |

<details><summary>翻译 · 长尾未验证（8）</summary>

- [djx30103/bob-plugin-spark-translate](https://github.com/djx30103/bob-plugin-spark-translate) — 基于 讯飞星火Spark API 的文本翻译、文本润色、语法纠错 Bob 插件。
- [gray0128/bob-hy-mt](https://github.com/gray0128/bob-hy-mt) — Bob 插件：腾讯混元翻译模型 HY-MT2
- [meouwu3/bob-plugin-vercel-ai-gateway](https://github.com/meouwu3/bob-plugin-vercel-ai-gateway) — Minimal Bob translation plugin for Vercel AI Gateway
- [meouwu3/bob-plugin-zenmux](https://github.com/meouwu3/bob-plugin-zenmux) — Minimal Bob translation plugin for ZenMux with streaming and
- [normal-coder/bob-plugin-giteeai-translate](https://github.com/normal-coder/bob-plugin-giteeai-translate) — 基于 GiteeAI 的 Bob 翻译插件。AI 翻译，从未如此丝滑。
- [NotchL1118/bob-plugin-google-translate](https://github.com/NotchL1118/bob-plugin-google-translate) — Bob 翻译插件：Google 翻译 (gtx, 免 Key)
- [unbrain/Relingo-bob](https://github.com/unbrain/Relingo-bob) — 句子翻译使用 relingo
- [Z2U35/bob-plugin-doubao-web](https://github.com/Z2U35/bob-plugin-doubao-web) — Bob 豆包翻译插件，无需apikey

</details>

<details><summary>词典 · 长尾未验证（1）</summary>

- [Ocnos936/bob-plugin-translate-dictionary](https://github.com/Ocnos936/bob-plugin-translate-dictionary) — Bob 翻译插件：句子自动翻译，英文单词或词组自动查词典。快速、简单，兼容 Bob 社区版。

</details>

<details><summary>OCR · 长尾未验证（4）</summary>

- [Kenw800c/bob-plugin-currency-converter](https://github.com/Kenw800c/bob-plugin-currency-converter) — Bob 划词/OCR 汇率自动换算插件
- [kikohz/bob-plugin-local-ocr](https://github.com/kikohz/bob-plugin-local-ocr) — Bob 离线 OCR 插件：用沙盒外的本地 Vision 服务解决 macOS 27 上系统 OCR 很慢的问题
- [SchweppesSoda/bailian-plugins](https://github.com/SchweppesSoda/bailian-plugins) — Alibaba Cloud Model Studio (Bailian) translation and OCR plu
- [www011215/bob-plugin-glm](https://github.com/www011215/bob-plugin-glm) — Bob 插件：智谱 GLM 文字识别（glm-ocr）+ 语音合成（glm-tts）。识别插件基于 MinatoHika

</details>

<details><summary>TTS · 长尾未验证（2）</summary>

- [ipfans/bob-plugin-mimo-2-tts](https://github.com/ipfans/bob-plugin-mimo-2-tts) — Bob 插件，使用小米 MiMo-2-TTS 模型将文本转换为语音
- [poyih/bob-plugin-11labs-tts](https://github.com/poyih/bob-plugin-11labs-tts) — 

</details>

<details><summary>其它 · 长尾未验证（5）</summary>

- [dingye18/bobplugin-copy2bibtex](https://github.com/dingye18/bobplugin-copy2bibtex) — A Bob plugin that converts paper titles or DOIs into BibTeX 
- [rhyspenn/lemmatization-plugin](https://github.com/rhyspenn/lemmatization-plugin) — 查询英文单词的各种词形变化，包括复数、过去式、现在分词等形式的专业 Bob 插件
- [SuCicada/bob-plugin-japanese-furigana](https://github.com/SuCicada/bob-plugin-japanese-furigana) — 
- [TastyHeadphones/bob-plugin-hiragana](https://github.com/TastyHeadphones/bob-plugin-hiragana) — 
- [xingty/bob-plugin-transcat](https://github.com/xingty/bob-plugin-transcat) — A Bob plugin for transcat

</details>
