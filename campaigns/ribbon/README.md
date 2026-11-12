# Current ribbon campaign inputs

`config.v1.json` is exported from the working Lua game's `src/config.lua`.
`config.source.lua` and `game.source.lua` preserve the exact config and match
methods used by this campaign. `provenance.json` records their hashes and the
Lua revision; the config is explicitly marked dirty when it differs from HEAD.

Sync or verify from the Julia repository root:

```bash
julia --project=julia/PeggleSim scripts/sync_campaign_config.jl
julia --project=julia/PeggleSim scripts/sync_campaign_config.jl --check
luajit tools/capture_match_rules.lua > fixtures/matches/rules.v1.json
```

The current config is synced from peggle_evolved `10ee3a0` ("Reshape bucket
with side ramps, hold shot end after catch, fix multiball"): gravity 700,
launch speed 400, wall damping 0.8, and the 10ee3a0 bucket keys
(`bucket_rim_width`, `bucket_rim_height`, `bucket_ramp_slope_deg`,
`bucket_catch_hold`, render-only `bucket_rim_color`; no `bucket_edge`). Those
keys select `RULES_RAMP_BUCKET` in Julia: ramp bucket, catch hold and one-ball
multiball (see [bucket ramps](../../wiki/context/bucket-ramps.md)).
`provenance.json` lists every difference from the ribbon fixture config.
The first sync (at `bbd8622`) found no differences from that fixture.
Unlike that historical fixture, this directory is the current campaign input;
future parameter changes should be synced here without rewriting trace goldens
or previous benchmark inputs.

The rule oracle executes the saved Lua GameState methods with an engine double.
It covers match bookkeeping only; Julia's existing ribbon Lua-trace corpus
covers shot physics. The tests compare the Julia match handoff against that
oracle, including canceled no-red scores, floor-rounded penalties, escalating
shared catch bonuses, skipped exhausted players, score-based winners and ties.
