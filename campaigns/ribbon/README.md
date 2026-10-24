# Current ribbon campaign inputs

`config.v1.json` is exported from the working Lua game's `src/config.lua`.
`config.source.lua` and `game.source.lua` preserve the exact config and match
methods used by this campaign. `provenance.json` records their hashes and the
Lua revision; the config is explicitly marked dirty when it differs from HEAD.

Sync or verify from the Julia repository root:

```bash
python3 scripts/sync_campaign_config.py
python3 scripts/sync_campaign_config.py --check
luajit tools/capture_match_rules.lua > fixtures/matches/rules.v1.json
```

The current values are gravity 700, launch speed 600 and wall damping 1.0.
The first sync found no differences from the existing ribbon fixture config.
Unlike that historical fixture, this directory is the current campaign input;
future parameter changes should be synced here without rewriting trace goldens
or previous benchmark inputs.

The rule oracle executes the saved Lua GameState methods with an engine double.
It covers match bookkeeping only; Julia's existing ribbon Lua-trace corpus
covers shot physics. The tests compare the Julia match handoff against that
oracle, including canceled no-red scores, floor-rounded penalties, escalating
shared catch bonuses, skipped exhausted players, score-based winners and ties.
