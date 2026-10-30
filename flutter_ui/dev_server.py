"""Serve Flutter's web build and proxy Django paths on one local origin."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parent
BUILD = PROJECT_ROOT / "flutter" / "flutter_application_1" / "build" / "web"
DJANGO = "http://127.0.0.1:8001"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(BUILD), **kwargs)

    def _proxy(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in {"host", "content-length", "connection"}}
        headers["Host"] = self.headers.get("Host", "127.0.0.1:8080")
        request = Request(DJANGO + self.path, data=body or None,
                          headers=headers, method=self.command)
        try:
            upstream = urlopen(request, timeout=30)
            status, response_headers, response_body = upstream.status, upstream.headers, upstream.read()
        except HTTPError as error:
            status, response_headers, response_body = error.code, error.headers, error.read()
        except URLError as error:
            response_body = str(error).encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(response_body)
            return
        self.send_response(status)
        for key, value in response_headers.items():
            if key.lower() not in {"transfer-encoding", "connection", "content-length", "set-cookie"}:
                self.send_header(key, value)
        for cookie in response_headers.get_all("Set-Cookie", []):
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(response_body)

    def do_GET(self):
        if self.path.startswith(("/api/", "/static/")):
            return self._proxy()
        return super().do_GET()

    def do_HEAD(self):
        if self.path.startswith(("/api/", "/static/")):
            return self._proxy()
        return super().do_HEAD()

    def do_POST(self):
        return self._proxy()


if __name__ == "__main__":
    if not (BUILD / "index.html").exists():
        raise SystemExit("Flutter web build missing. Run the project launcher from the repository root first.")
    print("PMMS preview: http://127.0.0.1:8080")
    print("Django API:   http://127.0.0.1:8001/api/v1/")
    ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
