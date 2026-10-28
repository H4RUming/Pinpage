#!/usr/bin/env python3
"""개발용 가짜 OpenAI 호환 서버 (표준 라이브러리만 사용).

vLLM 없이 설정 탭의 모델 불러오기, 연결 테스트, 오류 메시지, 재시도를 확인하기 위한 도구다.

예:
  python3 Tools/mock_openai_server.py                      # http://127.0.0.1:8000
  python3 Tools/mock_openai_server.py --require-key sk-dev # 키 없으면 401
  python3 Tools/mock_openai_server.py --delay 15           # 응답 지연 (시간 초과 확인)
  python3 Tools/mock_openai_server.py --fail-first 2       # 처음 2번은 503 (재시도 확인)
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=8000)
parser.add_argument("--models", default="mock-chat-7b,mock-embed-small", help="쉼표로 구분한 모델 이름")
parser.add_argument("--require-key", default=None, help="이 키가 Bearer 헤더로 와야 응답")
parser.add_argument("--delay", type=float, default=0.0, help="모든 응답 전 대기 시간(초)")
parser.add_argument("--fail-first", type=int, default=0, help="처음 N번 요청은 503으로 실패")
parser.add_argument("--embedding-dim", type=int, default=384)
args = parser.parse_args()

MODELS = [m.strip() for m in args.models.split(",") if m.strip()]
state = {"requests": 0}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _gate(self):
        """공통 처리: 지연, 일부러 실패, 키 확인. 응답을 보냈으면 True."""
        state["requests"] += 1
        auth = self.headers.get("Authorization")
        print(f"#{state['requests']} {self.command} {self.path} Authorization={'있음' if auth else '없음'}", flush=True)
        if args.delay:
            time.sleep(args.delay)
        if state["requests"] <= args.fail_first:
            self._send(503, {"object": "error", "message": "model is loading", "code": 503})
            return True
        if args.require_key and auth != f"Bearer {args.require_key}":
            self._send(401, {"error": {"message": "Unauthorized", "type": "auth_error"}})
            return True
        return False

    def _model_error(self, model):
        self._send(404, {"object": "error", "message": f"The model `{model}` does not exist.",
                         "type": "NotFoundError", "code": 404})

    def do_GET(self):
        if self._gate():
            return
        if self.path.rstrip("/") == "/v1/models":
            self._send(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": 0, "owned_by": "mock"} for m in MODELS]})
        else:
            self._send(404, {"detail": "Not Found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        if self._gate():
            return
        model = body.get("model", "")
        path = self.path.rstrip("/")
        if path == "/v1/chat/completions":
            if model not in MODELS:
                return self._model_error(model)
            self._send(200, {"id": "chatcmpl-mock", "object": "chat.completion", "model": model,
                             "choices": [{"index": 0, "finish_reason": "length",
                                          "message": {"role": "assistant", "content": "pong"}}]})
        elif path == "/v1/embeddings":
            if model not in MODELS:
                return self._model_error(model)
            inputs = body.get("input", [])
            inputs = [inputs] if isinstance(inputs, str) else inputs
            self._send(200, {"object": "list", "model": model, "data": [
                {"object": "embedding", "index": i, "embedding": [0.01] * args.embedding_dim}
                for i, _ in enumerate(inputs)]})
        else:
            self._send(404, {"detail": "Not Found"})

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    print(f"mock OpenAI server: http://{args.host}:{args.port}/v1  models={MODELS}", flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
