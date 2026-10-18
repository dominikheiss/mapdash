#!/usr/bin/env python3
"""Offline proof for V29 read-only WebSocket list parsing and event lifetimes."""
import importlib.util
import io
import json
import sys
from contextlib import redirect_stdout
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / 'Sources/Probe'
sys.path.insert(0, str(SRC))
import V29LobbyBridge as bridge


def fake_game(id, name, map_file, players=1, cap=12):
    return {'id': id, 'name': name, 'mapFile': map_file,
            'currentPlayers': players, 'maxPlayers': cap,
            'mapProperties': {'playerHost': 'PRIVATE#12345'}}


def run():
    store = bridge.LobbyStore()
    assert not store.ready and store.snapshot()['games'] == []
    base = {'messageType': 'GameList', 'payload': {'games': [
        fake_game(10, 'Footmen Frenzy OFFICIAL #10', 'Maps/Download/Footmen.w3x', 2, 24),
        fake_game(20, 'Example', 'Maps/Download/Example.w3m')]}}
    assert store.accept(base)
    s = store.snapshot()
    assert s['total'] == 2 and s['verifiedHashes'] is False
    assert s['games'][0]['map'] == 'Example.w3m'
    assert 'PRIVATE' not in json.dumps(s)
    assert not store.accept(base)
    assert store.accept({'messageType': 'GameListUpdate', 'payload': {'game':
        fake_game(10, 'Footmen Frenzy OFFICIAL #10', 'Maps/Download/Footmen.w3x', 3, 24)}})
    assert store.snapshot()['games'][1]['players'] == 3
    assert store.accept({'messageType': 'GameListRemove', 'payload': {'game': {'id': 20}}})
    assert store.snapshot()['total'] == 1
    assert not store.accept({'messageType': 'ProgressDownloadModal', 'payload': {'downloadPercentage': 1}})
    assert bridge.game_summary({'id': 42, 'name': 'Oops', 'mapFile': '../../not-a-map.exe'}) is None
    assert bridge.game_summary({'id': 42, 'name': 'Oops', 'mapFile': '.hidden.w3x'}) is not None
    assert bridge.game_summary({'id': 42, 'name': 'No map'}) is None
    assert bridge.game_summary({'id': 42, 'name': 'U', 'mapFile': 'M.w3x', 'currentPlayers': True})['players'] == 0
    assert bridge.safe_text('foo\x00bar') == 'foobar'
    assert bridge.map_filename('Maps\\Download\\Hello.W3X') == 'Hello.W3X'
    assert not store.accept({'messageType': 'GameList', 'payload': {'games': 'bad'}})
    assert store.snapshot()['total'] == 1
    assert store.accept({'messageType': 'GameList', 'payload': {'games': []}})
    assert store.snapshot()['total'] == 0
    with redirect_stdout(io.StringIO()) as captured:
        bridge.emit(store.snapshot())
    assert json.loads(captured.getvalue())['verifiedHashes'] is False
    print('v29 lobby bridge offline tests passed')


if __name__ == '__main__':
    run()
