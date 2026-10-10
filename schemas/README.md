# Interchange schemas

Versioned JSON-Schema definitions for every M1 interchange artifact. The
rationale and format notes are in `wiki/context/interchange.md`.

| Schema | Format value |
| --- | --- |
| `level.v1.schema.json` | `peggle.level` |
| `config.v1.schema.json` | `peggle.config` |
| `checkpoint.v1.schema.json` | `peggle.checkpoint` |
| `action.v1.schema.json` | (referenced by logs and results) |
| `action-log.v1.schema.json` | `peggle.action_log` |
| `shot-result.v1.schema.json` | `peggle.shot_result` |
| `fixture.v1.schema.json` | `peggle.fixture` |

## Validation

`scripts/validate_interchange.py` implements the subset of draft-07 used by
these files, so no third-party dependency is required:

`$ref` (local pointers), `type`, `enum`, `minimum`, `maximum`, `minLength`,
`pattern`, `minItems`, `items`, `properties`, `required`,
`additionalProperties`, and `oneOf` (exactly one match).

```bash
scripts/validate_interchange.py                  # artifacts, fixtures, examples
scripts/validate_interchange.py path/to/file...  # specific files
```

The validator also enforces cross-field invariants. Levels: contiguous peg
ids, effective type counts, and consistent line-group metadata. Checkpoints:
the `ready_to_aim` boundary only, complete ball-ID allocation state,
unlaunched balls, ordered unique peg ids, consistent purple queues, inactive
clearing (`timer` 0; `is_end_of_turn` is retained and may be true) with reset
tracker state and authoritative scoring fields (`hit_counter`, `total_red_pegs`,
`red_pegs_hit_amount`) whose derived values must match (`current_multiplier`
from the core.lua:306-320 thresholds; `is_fever` iff `current_multiplier == 100`;
`bonus_score`/`style_score` 0 at ready-to-aim), and exactly two match players
with no `winner` before `game_over`. Shot fixtures: the embedded `result`
must validate as a `peggle.shot_result`, so a zero-style `styles` value must
be `{}`, never `[]`.

## Versioning

`schema_version` is an integer that increments on any incompatible change;
`format` selects the schema. Provenance fields (`reference_revision`,
`reference_tree`, `config_sha256`) always identify the source revision.
Artifacts are written with the canonical encoder in
`tools/canonical_json.lua`, so byte-identical output is a valid equality
check across machines.

## Examples

`examples/` contains captured, schema-valid examples of the shot-result and
action-log formats. `checkpoint.v1.example.json` is the captured fixture-grade
`super_long_shot` ready-to-aim record, byte-identical to
`fixtures/checkpoints/super_long_shot.v1.json`; the full captured checkpoint
set lives in `fixtures/checkpoints/`. Level, config, and fixture examples are
the generated artifacts themselves under `interchange/` and `fixtures/`.
