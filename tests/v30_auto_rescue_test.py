#!/usr/bin/env python3
"""Safety and automation contract tests, no network/Warcraft dependencies."""
import hashlib
from pathlib import Path
import queue
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Probe'))
import V30AutoRescue as auto


class Clock:
    def __init__(self): self.value = 0.0
    def now(self): return self.value
    def sleep(self, seconds): self.value += seconds


class TestAutomaticRescue(unittest.TestCase):
    def test_no_modal_no_resolver_scans(self):
        """An idle WebSocket stream contains no downloads and causes no scan."""
        q = queue.Queue()
        self.assertEqual(auto.extra_modal_or_closed(q), (False, False))

    def test_single_new_hash_requires_two_scans(self):
        q = queue.Queue()
        sha = 'a' * 40
        scans = iter([{'f'*40, sha}, {'f'*40, sha}])
        count = []
        def scan(binary, pid):
            count.append(1)
            return next(scans)
        clock = Clock()
        value, reason = auto.resolve_after_modal({'f'*40}, 'scanner', 123, q,
                                                  scan=scan, now=clock.now, sleep=clock.sleep)
        self.assertEqual((value, reason), (sha, 'stable_unique_candidate'))
        self.assertEqual(len(count), 2)

    def test_missing_new_url_never_triggers_fetch(self):
        q = queue.Queue()
        clock = Clock()
        digest, why = auto.resolve_after_modal({'a'*40}, 'scanner', 123, q,
                                                scan=lambda *a:{'a'*40}, now=clock.now,
                                                sleep=clock.sleep, window=3.0)
        self.assertIsNone(digest)
        self.assertEqual(why, 'no_unique_new_cdn_hash')

    def test_second_click_while_scanning_rejects(self):
        q = queue.Queue()
        seen = []
        def scan(*_):
            seen.append(1)
            q.put(('modal', ('valid', 'Other.w3x')))
            return {'b'*40}
        clock = Clock()
        self.assertEqual(auto.resolve_after_modal(set(), 'x', 1, q, scan=scan,
                         now=clock.now, sleep=clock.sleep)[1], 'overlapping_download_modals')
        self.assertEqual(len(seen), 1)

    def test_overlapping_click_during_fetch_discards_misnamed_backup(self):
        sha = hashlib.sha1(b'valid backup').hexdigest()
        with tempfile.TemporaryDirectory() as d:
            stage = Path(d) / 'stage'
            stage.mkdir()
            installed = Path(d) / 'maps'
            q = queue.Queue()
            staged = stage / (sha + '-First.w3x')
            def fetch(digest, filename, stage_dir):
                staged.write_bytes(b'valid backup')
                q.put(('modal', ('valid', 'Second.w3x')))
                return staged, 'downloaded_and_verified'
            def scan(*_): return {sha}
            with patch.object(auto, 'resolve_after_modal', return_value=(sha, 'stable_unique_candidate')):
                state, _ = auto.recover_event(('valid', 'First.w3x'), set(), 'x', 1, q,
                                              stage_dir=stage, dest_dir=installed,
                                              scan=scan, fetch=fetch)
            self.assertEqual(state, 'overlapping_downloads_discarded')
            self.assertFalse(staged.exists())
            self.assertFalse(installed.exists())

    def test_valid_click_downloads_verifies_and_installs_with_existing_code(self):
        data = b'HM3W' + b'valid w3x archive stub'
        sha = hashlib.sha1(data).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            stage, installed = Path(d)/'stage', Path(d)/'maps'
            q = queue.Queue()
            def fake_curl(command, tmp):
                self.assertIn(sha + '.map', command[-1])
                tmp.write_bytes(data)
                return True
            def fetch(h, name, stage_dir):
                return auto.fetch_verified(h, name, stage_dir, fake_curl)
            with patch.object(auto, 'resolve_after_modal', return_value=(sha,'stable_unique_candidate')):
                status, baseline = auto.recover_event(('valid','Right.w3x'), set(), 'scan', 2,
                                     q, stage_dir=stage, dest_dir=installed, fetch=fetch)
            self.assertEqual(status, 'installed_no_overwrite')
            self.assertEqual(baseline, {sha})
            self.assertEqual((installed/'Right.w3x').read_bytes(), data)
            self.assertEqual(len(list(stage.glob('*.w3x'))), 1)
            self.assertNotEqual((installed/'Right.w3x').stat().st_ino,
                                next(stage.glob('*.w3x')).stat().st_ino)
            (installed/'Right.w3x').write_bytes(b'different')
            with patch.object(auto, 'resolve_after_modal', return_value=(sha,'stable_unique_candidate')):
                status, baseline = auto.recover_event(('valid','Right.w3x'), set(), 'scan', 2,
                                     queue.Queue(), stage_dir=stage, dest_dir=installed, fetch=fetch)
            self.assertEqual(status, 'conflict_kept_staged')
            self.assertEqual((installed/'Right.w3x').read_bytes(), b'different')

    def test_reader_accepts_real_websocket_modal_and_drops_other_data(self):
        class FakeSock:
            def close(self): pass
        class FakeWS:
            sock = FakeSock()
            def __init__(self): self.count = 0
            def recv_frame(self, deadline):
                self.count += 1
                if self.count == 1:
                    return 1, True, b'{"messageType":"GameList","payload":{"secret":"redacted"}}'
                if self.count == 2:
                    return 1, True, b'{"messageType":"ShowDownloadModal","payload":{"fileName":"Maps/Download/A.w3x"}}'
                return 8, True, b''
            def send_control(self, *args): pass
        q = queue.Queue()
        stop = threading.Event()
        auto.read_modals(FakeWS(), q, stop)
        self.assertEqual(q.get_nowait(), ('modal', ('valid', 'A.w3x')))
        self.assertEqual(q.get_nowait(), ('closed', None))

    def test_interrupted_socket_is_fail_closed(self):
        q = queue.Queue()
        q.put(('closed', None))
        digest, why = auto.resolve_after_modal(set(), 'x', 1, q, scan=lambda *_: {'a'*40})
        self.assertIsNone(digest)
        self.assertEqual(why, 'websocket_disconnected')

    def test_one_watcher_handles_two_sequential_native_downloads(self):
        class FakeSock:
            def close(self): pass
        class FakeWS:
            sock = FakeSock()
        completed_first = threading.Event()
        seen = []
        def reader(ws, events, stop):
            events.put(('modal', ('valid', 'One.w3x')))
            self.assertTrue(completed_first.wait(3))
            events.put(('modal', ('valid', 'Two.w3x')))
            stop.wait(2)
        def rescue(modal, baseline, scanner, pid, events, **kwargs):
            seen.append(modal[1])
            if len(seen) == 1:
                completed_first.set()
            return 'installed_no_overwrite', baseline | {str(len(seen))*40}
        scans = []
        def baseline_scan(*args):
            scans.append(1)
            return set()
        with patch.object(auto, 'read_modals', side_effect=reader), \
             patch.object(auto, 'recover_event', side_effect=rescue), \
             patch.object(auto, 'current_pid', return_value=123):
            auto.run_connection(FakeWS(), 123, '/tmp/scanner', scan=baseline_scan, stop_after=2)
        self.assertEqual(seen, ['One.w3x', 'Two.w3x'])
        self.assertEqual(len(scans), 1)  # No idle periodic 2 GiB scans

    def test_unverified_modals_cannot_write(self):
        q = queue.Queue()
        result, _ = auto.recover_event(('invalid', None), set(), 'x', 1, q)
        self.assertEqual(result, 'invalid_map_filename')

if __name__ == '__main__':
    unittest.main()
