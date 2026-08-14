"""Private OpenMRS OAuth bridge for Bahmni connectors that only support Basic auth.

The bridge never exposes a public port. It strips the connector Authorization
header, obtains a Keycloak client-credentials token, injects Bearer, caches it,
and retries exactly once after an upstream 401.
"""

from __future__ import annotations

import http.client
import json
import os
import ssl
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def read_secret() -> str:
    path = required("OIDC_CLIENT_SECRET_FILE")
    with open(path, "r", encoding="utf-8") as stream:
        value = stream.read().strip()
    if not value:
        raise RuntimeError("OIDC client secret file is empty")
    return value


class TokenCache:
    def __init__(self) -> None:
        self._token = ""
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def invalidate(self) -> None:
        with self._lock:
            self._token = ""
            self._expires_at = 0.0

    def get(self) -> str:
        with self._lock:
            if self._token and time.monotonic() < self._expires_at:
                return self._token
            token_url = urllib.parse.urlsplit(required("OIDC_TOKEN_URL"))
            payload = urllib.parse.urlencode({
                "grant_type": "client_credentials",
                "client_id": required("OIDC_CLIENT_ID"),
                "client_secret": read_secret(),
                "scope": "openid",
            })
            connection = connection_for(token_url.scheme, token_url.hostname or "", token_url.port)
            path = token_url.path + (("?" + token_url.query) if token_url.query else "")
            connection.request("POST", path, payload, {
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            })
            response = connection.getresponse()
            body = response.read()
            connection.close()
            if response.status != 200:
                raise RuntimeError(f"Identity provider rejected client credentials with HTTP {response.status}")
            document = json.loads(body)
            token = document.get("access_token")
            if not isinstance(token, str) or not token:
                raise RuntimeError("Identity provider response does not contain an access token")
            expires_in = max(int(document.get("expires_in", 60)), 1)
            self._token = token
            self._expires_at = time.monotonic() + max(expires_in - 30, 1)
            return token


def connection_for(scheme: str, host: str, port: int | None) -> http.client.HTTPConnection:
    timeout = float(os.environ.get("HTTP_TIMEOUT_SECONDS", "60"))
    if scheme == "https":
        verify = os.environ.get("UPSTREAM_TLS_VERIFY", "true").lower() == "true"
        context = ssl.create_default_context() if verify else ssl._create_unverified_context()
        return http.client.HTTPSConnection(host, port or 443, timeout=timeout, context=context)
    return http.client.HTTPConnection(host, port or 80, timeout=timeout)


def upstream_headers(
    incoming: list[tuple[str, str]], host: str, token: str, body_length: int | None
) -> dict[str, str]:
    headers = {
        name: value for name, value in incoming
        if name.lower() not in HOP_BY_HOP and name.lower() not in {"authorization", "host", "content-length"}
    }
    headers["Authorization"] = f"Bearer {token}"
    headers["Host"] = host
    if body_length is not None:
        headers["Content-Length"] = str(body_length)
    return headers


TOKENS = TokenCache()


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # Do not record URLs, identifiers, headers or clinical payloads.
        print(f"openmrs-token-bridge status={args[1] if len(args) > 1 else 'unknown'}", flush=True)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._reply(200, b'{"status":"ok"}', "application/json")
            return
        self._proxy()

    do_POST = do_GET
    do_PUT = do_GET
    do_PATCH = do_GET
    do_DELETE = do_GET
    do_OPTIONS = do_GET
    do_HEAD = do_GET

    def _proxy(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request_body = self.rfile.read(length) if length else None
            status, reason, headers, body = self._request_upstream(TOKENS.get(), request_body)
            if status == 401:
                TOKENS.invalidate()
                status, reason, headers, body = self._request_upstream(TOKENS.get(), request_body)
            self.send_response(status, reason)
            for name, value in headers:
                if name.lower() not in HOP_BY_HOP and name.lower() not in {"content-length", "server", "date"}:
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except Exception as error:  # no secrets or request details in the response/log
            print(f"openmrs-token-bridge upstream_error={type(error).__name__}", flush=True)
            self._reply(502, b'{"error":"OpenMRS authentication bridge unavailable"}', "application/json")

    def _request_upstream(self, token: str, body: bytes | None) -> tuple[int, str, list[tuple[str, str]], bytes]:
        scheme = os.environ.get("UPSTREAM_SCHEME", "https")
        host = required("UPSTREAM_HOST")
        port = int(os.environ.get("UPSTREAM_PORT", "443" if scheme == "https" else "80"))
        connection = connection_for(scheme, host, port)
        headers = upstream_headers(list(self.headers.items()), host, token, len(body) if body is not None else None)
        connection.request(self.command, self.path, body=body, headers=headers)
        response = connection.getresponse()
        response_body = response.read()
        result = response.status, response.reason, response.getheaders(), response_body
        connection.close()
        return result

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), BridgeHandler)
    server.serve_forever()
