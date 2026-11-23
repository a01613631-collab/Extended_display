#!/usr/bin/env python3
"""Tablet simulada: prueba la app de Mac sin la tablet (Fase 2+).

Se conecta como lo haría la tablet, manda HELLO, guarda el video recibido en un archivo
Annex B (reproducible con ffplay) y muestra fps, Mbps, RTT y keyframes cada segundo.

Ejemplos:
  python3 scripts/mock_tablet.py                       # 10 s contra 127.0.0.1:47800
  python3 scripts/mock_tablet.py --seconds 30 --out /tmp/rx.h264
  python3 scripts/mock_tablet.py --tap 0.5 0.5         # además hace un clic en el centro
  python3 scripts/mock_tablet.py --host 192.168.1.20 --token <token>   # modo Wi-Fi
"""
from __future__ import annotations

import argparse
import json
import socket
import statistics
import struct
import threading
import time

import tdproto as p


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=p.DEFAULT_PORT)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--out", default="rx.h264", help="archivo Annex B de salida ('' = no guardar)")
    ap.add_argument("--width", type=int, default=2800)
    ap.add_argument("--height", type=int, default=1752)
    ap.add_argument("--hevc", action="store_true", help="anunciar soporte HEVC")
    ap.add_argument("--hz120", action="store_true", help="anunciar panel de 120 Hz")
    ap.add_argument("--token", default=None, help="token de emparejamiento (Wi-Fi)")
    ap.add_argument("--tap", nargs=2, type=float, metavar=("X", "Y"), help="clic en coordenadas normalizadas tras 2 s")
    ap.add_argument("--keyframe-every", type=float, default=0, help="pedir keyframe cada N segundos")
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    send_lock = threading.Lock()

    def send(data: bytes) -> None:
        with send_lock:
            sock.sendall(data)

    codecs = [{"mime": "video/avc", "lowLatency": True, "max60": True, "max120": False}]
    if args.hevc:
        codecs.append({"mime": "video/hevc", "lowLatency": True, "max60": True, "max120": True})
    hello = {
        "protocolVersion": 1, "deviceName": "mock_tablet.py", "widthPx": args.width, "heightPx": args.height,
        "densityDpi": 266, "refreshRates": [60, 120] if args.hz120 else [60], "codecs": codecs,
        "transport": "usb" if args.token is None else "wifi", "token": args.token,
    }
    send(p.encode_json(p.HELLO, hello))

    msg_type, _, _, payload = p.read_message(sock)
    if msg_type == p.BYE:
        print(f"BYE inmediato, motivo {payload[0] if payload else '?'}")
        return
    if msg_type != p.HELLO_ACK:
        raise SystemExit(f"se esperaba HELLO_ACK, llegó {p.NAMES.get(msg_type, msg_type)}")
    ack = json.loads(payload)
    print("HELLO_ACK:", json.dumps({k: (v[:8] + "…" if k == "pairingToken" and v else v) for k, v in ack.items()},
                                   ensure_ascii=False))
    if not ack.get("accepted"):
        return

    out = open(args.out, "wb") if args.out else None
    stop = threading.Event()
    rtts: list[float] = []
    stats = {"frames": 0, "keyframes": 0, "bytes": 0, "configs": 0, "latency": []}
    clock_offsets: list[tuple[int, int]] = []

    def periodic() -> None:
        start = time.monotonic()
        next_kf = args.keyframe_every
        tapped = False
        last = {"frames": 0, "bytes": 0}
        while not stop.wait(1.0):
            elapsed = time.monotonic() - start
            send(p.encode(p.PING))
            frames = stats["frames"] - last["frames"]
            mbps = (stats["bytes"] - last["bytes"]) * 8 / 1e6
            last = {"frames": stats["frames"], "bytes": stats["bytes"]}
            rtt = statistics.median(rtts[-10:]) if rtts else None
            send(p.encode_json(p.STATS, {"fpsReceived": frames, "fpsRendered": frames, "mbps": round(mbps, 1),
                                         "rttMs": round(rtt, 2) if rtt else None, "decoder": "mock"}))
            lat = stats["latency"][-frames:] if frames else []
            lat_txt = f"{statistics.mean(lat):.1f} ms" if lat else "—"
            print(f"[{elapsed:4.0f}s] {frames:3d} fps  {mbps:5.1f} Mbps  RTT {rtt or 0:.2f} ms  "
                  f"captura→recepción {lat_txt}  keyframes {stats['keyframes']}")
            if args.tap and not tapped and elapsed >= 2:
                x, y = args.tap
                send(p.encode(p.TOUCH_MSG, p.encode_touch(0, 0, 0, 0, x, y, 1.0)))
                send(p.encode(p.TOUCH_MSG, p.encode_touch(2, 0, 0, 0, x, y, 0.0)))
                print(f"         → tap en ({x}, {y})")
                tapped = True
            if args.keyframe_every and elapsed >= next_kf:
                send(p.encode(p.KEYFRAME_REQUEST))
                next_kf += args.keyframe_every
            if elapsed >= args.seconds:
                stop.set()

    threading.Thread(target=periodic, daemon=True).start()
    sock.settimeout(1.0)
    try:
        while not stop.is_set():
            try:
                msg_type, flags, ts, payload = p.read_message(sock)
            except socket.timeout:
                continue
            if msg_type == p.VIDEO_FRAME:
                stats["frames"] += 1
                stats["bytes"] += len(payload) + p.HEADER.size
                if flags & p.FLAG_KEYFRAME:
                    stats["keyframes"] += 1
                if clock_offsets:
                    # Offset de la muestra con menor RTT (PROTOCOL.md, "Medición de latencia").
                    offset = min(clock_offsets[-30:])[1]
                    stats["latency"].append((p.now_us() - (ts - offset)) / 1000)
                if out:
                    out.write(payload)
            elif msg_type == p.CODEC_CONFIG:
                stats["configs"] += 1
                if out:
                    out.write(payload)
            elif msg_type == p.PONG:
                (echo,) = struct.unpack(">Q", payload[:8])
                now = p.now_us()
                rtt_us = now - echo
                rtts.append(rtt_us / 1000)
                clock_offsets.append((rtt_us, ts - (echo + rtt_us // 2)))
            elif msg_type == p.PING:
                send(p.encode(p.PONG, ts.to_bytes(8, "big")))
            elif msg_type == p.BYE:
                print(f"BYE de la Mac, motivo {payload[0] if payload else '?'}")
                break
    except EOFError:
        print("La Mac cerró la conexión")
    finally:
        stop.set()
        try:
            send(p.encode(p.BYE, b"\x00"))
        except OSError:
            pass
        sock.close()
        if out:
            out.close()
    print(f"Total: {stats['frames']} cuadros ({stats['keyframes']} keyframes, {stats['configs']} CODEC_CONFIG), "
          f"{stats['bytes'] / 1e6:.1f} MB" + (f" → {args.out}  (ffplay {args.out})" if out else ""))


if __name__ == "__main__":
    main()
