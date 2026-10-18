#!/usr/bin/env python3
"""MapDash Rescue V28: one-click native trigger -> independent verified CDN download.

The local game WebSocket supplies the download-modal filename. A before/after
read-only memory scan supplies a *candidate* official CDN content SHA-1. We
require exactly one newly appearing candidate, stable across two scans, and
exactly one valid modal event before downloading. Staged files are retained
independently of the Warcraft lobby. Optional installation never overwrites.

V28 DOES NOT offer fully automatic pre-click map discovery. It uses the game's
Download Map action as the resolution trigger. Session IDs/raw WebSocket data
remain in-process, never written to disk or logs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time

from V23LocalSocketProbe import handshake, ProtocolFailure, MAX_PAYLOAD

SHA1 = re.compile(r'^[0-9a-f]{40}$')
GUID = re.compile(r'^[0-9]{11,32}$')
CANDIDATE = re.compile(r'^v27_candidate sha1=([0-9a-f]{40})\b', re.MULTILINE)
CDN = 'https://ugc.cdn.warcraft3-prod.battle.net/W3-maps-user/{}.map'
MAP_DIR = Path.home() / 'Library/Application Support/Blizzard/Warcraft III/Maps/Download'
STAGE_DIR = Path.home() / 'Library/Application Support/MapDash/Rescue'
MAX_FRAMES = 3000


def safe_map_name(value):
    """A filename provided by Warcraft; reject traversal/control/other files."""
    if not isinstance(value, str) or len(value) > 255 or not value:
        return None
    value = value.replace('\\', '/')
    name = value.rsplit('/', 1)[-1]
    if (not name or name[0] == '.' or ':' in name or '\x00' in name or
            any(ord(ch) < 32 or ord(ch) == 127 for ch in name) or
            name.lower().endswith(('.w3x', '.w3m')) is False):
        return None
    return name


def scan_hashes(scanner, pid):
    proc = subprocess.run([scanner, str(pid)], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True,
                          timeout=50, check=False)
    if proc.returncode != 0:
        raise RuntimeError('memory_scan_failed')
    if 'overflow=' not in proc.stdout:
        raise RuntimeError('memory_scan_format_unknown')
    if re.search(r'\boverflow=([1-9][0-9]*)', proc.stdout):
        raise RuntimeError('memory_scan_overflow')
    if 'v27_memory' not in proc.stdout:
        raise RuntimeError('memory_scan_summary_missing')
    return set(CANDIDATE.findall(proc.stdout))


def digest_file(path):
    sha = hashlib.sha1()
    with open(str(path), 'rb') as f:
        while True:
            data = f.read(1 << 20)
            if not data:
                break
            sha.update(data)
    return sha.hexdigest()


def select_candidate(baseline, observations):
    """Exactly one new hash in at least two independent consecutive scans."""
    newly = [observed - baseline for observed in observations]
    if any(len(x) > 1 for x in newly):
        return None, 'ambiguous_multiple_new_hashes'
    seen = set().union(*newly) if newly else set()
    if len(seen) > 1:
        return None, 'ambiguous_multiple_new_hashes'
    if len(newly) < 2 or not newly[-1] or newly[-1] != newly[-2]:
        return None, 'awaiting_repeated_hash'
    return next(iter(newly[-1])), 'stable_unique_candidate'


def extract_modal(message):
    if not isinstance(message, dict) or message.get('messageType') != 'ShowDownloadModal':
        return None
    payload = message.get('payload')
    if not isinstance(payload, dict):
        return ('invalid', None)
    value = payload.get('fileName')
    name = safe_map_name(value)
    return ('valid' if name else 'invalid', name)


def fetch_verified(sha, name, stage_dir=STAGE_DIR, run=None):
    """Fetch to private staging; publish only after SHA-1 validation.

    The downloader never replaces an existing valid staged artifact. On any
    mismatch, removes only its own temporary file. Network command is fixed to
    official CDN hostname, and the URL hash is strictly validated.
    """
    if not SHA1.fullmatch(sha) or safe_map_name(name) != name:
        raise ValueError('invalid_digest_or_filename')
    stage_dir.mkdir(parents=True, exist_ok=True)
    staged = stage_dir / (sha + '-' + name)
    if staged.exists() or staged.is_symlink():
        if not staged.is_file() or staged.is_symlink() or digest_file(staged) != sha:
            raise RuntimeError('staging_conflict_existing_file')
        return staged, 'already_staged'
    fd, tmp = tempfile.mkstemp(prefix='.rescue-', suffix='.part', dir=str(stage_dir))
    os.close(fd)
    try:
        cmd = ['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error',
               '--retry', '2', '--connect-timeout', '12', '--max-time', '240',
               '--output', tmp, CDN.format(sha)]
        if run is None:
            proc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                  universal_newlines=True, check=False)
            success = proc.returncode == 0
        else:
            success = bool(run(cmd, Path(tmp)))
        if not success:
            raise RuntimeError('cdn_download_failed')
        if os.path.getsize(tmp) == 0 or digest_file(tmp) != sha:
            raise RuntimeError('download_sha1_mismatch')
        # Atomic, no-clobber publication. Directory and temp share a volume.
        os.link(tmp, str(staged))
        return staged, 'downloaded_and_verified'
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def install_no_overwrite(staged, name, dest_dir=MAP_DIR):
    """Atomically install a *separate copy* of a verified map without replacing.

    Never hardlink the installed file to the rescue backup: Warcraft may mutate
    or truncate its installed copy and a hardlink would corrupt the backup too.
    Copy into a private temporary file inside the target filesystem, validate
    SHA-1 again, then publish with atomic exclusive os.link().
    """
    if safe_map_name(name) != name:
        raise ValueError('invalid_filename')
    if not staged.is_file() or staged.is_symlink():
        raise RuntimeError('invalid_staged_file')
    expected = digest_file(staged)
    dest_dir.mkdir(parents=True, exist_ok=True)
    target = dest_dir / name
    if target.exists() or target.is_symlink():
        if target.is_file() and not target.is_symlink() and digest_file(target) == expected:
            return target, 'already_installed_same_sha1'
        return target, 'conflict_kept_staged'
    fd, temp = tempfile.mkstemp(prefix='.mapdash-install-', suffix='.part', dir=str(dest_dir))
    try:
        with os.fdopen(fd, 'wb') as output, open(staged, 'rb') as source:
            while True:
                chunk = source.read(1 << 20)
                if not chunk:
                    break
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if digest_file(Path(temp)) != expected:
            raise RuntimeError('install_copy_sha1_mismatch')
        try:
            os.link(temp, str(target))
        except FileExistsError:
            return target, 'conflict_kept_staged'
        return target, 'installed_no_overwrite'
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


class Observations:
    def __init__(self):
        self.lock = threading.Lock()
        self.modals = []  # (valid|invalid, filename); only available inside this process
        self.progress = 0
        self.messages = 0
        self.end_reason = ''
        self.stop = threading.Event()

    def feed(self, message):
        modal = extract_modal(message)
        with self.lock:
            self.messages += 1
            if modal is not None:
                self.modals.append(modal)
            if isinstance(message, dict) and message.get('messageType') == 'ProgressDownloadModal':
                self.progress += 1

    def snapshot(self):
        with self.lock:
            return list(self.modals), self.progress, self.messages


def receive_forever(ws, obs):
    chunks = bytearray()
    binary = False
    try:
        while not obs.stop.is_set() and obs.messages < MAX_FRAMES:
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
                chunks = bytearray()
                binary = op == 2
            elif op != 0:
                continue
            if len(chunks) + len(data) > MAX_PAYLOAD:
                raise ProtocolFailure('message_too_large')
            chunks.extend(data)
            if fin:
                if not binary:
                    try:
                        message = json.loads(chunks)
                    except (ValueError, UnicodeError):
                        message = None
                    obs.feed(message)
                chunks = bytearray()
    except (OSError, ProtocolFailure):
        obs.end_reason = 'socket_ended'
    finally:
        obs.stop.set()


def connect(ids, ports):
    for port in ports:
        for sid in ids:
            try:
                return handshake(port, sid), port
            except (OSError, TimeoutError, ProtocolFailure):
                continue
    raise RuntimeError('local_websocket_not_available')


def rescue(ids, ports, pid, scanner, seconds, install, stage_dir=STAGE_DIR, dest_dir=MAP_DIR,
           fetch=fetch_verified):
    ids = list(dict.fromkeys(x for x in ids if GUID.fullmatch(x)))[:16]
    print('v28_session_ids=%d redacted=1' % len(ids), flush=True)
    if not ids or not ports:
        raise RuntimeError('no_game_session_or_listening_ports')
    ws, port = connect(ids, ports)
    print('v28_websocket=CONNECTED port=%d' % port, flush=True)
    try:
        baseline = scan_hashes(scanner, pid)
    except Exception:
        ws.sock.close()
        raise
    print('v28_baseline_cdn_hashes=%d' % len(baseline), flush=True)
    obs = Observations()
    worker = threading.Thread(target=receive_forever, args=(ws, obs), daemon=True)
    worker.start()
    print('v28_READY=NOW right-click ONE missing map and choose Download Map', flush=True)
    started = time.monotonic()
    first_modal_time = None
    scans = []
    last_scan_at = 0
    candidate = None
    try:
        while time.monotonic() - started < seconds and not obs.stop.is_set():
            modals, _, _ = obs.snapshot()
            if len(modals) > 1:
                raise RuntimeError('multiple_download_modals_ambiguous')
            if modals and modals[0][0] != 'valid':
                raise RuntimeError('download_modal_filename_not_safe_w3x_or_w3m')
            if modals and first_modal_time is None:
                first_modal_time = time.monotonic()
                print('v28_download_modal=OBSERVED filename=%s' % modals[0][1], flush=True)
            if first_modal_time is not None and time.monotonic() - last_scan_at >= 2.0:
                observations = scan_hashes(scanner, pid)
                scans.append(observations)
                last_scan_at = time.monotonic()
                candidate, status = select_candidate(baseline, scans)
                print('v28_scan=%d new_hashes=%d status=%s' %
                      (len(scans), len(observations-baseline), status), flush=True)
                if status == 'ambiguous_multiple_new_hashes':
                    raise RuntimeError(status)
                if candidate:
                    # A quick quiet window catches accidental second clicks.
                    time.sleep(0.5)
                    if len(obs.snapshot()[0]) != 1:
                        raise RuntimeError('multiple_download_modals_ambiguous')
                    break
            time.sleep(0.25)
        modals, progress, message_count = obs.snapshot()
    finally:
        obs.stop.set()
        try:
            ws.send_control(8)
        except (OSError, TimeoutError):
            pass
        ws.sock.close()
        worker.join(timeout=2)
    print('v28_events download_modals=%d progress_updates=%d websocket_messages=%d' %
          (len(modals), progress, message_count), flush=True)
    if not modals:
        raise RuntimeError('no_native_download_modal_received')
    if not candidate:
        raise RuntimeError('no_unique_repeated_new_cdn_hash')
    if len(modals) != 1:
        raise RuntimeError('multiple_download_modals_ambiguous')
    name = modals[0][1]
    print('v28_candidate sha1=%s confidence=single_modal_plus_repeated_new_cdn_url' % candidate, flush=True)
    print('v28_fetch=starting official_blizzard_cdn', flush=True)
    staged, outcome = fetch(candidate, name, stage_dir=stage_dir)
    print('v28_fetch=%s verified_sha1=%s' % (outcome, candidate), flush=True)
    print('v28_staged_file=%s' % staged, flush=True)
    if install:
        target, state = install_no_overwrite(staged, name, dest_dir)
        print('v28_install=%s destination=%s' % (state, target), flush=True)
    else:
        print('v28_install=NOT_REQUESTED use_--install_to_place_in_Warcraft_Maps/Download', flush=True)
    print('v28_status=RESCUED_VERIFIED_CONTENT (game-title association remains temporal)', flush=True)
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ports', required=True)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--scanner', required=True)
    p.add_argument('--seconds', type=int, default=90)
    p.add_argument('--install', action='store_true')
    args = p.parse_args()
    ports = list(dict.fromkeys(int(x) for x in args.ports.split(',')
                               if x.isdecimal() and 0 < int(x) < 65536))[:8]
    try:
        return rescue(sys.stdin.read().splitlines(), ports, args.pid, args.scanner,
                      max(20, min(180, args.seconds)), args.install)
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as e:
        # No external strings (session identifiers, URLs, private payloads) are printed.
        print('v28_status=NOT_RESCUED reason=%s' % type(e).__name__ +
              ((' detail=%s' % str(e)) if isinstance(e, RuntimeError) and
               str(e) in {'memory_scan_failed','memory_scan_overflow','memory_scan_format_unknown',
                          'memory_scan_summary_missing','multiple_download_modals_ambiguous',
                          'download_modal_filename_not_safe_w3x_or_w3m',
                          'ambiguous_multiple_new_hashes','no_native_download_modal_received',
                          'no_unique_repeated_new_cdn_hash','cdn_download_failed',
                          'download_sha1_mismatch','local_websocket_not_available',
                          'no_game_session_or_listening_ports','staging_conflict_existing_file'}
               else ''), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
