#!/usr/bin/env python3
"""Validate Peggle Evolved interchange artifacts against versioned schemas.

Implements the small JSON-Schema subset used by schemas/*.schema.json:
$ref (local JSON pointers), type, enum, minimum, maximum, minLength, pattern,
minItems, items, properties, required, additionalProperties, oneOf.

Beyond schema validation, level artifacts are checked for cross-field
invariants: contiguous peg ids, effective type counts, and line-group
consistency (ids, index ordering, matching metadata). Checkpoints are
checked for ready-to-aim invariants: complete identity/match state, unique
and ordered ids, consistent purple queues, authoritative scoring fields with
their derived multiplier/fever consistency and zeroed per-turn accumulators,
reset tracker state, and inactive clearing (timer 0; is_end_of_turn is
retained and inert).

Usage:
  scripts/validate_interchange.py [FILES...]
  scripts/validate_interchange.py --interchange DIR --fixtures DIR

With no files, validates interchange/config.v1.json,
interchange/levels/*.v1.json, and fixtures/expected/*.json relative to the
repository root.
"""

import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
SCHEMA_DIR = os.path.join(REPO_ROOT, "schemas")

FORMAT_SCHEMAS = {
    "peggle.level": "level.v1.schema.json",
    "peggle.config": "config.v1.schema.json",
    "peggle.checkpoint": "checkpoint.v1.schema.json",
    "peggle.action_log": "action-log.v1.schema.json",
    "peggle.shot_result": "shot-result.v1.schema.json",
    "peggle.fixture": "fixture.v1.schema.json",
}


class ValidationError(Exception):
    pass


def resolve_pointer(root, pointer):
    if pointer in ("", "#"):
        return root
    if not pointer.startswith("#/"):
        raise ValidationError(f"unsupported $ref {pointer!r}")
    node = root
    for raw in pointer[2:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, list):
            node = node[int(token)]
        else:
            node = node[token]
    return node


def json_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    raise ValidationError(f"unknown python type {type(value)!r}")


def type_matches(value, expected):
    actual = json_type(value)
    if expected == "number":
        return actual in ("integer", "number")
    return actual == expected


def validate(instance, schema, root, path="$"):
    if "$ref" in schema:
        return validate(instance, resolve_pointer(root, schema["$ref"]), root, path)

    if "oneOf" in schema:
        matches = []
        for index, subschema in enumerate(schema["oneOf"]):
            try:
                validate(instance, subschema, root, path)
                matches.append(index)
            except ValidationError:
                pass
        if len(matches) != 1:
            raise ValidationError(
                f"{path}: expected exactly one oneOf match, got {matches}"
            )

    if "type" in schema:
        expected = schema["type"]
        if not type_matches(instance, expected):
            raise ValidationError(
                f"{path}: expected type {expected}, got {json_type(instance)}"
            )

    if "enum" in schema and instance not in schema["enum"]:
        raise ValidationError(
            f"{path}: value {instance!r} is not one of {schema['enum']!r}"
        )

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValidationError(
                f"{path}: {instance} is below minimum {schema['minimum']}"
            )
        if "maximum" in schema and instance > schema["maximum"]:
            raise ValidationError(
                f"{path}: {instance} is above maximum {schema['maximum']}"
            )

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise ValidationError(
                f"{path}: string is shorter than minLength {schema['minLength']}"
            )
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            raise ValidationError(
                f"{path}: {instance!r} does not match pattern {schema['pattern']!r}"
            )

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise ValidationError(
                f"{path}: array has fewer than minItems {schema['minItems']}"
            )
        if "items" in schema:
            for index, item in enumerate(instance):
                validate(item, schema["items"], root, f"{path}[{index}]")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                raise ValidationError(f"{path}: missing required key {key!r}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            if key in properties:
                validate(value, properties[key], root, f"{path}.{key}")
            elif additional is False:
                raise ValidationError(f"{path}: unexpected key {key!r}")
            elif isinstance(additional, dict):
                validate(value, additional, root, f"{path}.{key}")


def check_level_invariants(artifact, path):
    pegs = artifact["pegs"]
    counts = artifact["type_counts"]
    total = counts["blue"] + counts["green"] + counts["purple"] + counts["red"]
    if total != len(pegs):
        raise ValidationError(
            f"{path}: type_counts sum {total} != peg count {len(pegs)}"
        )
    derived_blue = len(pegs) - counts["red"] - counts["green"] - counts["purple"]
    if counts["blue"] != derived_blue:
        raise ValidationError(
            f"{path}: type_counts.blue {counts['blue']} != derived {derived_blue}"
        )

    for index, peg in enumerate(pegs):
        if peg["id"] != index + 1:
            raise ValidationError(
                f"{path}: peg at position {index + 1} has id {peg['id']}"
            )

    groups = {}
    group_order = []
    previous_index = {}
    for peg in pegs:
        line = peg.get("line")
        if line is None:
            continue
        key = line["id"]
        if key not in groups:
            groups[key] = {"count": line["count"], "closed": line["closed"],
                           "gap": line["gap"], "indexes": []}
            group_order.append(key)
        group = groups[key]
        for field in ("count", "closed", "gap"):
            if group[field] != line[field]:
                raise ValidationError(
                    f"{path}: line {key!r} has inconsistent {field}"
                )
        expected = previous_index.get(key, 0) + 1
        if line["index"] != expected:
            raise ValidationError(
                f"{path}: line {key!r} index {line['index']} is not contiguous "
                f"(expected {expected})"
            )
        previous_index[key] = line["index"]
        group["indexes"].append(line["index"])
    for key in group_order:
        group = groups[key]
        if len(group["indexes"]) != group["count"]:
            raise ValidationError(
                f"{path}: line {key!r} declares {group['count']} pegs but "
                f"holds {len(group['indexes'])}"
            )


def derived_multiplier(red_pegs_hit_amount, total_red_pegs):
    """Engine:updateMultiplier threshold ladder (core.lua:306-320)."""
    if total_red_pegs == 0:
        return 1
    percentage = red_pegs_hit_amount / total_red_pegs
    if percentage >= 1.0:
        return 100
    if percentage >= 0.88:
        return 10
    if percentage >= 0.75:
        return 5
    if percentage >= 0.60:
        return 3
    if percentage >= 0.40:
        return 2
    return 1


def check_checkpoint_invariants(artifact, path):
    boundary = artifact["boundary"]
    if boundary != "ready_to_aim":
        raise ValidationError(
            f"{path}.boundary: {boundary!r} is not supported by v1 "
            f"(only 'ready_to_aim'; mid-shot capture requires a schema "
            f"version bump)"
        )

    engine = artifact["engine"]

    used = engine["used_ball_ids"]
    if len(set(used)) != len(used):
        raise ValidationError(
            f"{path}.engine.used_ball_ids: ids must be unique"
        )
    for ball_id in used:
        if ball_id < 1:
            raise ValidationError(
                f"{path}.engine.used_ball_ids: id {ball_id} is below 1"
            )
    next_id = engine["next_ball_id"]
    if used and next_id <= max(used):
        raise ValidationError(
            f"{path}.engine.next_ball_id: {next_id} must be greater than "
            f"max used_ball_id {max(used)}"
        )

    ball_ids = [ball["id"] for ball in engine["balls"]]
    if len(set(ball_ids)) != len(ball_ids):
        raise ValidationError(
            f"{path}.engine.balls: ball ids must be unique"
        )
    for index, ball in enumerate(engine["balls"]):
        if ball["id"] not in used:
            raise ValidationError(
                f"{path}.engine.balls[{index}].id: {ball['id']} is not in "
                f"used_ball_ids"
            )
        if ball["id"] >= next_id:
            raise ValidationError(
                f"{path}.engine.balls[{index}].id: {ball['id']} is not "
                f"below next_ball_id {next_id}"
            )
        if ball["launched"]:
            raise ValidationError(
                f"{path}.engine.balls[{index}].launched: ready_to_aim "
                f"balls must be unlaunched"
            )

    pegs = engine["pegs"]
    peg_by_id = {}
    previous_id = None
    for index, peg in enumerate(pegs):
        if not isinstance(peg["hit"], bool):
            raise ValidationError(
                f"{path}.engine.pegs[{index}].hit: must be a boolean"
            )
        peg_id = peg["id"]
        if peg_id in peg_by_id:
            raise ValidationError(
                f"{path}.engine.pegs[{index}].id: duplicate peg id {peg_id}"
            )
        if previous_id is not None and peg_id <= previous_id:
            raise ValidationError(
                f"{path}.engine.pegs[{index}].id: peg ids must be strictly "
                f"ascending in engine order; {peg_id} follows {previous_id}"
            )
        previous_id = peg_id
        peg_by_id[peg_id] = peg

    queue = artifact["purple_queue"]["queue"]
    active = artifact["purple_queue"]["active"]
    overlap = set(queue) & set(active)
    if overlap:
        raise ValidationError(
            f"{path}.purple_queue: queue and active must be disjoint; "
            f"overlap on {sorted(overlap)}"
        )
    for index, peg_id in enumerate(queue):
        peg = peg_by_id.get(peg_id)
        if peg is None:
            raise ValidationError(
                f"{path}.purple_queue.queue[{index}]: peg id {peg_id} is "
                f"not on the board"
            )
        if peg["type"] != "blue" or peg["hit"]:
            raise ValidationError(
                f"{path}.purple_queue.queue[{index}]: peg id {peg_id} must "
                f"be an un-hit blue peg, got type {peg['type']!r} with "
                f"hit {peg['hit']!r}"
            )
    for index, peg_id in enumerate(active):
        peg = peg_by_id.get(peg_id)
        if peg is None:
            raise ValidationError(
                f"{path}.purple_queue.active[{index}]: peg id {peg_id} is "
                f"not on the board"
            )
        if peg["type"] != "purple":
            raise ValidationError(
                f"{path}.purple_queue.active[{index}]: peg id {peg_id} must "
                f"be a purple peg, got type {peg['type']!r}"
            )

    if engine["turn_pegs_hit"]:
        raise ValidationError(
            f"{path}.engine.turn_pegs_hit: must be empty at ready_to_aim"
        )

    clearing = engine["clearing"]
    # Engine:resetTurn() clears the queue and timer but not
    # clearingIsEndOfTurn (core.lua:510-554). That flag is set by
    # Engine:startClearing(isEndOfTurn) (core.lua:1019) and read only while
    # the queue drains (core.lua:1059), so while clearing is inactive it is a
    # retained, inert flag: both true and false are valid at ready_to_aim.
    if clearing["active"]:
        raise ValidationError(
            f"{path}.engine.clearing.active: must be false at ready_to_aim"
        )
    if clearing["timer"] != 0:
        raise ValidationError(
            f"{path}.engine.clearing.timer: must be 0 at ready_to_aim"
        )

    reds_hit = engine["red_pegs_hit_amount"]
    total_reds = engine["total_red_pegs"]
    if reds_hit > total_reds:
        raise ValidationError(
            f"{path}.engine.red_pegs_hit_amount: {reds_hit} exceeds "
            f"total_red_pegs {total_reds}"
        )
    expected_multiplier = derived_multiplier(reds_hit, total_reds)
    if engine["current_multiplier"] != expected_multiplier:
        raise ValidationError(
            f"{path}.engine.current_multiplier: "
            f"{engine['current_multiplier']} does not match derived "
            f"{expected_multiplier} from red_pegs_hit_amount {reds_hit} / "
            f"total_red_pegs {total_reds} (core.lua:306-320)"
        )
    fever_expected = engine["current_multiplier"] == 100
    if engine["is_fever"] != fever_expected:
        raise ValidationError(
            f"{path}.engine.is_fever: {engine['is_fever']} must be "
            f"(current_multiplier == 100) == {fever_expected}"
        )
    if engine["bonus_score"] != 0:
        raise ValidationError(
            f"{path}.engine.bonus_score: must be 0 at ready_to_aim "
            f"(Engine:resetTurn resets it, core.lua:544)"
        )
    if engine["style_score"] != 0:
        raise ValidationError(
            f"{path}.engine.style_score: must be 0 at ready_to_aim "
            f"(Engine:resetTurn resets it, core.lua:545)"
        )

    trackers = artifact["trackers"]
    style_shots = trackers["style_shots"]
    for key in ("last_impact", "qualifying_streak", "last_qualifying_seq",
                "bucket_bounced", "bounced_after_bucket", "side_wall_hit",
                "hit_any_peg", "awarded", "slide_runs", "slide_awarded"):
        if style_shots[key]:
            raise ValidationError(
                f"{path}.trackers.style_shots.{key}: must be an empty "
                f"object at ready_to_aim"
            )
    ball_state = trackers["ball_state"]
    for key in ("idle", "idle_timer", "reacted"):
        if ball_state[key]:
            raise ValidationError(
                f"{path}.trackers.ball_state.{key}: must be an empty "
                f"object at ready_to_aim"
            )
    if ball_state["all_idle_latch"]:
        raise ValidationError(
            f"{path}.trackers.ball_state.all_idle_latch: must be false at "
            f"ready_to_aim"
        )
    if ball_state["no_score_timer"] != 0:
        raise ValidationError(
            f"{path}.trackers.ball_state.no_score_timer: must be 0 at "
            f"ready_to_aim"
        )
    if ball_state["no_score_timeout_fired"]:
        raise ValidationError(
            f"{path}.trackers.ball_state.no_score_timeout_fired: must be "
            f"false at ready_to_aim"
        )
    slide_inversion = trackers["slide_inversion"]
    for key in ("line_hits", "hit_seen", "removed", "track"):
        if slide_inversion[key]:
            raise ValidationError(
                f"{path}.trackers.slide_inversion.{key}: must be an empty "
                f"object at ready_to_aim"
            )

    match = artifact["match"]
    player_count = len(match["players"])
    if player_count != 2:
        raise ValidationError(
            f"{path}.match.players: expected exactly 2 players, got "
            f"{player_count}"
        )
    if not match["game_over"] and "winner" in match:
        raise ValidationError(
            f"{path}.match.winner: must be absent while game_over is false"
        )


def check_fixture_invariants(artifact, path):
    if artifact.get("kind") != "shot":
        return
    action = artifact.get("action") or {}
    completion = artifact.get("completion") or {}
    result = artifact.get("result") or {}

    shot_result = {
        "format": "peggle.shot_result",
        "schema_version": 1,
        "action": {
            "aim_index": action.get("aim_index"),
            "delay": action.get("delay", 0),
        },
        "steps": completion.get("steps"),
        "completed": completion.get("completed"),
        "reason": completion.get("reason"),
    }
    if action.get("angle") is not None:
        shot_result["angle"] = action["angle"]
    shot_result.update(result)

    schema_path = os.path.join(
        SCHEMA_DIR, FORMAT_SCHEMAS["peggle.shot_result"]
    )
    with open(schema_path, "r", encoding="utf-8") as handle:
        schema = json.load(handle)
    validate(shot_result, schema, schema, f"{path}.result")


def validate_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        artifact = json.load(handle)
    fmt = artifact.get("format")
    if fmt not in FORMAT_SCHEMAS:
        raise ValidationError(f"{path}: unknown format {fmt!r}")
    schema_path = os.path.join(SCHEMA_DIR, FORMAT_SCHEMAS[fmt])
    with open(schema_path, "r", encoding="utf-8") as handle:
        schema = json.load(handle)
    validate(artifact, schema, schema, path)
    if fmt == "peggle.level":
        check_level_invariants(artifact, path)
    elif fmt == "peggle.checkpoint":
        check_checkpoint_invariants(artifact, path)
    elif fmt == "peggle.fixture":
        check_fixture_invariants(artifact, path)


def default_files(args):
    files = []
    files.extend(sorted(glob.glob(os.path.join(args.interchange, "levels", "*.v1.json"))))
    config = os.path.join(args.interchange, "config.v1.json")
    if os.path.exists(config):
        files.append(config)
    files.extend(sorted(glob.glob(os.path.join(args.fixtures, "*.json"))))
    files.extend(sorted(glob.glob(os.path.join(REPO_ROOT, "schemas", "examples", "*.json"))))
    return files


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", help="artifact files to validate")
    parser.add_argument(
        "--interchange",
        default=os.path.join(REPO_ROOT, "interchange"),
        help="interchange directory used when no files are given",
    )
    parser.add_argument(
        "--fixtures",
        default=os.path.join(REPO_ROOT, "fixtures", "expected"),
        help="fixture directory used when no files are given",
    )
    args = parser.parse_args(argv)

    files = args.files or default_files(args)
    if not files:
        print("validate_interchange: no artifact files found", file=sys.stderr)
        return 1

    failures = 0
    for path in files:
        try:
            validate_file(path)
            print(f"OK   {os.path.relpath(path, REPO_ROOT)}")
        except ValidationError as error:
            failures += 1
            print(f"FAIL {os.path.relpath(path, REPO_ROOT)}: {error}", file=sys.stderr)
        except (OSError, json.JSONDecodeError, KeyError) as error:
            failures += 1
            print(f"FAIL {os.path.relpath(path, REPO_ROOT)}: {error}", file=sys.stderr)

    if failures:
        print(f"validate_interchange: {failures} file(s) failed", file=sys.stderr)
        return 1
    print(f"validate_interchange: {len(files)} file(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
