#!/usr/bin/env python3
import os
import sys
import glob
import struct
import time

# -------- SETTINGS --------
REQUIRE_PREFIX = "PWDID"
STATUS_FILE = "/var/www/html/photostation/status.txt"
DEBOUNCE_SEC = 2

# 32/64-bit safe input_event struct
if struct.calcsize("l") == 8:
    EVENT_FORMAT = "qqHHi"
else:
    EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

EV_KEY = 1
KEY_PRESS = 1
SHIFT_KEYS = {42, 54}

KEY_MAP = {
    2:'1',3:'2',4:'3',5:'4',6:'5',7:'6',8:'7',9:'8',10:'9',11:'0',
    16:'q',17:'w',18:'e',19:'r',20:'t',21:'y',22:'u',23:'i',24:'o',25:'p',
    30:'a',31:'s',32:'d',33:'f',34:'g',35:'h',36:'j',37:'k',38:'l',
    44:'z',45:'x',46:'c',47:'v',48:'b',49:'n',50:'m',
    52:'.',
    28:'ENTER', 96:'ENTER'
}

def status_is_busy():
    try:
        s = open(STATUS_FILE).read().strip().upper()
        return s.startswith("CAPTURING") or s.startswith("UPLOADING")
    except Exception:
        return False

def find_scanner():
    kbds = sorted(glob.glob("/dev/input/by-id/*-event-kbd"))
    for dev in kbds:
        name = os.path.basename(dev).lower()
        if any(k in name for k in ("symbol", "zebra", "scanner", "barcode", "code")):
            return os.path.realpath(dev)
    if kbds:
        newest = max(kbds, key=lambda p: os.stat(p).st_mtime)
        return os.path.realpath(newest)
    return None

device = find_scanner()
if not device:
    print("No scanner device found.", file=sys.stderr)
    sys.exit(1)

print(f"Using device: {device}", file=sys.stderr)

buffer = ""
shift = False
last_scan_time = 0

with open(device, "rb") as f:
    while True:
        data = f.read(EVENT_SIZE)
        if len(data) != EVENT_SIZE:
            continue

        sec, usec, ev_type, code, value = struct.unpack(EVENT_FORMAT, data)

        if ev_type == EV_KEY and code in SHIFT_KEYS:
            shift = (value == KEY_PRESS)
            continue

        if ev_type == EV_KEY and value == KEY_PRESS:
            key = KEY_MAP.get(code)
            if not key:
                continue

            if key == "ENTER":
                candidate = buffer
                buffer = ""

                if not candidate:
                    continue

                if REQUIRE_PREFIX and not candidate.upper().startswith(REQUIRE_PREFIX):
                    continue

                if status_is_busy():
                    continue

                now = time.time()
                if now - last_scan_time < DEBOUNCE_SEC:
                    continue

                last_scan_time = now
                try:
                    print(candidate, flush=True)
                except BrokenPipeError:
                    raise SystemExit(0)
                continue

            if shift and key.isalpha():
                buffer += key.upper()
            else:
                buffer += key
