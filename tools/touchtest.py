#!/usr/bin/env python3
"""Drive PhoneCast's InputService directly over TCP (adb forward tcp:27183 tcp:27183).

Quit the Mac app first (a new client replaces the old one). Put the phone on a harmless
screen (Chrome about:blank). Usage:
  touchtest.py PIN hold2 [seconds] [--tap-at S]   two fingers held (joystick + look), look moving
  touchtest.py PIN taps  [seconds]                 joystick held, look moving, extra taps as fingers 2..8
After each run it prints the dispatcher's injected-pointer state (should be empty).
"""
import socket, struct, subprocess, sys, threading, time

DOWN, MOVE, UP, CANCEL_ALL = 0, 1, 2, 3


def connect(pin):
    s = socket.create_connection(("127.0.0.1", 27183))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    p = pin.encode()
    s.sendall(struct.pack(">BH", 9, len(p)) + p)
    t, n = struct.unpack(">BI", s.recv(5, socket.MSG_WAITALL))
    if t != 4:
        sys.exit(f"handshake failed (type {t})")

    def drain():
        try:
            while s.recv(1 << 16):
                pass
        except OSError:
            pass

    threading.Thread(target=drain, daemon=True).start()
    return s


def touch(s, action, fid, x, y):
    pl = struct.pack(">BBHH", action, fid, int(x * 65535), int(y * 65535))
    s.sendall(struct.pack(">BH", 10, len(pl)) + pl)


def verifier():
    out = subprocess.run(["adb", "shell", "dumpsys input"], capture_output=True, text=True).stdout
    i = out.find("Filter verifier on display 0")
    return out[i:].splitlines()[1].strip() if i >= 0 else "?"


def main():
    pin, mode = sys.argv[1], sys.argv[2]
    secs = float(sys.argv[3]) if len(sys.argv) > 3 and not sys.argv[3].startswith("--") else 4
    tap_at = float(sys.argv[sys.argv.index("--tap-at") + 1]) if "--tap-at" in sys.argv else None
    s = connect(pin)
    time.sleep(0.3)
    touch(s, DOWN, 1, 0.25, 0.7)          # joystick
    time.sleep(0.05)
    touch(s, DOWN, 9, 0.7, 0.5)           # look
    t0 = time.time(); k = 0; tapped = False; extra = 2
    if mode in ("aim", "combat"):   # joystick still, look finger: tiny horizontal steps at mouse rate (like ⌘G)
        import os, random
        step = float(os.environ.get("STEP", "0.0004")); dt = float(os.environ.get("DT", "0.004"))
        x = 0.7
        while time.time() - t0 < secs:
            x += step * random.choice((1, 1, 1, -1)) * (1 if (time.time() - t0) % 4 < 2 else -1)
            if mode == "combat" and random.random() < dt / 0.25:   # fire/jump taps ~4/s
                fid = random.choice((2, 3, 4, 5))
                touch(s, DOWN, fid, 0.8 + 0.02 * fid, 0.75)
                threading.Timer(0.08, touch, (s, UP, fid, 0.8 + 0.02 * fid, 0.75)).start()
            if mode == "combat" and random.random() < dt / 0.6:    # W re-pressed, look re-centres with it
                touch(s, UP, 1, 0.25, 0.7); touch(s, DOWN, 1, 0.25, 0.7)
                touch(s, UP, 9, x, 0.5); x = 0.7; touch(s, DOWN, 9, x, 0.5)
            if abs(x - 0.7) > 0.06:            # like the Mac: out of room -> lift and re-centre
                touch(s, UP, 9, x, 0.5); x = 0.7; touch(s, DOWN, 9, x, 0.5)
            else:
                touch(s, MOVE, 9, x, 0.5)
            time.sleep(dt)
        secs = 0
    while time.time() - t0 < secs:
        k += 1
        touch(s, MOVE, 1, 0.25, 0.65 - 0.02 * ((k // 10) % 2))
        touch(s, MOVE, 9, 0.7 + 0.1 * ((k % 40) / 40), 0.5)
        if mode == "taps" and k % 15 == 0:   # fire button taps while holding
            touch(s, DOWN, extra, 0.85, 0.75)
            threading.Timer(0.07, touch, (s, UP, extra, 0.85, 0.75)).start()
            extra = 2 + (extra - 1) % 7
        if tap_at is not None and not tapped and time.time() - t0 > tap_at:
            tapped = True
            subprocess.run(["adb", "shell", "input", "tap", "540", "300"])
            print("outside tap sent; during hold:", verifier())
        time.sleep(0.016)
    touch(s, UP, 9, 0.8, 0.5)
    touch(s, UP, 1, 0.25, 0.65)
    time.sleep(0.5)
    print("after release:", verifier())
    s.close()


if __name__ == "__main__":
    main()
