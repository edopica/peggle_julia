#!/usr/bin/env python3
"""Run one benchmark process and record its wall time and peak RSS.

The M4 benchmark measures peak process memory per sweep.  The preferred
instrument is GNU ``time -v`` (``Maximum resident set size (kbytes)``), which
is what wiki/benchmarks/m3-shot.md style reports use.  Some hosts (including
the current Omarchy image) do not ship /usr/bin/time, so this wrapper falls
back to the kernel's per-child high-water mark exposed by
``resource.getrusage(RUSAGE_CHILDREN).ru_maxrss``.  That value is exactly the
kernel ``VmHWM`` of the one child this wrapper waits for, so it is the same
quantity GNU time reports; it is not an estimate.

Usage:
  scripts/bench_process.py --out MEASUREMENT.json --label NAME -- COMMAND ...

The measurement JSON is canonical (sorted keys, one trailing newline).  The
wrapper forwards the child's stdout/stderr untouched and exits with the
child's exit status.  It is stdlib-only.
"""

import argparse
import json
import os
import re
import resource
import subprocess
import sys
import time

GNU_TIME_DEFAULT = "/usr/bin/time"
GNU_TIME_RSS_RE = re.compile(
    r"Maximum resident set size \(kbytes\):\s*(\d+)")


def _load_gnu_time_output(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def _wall_seconds(value):
    return round(float(value), 6)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Run a benchmark command and record wall time + peak RSS.")
    parser.add_argument("--out", required=True,
                        help="measurement JSON output path")
    parser.add_argument("--label", default="",
                        help="label recorded in the measurement JSON")
    parser.add_argument("--time-bin", default=os.environ.get(
                            "GNU_TIME", GNU_TIME_DEFAULT),
                        help="GNU time binary (default: /usr/bin/time or $GNU_TIME)")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="command to run (after --)")
    args = parser.parse_args(argv)

    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("bench_process: ERROR: missing command after --", file=sys.stderr)
        return 2

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    out_json = os.path.abspath(args.out)

    gnu_time = (args.time_bin
                if args.time_bin and os.path.isfile(args.time_bin)
                and os.access(args.time_bin, os.X_OK) else None)

    measurement = {
        "label": args.label,
        "command": command,
    }
    started = time.monotonic()

    if gnu_time is not None:
        time_output_path = out_json + ".gnu-time.txt"
        time_argv = [gnu_time, "-v", "-o", time_output_path, "--"] + command
        try:
            completed = subprocess.run(time_argv)
        except FileNotFoundError as exc:
            measurement.update({
                "exit_code": 127,
                "wall_seconds": _wall_seconds(time.monotonic() - started),
                "peak_rss_kb": None,
                "peak_rss_mb": None,
                "method": "gnu_time_v",
                "method_note": "command not found: %s" % exc,
                "time_tool": gnu_time,
            })
            _write(out_json, measurement)
            return 127
        wall = time.monotonic() - started
        text = _load_gnu_time_output(time_output_path)
        match = GNU_TIME_RSS_RE.search(text)
        peak_kb = int(match.group(1)) if match else None
        measurement.update({
            "exit_code": completed.returncode,
            "wall_seconds": _wall_seconds(wall),
            "peak_rss_kb": peak_kb,
            "peak_rss_mb": (round(peak_kb / 1024.0, 3)
                            if peak_kb is not None else None),
            "method": "gnu_time_v",
            "method_note": ("GNU time -v Maximum resident set size (kbytes) "
                            "of the measured process tree"),
            "time_tool": gnu_time,
            "gnu_time_output": time_output_path,
        })
        _write(out_json, measurement)
        return completed.returncode

    # Fallback: this wrapper waits for exactly one child, so RUSAGE_CHILDREN's
    # high-water mark is that child's peak RSS (Linux reports kbytes, macOS
    # bytes).
    try:
        completed = subprocess.run(command)
        exit_code = completed.returncode
    except FileNotFoundError as exc:
        wall = time.monotonic() - started
        measurement.update({
            "exit_code": 127,
            "wall_seconds": _wall_seconds(wall),
            "peak_rss_kb": None,
            "peak_rss_mb": None,
            "method": "python_resource_ru_maxrss",
            "method_note": "command not found: %s" % exc,
            "time_tool": None,
        })
        _write(out_json, measurement)
        return 127
    wall = time.monotonic() - started
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    raw_maxrss = int(usage.ru_maxrss)
    if sys.platform == "darwin":
        peak_kb = raw_maxrss // 1024
    else:
        peak_kb = raw_maxrss
    measurement.update({
        "exit_code": exit_code,
        "wall_seconds": _wall_seconds(wall),
        "peak_rss_kb": peak_kb,
        "peak_rss_mb": round(peak_kb / 1024.0, 3),
        "method": "python_resource_ru_maxrss",
        "method_note": ("resource.getrusage(RUSAGE_CHILDREN).ru_maxrss after "
                        "waiting for the single measured child; the kernel "
                        "high-water mark (VmHWM), same quantity as GNU time -v"),
        "time_tool": None,
    })
    _write(out_json, measurement)
    return exit_code


def _write(path, measurement):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(measurement, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    sys.exit(main())
