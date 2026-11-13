#!/usr/bin/env python3
"""Mock OpenAI 兼容服务，用来在没有真实 API Key 的情况下验证 LocalTranslate 全链路。

用法: mock_openai.py [port]

覆盖的场景：
  - 流式 chat/completions（SSE 分片）
  - 非流式（词典模式要的是整块 JSON）
  - 按请求里的 model 字段返回不同内容 → 验证多模型对比标签页
  - /reasoning/ 路径带 reasoning_content → 验证思考过程分流
  - /error/ 路径返回 401
  - system 提示是词典那套时返回词典 JSON → 验证词典区块渲染
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

DICTIONARY_JSON = json.dumps({
    "word": "pressure",
    "translations": [
        "n. 压力；压强；压迫",
        "v. 压；挤；施加压力",
    ],
    "phonetics": [
        {"type": "us", "value": "ˈpreʃɚ"},
        {"type": "uk", "value": "ˈpreʃə"},
    ],
    "parts": [
        {"part": "n.", "means": ["压力", "压强", "压迫", "心理压力"]},
        {"part": "vt.", "means": ["压", "挤", "施加压力", "逼迫"]},
    ],
    "exchanges": [
        {"name": "第三人称单数", "words": ["pressures"]},
        {"name": "现在分词", "words": ["pressuring"]},
        {"name": "过去式", "words": ["pressured"]},
    ],
    "collocations": [
        {"phrase": "under pressure", "translation": "处于压力之下"},
        {"phrase": "blood pressure", "translation": "血压"},
    ],
}, ensure_ascii=False)


def chunks_for(model):
    """按模型名给不同译文，模拟多模型对比。"""
    if "deepseek" in model:
        return ["【" + model + "】", "这是", "DeepSeek", "风格", "的", "译文", "。"]
    if "kimi" in model:
        return ["【" + model + "】", "Kimi", "版本", "的", "译文", "。"]
    return ["【" + model + "】", "Hello", " world", "，", "这是", "流式", "测试", "。"]


def is_dictionary_request(body):
    """词典那一路的 system 提示有明确特征，用它区分。"""
    for message in body.get("messages", []):
        if message.get("role") != "system":
            continue
        content = message.get("content", "") or ""
        if "phonetics" in content and "collocations" in content:
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except Exception:
            body = {}

        auth = self.headers.get("Authorization", "")
        if "Bearer" not in auth:
            self.send_error_json(401, {"error": {"message": "缺少 Authorization"}})
            return

        if "/error/" in self.path:
            self.send_error_json(401, {"error": {"message": "invalid api key"}})
            return

        model = body.get("model", "unknown")
        wants_dictionary = is_dictionary_request(body)

        # 非流式：词典要整块 JSON
        if not body.get("stream", False):
            content = DICTIONARY_JSON if wants_dictionary else "".join(chunks_for(model))
            payload = {"choices": [{"message": {"role": "assistant", "content": content}}]}
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # 流式
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        if "/reasoning/" in self.path:
            for piece in ["先判断词性", "，", "再给释义"]:
                self.write_sse({"choices": [{"delta": {"reasoning_content": piece}}]})
                time.sleep(0.02)

        pieces = [DICTIONARY_JSON] if wants_dictionary else chunks_for(model)
        for piece in pieces:
            self.write_sse({"choices": [{"delta": {"content": piece}}]})
            time.sleep(0.03)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def write_sse(self, obj):
        payload = "data: " + json.dumps(obj, ensure_ascii=False) + "\n\n"
        self.wfile.write(payload.encode("utf-8"))
        self.wfile.flush()

    def send_error_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock OpenAI server on http://127.0.0.1:{PORT}/v1", flush=True)
    server.serve_forever()
