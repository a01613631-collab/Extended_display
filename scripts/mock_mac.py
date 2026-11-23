#!/usr/bin/env python3
"""Mac simulada: prueba la app de Android sin la Mac.

Sirve un archivo H.264 Annex B por el protocolo TabDisplay y muestra los toques, scrolls y
estadísticas que manda la tablet. Con `adb reverse tcp:47800 tcp:47800` la tablet se conecta
a este script como si fuera la Mac.

Generar un video de prueba (2800×1752, sin B-frames, un keyframe por segundo):
  ffmpeg -f lavfi -i testsrc2=size=2800x1752:rate=60 -t 20 -c:v libx264 -tune zerolatency \\
         -profile:v high -g 60 -bf 0 -pix_fmt yuv420p test.h264

Uso:
  python3 scripts/mock_mac.py test.h264 --loop
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import threading
import time

import tdproto as p


def serve(conn: socket.socket, units, args) -> None:
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    send_lock = threading.Lock()

    def send(data: bytes) -> None:
        with send_lock:
            conn.sendall(data)

    msg_type, _, _, payload = p.read_message(conn)
    if msg_type != p.HELLO:
        send(p.encode(p.BYE, b"\x01"))
        return
    hello = json.loads(payload)
    print("HELLO:", json.dumps(hello, ensure_ascii=False))
    ack = {
        "protocolVersion": 1, "accepted": True, "codec": "video/avc",
        "streamWidthPx": args.width or hello["widthPx"], "streamHeightPx": args.height or hello["heightPx"],
        "fps": args.fps, "bitrate": 30_000_000,
        "pairingToken": base64.b64encode(os.urandom(32)).decode(), "macName": "mock_mac.py",
    }
    send(p.encode_json(p.HELLO_ACK, ack))

    stop = threading.Event()
    keyframe_wanted = threading.Event()

    def reader() -> None:
        try:
            while not stop.is_set():
                t, _, ts, data = p.read_message(conn)
                if t == p.PING:
                    send(p.encode(p.PONG, ts.to_bytes(8, "big")))
                elif t == p.TOUCH_MSG:
                    print("TOUCH ", p.describe_touch(data))
                elif t == p.SCROLL_MSG:
                    print("SCROLL", p.describe_scroll(data))
                elif t == p.KEYFRAME_REQUEST:
                    print("KEYFRAME_REQUEST (se salta al siguiente IDR del archivo)")
                    keyframe_wanted.set()
                elif t == p.STATS:
                    print("STATS ", data.decode())
                elif t == p.BYE:
                    print(f"BYE de la tablet, motivo {data[0] if data else '?'}")
                    break
        except (EOFError, OSError):
            pass
        stop.set()

    threading.Thread(target=reader, daemon=True).start()

    interval = 1.0 / args.fps
    next_time = time.monotonic()
    index = 0
    sent = 0
    try:
        while not stop.is_set():
            is_idr, config, frame = units[index]
            if keyframe_wanted.is_set() and not is_idr:
                index = (index + 1) % len(units)
                continue
            keyframe_wanted.clear()
            ts = p.now_us()
            if is_idr and config:
                send(p.encode(p.CODEC_CONFIG, config, timestamp_us=ts))
            send(p.encode(p.VIDEO_FRAME, frame, flags=p.FLAG_KEYFRAME if is_idr else 0, timestamp_us=ts))
            sent += 1
            index += 1
            if index >= len(units):
                if not args.loop:
                    break
                index = 0  # el archivo empieza con IDR, así que el bucle es válido
            next_time += interval
            delay = next_time - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_time = time.monotonic()
    except OSError:
        pass
    finally:
        stop.set()
        try:
            send(p.encode(p.BYE, b"\x00"))
        except OSError:
            pass
        conn.close()
        print(f"Sesión terminada: {sent} cuadros enviados")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video", help="archivo H.264 Annex B")
    ap.add_argument("--port", type=int, default=p.DEFAULT_PORT)
    ap.add_argument("--lan", action="store_true", help="escuchar en todas las interfaces (Wi-Fi)")
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--loop", action="store_true", help="repetir el video indefinidamente")
    ap.add_argument("--once", action="store_true", help="atender una sola conexión y salir")
    ap.add_argument("--width", type=int, default=0, help="tamaño del stream (por defecto, el de la tablet)")
    ap.add_argument("--height", type=int, default=0)
    args = ap.parse_args()

    with open(args.video, "rb") as f:
        units = p.h264_access_units(f.read())
    if not units or not units[0][0]:
        raise SystemExit("El archivo debe empezar con un keyframe (IDR) y SPS/PPS.")
    print(f"{len(units)} access units, {sum(1 for u in units if u[0])} keyframes")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0" if args.lan else "127.0.0.1", args.port))
    server.listen(1)
    print(f"Escuchando en el puerto {args.port}… (con la tablet: adb reverse tcp:{args.port} tcp:{args.port})")
    while True:
        conn, addr = server.accept()
        print("Conexión de", addr)
        try:
            serve(conn, units, args)
        except (EOFError, OSError, ValueError) as e:
            print("Error:", e)
        if args.once:
            break


if __name__ == "__main__":
    main()
