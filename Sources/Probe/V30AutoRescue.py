#!/usr/bin/env python3
"""Always-armed MapDash Rescue, macOS Warcraft III local WebSocket edition.

Listens passively for native ShowDownloadModal. Only after that event does it
scan the game for an exact Blizzard CDN URL; it requires one NEW SHA-1 seen in
TWO scans, downloads from the pinned Blizzard CDN, SHA-1 verifies and saves a
backup, and attempts a no-overwrite install. It does NOT discover a hash before
Warcraft's own Download Map action and never clicks Download Map itself.

For safety: no session identifiers, raw WebSocket messages or arbitrary network
values are logged. The game process memory is read, never written. If two
modal events overlap, the association is rejected rather than guessed.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import sys
import threading
import time

from V23LocalSocketProbe import ProtocolFailure, MAX_PAYLOAD
from V28Rescue import (extract_modal, fetch_verified, install_no_overwrite,
                       scan_hashes, select_candidate, STAGE_DIR, MAP_DIR)
from V29LobbyBridge import current_pid, owned_ports, find_sessions, connect

SCAN_INTERVAL = 2.0
SCAN_WINDOW = 90.0
RECONNECT_PAUSE = 5.0
MAX_EVENTS = 128


def notify(kind, **fields):
    """Trusted, bounded machine-readable messages for MapDash's status menu."""
    record = {'event': kind}
    record.update(fields)
    print(json.dumps(record, separators=(',', ':'), ensure_ascii=True), flush=True)


def read_modals(ws, events, stop):
    """Receive frames indefinitely; queue ONLY modal metadata, not raw frames."""
    buf = bytearray()
    binary = False
    try:
        while not stop.is_set():
            try:
                op, fin, data = ws.recv_frame(time.monotonic() + 1.0)
            except TimeoutError:
                continue
            if op == 9:
                ws.send_control(10, data)
                continue
            if op == 8:
                break
            if op in (1, 2):
                buf = bytearray()
                binary = (op == 2)
            elif op != 0:
                continue
            if len(buf) + len(data) > MAX_PAYLOAD:
                raise ProtocolFailure('message_too_large')
            buf.extend(data)
            if fin:
                if not binary:
                    try:
                        msg = json.loads(buf)
                    except (UnicodeError, ValueError):
                        msg = None
                    modal = extract_modal(msg)
                    if modal is not None:
                        try:
                            events.put_nowait(('modal', modal))
                        except queue.Full:
                            # Fail closed instead of losing a second modal.
                            events.put(('overflow', None), timeout=0.25)
                            break
                buf = bytearray()
    except (OSError, ProtocolFailure, queue.Full):
        pass
    finally:
        stop.set()
        try:
            events.put_nowait(('closed', None))
        except queue.Full:
            pass


def extra_modal_or_closed(events):
    """Drain pending events. Returns (ambiguous, closed)."""
    ambiguous = closed = False
    while True:
        try:
            kind, _ = events.get_nowait()
        except queue.Empty:
            break
        if kind in ('modal', 'overflow'):
            ambiguous = True
        if kind in ('closed', 'overflow'):
            closed = True
    return ambiguous, closed


def resolve_after_modal(baseline, scanner, pid, events, scan=scan_hashes,
                        now=time.monotonic, sleep=time.sleep, window=SCAN_WINDOW):
    """Correlation gate; no download here. Returns (digest|None, reason)."""
    observations = []
    start = now()
    last = start - SCAN_INTERVAL
    while now() - start < window:
        ambiguous, closed = extra_modal_or_closed(events)
        if ambiguous:
            return None, 'overlapping_download_modals'
        if closed:
            return None, 'websocket_disconnected'
        if now() - last >= SCAN_INTERVAL:
            observations.append(scan(scanner, pid))
            last = now()
            digest, status = select_candidate(baseline, observations)
            if status == 'ambiguous_multiple_new_hashes':
                return None, status
            if digest:
                ambiguous, closed = extra_modal_or_closed(events)
                if ambiguous:
                    return None, 'overlapping_download_modals'
                if closed:
                    return None, 'websocket_disconnected'
                return digest, 'stable_unique_candidate'
        sleep(0.25)
    return None, 'no_unique_new_cdn_hash'


def recover_event(modal, baseline, scanner, pid, events,
                  stage_dir=STAGE_DIR, dest_dir=MAP_DIR,
                  scan=scan_hashes, fetch=fetch_verified,
                  install=install_no_overwrite, window=SCAN_WINDOW):
    """Return (outcome, updated baseline). No candidate => no network or write."""
    status, filename = modal
    if status != 'valid' or not filename:
        return 'invalid_map_filename', baseline
    digest, reason = resolve_after_modal(baseline, scanner, pid, events, scan=scan, window=window)
    if digest is None:
        return reason, baseline
    notify('rescue', status='downloading', filename=filename)
    # Existing fetch_verified guards the hostname, path, SHA-1 and stage-file conflicts.
    staged, fetch_state = fetch(digest, filename, stage_dir=stage_dir)
    # The WebSocket reader keeps running while curl fetches. If the user starts
    # another download mid-fetch, never install a potentially wrong association.
    ambiguous, closed = extra_modal_or_closed(events)
    if ambiguous:
        # fetch_verified has already published the stage file. On ambiguous
        # filenames, DO NOT leave a potentially misnamed backup that Restore
        # might later install under the wrong name.
        if fetch_state == 'downloaded_and_verified':
            try:
                staged.unlink()
            except OSError:
                pass
        return 'overlapping_downloads_discarded', baseline | {digest}
    if closed:
        # Verified backup survives even if Warcraft exited during download.
        return 'game_disconnected_backup_only', baseline | {digest}
    target, result = install(staged, filename, dest_dir)
    notify('rescue', status='verified', filename=filename,
           fetched=fetch_state, installed=result)
    return result, baseline | {digest}


def run_connection(ws, pid, scanner, scan=scan_hashes, stop_after=None):
    """One Warcraft session; exits on socket close or game restart."""
    notify('state', status='warming_up')
    baseline = scan(scanner, pid)
    events = queue.Queue(maxsize=MAX_EVENTS)
    stop = threading.Event()
    receiver = threading.Thread(target=read_modals, args=(ws, events, stop), daemon=True)
    receiver.start()
    notify('state', status='armed')
    started = time.monotonic()
    completed = 0
    try:
        while not stop.is_set():
            if stop_after is not None and completed >= stop_after:
                return 0
            if current_pid() != pid:
                return 0
            try:
                kind, modal = events.get(timeout=1.5)
            except queue.Empty:
                continue
            if kind != 'modal':
                if kind == 'closed':
                    break
                continue
            completed += 1
            notify('rescue', status='detected')
            try:
                outcome, baseline = recover_event(modal, baseline, scanner, pid, events,
                                                  scan=scan)
            except (RuntimeError, ValueError, OSError, TimeoutError) as exc:
                # Never log exception text; subprocess/network messages may contain
                # local paths or more than we intended to display.
                notify('rescue', status='failed', reason=type(exc).__name__)
                # If correlation failed, refresh baseline before accepting another
                # download so older URLs cannot be attributed to the next map.
                try:
                    baseline = scan(scanner, pid)
                except (OSError, RuntimeError, TimeoutError):
                    break
            else:
                if outcome in ('installed_no_overwrite', 'already_installed_same_sha1',
                               'conflict_kept_staged', 'staged_only_different_volume'):
                    notify('rescue', status='complete', result=outcome)
                else:
                    notify('rescue', status='skipped', reason=outcome)
                    if outcome in ('websocket_disconnected', 'overlapping_download_modals',
                                   'overlapping_downloads_discarded'):
                        # Can't safely attribute a later URL to a single request.
                        # Reset baseline only after the current download activity.
                        try:
                            baseline = scan(scanner, pid)
                        except (OSError, RuntimeError, TimeoutError):
                            break
            # If a new click occurred during processing, recover_event deliberately
            # fails closed. Do not silently discard newer modal messages as valid.
        return 0
    finally:
        stop.set()
        try:
            ws.sock.close()
        except OSError:
            pass
        receiver.join(timeout=2)


def serve(guid_probe, scanner, once=False, pause=RECONNECT_PAUSE):
    last = None
    while True:
        pid = current_pid()
        if not pid:
            state = 'waiting_for_game'
        else:
            ports = owned_ports(pid)
            sessions = find_sessions(guid_probe, pid) if ports else []
            ws = connect(sessions, ports) if ports and sessions else None
            state = 'waiting_for_socket' if ws is None else 'connected'
        if state != last:
            notify('state', status=state)
            last = state
        if state == 'connected':
            try:
                run_connection(ws, pid, scanner, stop_after=1 if once else None)
            except (RuntimeError, ValueError, OSError, TimeoutError):
                notify('state', status='scan_or_socket_failed')
            last = None
        if once:
            return 0 if state == 'connected' else 2
        time.sleep(pause)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--guid-probe', required=True)
    parser.add_argument('--cdn-probe', required=True)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    try:
        return serve(args.guid_probe, args.cdn_probe, args.once)
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    sys.exit(main())
