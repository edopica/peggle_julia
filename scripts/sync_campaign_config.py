#!/usr/bin/env python3
"""Export the current Lua config into campaign inputs, preserving golden fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--lua-root', type=Path, default=ROOT.parent / 'peggle_evolved')
p.add_argument('--out-dir', type=Path, default=ROOT / 'campaigns/ribbon')
p.add_argument('--check', action='store_true', help='check the saved export against the Lua source')
a = p.parse_args()
lua = a.lua_root.resolve()
source = (lua / 'src/config.lua').read_bytes()
game_source = (lua / 'src/states/game.lua').read_bytes()
sha = hashlib.sha256(source).hexdigest()
cmd = ['luajit', str(ROOT/'tools/export_config.lua'), '--reference', str(lua), '--source-sha256', sha]
export = subprocess.check_output(cmd, cwd=ROOT)
config = json.loads(export)
old = json.loads((ROOT/'fixtures/ribbon_waves/config.dev.v1.json').read_text())['values']
changes = {k: {'previous': old.get(k), 'current': v} for k,v in config['values'].items() if old.get(k) != v}
if a.check:
    assert (a.out_dir/'config.v1.json').read_bytes() == export, 'campaign export differs from current Lua config'
    assert (a.out_dir/'config.source.lua').read_bytes() == source, 'saved Lua source differs'
    assert (a.out_dir/'game.source.lua').read_bytes() == game_source, 'saved match rules differ'
    print('Campaign config matches current Lua source:', sha)
else:
    a.out_dir.mkdir(parents=True, exist_ok=True)
    (a.out_dir/'config.v1.json').write_bytes(export)
    (a.out_dir/'config.source.lua').write_bytes(source)
    (a.out_dir/'game.source.lua').write_bytes(game_source)
    metadata = {'source': '../peggle_evolved/src/config.lua', 'source_sha256': sha, 'game_source_sha256': hashlib.sha256(game_source).hexdigest(),
                'lua_revision': subprocess.check_output(['git','-C',str(lua),'rev-parse','HEAD'],text=True).strip(),
                'lua_config_dirty': bool(subprocess.check_output(['git','-C',str(lua),'status','--porcelain','--','src/config.lua'],text=True).strip()),
                'changes_from_ribbon_fixture': changes}
    (a.out_dir/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps(metadata,indent=2))
