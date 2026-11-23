"""Implementación mínima del protocolo TabDisplay (docs/PROTOCOL.md) para las herramientas de prueba.

Solo biblioteca estándar. La usan mock_tablet.py y mock_mac.py.
"""

from __future__ import annotations

import json
import socket
import struct
import time

HEADER = struct.Struct(">BBHIQ")  # type, flags, reserved, length, timestampUs
TOUCH = struct.Struct(">BBBBfffI")
SCROLL = struct.Struct(">ffB")
MAX_PAYLOAD = 8 * 1024 * 1024
DEFAULT_PORT = 47800

HELLO, HELLO_ACK, CODEC_CONFIG, VIDEO_FRAME = 0x01, 0x02, 0x03, 0x04
TOUCH_MSG, SCROLL_MSG, KEYFRAME_REQUEST = 0x10, 0x11, 0x20
PING, PONG, STATS, BYE = 0x30, 0x31, 0x40, 0x7F
FLAG_KEYFRAME = 0x01

NAMES = {
    HELLO: "HELLO", HELLO_ACK: "HELLO_ACK", CODEC_CONFIG: "CODEC_CONFIG", VIDEO_FRAME: "VIDEO_FRAME",
    TOUCH_MSG: "TOUCH", SCROLL_MSG: "SCROLL", KEYFRAME_REQUEST: "KEYFRAME_REQUEST",
    PING: "PING", PONG: "PONG", STATS: "STATS", BYE: "BYE",
}
TOUCH_ACTIONS = ["down", "move", "up", "cancel", "hover_move", "hover_exit"]
TOOL_TYPES = ["dedo", "stylus", "borrador"]
SCROLL_PHASES = ["began", "changed", "ended", "momentum"]


class ProtocolError(Exception):
    pass


def now_us() -> int:
    return time.monotonic_ns() // 1000


def encode(msg_type: int, payload: bytes = b"", flags: int = 0, timestamp_us: int | None = None) -> bytes:
    ts = now_us() if timestamp_us is None else timestamp_us
    return HEADER.pack(msg_type, flags, 0, len(payload), ts) + payload


def encode_json(msg_type: int, value) -> bytes:
    return encode(msg_type, json.dumps(value, ensure_ascii=False).encode("utf-8"))


def recv_exact(sock: socket.socket, n: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < n:
        chunk = sock.recv(n - len(chunks))
        if not chunk:
            raise EOFError("conexión cerrada")
        chunks += chunk
    return bytes(chunks)


def read_message(sock: socket.socket):
    """Devuelve (type, flags, timestampUs, payload)."""
    msg_type, flags, _reserved, length, ts = HEADER.unpack(recv_exact(sock, HEADER.size))
    if length > MAX_PAYLOAD:
        raise ProtocolError(f"payload de {length} bytes")
    payload = recv_exact(sock, length) if length else b""
    return msg_type, flags, ts, payload


def encode_touch(action: int, pointer_id: int, tool: int, buttons: int, x: float, y: float, pressure: float) -> bytes:
    return TOUCH.pack(action, pointer_id, tool, buttons, x, y, pressure, 0)


def describe_touch(payload: bytes) -> str:
    action, pid, tool, buttons, x, y, pressure, _ = TOUCH.unpack(payload[:TOUCH.size])
    name = TOUCH_ACTIONS[action] if action < len(TOUCH_ACTIONS) else f"?{action}"
    tool_name = TOOL_TYPES[tool] if tool < len(TOOL_TYPES) else f"?{tool}"
    button = " +botón" if buttons & 1 else ""
    return f"{name:<10} id={pid} {tool_name}{button} x={x:.3f} y={y:.3f} p={pressure:.2f}"


def describe_scroll(payload: bytes) -> str:
    dx, dy, phase = SCROLL.unpack(payload[:SCROLL.size])
    name = SCROLL_PHASES[phase] if phase < len(SCROLL_PHASES) else f"?{phase}"
    return f"{name:<9} dx={dx:+.1f} dy={dy:+.1f} px"


# --- Annex B (H.264) ---

def split_nals(data: bytes):
    """Divide un flujo Annex B en NAL units (sin start codes)."""
    starts = []
    i = data.find(b"\x00\x00\x01")
    while i != -1:
        starts.append(i + 3)
        i = data.find(b"\x00\x00\x01", i + 3)
    nals = []
    for k, start in enumerate(starts):
        end = starts[k + 1] - 3 if k + 1 < len(starts) else len(data)
        # Un start code de 4 bytes deja un 0 extra al final de la NAL anterior.
        while end > start and data[end - 1] == 0 and k + 1 < len(starts):
            end -= 1
        nals.append(data[start:end])
    return nals


def h264_access_units(data: bytes):
    """Agrupa NALs H.264 en access units. Devuelve [(is_idr, config_annexb | None, frame_annexb)]."""
    sc = b"\x00\x00\x00\x01"
    units = []
    config = []
    current = []
    current_has_vcl = False
    current_idr = False

    def flush():
        nonlocal current, current_has_vcl, current_idr
        if current_has_vcl:
            cfg = b"".join(sc + n for n in config) if current_idr and config else None
            units.append((current_idr, cfg, b"".join(sc + n for n in current)))
        current, current_has_vcl, current_idr = [], False, False

    for nal in split_nals(data):
        if not nal:
            continue
        nal_type = nal[0] & 0x1F
        if nal_type in (7, 8):  # SPS / PPS → CODEC_CONFIG
            if current_has_vcl:
                flush()
            if nal_type == 7:
                config = [nal]
            else:
                config.append(nal)
            continue
        if nal_type in (1, 5):
            first_mb_zero = len(nal) > 1 and (nal[1] & 0x80) != 0
            if current_has_vcl and first_mb_zero:
                flush()
            current.append(nal)
            current_has_vcl = True
            current_idr = current_idr or nal_type == 5
        else:
            if nal_type in (6, 9) and current_has_vcl:  # SEI / AUD abren una nueva AU
                flush()
            if nal_type != 9:
                current.append(nal)
    flush()
    return units
