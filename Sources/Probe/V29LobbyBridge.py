#!/usr/bin/env python3
"""Read-only local Warcraft III WebSocket -> safe, newline-delimited lobby snapshots.

This experimental feed has NO map content SHA-1. The consumer must not enqueue
CDN downloads from these unverified titles/map filenames.

Session identifiers are consumed in memory via the GUID probe; they never appear
in this program's output or command-line arguments. Only the localhost Warcraft
WebSocket is contacted. No Battle.net credentials, raw messages, or host tags
are emitted. On disconnect, the visible snapshot is explicitly cleared.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from V23LocalSocketProbe import handshake, ProtocolFailure, MAX_PAYLOAD

MAX_GAMES = 700
MAX_VISIBLE = 100
MAX_BYTES = 2 * 1024 * 1024
VALID_EXT = ('.w3x', '.w3m')


def safe_text(value, limit=120):
    if not isinstance(value, str):
        return ''
    return ''.join(c for c in value[:limit] if ord(c) >= 32 and ord(c) != 127)


def map_filename(value):
    if not isinstance(value, str):
        return ''
    path = value.replace('\\', '/')
    basename = path.rsplit('/', 1)[-1]
    return safe_text(basename, 255) if basename.lower().endswith(VALID_EXT) else ''


def bounded_int(value, limit):
    return value if type(value) is int and 0 <= value <= limit else 0


def game_summary(value):
    if not isinstance(value, dict):
        return None
    name = safe_text(value.get('name'), 120)
    props = value.get('mapProperties')
    if not isinstance(props, dict):
        props = {}
    filename = map_filename(value.get('mapFile') or props.get('mapPath'))
    gid = value.get('id')
    if not name or not filename or type(gid) is not int or gid < 0:
        return None
    return {
        'id': gid,
        'name': name,
        'map': filename,
        'players': bounded_int(value.get('currentPlayers'), 64),
        'capacity': bounded_int(value.get('maxPlayers'), 64),
    }


class LobbyStore:
    def __init__(self):
        self.by_id = {}
        self.ready = False

    def accept(self, obj):
        if not isinstance(obj, dict):
            return False
        event = obj.get('messageType')
        payload = obj.get('payload')
        if not isinstance(payload, dict):
            return False
        if event == 'GameList':
            items = payload.get('games')
            if not isinstance(items, list):
                return False
            updated = {}
            for item in items[:MAX_GAMES]:
                row = game_summary(item)
                if row:
                    updated[row['id']] = row
            changed = not self.ready or updated != self.by_id
            self.by_id = updated
            self.ready = True
            return changed
        if event not in ('GameListUpdate', 'GameListRemove'):
            return False
        item = payload.get('game')
        if event == 'GameListUpdate':
            row = game_summary(item)
            if row is None:
                return False
            old = self.by_id.get(row['id'])
            self.by_id[row['id']] = row
            return old != row
        gid = item.get('id') if isinstance(item, dict) else item
        if type(gid) is not int:
            return False
        return self.by_id.pop(gid, None) is not None

    def snapshot(self):
        records = sorted(self.by_id.values(), key=lambda x: (x['name'].casefold(), x['id']))
        return {'event': 'lobbies', 'total': len(records), 'games': records[:MAX_VISIBLE],
                'limited': len(records) > MAX_VISIBLE, 'verifiedHashes': False}


def emit(obj):
    print(json.dumps(obj, separators=(',', ':'), ensure_ascii=True), flush=True)


def current_pid():
    p = subprocess.run(['/usr/bin/pgrep', '-x', 'Warcraft III'], capture_output=True,
                       text=True, timeout=5, check=False)
    for line in p.stdout.splitlines():
        if line.isdecimal():
            return int(line)
    return None


def owned_ports(pid):
    p = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN'],
                       capture_output=True, text=True, timeout=5, check=False)
    found = set()
    for line in p.stdout.splitlines()[1:]:
        match = re.search(r':([0-9]{1,5})(?:\s|$)', line)
        if match:
            port = int(match.group(1))
            if 0 < port < 65536:
                found.add(port)
    return sorted(found)[:8]


def find_sessions(binary, pid):
    # GUIDs move solely over an internal pipe; never logged, persisted, or put in argv.
    p = subprocess.run([binary, str(pid)], capture_output=True, timeout=45, check=False)
    if p.returncode:
        return []
    return list(dict.fromkeys(x for x in p.stdout.decode('ascii', 'ignore').splitlines()
                              if re.fullmatch(r'[0-9]{11,32}', x)))[:16]


def connect(ids, ports):
    for port in ports:
        for sid in ids:
            try:
                return handshake(port, sid)
            except (OSError, TimeoutError, ProtocolFailure):
                continue
    return None


def pump(ws, store, stop_at=None):
    chunks = bytearray()
    binary = False
    dirty = False
    last_emit = 0.0
    while stop_at is None or time.monotonic() < stop_at:
        # Avoid rebuilding the entire native SwiftUI menu for every player-count tick.
        if dirty and time.monotonic() - last_emit >= 4.0:
            emit(store.snapshot())
            dirty = False
            last_emit = time.monotonic()
        try:
            opcode, fin, data = ws.recv_frame(time.monotonic() + 1.5)
        except TimeoutError:
            continue
        if opcode == 9:
            ws.send_control(10, data)
            continue
        if opcode == 8:
            raise ProtocolFailure('closed')
        if opcode in (1, 2):
            chunks = bytearray()
            binary = opcode == 2
        elif opcode != 0:
            continue
        if len(chunks) + len(data) > MAX_PAYLOAD:
            raise ProtocolFailure('message_too_large')
        chunks.extend(data)
        if fin:
            if not binary:
                try:
                    obj = json.loads(chunks)
                except (UnicodeError, ValueError):
                    obj = None
                if store.accept(obj):
                    dirty = True
            chunks = bytearray()
    if dirty:
        emit(store.snapshot())


def serve(binary, once_seconds=None):
    last_state = None
    while True:
        pid = current_pid()
        if not pid:
            if last_state != 'waiting_for_game':
                emit({'event': 'state', 'status': 'waiting_for_game'})
                last_state = 'waiting_for_game'
            if once_seconds is not None:
                return 2
            time.sleep(5)
            continue
        ports = owned_ports(pid)
        sessions = find_sessions(binary, pid) if ports else []
        ws = connect(sessions, ports)
        if ws is None:
            if last_state != 'waiting_for_socket':
                emit({'event': 'state', 'status': 'waiting_for_socket'})
                last_state = 'waiting_for_socket'
            if once_seconds is not None:
                return 2
            time.sleep(6)
            continue
        last_state = 'connected'
        emit({'event': 'state', 'status': 'connected'})
        store = LobbyStore()
        try:
            stop = (time.monotonic() + once_seconds) if once_seconds is not None else None
            pump(ws, store, stop)
            if once_seconds is not None:
                return 0
        except (OSError, ProtocolFailure):
            pass
        finally:
            try:
                ws.send_control(8)
            except (OSError, TimeoutError):
                pass
            ws.sock.close()
            emit({'event': 'lobbies', 'total': 0, 'games': [], 'limited': False,
                  'verifiedHashes': False})
            emit({'event': 'state', 'status': 'disconnected'})
        last_state = 'disconnected'
        if once_seconds is not None:
            return 0
        time.sleep(3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--guid-probe', required=True)
    parser.add_argument('--once-seconds', type=float)
    args = parser.parse_args()
    if not os.path.isfile(args.guid_probe):
        emit({'event': 'state', 'status': 'missing_helper'})
        return 2
    try:
        return serve(args.guid_probe, args.once_seconds)
    except (OSError, subprocess.TimeoutExpired):
        emit({'event': 'state', 'status': 'helper_failed'})
        return 2


if __name__ == '__main__':
    sys.exit(main())
