#!/usr/bin/env python3
"""Render a baseline summary JSON (harness output) as Markdown.

Usage: scripts/render_summary.py results/RUN.summary.json
"""
import json
import sys
from pathlib import Path


def phase(row, name, stat):
    return row["phases"][name][stat]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    data = json.loads(path.read_text())

    ref = data.get("reference", {})
    grid = data.get("grid", {})
    host = data.get("host", {})
    opts = data.get("options", {})
    cold = data.get("cold_start", {})
    mem = data.get("memory", {})

    print(f"# Baseline summary: `{path.name}`")
    print()
    print(f"- Run id: `{data.get('run_id')}`")
    print(f"- Date (UTC): {data.get('date_utc')}")
    print(f"- Harness version: {data.get('harness_version')}")
    print(f"- Reference: `{ref.get('revision')}` (tree `{ref.get('tree')}`)")
    print(f"- Config SHA-256: `{ref.get('config_sha256')}`")
    print(f"- Grid: {grid.get('count')} indices ({grid.get('steps')} steps), mismatches={grid.get('mismatches')}")
    print(f"- Options: stride={opts.get('stride')} indices={opts.get('index_count')} "
          f"max_steps={opts.get('max_steps')} clearing={opts.get('clearing')} "
          f"replay_serialize={opts.get('replay_serialize')} warmup={opts.get('warmup')} "
          f"repeat={opts.get('repeat_count')}")
    print(f"- Host: {host.get('cpu_model')} x{host.get('cpu_processors')}, "
          f"{host.get('mem_total_kb', 0) // 1024} MiB RAM, {host.get('os')}")
    print(f"- Runtime: {host.get('luajit')}, LÖVE {host.get('love_version')}, jit={host.get('jit_status')}")
    print(f"- Cold start: process age at load {cold.get('process_age_at_load_ms'):.1f} ms, "
          f"setup {cold.get('setup_seconds'):.3f} s")
    print(f"- Memory: RSS {mem.get('rss_kb_start')} -> {mem.get('rss_kb_end')} KiB, "
          f"Lua heap {mem.get('lua_kb_start'):.0f} -> {mem.get('lua_kb_end'):.0f} KiB")
    print()

    header = ("| workload | balls | cand | done | inc | sweep s | cand/s | steps/s | "
              "init p50 | reset p50 | sim p50 | sim p90 | extract p50 | output p50 |")
    sep = "|" + "---|" * 14
    print(header)
    print(sep)
    for row in data.get("workloads", []):
        print("| {} | {} | {} | {} | {} | {:.2f} | {:.1f} | {:.0f} | {:.0f} | {:.0f} | {:.0f} | {:.0f} | {:.0f} | {:.0f} |".format(
            row["workload"], row["balls"], row["candidates"], row["completed"],
            row["incomplete"], row["wall_seconds"], row["candidates_per_second"],
            row["sim_steps_per_second"],
            phase(row, "init", "p50"), phase(row, "reset", "p50"),
            phase(row, "sim", "p50"), phase(row, "sim", "p90"),
            phase(row, "extract", "p50"), phase(row, "output", "p50")))
    print()

    totals = data.get("totals", {})
    print(f"Totals: {totals.get('candidates')} candidates, {totals.get('completed')} completed, "
          f"{totals.get('incomplete')} incomplete, {totals.get('wall_seconds'):.1f} s "
          f"({totals.get('candidates', 0) / max(totals.get('wall_seconds', 1), 1e-9):.1f} candidates/s).")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
