#!/usr/bin/env python3
"""Phase 2 diagnostics, deliberately separate from headline benchmarks.

One fresh Julia process per worker setting, paired timers on/off, plus separate
one-worker CPU/allocation profiles. Raw evidence is checksum-verified in a
compressed archive; compact records retain every trial. No baseline is replaced.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

from benchmark_schema import (capture_source_snapshot, collect_host_metadata,
                              compute_harness_fingerprint, create_archive_exclusive,
                              get_git_info, harness_files, reserve_run,
                              sha256_file, write_csv_rows)

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = "campaign-diagnostics/1"


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def sample_rss(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    except FileNotFoundError:
        pass
    return None


def run_child(command, raw, label, interval):
    """External sampler; never schedules sampling tasks on simulation workers."""
    started = time.monotonic()
    launch_unix = time.time()
    child_out = raw / label
    samples = []
    with (raw / f"{label}.log").open("x") as log, (raw / f"{label}-rss.csv").open("x") as mem:
        writer = csv.writer(mem)
        writer.writerow(["elapsed_seconds", "stage", "rss_bytes"])
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                value = sample_rss(process.pid) if sys.platform.startswith("linux") else None
                stage_file = child_out / "stage.txt"
                stage = stage_file.read_text() if stage_file.exists() else "load_or_warmup"
                if value is not None:
                    writer.writerow([time.monotonic() - started, stage, value])
                    samples.append((stage, value))
                time.sleep(interval)
            if process.returncode:
                raise RuntimeError(f"{label} failed ({process.returncode}); see {log.name}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    report = json.loads((child_out / "report.json").read_text())
    report.update(process_wall_seconds=time.monotonic()-started,
                  process_launch_unix_seconds=launch_unix,
                  launch_to_entry_seconds=report["entry_unix_seconds"]-launch_unix,
                  command=command, external_rss_sample_interval_seconds=interval)
    for trial in report["trials"]:
        stage = f"campaign-r{trial['repeat']}-{str(trial['phase_instrumentation']).lower()}"
        values = [v for s, v in samples if s == stage]
        trial["sampled_campaign_peak_rss_bytes"] = max(values) if values else None
        trial["rss_sample_count"] = len(values)
    save(child_out / "report.json", report)
    return report


def validate_reports(reports, games, allow_incomplete=False):
    trials = [t for r in reports for t in r["trials"]]
    hashes = {t["gameplay_sha256"] for t in trials}
    hashes.update(r["warmup_gameplay_sha256"] for r in reports)
    if len(hashes) != 1:
        raise ValueError("gameplay hashes differ across trials/profiles/warmups")
    if not allow_incomplete and any(t["completed_matches"] != games for t in trials):
        raise ValueError("incomplete matches; retained as failed diagnostic evidence")
    if len({t["candidates"] for t in trials}) != 1:
        raise ValueError("candidate counts differ")
    for r in reports:
        if r["kind"] == "cpu":
            for t in r["trials"]:
                if t["cpu"]["buffer_full"] or not t["cpu"]["samples"]:
                    raise ValueError("CPU profile is empty or truncated")
    return next(iter(hashes))


def spread(values):
    return f"{statistics.median(values):.3f} [{min(values):.3f}, {max(values):.3f}]"


def generate_report(run_id, reports, gameplay_hash, smoke=False):
    lines = [f"# Campaign diagnostics {run_id}", "", f"Protocol: `{PROTOCOL}`. Gameplay SHA-256: `{gameplay_hash}`.", "",
             "Smoke run; incomplete matches permitted, not performance evidence." if smoke else
             "Every measured trial and warmup has identical gameplay; all matches complete.", "",
             "Times are median [min, max] seconds. Each worker setting uses a fresh process with a fixed Julia/GC thread budget. Profilers are excluded from timing rows.", "",
             "| Workers | Phases | N | End-to-end s | Setup/simulation s | Verification/output s | Allocated MiB | GC s | GC collections |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    overhead_lines = []
    for r in reports:
        if r["kind"] != "timing":
            continue
        workers = r["options"]["workers"]
        for enabled in (True, False):
            ts = [t for t in r["trials"] if t["phase_instrumentation"] == enabled]
            lines.append(f"| {workers} | {enabled} | {len(ts)} | " + " | ".join(
                spread([t[k] for t in ts]) for k in ("wall_seconds", "campaign_setup_and_simulation_seconds", "verification_and_output_seconds")) +
                f" | {spread([t['allocated_bytes']/2**20 for t in ts])} | {spread([t['gc_seconds'] for t in ts])} | {spread([t['gc_collections'] for t in ts])} |")
        pairs = {}
        for t in r["trials"]:
            pairs.setdefault(t["repeat"], {})[t["phase_instrumentation"]] = t["wall_seconds"]
        overhead = [(p[True]/p[False]-1)*100 for p in pairs.values()]
        overhead_lines.extend(["", f"Workers {workers}: paired instrumentation overhead {spread(overhead)}%; positive means timers enabled was slower. {len(pairs)} pairs describe variability; small differences do not establish a gain.", ""])
    lines.extend(overhead_lines)
    lines.extend(["", "GC fraction is available from each raw trial as gc_seconds / wall_seconds; GC time is process-wide elapsed collection time, not aggregate GC-thread CPU time.", "", "Memory values below are MiB, with no forced GC between campaign completion and post-campaign RSS. Loaded/warmed values are snapshots, not live object sizes. Campaign peaks are external samples; lifetime peaks include loading, compilation and both warmups.", "",
                  "| Workers | Loaded RSS | Warmed RSS | Post-campaign RSS | Sampled campaign peak | Lifetime peak |",
                  "| --- | --- | --- | --- | --- | --- |"])
    mib = lambda x: "N/A" if x is None else f"{x/2**20:.1f}"
    for r in reports:
        if r["kind"] == "timing":
            lines.append(f"| {r['options']['workers']} | {mib(r['loaded_rss_bytes'])} | {mib(r['warmed_rss_bytes'])} | " + " | ".join(
                mib(max((t[k] for t in r["trials"] if t[k] is not None), default=None)) for k in
                ("post_campaign_rss_bytes", "sampled_campaign_peak_rss_bytes", "process_lifetime_peak_rss_bytes")) + " |")
    for r in reports:
        for t in r["trials"]:
            if r["kind"] == "cpu":
                p = t["cpu"]
                lines.extend(["", f"CPU profile repeat {t['repeat']}: {p['samples']} primary-thread samples across the complete campaign and output.", "",
                              "| Exclusive stack category | Samples | Percent |", "| --- | --- | --- |"])
                for k,v in sorted(p["samples_by_category"].items(), key=lambda kv:-kv[1]):
                    lines.append(f"| {k} | {v} | {100*v/p['samples']:.2f}% |")
            if r["kind"] == "allocations":
                p=t["allocations"]
                lines.extend(["", f"Allocation profile repeat {t['repeat']}: {p['sampled_allocations']} sampled events at rate {p['sample_rate']}. Largest sources by sampled bytes (not exact totals):", ""])
                for k,v in sorted(p["sampled_bytes_by_site"].items(),key=lambda kv:-kv[1])[:10]:
                    lines.append(f"- `{k}`: {v:,} sampled bytes")
    lines.extend(["", "GC seconds and collection counts are process-wide deltas over setup/simulation plus verification/output, measured with Julia's `@timed`; explicit pre-trial GC is excluded. Allocation profiling is a separate campaign. Strict-zero shot probes do not imply a zero-allocation campaign.", "",
                  "CPU categories use the deepest recognized stack frame; inlined code and native GC constrain attribution. Precise collision/physics includes integration and resolution. Tree and portable stack counts retain the detail needed to refine attribution. Category percentages use the primary campaign thread, excluding parked worker threads; all-thread trees are retained. Samples are not CPU cycle counts.", "",
                  "Each setting warms both variants with the entire campaign. Enabled/disabled order alternates by repetition. Match scheduling is unchanged. Decision latency and match setup timers remain in both variants; the experiment removes candidate/phase timers only. RSS is sampled externally every 100 ms by default, and can miss brief peaks. Worker counts run sequentially in requested order; thermal, frequency, SMT and contention remain uncontrolled.", "",
                  "The original end-to-end boundary includes grid/checkpoint validation, engine setup, decisions, gameplay equality verification, JSON output and close. Hash computation, profile decoding and final summary writing remain outside it. Raw records separately retain process wall time, entry/load duration, artifact load, full warmup and measured compilation times; warmup includes compilation and is not pure startup cost. `@timed` totals include the small enclosing diagnostic wrapper. This protocol is separate from historical throughput protocol 1.0.0.", "",
                  "Raw histories, samples, logs, profiles and source snapshot are in the checksum-verified archive named in manifest.json. It is currently a local Git artifact; external durable archival remains unconfigured. No historical evidence was removed.", ""])
    return "\n".join(lines)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--worker-counts",default="1,2,4,8")
    p.add_argument("--julia-threads",type=int,default=8)
    p.add_argument("--gc-threads",type=int,default=1)
    p.add_argument("--games",type=int,default=8)
    p.add_argument("--repeats",type=int,default=3)
    p.add_argument("--profile-repeats",type=int,default=1)
    p.add_argument("--allocation-rate",type=float,default=.01)
    p.add_argument("--sample-interval",type=float,default=.1)
    p.add_argument("--max-turns",type=int,default=100)
    p.add_argument("--max-steps",type=int,default=3600)
    p.add_argument("--allow-dirty",action="store_true")
    p.add_argument("--smoke",action="store_true",help="permit incomplete matches; label evidence as smoke only")
    p.add_argument("--out",type=Path,default=ROOT/"results/diagnostics")
    p.add_argument("--run-id")
    p.add_argument("--expected-gameplay-sha256", help="require agreement with a previous qualified campaign")
    a=p.parse_args(argv)
    counts=[int(w) for w in a.worker_counts.split(",")]
    if not counts or len(set(counts))!=len(counts) or min(counts)<1 or max(counts)>min(a.games,a.julia_threads):
        p.error("worker counts must be unique and within games and Julia threads")
    if min(a.repeats,a.profile_repeats,a.max_turns,a.max_steps,a.gc_threads)<1 or not 0<a.allocation_rate<=1 or a.sample_interval<=0:
        p.error("counts/interval must be positive and allocation rate in (0,1]")
    rev,dirty,status=get_git_info(ROOT)
    if dirty and not a.allow_dirty:
        p.error("official diagnostics require committed source; use --allow-dirty for a retained exploratory snapshot")
    stamp=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id=a.run_id or f"{stamp}_{os.uname().nodename}_{secrets.token_hex(3)}"
    base=a.out.resolve()
    stage=reserve_run(base,run_id)
    raw=stage/"raw"
    raw.mkdir()
    manifest=dict(schema_version=PROTOCOL,protocol_version=PROTOCOL,run_id=run_id,status="running",
                  timestamp_utc=stamp,command=sys.argv,source=dict(git_revision=rev,git_dirty=dirty,git_status=status),
                  host=collect_host_metadata(), options=vars(a)|{"out":str(base)}, smoke=a.smoke)
    save(stage/"manifest.json",manifest)
    reports=[]
    try:
        inputs=[ROOT/"fixtures/ribbon_waves/artifact/ribbon_waves.v1.json", ROOT/"campaigns/ribbon/config.v1.json"]
        snapshot, _=capture_source_snapshot(ROOT,raw,inputs)
        manifest["workload"]=dict(mode="1v1",games=a.games,base_seed=20261024,sector_size=100,epsilon=1,
                                  max_steps=a.max_steps,max_turns=a.max_turns,
                                  inputs={str(f.relative_to(ROOT)):sha256_file(f) for f in inputs})
        manifest["source"]["snapshot_sha256"]=sha256_file(snapshot)
        files=harness_files(ROOT)+["scripts/run_campaign_diagnostics.py"]+[str(f.relative_to(ROOT)) for f in inputs]
        fingerprint, inventory=compute_harness_fingerprint(ROOT,files=sorted(set(files)))
        manifest["source"].update(harness_fingerprint=fingerprint,harness_files=inventory)
        with (raw/"reference-before.txt").open("x") as log:
            subprocess.run(["scripts/verify_reference.sh"],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        with (raw/"config-check.txt").open("x") as log:
            subprocess.run(["julia","--project=julia/PeggleSim","scripts/sync_campaign_config.jl","--check"],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        settings=[("timing",w,a.repeats) for w in counts]+[("cpu",1,a.profile_repeats),("allocations",1,a.profile_repeats)]
        for kind,w,reps in settings:
            label=f"{kind}-w{w}"
            cmd=["julia","--project=julia/PeggleSim","-t",f"{a.julia_threads},0",f"--gcthreads={a.gc_threads}",
                 "julia/PeggleSim/bin/campaign_diagnostics.jl","--kind",kind,"--workers",str(w),
                 "--games",str(a.games),"--repeats",str(reps),"--max-turns",str(a.max_turns),
                 "--max-steps",str(a.max_steps),"--allocation-rate",str(a.allocation_rate),"--out",str(raw/label)]
            print(f"Starting {label} (fresh process, full warmups)",flush=True)
            report=run_child(cmd,raw,label,a.sample_interval)
            reports.append(report)
            save(stage/"diagnostics.json",reports)
            for t in report["trials"]:
                print(f"  repeat={t['repeat']} phases={t['phase_instrumentation']} wall={t['wall_seconds']:.3f}s",flush=True)
        with (raw/"reference-after.txt").open("x") as log:
            subprocess.run(["scripts/verify_reference.sh"],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        digest=validate_reports(reports,a.games,a.smoke)
        if a.expected_gameplay_sha256 and digest!=a.expected_gameplay_sha256:
            raise ValueError("gameplay differs from requested qualified baseline")
        # Check fingerprint did not change while the run was in flight.
        after,_=compute_harness_fingerprint(ROOT,files=sorted(set(files)))
        if after!=fingerprint:
            raise ValueError("source changed during diagnostics")
        rows=[]
        memory=[]
        for report in reports:
            for order,t in enumerate(report["trials"],1):
                row={k:v for k,v in t.items() if k not in ("cpu","allocations")}
                row.update(run_id=run_id,trial_id=f"{report['kind']}-w{report['options']['workers']}-r{t['repeat']}-{t['phase_instrumentation']}",
                           kind=report["kind"],workers=int(report["options"]["workers"]),execution_order=order)
                rows.append(row)
            memory.append(dict(run_id=run_id,kind=report["kind"],workers=report["options"]["workers"],
                               loaded_rss_bytes=report["loaded_rss_bytes"],warmed_rss_bytes=report["warmed_rss_bytes"],
                               process_wall_seconds=report["process_wall_seconds"],entry_to_load_seconds=report["entry_to_load_seconds"],
                               load_seconds=report["load_seconds"],warmup_seconds=report["warmup_seconds"],
                               load_compile_seconds=report.get("load_compile_seconds"),
                               warmup_compile_seconds=report.get("warmup_compile_seconds"),
                               launch_to_entry_seconds=report["launch_to_entry_seconds"]))
        write_csv_rows(stage/"trials.csv",list(rows[0]),rows)
        write_csv_rows(stage/"processes.csv",list(memory[0]),memory)
        (stage/"README.md").write_text(generate_report(run_id,reports,digest,a.smoke))
        inventory={str(f.relative_to(raw)):sha256_file(f) for f in raw.rglob("*") if f.is_file()}
        archive=base/"artifacts"/f"{run_id}.tar.gz"
        checksum,size=create_archive_exclusive(archive,[(raw/name,name) for name in sorted(inventory)])
        import hashlib
        with tarfile.open(archive,"r:gz") as bundle:
            for name,sha in inventory.items():
                with bundle.extractfile(name) as stream:
                    if hashlib.file_digest(stream,"sha256").hexdigest()!=sha:
                        raise ValueError(f"archive checksum mismatch: {name}")
        checks=dict(gameplay_identity="passed",complete_matches="not_collected" if a.smoke else "passed",
                    source_unchanged="passed",reference_before_after="passed",archive_retrieval="passed",
                    historical_gameplay="passed" if a.expected_gameplay_sha256 else "not_collected",
                    gameplay_sha256=digest,artifact_files=inventory)
        save(stage/"checks.json",checks)
        manifest.update(status="completed",gameplay_sha256=digest,
                        archive=dict(path=str(archive.relative_to(base)),sha256=checksum,size_bytes=size,format="tar.gz",
                                     retrieval=f"tar -xzf {archive}"))
        save(stage/"manifest.json",manifest)
        shutil.rmtree(raw)  # only newly generated files, verified in archive above
        final=base/"runs"/run_id
        final.parent.mkdir(parents=True,exist_ok=True)
        stage.rename(final)
        print(f"Validated diagnostics: {final}",flush=True)
        return 0
    except BaseException as exc:
        manifest.update(status="interrupted" if isinstance(exc,KeyboardInterrupt) else "failed",error=str(exc))
        save(stage/"manifest.json",manifest)
        raise


if __name__=="__main__":
    raise SystemExit(main())
