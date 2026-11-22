#!/usr/bin/env python3
"""Open LeetCode's login page in a browser this script controls, then print the
cookie header once the user has signed in.

The browser is a normal Chrome (or Chromium, Edge, or Brave) window with its
own profile, so it does not touch the user's everyday browser. Cookies are
read through the browser's local debugging port, which listens only on
127.0.0.1.

Prints one line, "COOKIE <header>", when LEETCODE_SESSION appears. Progress
goes to stderr.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlparse

LOGIN_URL = "https://leetcode.com/accounts/login/"


def browsers():
    home = Path.home()
    found = []
    mac = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        str(home / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    ]
    linux = [
        "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
        "microsoft-edge", "brave-browser",
    ]
    windows = [
        os.environ.get("PROGRAMFILES", "") + r"\Google\Chrome\Application\chrome.exe",
        os.environ.get("PROGRAMFILES(X86)", "") + r"\Google\Chrome\Application\chrome.exe",
        os.environ.get("LOCALAPPDATA", "") + r"\Google\Chrome\Application\chrome.exe",
        os.environ.get("PROGRAMFILES", "") + r"\Microsoft\Edge\Application\msedge.exe",
    ]
    for path in mac + windows:
        if path and os.path.isfile(path):
            found.append(path)
    for name in linux:
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            candidate = os.path.join(directory, name)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                found.append(candidate)
    return found


def http_json(url, timeout=2):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def port_open(port):
    try:
        http_json("http://127.0.0.1:%d/json/version" % port, timeout=0.4)
        return True
    except Exception:
        return False


def launch(binary, profile, port):
    profile.mkdir(parents=True, exist_ok=True)
    subprocess.Popen(
        [
            binary,
            "--remote-debugging-port=%d" % port,
            "--remote-allow-origins=*",
            "--user-data-dir=%s" % profile,
            "--no-first-run",
            "--no-default-browser-check",
            LOGIN_URL,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def open_tab(port):
    quoted = quote(LOGIN_URL, safe="")
    try:
        http_json("http://127.0.0.1:%d/json/new?%s" % (port, quoted), timeout=3)
    except Exception:
        pass


class SocketWebSocket:
    """Just enough of a WebSocket client to exchange one JSON message at a time."""

    def __init__(self, url):
        parsed = urlparse(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=5)
        self.sock.settimeout(5)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (path, parsed.hostname, parsed.port or 80, key)
        )
        self.sock.sendall(request.encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("debugging port closed the connection")
            data += chunk
        status = data.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise RuntimeError("debugging port refused the connection: %s" % status.decode("latin1", "replace"))
        self.pending = data.split(b"\r\n\r\n", 1)[1]

    def send(self, text):
        payload = text.encode()
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack(">Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self):
        buffer = self.pending
        self.pending = b""
        parts = []
        while True:
            while len(buffer) < 2:
                buffer += self._read()
            first, second = buffer[0], buffer[1]
            offset = 2
            size = second & 0x7F
            if size == 126:
                while len(buffer) < 4:
                    buffer += self._read()
                size = struct.unpack(">H", buffer[2:4])[0]
                offset = 4
            elif size == 127:
                while len(buffer) < 10:
                    buffer += self._read()
                size = struct.unpack(">Q", buffer[2:10])[0]
                offset = 10
            mask = b""
            if second & 0x80:
                while len(buffer) < offset + 4:
                    buffer += self._read()
                mask = buffer[offset:offset + 4]
                offset += 4
            while len(buffer) < offset + size:
                buffer += self._read()
            payload = buffer[offset:offset + size]
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            buffer = buffer[offset + size:]
            opcode = first & 0x0F
            if opcode == 0x8:
                raise RuntimeError("debugging connection closed")
            if opcode == 0x9:
                continue
            if opcode in (0x1, 0x2):
                parts = [payload]
            elif opcode == 0x0:
                parts.append(payload)
            if first & 0x80 and parts and opcode != 0x0 or (first & 0x80 and opcode == 0x0 and parts):
                if opcode == 0x0 or opcode == 0x1:
                    self.pending = buffer
                    return b"".join(parts).decode("utf-8")

    def _read(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise RuntimeError("debugging connection ended")
        return chunk

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def _command(connection, message_id, method, params=None, session_id=None):
    message = {"id": message_id, "method": method}
    if params:
        message["params"] = params
    if session_id:
        message["sessionId"] = session_id
    connection.send(json.dumps(message))
    deadline = time.time() + 5
    while time.time() < deadline:
        reply = json.loads(connection.recv())
        if reply.get("id") != message_id:
            continue
        if reply.get("error"):
            raise RuntimeError(reply["error"].get("message") or "browser command failed")
        return reply.get("result") or {}
    raise RuntimeError("browser command timed out")


def cookie_header(port):
    """Read leetcode.com cookies. Current Chrome builds reject Network.getAllCookies
    on the browser socket, so attach to a tab first."""
    version = http_json("http://127.0.0.1:%d/json/version" % port)
    socket_url = version.get("webSocketDebuggerUrl")
    if not socket_url:
        return None
    connection = SocketWebSocket(socket_url)
    try:
        targets = _command(connection, 1, "Target.getTargets").get("targetInfos") or []
        page = next((item for item in targets if item.get("type") == "page"), None)
        if page is None:
            created = _command(connection, 2, "Target.createTarget", {"url": "about:blank"})
            page = {"targetId": created.get("targetId")}
        attached = _command(
            connection, 3, "Target.attachToTarget",
            {"targetId": page["targetId"], "flatten": True},
        )
        cookies = _command(
            connection, 4, "Network.getAllCookies", session_id=attached.get("sessionId"),
        ).get("cookies") or []
        pairs = []
        signed_in = False
        for cookie in cookies:
            domain = cookie.get("domain") or ""
            if "leetcode.com" not in domain:
                continue
            pairs.append("%s=%s" % (cookie.get("name", ""), cookie.get("value", "")))
            if cookie.get("name") == "LEETCODE_SESSION" and cookie.get("value"):
                signed_in = True
        if signed_in:
            return "; ".join(pairs)
        return None
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description="Capture a LeetCode cookie after a browser login.")
    parser.add_argument("--profile", required=True, help="Browser profile directory. It is created if missing.")
    parser.add_argument("--port", type=int, default=9333)
    parser.add_argument("--timeout", type=int, default=180, help="Seconds to wait for the user to finish signing in.")
    args = parser.parse_args()

    if not port_open(args.port):
        choices = browsers()
        if not choices:
            print("No Chrome, Chromium, Edge, or Brave browser was found.", file=sys.stderr)
            return 1
        print("Opening the LeetCode login page...", file=sys.stderr)
        launch(choices[0], Path(args.profile), args.port)
    else:
        print("Reopening the LeetCode login page...", file=sys.stderr)
        open_tab(args.port)

    deadline = time.time() + args.timeout
    announced = False
    reported_error = False
    while time.time() < deadline:
        try:
            header = cookie_header(args.port)
        except Exception as exc:
            header = None
            if not reported_error:
                print("Could not read cookies yet: %s" % exc, file=sys.stderr)
                reported_error = True
        if header:
            print("COOKIE " + header)
            print("Signed in. You can close the browser window.", file=sys.stderr)
            return 0
        if not announced:
            print("Sign in in the browser window. This window is only used for LeetCode.", file=sys.stderr)
            announced = True
        time.sleep(1)
    print("Timed out waiting for a LeetCode login.", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
