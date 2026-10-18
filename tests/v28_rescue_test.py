#!/usr/bin/env python3
"""Offline contract tests for the first MapDash Rescue pipeline."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/Probe'))
import V28Rescue as r
import V28Restore as restore


class TestV28Rescue(unittest.TestCase):
    def test_filename_validation(self):
        self.assertEqual(r.safe_map_name('Maps\\Download\\Legion TD.w3x'), 'Legion TD.w3x')
        self.assertEqual(r.safe_map_name('Maps/0/Test.w3m'), 'Test.w3m')
        for value in ('../.secret.w3x', '../file.txt', '/tmp/file.mp3', 'map.w3x\n',
                      'X:foo.w3x', 'Maps/Download/.hidden.w3x', '', 'map.w3x/../x.bat'):
            self.assertIsNone(r.safe_map_name(value), value)

    def test_modal_has_filename_only_when_present(self):
        self.assertIsNone(r.extract_modal({'messageType':'GameList', 'payload':{}}))
        self.assertEqual(r.extract_modal({'messageType':'ShowDownloadModal', 'payload':{'fileName':'Maps/Download/A.w3x'}}), ('valid','A.w3x'))
        self.assertEqual(r.extract_modal({'messageType':'ShowDownloadModal', 'payload':{'fileName':'not-a-map'}}), ('invalid',None))

    def test_candidate_requires_unique_repeated_new_url(self):
        a = 'a'*40; b='b'*40; c='c'*40
        self.assertEqual(r.select_candidate({a}, [{a,b}, {a,b}]), (b, 'stable_unique_candidate'))
        self.assertEqual(r.select_candidate({a}, [{a,b}, {a,c}])[0], None)
        self.assertEqual(r.select_candidate({a}, [{a,b,c}])[1], 'ambiguous_multiple_new_hashes')
        self.assertEqual(r.select_candidate({a}, [{a,b}])[1], 'awaiting_repeated_hash')

    def test_scan_candidate_extraction_and_failure(self):
        sha='5e955971b4c941e40c3b8703e47a2b3a6d48f57f'
        with mock.patch.object(r.subprocess, 'run') as run:
            run.return_value.returncode = 0
            run.return_value.stdout = 'v27_memory scanned_mib=2048 distinct_cdn_sha1=1 overflow=0\nv27_candidate sha1='+sha+' sightings=7 encoding=ascii\n'
            self.assertEqual(r.scan_hashes('/tmp/scanner', 123), {sha})
            run.return_value.stdout = 'v27_memory scanned_mib=2048 distinct_cdn_sha1=1 overflow=1\n'
            with self.assertRaisesRegex(RuntimeError, 'overflow'):
                r.scan_hashes('/tmp/scanner', 123)

    def test_sha1_checked_before_publication_and_install_is_exclusive(self):
        correct = b'HM3W' + b'test map content' * 40
        h=hashlib.sha1(correct).hexdigest()
        wrong = b'not same sha1'
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); stage=root/'stage'; install=root/'game'
            def fake_curl(cmd, dest):
                self.assertTrue(cmd[-1].endswith('/'+h+'.map'))
                dest.write_bytes(wrong)
                return True
            with self.assertRaisesRegex(RuntimeError, 'sha1_mismatch'):
                r.fetch_verified(h, 'Demo.w3x', stage, fake_curl)
            self.assertEqual(list(stage.iterdir()), [])
            def fake_curl_good(cmd, dest):
                dest.write_bytes(correct)
                return True
            staged, out = r.fetch_verified(h, 'Demo.w3x', stage, fake_curl_good)
            self.assertEqual(out, 'downloaded_and_verified')
            self.assertEqual(staged.read_bytes(), correct)
            same, out2 = r.fetch_verified(h, 'Demo.w3x', stage, fake_curl_good)
            self.assertEqual(same, staged)
            self.assertEqual(out2, 'already_staged')
            target, result = r.install_no_overwrite(staged, 'Demo.w3x', install)
            self.assertEqual(result, 'installed_no_overwrite')
            self.assertEqual(target.read_bytes(), correct)
            self.assertEqual(r.install_no_overwrite(staged, 'Demo.w3x', install)[1], 'already_installed_same_sha1')
            target.unlink()
            target.write_bytes(b'other data')
            self.assertEqual(r.install_no_overwrite(staged, 'Demo.w3x', install)[1], 'conflict_kept_staged')
            self.assertEqual(target.read_bytes(), b'other data')
            target.unlink()
            os.symlink(staged, target)
            self.assertEqual(r.install_no_overwrite(staged, 'Demo.w3x', install)[1], 'conflict_kept_staged')

    def test_restore_after_game_deletes_map(self):
        data=b'HM3W' + b'rescued binary content'
        digest=hashlib.sha1(data).hexdigest()
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)
            stage=base/'stage'; stage.mkdir()
            dest=base/'warcraft'
            staged=stage/(digest+'-Recovered.w3x')
            staged.write_bytes(data)
            self.assertEqual(restore.restore(stage,dest), 0)
            self.assertEqual((dest/'Recovered.w3x').read_bytes(), data)
            (dest/'Recovered.w3x').unlink()   # simulate Warcraft cleanup
            self.assertEqual(restore.restore(stage,dest), 0)
            self.assertEqual((dest/'Recovered.w3x').read_bytes(), data)
            (dest/'Recovered.w3x').unlink()
            (dest/'Recovered.w3x').write_bytes(b'existing different map')
            self.assertEqual(restore.restore(stage,dest), 0)
            self.assertEqual((dest/'Recovered.w3x').read_bytes(), b'existing different map')
            staged.write_bytes(b'corrupted staged file')
            self.assertEqual(restore.restore(stage,dest), 1)

    def test_live_logic_with_simulated_native_modal(self):
        sha='a'*40
        class FakeSock:
            def close(self):pass
        class FakeWS:
            def __init__(self): self.sock=FakeSock(); self.sent=False
            def recv_frame(self, deadline):
                if not self.sent:
                    self.sent=True
                    return (1,True,b'{"messageType":"ShowDownloadModal","payload":{"fileName":"Maps/Download/Legion.w3x"}}')
                time.sleep(0.02)
                raise TimeoutError()
            def send_control(self,opcode,data=b''):pass
        fake=FakeWS()
        scans=iter([set(), {sha}, {sha}])
        collected=[]
        def fake_fetch(h,name,stage_dir):
            collected.append((h,name))
            return Path('/tmp/verified-test.w3x'), 'downloaded_and_verified'
        with mock.patch.object(r,'connect',return_value=(fake,59774)), \
             mock.patch.object(r,'scan_hashes',side_effect=lambda *args: next(scans)), \
             mock.patch.object(r.time,'sleep', side_effect=lambda seconds: None):
            # Mocking global time.sleep here also speeds up reader timeouts;
            # FakeWS may spin, so expect at least the correlation invariant.
            try:
                value=r.rescue(['1234567890123'],[59774],1,'fixture',20,False,fetch=fake_fetch)
            except StopIteration:
                self.fail('unexpected extra scans in synthetic rescue')
        self.assertEqual(value,0)
        self.assertEqual(collected,[(sha,'Legion.w3x')])


if __name__=='__main__': unittest.main()
