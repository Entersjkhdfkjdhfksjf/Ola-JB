#!/usr/bin/env python3
"""
ola.py -- talk to an Ola S1 / S1 Pro head unit over its root gRPC
diagnostics channel (TCP port 50005, IPv6 link-local).

This is an independent, clean-room implementation written from scratch
against the observed wire protocol. It does not share code with, and is
not derived from, any other project. No authentication, no adb, no
pairing is used or required -- the daemon on the scooter accepts plain
IPv6 connections on its own.

    python ola.py settings   --ipv6 fe80::1234:5678:9abc:def0%6
    python ola.py browser    --ipv6 fe80::1234:5678:9abc:def0%6
    python ola.py info       --ipv6 fe80::1234:5678:9abc:def0%6
    python ola.py shell "ls -l /data/local/tmp" --ipv6 ...
    python ola.py screenshot dash.png --ipv6 ...

A link-local address (fe80::...) needs an interface scope id, either
appended with "%6" or passed separately as --scope 6.

Commands run as root but NOT in a shell by default -- `shell` base64
encodes your command and pipes it into `sh`, so quoting, spaces and
redirection all survive the daemon's naive whitespace-split transport.
Pass --raw to send a command exactly as typed instead.
"""
from __future__ import annotations

import argparse
import base64
import sys
import time

try:
    import grpc
except ImportError:
    sys.exit("Missing grpcio. Run:  python -m pip install -r requirements.txt")

PORT = 50005
MAX_MSG = 64 << 20
METHOD = "/wifican.WifiCanRpc/ExecuteADBCommand"

# Stock Android framework intents -- these open real system screens that
# ship with every AOSP build. No root writes, no vehicle state touched.
INTENTS = {
    "settings": "android.settings.SETTINGS",
    "wifi": "android.settings.WIFI_SETTINGS",
    "bluetooth": "android.settings.BLUETOOTH_SETTINGS",
    "apps": "android.settings.APPLICATION_SETTINGS",
    "display": "android.settings.DISPLAY_SETTINGS",
    "sound": "android.settings.SOUND_SETTINGS",
    "about": "android.settings.DEVICE_INFO_SETTINGS",
    "date": "android.settings.DATE_SETTINGS",
}

KEY_EVENTS = {"back": 4, "recents": 187, "power": 26}

HMI_ACTIVITY = "com.olaelectric.hmiclient/.MainActivity"

# Common AOSP browser package/activity pairs. We try each in turn since
# which one (if any) ships depends on the exact MoveOS build.
BROWSER_CANDIDATES = [
    "com.android.browser/.BrowserActivity",
    "com.android.htmlviewer/.HTMLViewerActivity",
]


# --------------------------------------------------------------------------
# Minimal hand-rolled protobuf encode/decode.
#
# The daemon is weakly typed (it just reads a `command` string field and
# returns a `status` int + `message` string), so a full .proto / codegen
# step isn't needed -- these few lines of wire-format varint handling are
# the entire "schema".
# --------------------------------------------------------------------------

def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


def _encode_command(text: str) -> bytes:
    """Field 1, wire type 2 (length-delimited string) -- the `command` field."""
    raw = text.encode("utf-8")
    return _varint((1 << 3) | 2) + _varint(len(raw)) + raw


def _decode_reply(buf: bytes) -> tuple[int, str]:
    """Field 1 = status (varint), field 2 = message (string)."""
    fields: dict[int, object] = {}
    i = 0
    while i < len(buf):
        key, i = _read_varint(buf, i)
        field_no, wire_type = key >> 3, key & 0b111
        if wire_type == 0:
            fields[field_no], i = _read_varint(buf, i)
        elif wire_type == 2:
            length, i = _read_varint(buf, i)
            fields[field_no] = buf[i:i + length].decode("utf-8", "replace")
            i += length
        else:
            break  # unknown wire type; nothing else to decode safely
    return fields.get(1, 0), fields.get(2, "")


def _read_varint(buf: bytes, i: int) -> tuple[int, int]:
    value = shift = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7
    return value, i  # truncated reply -- don't raise, just stop


# --------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------

def build_target(host: str, port: int, scope: int | None) -> str:
    h = host.strip().strip("[]")
    if h.count(":") >= 2:  # looks like IPv6
        if h.lower().startswith("fe80") and "%" not in h:
            if scope is None:
                raise SystemExit(
                    "Link-local address needs an interface scope.\n"
                    "  --ipv6 fe80::1234:5678:9abc:def0%6   or   --scope 6")
            h = f"{h}%{scope}"
        h = h.replace("%", "%25") if "%25" not in h else h
        return f"ipv6:[{h}]:{port}"
    return f"{h}:{port}"


def connect(target: str, wait: float):
    channel = grpc.insecure_channel(
        target,
        options=[("grpc.max_receive_message_length", MAX_MSG),
                 ("grpc.max_send_message_length", MAX_MSG)])
    try:
        grpc.channel_ready_future(channel).result(timeout=wait)
    except grpc.FutureTimeoutError:
        channel.close()
        raise SystemExit(
            f"No answer from {target} after {wait:.0f}s.\n"
            "Check the scooter is awake and you're on its Wi-Fi / hotspot.")
    return channel


def call(channel, command: str, timeout: float) -> tuple[int, str]:
    fn = channel.unary_unary(
        METHOD,
        request_serializer=lambda b: b,
        response_deserializer=lambda b: b)
    reply = fn(_encode_command(command), timeout=timeout)
    return _decode_reply(reply)


def run(channel, command: str, timeout: float = 30.0, quiet: bool = False) -> tuple[int, str]:
    status, message = call(channel, command, timeout)
    text = (message or "").strip()
    if text and not quiet:
        print(text)
    return status, text


def ok(status: int) -> bool:
    return status in (0, 1)


def shell_wrap(command: str) -> str:
    """Base64-wrap a command so the daemon's whitespace-split doesn't mangle
    quotes, spaces or redirection -- it pipes the decoded bytes into sh."""
    b64 = base64.b64encode(command.encode()).decode()
    return "sh -c echo${IFS}" + b64 + "|base64${IFS}-d|sh"


# --------------------------------------------------------------------------
# actions
# --------------------------------------------------------------------------

def show_top_activity(channel) -> None:
    _, out = run(
        channel,
        "sh -c dumpsys${IFS}activity${IFS}activities|"
        "grep${IFS}-E${IFS}ResumedActivity|head${IFS}-2",
        timeout=20, quiet=True)
    print("--- on screen now ---")
    print(out or "(no activity info)")


def open_intent(channel, action: str, timeout: float) -> int:
    status, _ = run(channel, f"am start -a {action}", timeout)
    time.sleep(1.2)
    show_top_activity(channel)
    return 0 if ok(status) else 1


def open_browser(channel, timeout: float) -> int:
    """Try each known AOSP browser component until one actually starts."""
    for component in BROWSER_CANDIDATES:
        status, out = run(channel, f"am start -n {component}", timeout, quiet=True)
        if ok(status) and "Error" not in out and "does not exist" not in out:
            print(f"opened {component}")
            time.sleep(1.2)
            show_top_activity(channel)
            return 0
    # Fall back to a generic VIEW intent, which Android routes to whatever
    # browser/webview handler is registered, if any.
    print("no known browser component found directly -- trying a VIEW intent")
    status, _ = run(channel, "am start -a android.intent.action.VIEW -d https://youtube.com", timeout)
    time.sleep(1.2)
    show_top_activity(channel)
    return 0 if ok(status) else 1


def go_home(channel, timeout: float) -> int:
    status, _ = run(channel, f"am start -n {HMI_ACTIVITY}", timeout)
    time.sleep(1.0)
    show_top_activity(channel)
    return 0 if ok(status) else 1


def send_key(channel, code: int, timeout: float) -> int:
    status, _ = run(channel, f"input keyevent {code}", timeout)
    return 0 if ok(status) else 1


def device_info(channel) -> int:
    checks = [
        ("uid", "id -u"),
        ("android", "getprop ro.build.version.release"),
        ("build", "getprop ro.build.display.id"),
        ("model", "getprop ro.product.model"),
        ("selinux", "getenforce"),
        ("uptime", "uptime"),
    ]
    for label, cmd in checks:
        _, out = run(channel, cmd, 15, quiet=True)
        print(f"{label:<10} {out.strip() or '-'}")
    return 0


def take_screenshot(channel, path: str) -> int:
    tmp = "/data/local/tmp/_ola_shot.png"
    status, out = run(channel, f"screencap -p {tmp}", 60, quiet=True)
    if not ok(status):
        raise SystemExit(f"screencap failed: {out}")
    status, encoded = run(channel, shell_wrap(f"base64 {tmp}"), 90, quiet=True)
    if not ok(status):
        raise SystemExit(f"read-back failed: {encoded}")
    with open(path, "wb") as fh:
        fh.write(base64.b64decode(encoded))
    run(channel, f"rm -f {tmp}", 15, quiet=True)
    print(f"saved {path}")
    return 0


def interactive_shell(channel, raw: bool) -> int:
    print("Root shell. Type a command, or 'exit'.")
    while True:
        try:
            line = input("ola> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if line in ("exit", "quit"):
            return 0
        if not line:
            continue
        cmd = line if raw else shell_wrap(line)
        try:
            run(channel, cmd, 60)
        except grpc.RpcError as exc:
            print(f"RPC error: {exc.code().name}: {exc.details()}")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ipv6", help="scooter address, e.g. fe80::1%%6")
    common.add_argument("--scope", type=int, help="interface number for a link-local address")
    common.add_argument("--port", type=int, default=PORT)
    common.add_argument("--timeout", type=float, default=30.0)
    common.add_argument("--wait", type=float, default=8.0)
    common.add_argument("--raw", action="store_true", help="skip the sh -c base64 wrapper")

    sub = parser.add_subparsers(dest="action", required=True)

    def add(name, **kw):
        return sub.add_parser(name, parents=[common], **kw)

    for name in INTENTS:
        add(name, help=f"open {name}")
    add("browser", help="open an AOSP browser if one is present")
    add("home", help="return to the dash")
    for name in KEY_EVENTS:
        add(name, help=f"send the {name} key")
    add("info", help="uid, Android build, uptime")
    add("top", help="show the resumed activity")

    shell_p = add("shell", help="run a root shell command")
    shell_p.add_argument("command", nargs=argparse.REMAINDER)

    shot_p = add("screenshot", help="save a PNG of the screen")
    shot_p.add_argument("path")

    args = parser.parse_args(argv)
    if not args.ipv6:
        parser.error("--ipv6 is required")

    target = build_target(args.ipv6, args.port, args.scope)
    channel = connect(target, args.wait)

    try:
        a = args.action
        if a in INTENTS:
            return open_intent(channel, INTENTS[a], args.timeout)
        if a == "browser":
            return open_browser(channel, args.timeout)
        if a == "home":
            return go_home(channel, args.timeout)
        if a in KEY_EVENTS:
            return send_key(channel, KEY_EVENTS[a], args.timeout)
        if a == "info":
            return device_info(channel)
        if a == "top":
            show_top_activity(channel)
            return 0
        if a == "shell":
            if not args.command:
                return interactive_shell(channel, args.raw)
            cmd = " ".join(args.command)
            status, _ = run(channel, cmd if args.raw else shell_wrap(cmd), args.timeout)
            return 0 if ok(status) else 1
        if a == "screenshot":
            return take_screenshot(channel, args.path)
        parser.error(f"unknown action: {a}")
    except grpc.RpcError as exc:
        print(f"RPC error: {exc.code().name}: {exc.details()}", file=sys.stderr)
        return 1
    finally:
        channel.close()
    return 1


if __name__ == "__main__":
    sys.exit(main())
