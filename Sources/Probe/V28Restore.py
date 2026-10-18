#!/usr/bin/env python3
"""Restore SHA-1-verified MapDash Rescue staging files, without overwriting."""
from pathlib import Path
import re

from V28Rescue import STAGE_DIR, MAP_DIR, digest_file, install_no_overwrite

VALID_STAGED = re.compile(r'^([0-9a-f]{40})-(?!\.)([^/\\:\x00-\x1f\x7f]+\.(?:w3x|w3m))$', re.IGNORECASE)


def restore(stage_dir=STAGE_DIR, map_dir=MAP_DIR):
    if not stage_dir.is_dir():
        print('v28_restore=no_staged_maps')
        return 0
    installed=0
    conflicts=0
    invalid=0
    for path in sorted(stage_dir.iterdir()):
        if path.is_symlink() or not path.is_file():
            continue
        match=VALID_STAGED.fullmatch(path.name)
        if not match:
            continue
        digest, name = match.group(1), match.group(2)
        # Every copy is re-hashed, even if the filename claims a valid digest.
        if digest_file(path) != digest.lower():
            invalid+=1
            print('v28_restore_skipped=corrupt_stage_file name=%s' % name)
            continue
        _,result=install_no_overwrite(path, name, map_dir)
        if result=='installed_no_overwrite':
            installed+=1
        elif result=='conflict_kept_staged':
            conflicts+=1
        print('v28_restore_file=%s result=%s' % (name,result))
    print('v28_restore_summary installed=%d conflicts=%d invalid=%d' %
          (installed,conflicts,invalid))
    return 0 if not invalid else 1


if __name__=='__main__':
    raise SystemExit(restore())
