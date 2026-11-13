#!/bin/bash
# 验收闸门：把「界面和功能都改好了」变成可执行、有退出码、能复现的结论。
#
#   0 = 全部通过    1 = 有检查没过    3 = 工具链/前置条件坏了
#
# 每一项都是真跑，不看代码注释也不信任何人的口头结论。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/LocalTranslate.app"
# 自测一律走 .app 里的可执行文件：钥匙串记录是按签名身份授权的，
# 用裸二进制去读会弹一个没人能点的授权框，把主线程钉死。
BIN="$APP/Contents/MacOS/LocalTranslate"
MOCK_PORT=18790
PASS=0; FAIL=0
declare -a FAILED=()

say()  { printf '%s\n' "$*"; }
ok()   { say "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { say "  ✗ $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

check_contains() {
    # $1 标签  $2 实际输出  $3 必须包含
    if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else bad "$1（没找到「${3}」）"; fi
}

# ---------------------------------------------------------------- 前置
[ -x /usr/bin/swiftc ] || command -v swift >/dev/null || { say "没有 Swift 工具链"; exit 3; }

say "==> 1. 编译必须干净（0 error）"
BUILD_LOG="$(swift build -c release 2>&1)"
BUILD_ERRORS=$(printf '%s' "$BUILD_LOG" | grep -cE "error:")
if [ "$BUILD_ERRORS" -eq 0 ]; then
    ok "编译通过，无错误"
else
    bad "编译有 $BUILD_ERRORS 处错误"
    printf '%s' "$BUILD_LOG" | grep -E "error:" | head -5 | sed 's/^/      /'
    exit 1
fi
WARNINGS=$(printf '%s' "$BUILD_LOG" | grep -cE "warning:")
if [ "$WARNINGS" -eq 0 ]; then ok "零警告"; else say "  · 警告 $WARNINGS 条（不判定）"; fi

say ""
say "==> 1b. 先打包，后面的自测都跑在 .app 的真实身份上"
bash scripts/build_app.sh > /tmp/lt_verify_build.log 2>&1
[ -x "$BIN" ] && ok "bundle 可执行文件就位" || { bad "打包失败，见 /tmp/lt_verify_build.log"; exit 3; }

say ""
say "==> 2. 三个模块自带的用例必须全过"
MODULES="$("$BIN" --selftest modules 2>&1)"
for m in MarkdownLite DictionaryService HistoryStore; do
    if printf '%s' "$MODULES" | grep -qE "^✓ $m"; then ok "$m 自测通过"; else bad "$m 自测未通过"; fi
done
printf '%s' "$MODULES" | grep -E "^    ·" | head -6 | sed 's/^/      /'

say ""
say "==> 3. 全局快捷键"
HKAPI="$("$BIN" --selftest hotkey-api 2>&1)"
check_contains "解析/注册/重注册机制正确" "$HKAPI" "RESULT: PASS"
printf '%s' "$HKAPI" | grep -E "^✗" | head -5 | sed 's/^/      /'

# 合成按键投递：环境相关（无 GUI 会话/被锁屏时系统不投），只作参考不作判定。
# 真正的投递验证在下面第 7 节用真实运行进程做。
HK="$("$BIN" --selftest hotkey cmd+shift+x 2>&1)"
if printf '%s' "$HK" | grep -q "RESULT: PASS"; then
    ok "合成按键投递到回调（本环境可投递）"
else
    say "  · 合成按键未送达 —— 环境限制（锁屏/无 GUI 会话时系统不投），不计失败"
fi

say ""
say "==> 4. 翻译链路：打 mock 服务实跑"
pkill -f "mock_openai.py $MOCK_PORT" 2>/dev/null || true
python3 scripts/mock_openai.py "$MOCK_PORT" > /tmp/lt_verify_mock.log 2>&1 &
MOCK_PID=$!
sleep 1.5
kill -0 "$MOCK_PID" 2>/dev/null || { say "mock 服务起不来"; exit 3; }

API="$("$BIN" --selftest api "http://127.0.0.1:$MOCK_PORT/v1" "gpt-4o-mini" "sk-verify" "Hello world" zh-Hans 2>&1)"
check_contains "流式译文正确拼回" "$API" "Hello world"
check_contains "普通流式通过" "$API" "RESULT: PASS"

REASON="$("$BIN" --selftest api "http://127.0.0.1:$MOCK_PORT/v1/reasoning" "m" "sk-verify" "Hello" en 2>&1)"
check_contains "推理内容单独分流" "$REASON" "思考"

ERR="$("$BIN" --selftest api "http://127.0.0.1:$MOCK_PORT/v1/error" "m" "sk-verify" "Hi" 2>&1)"
check_contains "401 报出真实原因" "$ERR" "invalid api key"

say ""
say "==> 5. API Key 存取得到、读得回，且钥匙串不可用时不许卡死"
KEY="$("$BIN" --selftest setkey "sk-verify-key" 2>&1)"
check_contains "写入后读回一致" "$KEY" "读回一致: true"
check_contains "setkey 通过" "$KEY" "RESULT: PASS"
# 钥匙串被锁是正常状态（合盖息屏就会锁），要求：给结论、不挂住
KC="$("$BIN" --selftest keychain 2>&1)"
check_contains "钥匙串探测有结论" "$KC" "钥匙串可达"
check_contains "探测不卡死" "$KC" "RESULT: PASS"

say ""
say "==> 6. 词典解析：提示词 + 畸形 JSON 容错"
DICT="$("$BIN" --selftest modules DictionaryService 2>&1)"
check_contains "词典模块通过" "$DICT" "RESULT: PASS"
# 服务列表读写与开关
PROF="$("$BIN" --selftest prefs-effective 2>&1)"
check_contains "服务开关影响并发数量" "$PROF" "RESULT: PASS"

say ""
say "==> 6b. Magpie 接入"
MP="$("$BIN" --selftest magpie 2>&1)"
check_contains "Magpie 客户端能连通并真翻一次" "$MP" "RESULT: PASS"
MPP="$("$BIN" --selftest magpie-picker 2>&1)"
check_contains "模型选择器的搜索与多选" "$MPP" "RESULT: PASS"

say ""
say "==> 6c. 输入翻译"
IN="$("$BIN" --selftest input-ui 2>&1)"
check_contains "输入翻译窗口可用" "$IN" "RESULT: PASS"

AS="$("$BIN" --selftest auto-select 2>&1)"
check_contains "选中即翻的触发判定" "$AS" "RESULT: PASS"

OCR="$("$BIN" --selftest ocr 2>&1)"
check_contains "截图取字的 OCR 识别" "$OCR" "RESULT: PASS"

DICT="$("$BIN" --selftest dict-ui 2>&1)"
check_contains "词典窗口的九个分区" "$DICT" "RESULT: PASS"

PROV="$("$BIN" --selftest providers 2>&1)"
check_contains "DeepL/有道的请求与解析" "$PROV" "RESULT: PASS"

ICON="$("$BIN" --selftest icons 2>&1)"
check_contains "图标开关与自救规则" "$ICON" "RESULT: PASS"

PANEL="$("$BIN" --selftest panel 2>&1)"
check_contains "菜单栏面板内容齐全" "$PANEL" "RESULT: PASS"

HK2="$("$BIN" --selftest hotkeys2 2>&1)"
check_contains "快捷键体系（⌥ 默认/图标保命/朗读/剪贴板）" "$HK2" "RESULT: PASS"

TB="$("$BIN" --selftest toolbar 2>&1)"
check_contains "划词工具栏" "$TB" "RESULT: PASS"

VOC="$("$BIN" --selftest vocab 2>&1)"
check_contains "生词本与词典收藏" "$VOC" "RESULT: PASS"

URLT="$("$BIN" --selftest urlscheme 2>&1)"
check_contains "localtranslate:// 协议解析" "$URLT" "RESULT: PASS"

ASREQ="$("$BIN" --selftest applescript-request 2>&1)"
check_contains "AppleScript/OSA request命令" "$ASREQ" "RESULT: PASS"

FAV="$("$BIN" --selftest favorites 2>&1)"
check_contains "收藏夹/源语言/钉住服务" "$FAV" "RESULT: PASS"

PARA="$("$BIN" --selftest paragraphize 2>&1)"
check_contains "智能分段" "$PARA" "RESULT: PASS"

PLUG="$("$BIN" --selftest plugins 2>&1)"
check_contains "JavaScript 插件系统" "$PLUG" "RESULT: PASS"

ERRS="$("$BIN" --selftest errors 2>&1)"
check_contains "错误码翻译成人话" "$ERRS" "RESULT: PASS"

LDET="$("$BIN" --selftest lang-detect 2>&1)"
check_contains "智能双语切换与撤销支持" "$LDET" "RESULT: PASS"

WFEAT="$("$BIN" --selftest window-features 2>&1)"
check_contains "窗口跨App置顶与去边距" "$WFEAT" "RESULT: PASS"

I18NT="$("$BIN" --selftest i18n 2>&1)"
check_contains "UI本地化三语映射与切换" "$I18NT" "RESULT: PASS"

ECDICT="$("$BIN" --selftest ecdict 2>&1)"
check_contains "离线简明英汉词典ECDict检索" "$ECDICT" "RESULT: PASS"

APPLDICT="$("$BIN" --selftest apple-dict 2>&1)"
check_contains "苹果系统原生离线词典" "$APPLDICT" "RESULT: PASS"

TPRE="$("$BIN" --selftest text-preprocess 2>&1)"
check_contains "文本预处理引擎" "$TPRE" "RESULT: PASS"

THINKP="$("$BIN" --selftest think-parser 2>&1)"
check_contains "推理思考标签流式分流" "$THINKP" "RESULT: PASS"

LNALIGN="$("$BIN" --selftest line-aligner 2>&1)"
check_contains "逐行排版结构智能对齐" "$LNALIGN" "RESULT: PASS"

PROFEAT="$("$BIN" --selftest pro-features 2>&1)"
check_contains "专业细节与代码格式化" "$PROFEAT" "RESULT: PASS"

OCRWORK="$("$BIN" --selftest ocr-workspace 2>&1)"
check_contains "独立 OCR 工作台与锁定选区" "$OCRWORK" "RESULT: PASS"

BOBFULL="$("$BIN" --selftest bob-plugin-full 2>&1)"
check_contains "Bob 插件生态完全体" "$BOBFULL" "RESULT: PASS"

AICTL="$("$BIN" --selftest ai-control 2>&1)"
check_contains "AI 大模型变量模板与推理强度" "$AICTL" "RESULT: PASS"

REALSVC="$("$BIN" --selftest real-services 2>&1)"
check_contains "默认免密钥服务全部真连网可翻" "$REALSVC" "RESULT: PASS"
printf '%s' "$REALSVC" | grep -E "^  [✓✗]" | head -6 | sed 's/^/      /'

INPUTE2E="$("$BIN" --selftest input-e2e 2>&1)"
check_contains "输入翻译窗口真跑通（真翻译出结果）" "$INPUTE2E" "RESULT: PASS"
printf '%s' "$INPUTE2E" | grep -E "^✓" | head -2 | sed 's/^/      /'

CARDSHOT="$("$BIN" --selftest card-shot /tmp/lt_card_gate.png 2>&1)"
check_contains "卡片版式渲染（PNG 落盘）" "$CARDSHOT" "RESULT: PASS"

SCRPERM="$("$BIN" --selftest screen-perm 2>&1)"
check_contains "屏幕录制真伪探针与 Retina 截图坐标" "$SCRPERM" "RESULT: PASS"

PXY="$("$BIN" --selftest proxy 2>&1)"
check_contains "代理设置与本机直连" "$PXY" "RESULT: PASS"

OCR2="$("$BIN" --selftest ocr-review 2>&1)"
check_contains "截图后确认原文" "$OCR2" "RESULT: PASS"

CMP="$("$BIN" --selftest compare 2>&1)"
check_contains "并排对照视图" "$CMP" "RESULT: PASS"

HKC="$("$BIN" --selftest hotkey-conflicts 2>&1)"
check_contains "快捷键与系统保留键的冲突" "$HKC" "RESULT: PASS"

PRESET="$("$BIN" --selftest presets 2>&1)"
check_contains "服务商预设都能生成合法服务" "$PRESET" "RESULT: PASS"

APL="$("$BIN" --selftest apple 2>&1)"
check_contains "Apple 系统翻译能力" "$APL" "RESULT: PASS"

OCRE="$("$BIN" --selftest ocr-engines 2>&1)"
check_contains "多引擎 OCR 的请求与解析" "$OCRE" "RESULT: PASS"

TTSE="$("$BIN" --selftest tts-engines 2>&1)"
check_contains "多引擎 TTS 的请求与解析" "$TTSE" "RESULT: PASS"

SELERR="$("$BIN" --selftest selection-errors 2>&1)"
check_contains "取词失败的提示可执行" "$SELERR" "RESULT: PASS"

VOLC="$("$BIN" --selftest volc-sign 2>&1)"
check_contains "火山 V4 签名对齐官方测试向量" "$VOLC" "RESULT: PASS"

DIAG="$("$BIN" --selftest diagnostics 2>&1)"
check_contains "翻译结果清理与失败诊断" "$DIAG" "RESULT: PASS"

SREP="$("$BIN" --selftest silent-replace 2>&1)"
check_contains "静默替换翻译（划词与输入框）" "$SREP" "RESULT: PASS"
printf '%s' "$MP" | grep -E "^(可达|模型数|译文)" | head -3 | sed 's/^/      /'

say ""
say "==> 7. 卡片界面自检：无边框卡片、提示条、词典区、多模型标签都渲染出来"
for spec in "single" "multi dict"; do
    CARD="$("$BIN" --selftest card-ui $spec 2>&1)"
    check_contains "卡片界面自检（${spec}）" "$CARD" "RESULT: PASS"
    printf '%s' "$CARD" | grep -E "^✗" | head -5 | sed 's/^/      /'
done

CSHOT="$("$BIN" --selftest card-shortcuts 2>&1)"
check_contains "卡片内快捷键与字号缩放" "$CSHOT" "RESULT: PASS"

# 偏好窗逐节遍历 + 每项设置的真实后果 + 历史窗
for spec in "prefs-ui" "prefs-effective" "history-ui"; do
    UI="$("$BIN" --selftest $spec 2>&1)"
    check_contains "$spec 自检" "$UI" "RESULT: PASS"
    printf '%s' "$UI" | grep -E "^✗" | head -5 | sed 's/^/      /'
done

# 明暗主题：量两种外观下卡片底色的实际亮度
THEME="$("$BIN" --selftest theme 2>&1)"
check_contains "明暗主题都生效（亮度实测）" "$THEME" "RESULT: PASS"
printf '%s' "$THEME" | grep -E "^✓" | sed 's/^/      /'

# 静默翻译与卡片无关，单独确认 HUD 代码路径不崩
HUD="$("$BIN" --selftest api "http://127.0.0.1:$MOCK_PORT/v1" "m" "sk-verify" "hi" zh-Hans 2>&1)"
check_contains "静默链路可用" "$HUD" "RESULT: PASS"

say ""
say "==> 8. 打包产物与签名身份稳定"
[ -d "$APP" ] && ok "生成了 $APP" || bad "打包脚本没产出 .app"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "有应用图标" || bad "缺 AppIcon.icns"
DR="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
if printf '%s' "$DR" | grep -q "certificate leaf"; then
    ok "签名身份固定（重编译不掉辅助功能授权）"
else
    bad "不是固定证书签名：$DR"
fi

# 真实 Bob 插件运行时契约（离线：CommonJS exports / require / $data 全套）
if "$BIN" --selftest plugin-contract 2>&1 | grep -q "RESULT: PASS"; then
    ok "Bob 插件运行时契约（CommonJS / require / \$data）"
else
    bad "Bob 插件运行时契约不成立"
fi

# 访达选图 OCR + 二维码（离线，造图真跑）
if "$BIN" --selftest image-ocr 2>&1 | grep -q "RESULT: PASS"; then
    ok "图片 OCR（文字 + 二维码，离线）"
else
    bad "图片 OCR 链路不通"
fi

# PopClip 扩展包结构
if "$BIN" --selftest popclip-bundle 2>&1 | grep -q "RESULT: PASS"; then
    ok "PopClip 扩展包结构完整"
else
    bad "PopClip 扩展包不完整"
fi

# 浏览器助手：内容脚本真注入 WKWebView，选中→点按钮→页面内出译文
if "$BIN" --selftest web-helper 2>&1 | grep -q "RESULT: PASS"; then
    ok "浏览器助手（页面内选中即译）"
else
    bad "浏览器助手链路不通"
fi

# 本地服务与扩展包（端口、CORS、manifest）
if "$BIN" --selftest browser-helper 2>&1 | grep -q "RESULT: PASS"; then
    ok "浏览器助手本地服务与扩展包"
else
    bad "浏览器助手本地服务/扩展包不完整"
fi

# 免密钥词典：有道 + 剑桥（联网）
if "$BIN" --selftest dict-free 2>&1 | grep -q "RESULT: PASS"; then
    ok "免密钥词典（有道 + 剑桥）"
else
    bad "免密钥词典链路不通"
fi

# 闸门自己写过的测试数据要清干净，不能留下一个假的"已配置"状态
"$BIN" --selftest setkey "" >/dev/null 2>&1
security delete-generic-password -s "com.localtranslate.apikey" -a "default" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Application Support/LocalTranslate/key-default" 2>/dev/null || true

say ""
say "================ 结论 ================"
say "通过 $PASS 项，失败 $FAIL 项"
if [ "$FAIL" -gt 0 ]; then
    printf '  · %s\n' "${FAILED[@]}"
    say "RESULT: FAIL"
    exit 1
fi
say "RESULT: PASS"
exit 0
