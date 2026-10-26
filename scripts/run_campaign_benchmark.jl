#!/usr/bin/env julia
"""Orchestrator for benchmark campaigns producing versioned Phase 1 artifacts.

Captures host metadata, runtime environment, git provenance, runs the campaign
via julia/PeggleSim/bin/campaign.jl in a staging directory, transforms raw
results into canonical JSON and CSV schemas, generates checks and README,
archives raw artifacts, validates with BenchmarkValidator, and commits
the run to results/benchmarks/runs/<run_id>.

Usage:
  julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl [OPTIONS]

Example:
  julia --project=julia/PeggleSim scripts/run_campaign_benchmark.jl --worker-counts 2,4 --games 4 --repeats 1 --warmup none --workload-id ribbon_1v1_small_verification
"""

using Dates
using JSON
using Random
using SHA

include(joinpath(@__DIR__, "benchmark", "BenchmarkHarness.jl"))
using .BenchmarkHarness

const PROG = "run_campaign_benchmark.jl"
const DASHES = repeat("-", 80)
const EQUALS = repeat("=", 80)

struct CliError <: Exception
    msg::String
end

struct HelpRequested <: Exception end

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
function usage_text()
    return """
usage: $PROG [-h] [--worker-counts WORKER_COUNTS]
                                 [--games GAMES] [--repeats REPEATS]
                                 [--warmup {full,fast,none}] [--mode MODE]
                                 [--base-seed BASE_SEED]
                                 [--sector-size SECTOR_SIZE]
                                 [--epsilon EPSILON] [--max-steps MAX_STEPS]
                                 [--max-turns MAX_TURNS] [--level LEVEL]
                                 [--config CONFIG] [--workload-id WORKLOAD_ID]
                                 [--benchmark BENCHMARK] [--allow-dirty]
                                 [--run-id RUN_ID] [--suffix SUFFIX]
                                 [--threads THREADS]
                                 [--benchmarks-dir BENCHMARKS_DIR]

Orchestrator for benchmark campaigns producing versioned Phase 1 artifacts.
Captures host metadata, runtime environment, git provenance, runs the campaign
via julia/PeggleSim/bin/campaign.jl in a staging directory, transforms raw
results into canonical JSON and CSV schemas, generates checks and README,
archives raw artifacts, validates with BenchmarkValidator, and commits the run
to results/benchmarks/runs/<run_id>.

options:
  -h, --help            show this help message and exit
  --worker-counts WORKER_COUNTS
                        Comma-separated worker counts (e.g. 2,4)
  --games GAMES         Number of games/matches per campaign
  --repeats REPEATS     Number of repetitions across worker counts
  --warmup {full,fast,none}
                        Warmup mode
  --mode MODE           Mode: 1v1 or solo
  --base-seed BASE_SEED
                        Base seed
  --sector-size SECTOR_SIZE
                        Sector size
  --epsilon EPSILON     Aim noise epsilon
  --max-steps MAX_STEPS
                        Max simulation steps per candidate
  --max-turns MAX_TURNS
                        Max turns per match
  --level LEVEL         Path to level artifact
  --config CONFIG       Path to campaign config
  --workload-id WORKLOAD_ID
                        Identifier for workload
  --benchmark BENCHMARK
                        Benchmark name
  --allow-dirty         Allow exploratory dirty runs; retain source snapshot
  --run-id RUN_ID       Explicit run_id (overrides automatic generation)
  --suffix SUFFIX       Suffix for generated run_id
  --threads THREADS     Julia thread count (-t N)
  --benchmarks-dir BENCHMARKS_DIR
                        Root benchmark results directory
"""
end

const STRING_OPTIONS = Set([
    "--worker-counts", "--warmup", "--mode", "--level", "--config",
    "--workload-id", "--benchmark", "--run-id", "--suffix", "--benchmarks-dir",
])
const INT_OPTIONS = Set([
    "--games", "--repeats", "--base-seed", "--sector-size", "--epsilon",
    "--max-steps", "--max-turns", "--threads",
])
const BOOL_OPTIONS = Set(["--allow-dirty"])
const WARMUP_CHOICES = ("full", "fast", "none")

function _default_options()
    return Dict{String,Any}(
        "worker-counts" => "1,2,4,8",
        "games" => 8,
        "repeats" => 3,
        "warmup" => "full",
        "mode" => "1v1",
        "base-seed" => 20261024,
        "sector-size" => 100,
        "epsilon" => 1,
        "max-steps" => 3600,
        "max-turns" => 100,
        "level" => "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json",
        "config" => "campaigns/ribbon/config.v1.json",
        "workload-id" => "ribbon_1v1_8matches_1801aim",
        "benchmark" => "ribbon_1v1_campaign",
        "allow-dirty" => false,
        "run-id" => nothing,
        "suffix" => nothing,
        "threads" => nothing,
        "benchmarks-dir" => "results/benchmarks",
    )
end

function parse_args(args::Vector{String})
    options = _default_options()
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "-h" || arg == "--help"
            throw(HelpRequested())
        end

        flag = arg
        value = nothing
        has_inline_value = false
        if startswith(arg, "--") && occursin('=', arg)
            eq = findfirst(==('='), arg)
            flag = arg[1:eq-1]
            value = arg[eq+1:end]
            has_inline_value = true
        end

        if flag in STRING_OPTIONS || flag in INT_OPTIONS
            if !has_inline_value
                i < length(args) || throw(CliError("argument $flag: expected one argument"))
                value = args[i + 1]
                i += 2
            else
                i += 1
            end
            key = flag[3:end]
            if flag in INT_OPTIONS
                parsed = tryparse(Int, value)
                parsed === nothing && throw(CliError("argument $flag: invalid int value: '$value'"))
                options[key] = parsed
            else
                options[key] = value
            end
            if flag == "--warmup" && !(value in WARMUP_CHOICES)
                throw(CliError("argument --warmup: invalid choice: '$value' (choose from 'full', 'fast', 'none')"))
            end
        elseif flag in BOOL_OPTIONS
            has_inline_value && throw(CliError("argument $flag: ignored explicit argument '$value'"))
            options[flag[3:end]] = true
            i += 1
        else
            throw(CliError("unrecognized arguments: $arg"))
        end
    end
    return options
end

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
function _rooted(root_dir::AbstractString, path::AbstractString)
    return abspath(isabspath(path) ? path : joinpath(root_dir, path))
end

function _run_capture(cmd::Cmd)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = true)
    return (proc.exitcode, take!(out), take!(err))
end

function _group_digits(value::Integer)
    text = string(value)
    negative = startswith(text, "-")
    digits = negative ? text[2:end] : text
    groups = String[]
    while length(digits) > 3
        pushfirst!(groups, digits[end-2:end])
        digits = digits[1:end-3]
    end
    pushfirst!(groups, digits)
    return (negative ? "-" : "") * join(groups, ",")
end

function _as_int(value)
    value === nothing && return 0
    return Int(value)
end

function _as_float(value)
    value === nothing && return 0.0
    return Float64(value)
end

function _get(dict, key, default)
    return haskey(dict, key) ? dict[key] : default
end

function _check(name, status, command, evidence_path, evidence_sha256, details)
    return Dict{String,Any}(
        "name" => name,
        "status" => status,
        "command" => command,
        "evidence_path" => evidence_path,
        "evidence_sha256" => evidence_sha256,
        "details" => details,
    )
end

function _git_julia_threads(value)
    return value === nothing ? nothing : Int(value)
end

# ----------------------------------------------------------------------------
# Runner
# ----------------------------------------------------------------------------
function main(args::Vector{String} = ARGS)::Int
    options = try
        parse_args(args)
    catch exc
        if exc isa HelpRequested
            print(usage_text())
            return 0
        elseif exc isa CliError
            print(stderr, usage_text())
            println(stderr, "$PROG: error: $(exc.msg)")
            return 2
        else
            rethrow()
        end
    end

    root_dir = abspath(pwd())
    benchmarks_dir = abspath(String(options["benchmarks-dir"]))
    level_path = _rooted(root_dir, String(options["level"]))
    config_path = _rooted(root_dir, String(options["config"]))

    if !ispath(level_path)
        println(stderr, "Error: level artifact not found: $level_path")
        return 1
    end
    if !ispath(config_path)
        println(stderr, "Error: config artifact not found: $config_path")
        return 1
    end

    worker_counts = Int[]
    try
        for token in split(String(options["worker-counts"]), ",")
            stripped = strip(token)
            isempty(stripped) && continue
            push!(worker_counts, parse(Int, stripped))
        end
    catch
        println(stderr, "Error: invalid worker counts: $(options["worker-counts"])")
        return 1
    end
    if isempty(worker_counts) || !all(w -> w >= 1, worker_counts)
        println(stderr, "Error: invalid worker counts: $(options["worker-counts"])")
        return 1
    end
    max_workers = maximum(worker_counts)

    declared_threads = _git_julia_threads(options["threads"])
    julia_threads = (declared_threads === nothing || declared_threads == 0) ? max(max_workers, 1) : declared_threads

    host_meta = collect_host_metadata()
    host_id = String(host_meta["host_id"])
    now_utc = Dates.now(UTC)
    ts_compact = Dates.format(now_utc, dateformat"yyyymmdd") * "T" *
                 Dates.format(now_utc, dateformat"HHMMSS") * "Z"
    ts_iso = Dates.format(now_utc, dateformat"yyyy-mm-dd") * "T" *
             Dates.format(now_utc, dateformat"HH:MM:SS") * "Z"

    run_id = if options["run-id"] !== nothing && !isempty(String(options["run-id"]))
        String(options["run-id"])
    else
        suffix = (options["suffix"] !== nothing && !isempty(String(options["suffix"]))) ?
                 String(options["suffix"]) : "v_" * bytes2hex(rand(RandomDevice(), UInt8, 6))
        "$(ts_compact)_$(host_id)_$(suffix)"
    end

    staging_dir = joinpath(benchmarks_dir, ".staging", run_id)
    staging_raw_dir = joinpath(staging_dir, "raw")
    staging_verif_dir = joinpath(staging_dir, "verification")
    histories_dir = joinpath(benchmarks_dir, "histories")
    artifacts_dir = joinpath(benchmarks_dir, "artifacts")
    runs_dir = joinpath(benchmarks_dir, "runs")

    # Inspect source before creating result paths (which themselves become untracked).
    git_rev, git_dirty, git_status_str = get_git_info(root_dir)
    if git_rev == "unknown"
        error("Cannot identify source Git revision")
    end
    if git_dirty && !Bool(options["allow-dirty"])
        error("Official runs require a committed clean checkout; use --allow-dirty for an exploratory source snapshot")
    end
    reserve_run(benchmarks_dir, run_id)
    mkpath(staging_raw_dir)
    mkpath(staging_verif_dir)
    mkpath(histories_dir)
    mkpath(artifacts_dir)
    mkpath(runs_dir)

    println(EQUALS)
    println("CAMPAIGN BENCHMARK RUNNER: $run_id")
    println(EQUALS)
    println("Benchmark:      $(options["benchmark"])")
    println("Workload:       $(options["workload-id"])")
    println("Worker Counts:  $worker_counts")
    println("Games:          $(options["games"])")
    println("Repeats:        $(options["repeats"])")
    println("Warmup:         $(options["warmup"])")
    println("Julia Threads:  $julia_threads")
    println("Staging Dir:    $staging_dir")
    println(DASHES)

    # Record an interrupted attempt immediately, retaining logs on any exception.
    attempt = Dict{String,Any}(
        "schema_version" => SCHEMA_VERSION,
        "protocol_version" => PROTOCOL_VERSION,
        "run_id" => run_id,
        "benchmark" => String(options["benchmark"]),
        "workload_id" => String(options["workload-id"]),
        "timestamp_utc" => ts_iso,
        "status" => "interrupted",
        "source" => Dict{String,Any}(
            "git_revision" => git_rev,
            "git_dirty" => git_dirty,
            "git_status" => git_status_str,
        ),
    )
    save_manifest(joinpath(staging_dir, "manifest.json"), attempt)

    snapshot_path = nothing
    if git_dirty
        captured, _ = capture_source_snapshot(root_dir, staging_dir;
                                             extra_paths = String[level_path, config_path])
        snapshot_path = String(captured)
    end
    harness_fingerprint, harness_file_hashes = compute_harness_fingerprint(
        root_dir; files = harness_files(root_dir))
    println("Harness fingerprint: $harness_fingerprint")

    # 2. Run Pre-checks
    checks_records = Dict{String,Any}[]

    # Check 2a: verify reference files
    ref_exit, ref_out, ref_err = _run_capture(
        Cmd(Cmd(String[joinpath(root_dir, "scripts", "verify_reference.sh")]); dir = root_dir))
    ref_ok = ref_exit == 0
    ref_evidence_path = joinpath(staging_verif_dir, "reference-verification.txt")
    write(ref_evidence_path, vcat(ref_out, ref_err))
    push!(checks_records, _check(
        "reference_files",
        ref_ok ? "passed" : "failed",
        "scripts/verify_reference.sh",
        "verification/reference-verification.txt",
        sha256_file(ref_evidence_path),
        Dict{String,Any}("verified" => ref_ok),
    ))
    println("Pre-check reference files: $(ref_ok ? "OK" : "FAILED")")

    # Check 2b: sync campaign config check
    config_project = joinpath(root_dir, "julia", "PeggleSim")
    config_script = joinpath(root_dir, "scripts", "sync_campaign_config.jl")
    julia_exec = Base.julia_cmd().exec
    config_cmd = Cmd(Cmd(vcat(julia_exec,
                              String["--project=$config_project", config_script, "--check"]));
                     dir = root_dir)
    config_exit, config_out, config_err = _run_capture(config_cmd)
    config_ok = config_exit == 0
    config_evidence_path = joinpath(staging_verif_dir, "config-check.txt")
    write(config_evidence_path, vcat(config_out, config_err))
    push!(checks_records, _check(
        "current_config",
        config_ok ? "passed" : "failed",
        "julia --project=julia/PeggleSim scripts/sync_campaign_config.jl --check",
        "verification/config-check.txt",
        sha256_file(config_evidence_path),
        Dict{String,Any}("synchronized" => config_ok),
    ))
    println("Pre-check config sync:     $(config_ok ? "OK" : "FAILED")")

    # Re-execute the oracle and compare actual output to its frozen fixture.
    rules_file = joinpath(root_dir, "fixtures", "matches", "rules.v1.json")
    oracle_exit, oracle_out, oracle_err = _run_capture(
        Cmd(Cmd(String["luajit", "tools/capture_match_rules.lua"]); dir = root_dir))
    oracle_evidence = joinpath(staging_verif_dir, "match-rule-oracle.json")
    write(oracle_evidence, oracle_out)
    write(joinpath(staging_verif_dir, "match-rule-oracle.stderr.txt"), oracle_err)
    rules_ok = oracle_exit == 0 && isfile(rules_file) && oracle_out == read(rules_file)
    push!(checks_records, _check(
        "match_rule_oracle",
        rules_ok ? "passed" : "failed",
        "luajit tools/capture_match_rules.lua",
        "verification/match-rule-oracle.json",
        sha256_file(oracle_evidence),
        Dict{String,Any}("recapture_identical" => rules_ok),
    ))
    save_checks(joinpath(staging_dir, "checks.json"),
                Dict{String,Any}("schema_version" => SCHEMA_VERSION,
                                 "checks" => checks_records))
    if !(ref_ok && config_ok && rules_ok)
        attempt["status"] = "failed"
        attempt["error"] = "Required prechecks failed; campaign was not started"
        save_manifest(joinpath(staging_dir, "manifest.json"), attempt)
        return 1
    end

    # 3. Invoke Julia Campaign Benchmark
    raw_campaign_file = joinpath(staging_raw_dir, "campaign_raw.json")
    julia_cmd = String[
        "julia",
        "--project=$config_project",
        "-t",
        string(julia_threads),
        joinpath(root_dir, "julia", "PeggleSim", "bin", "campaign.jl"),
        "--mode", String(options["mode"]),
        "--games", string(options["games"]),
        "--base-seed", string(options["base-seed"]),
        "--sector-size", string(options["sector-size"]),
        "--epsilon", string(options["epsilon"]),
        "--max-steps", string(options["max-steps"]),
        "--max-turns", string(options["max-turns"]),
        "--workers", string(max_workers),
        "--worker-counts", join(string.(worker_counts), ","),
        "--repeats", string(options["repeats"]),
        "--warmup", String(options["warmup"]),
        "--level", level_path,
        "--config", config_path,
        "--out", raw_campaign_file,
    ]

    println(DASHES)
    println("Executing Julia campaign:\n  $(join(julia_cmd, " "))")
    println(DASHES)

    campaign_log_path = joinpath(staging_dir, "campaign.log")
    campaign_exit = 0
    open(campaign_log_path, "w") do log_file
        pipe = Pipe()
        proc = run(pipeline(ignorestatus(Cmd(Cmd(julia_cmd); dir = root_dir)),
                            stdout = pipe, stderr = pipe); wait = false)
        close(pipe.in)
        for line in eachline(pipe.out; keep = true)
            print(line)
            flush(stdout)
            print(log_file, line)
            flush(log_file)
        end
        wait(proc)
        campaign_exit = proc.exitcode
    end

    if campaign_exit != 0
        println(stderr)
        println(stderr, "[ERROR] Julia campaign failed with return code $campaign_exit")
        attempt["status"] = "failed"
        attempt["error"] = "Julia campaign returned code $campaign_exit"
        save_manifest(joinpath(staging_dir, "manifest.json"), attempt)
        return 1
    end

    if !ispath(raw_campaign_file)
        println(stderr, "[ERROR] Expected campaign output file not found: $raw_campaign_file")
        return 1
    end

    # 4. Transform Raw Campaign Outputs
    println()
    println(DASHES)
    println("Transforming campaign outputs into standard schemas...")
    raw_campaign_data = JSON.parse(read(raw_campaign_file, String))
    trials_data = get(raw_campaign_data, "trials", Any[])
    if isempty(trials_data)
        println(stderr, "[ERROR] Raw campaign data contains no trials")
        return 1
    end

    # Save canonical gameplay history from first trial
    first_history_rel = String(trials_data[1]["history"])
    first_history_path = _rooted(root_dir, first_history_rel)
    if !ispath(first_history_path)
        first_history_path = joinpath(staging_raw_dir, basename(first_history_rel))
    end
    if !ispath(first_history_path)
        println(stderr, "[ERROR] Trial history file not found: $first_history_path")
        return 1
    end

    first_history_data = JSON.parse(read(first_history_path, String))
    canonical_games = get(first_history_data, "games", Any[])
    gameplay_sha256, history_file_path_raw = save_canonical_gameplay_history(histories_dir, canonical_games)
    gameplay_sha256 = String(gameplay_sha256)
    history_file_path = String(history_file_path_raw)
    println("Saved canonical gameplay history: $history_file_path (SHA: $gameplay_sha256)")

    # Verify gameplay identity across all trials
    all_shas = sort(unique(String[String(t["gameplay_sha256"]) for t in trials_data]))
    gameplay_identity_ok = length(all_shas) == 1 && all_shas[1] == gameplay_sha256
    push!(checks_records, _check(
        "gameplay_identity",
        gameplay_identity_ok ? "passed" : "failed",
        nothing,
        relpath(history_file_path, root_dir),
        gameplay_sha256,
        Dict{String,Any}("unique_gameplay_hashes" => length(all_shas),
                         "sha256" => gameplay_sha256),
    ))

    # Check candidate count per turn
    aim_steps = _as_int(_get(raw_campaign_data, "candidate_count", 1801))
    total_candidates_expected = 0
    total_candidates_actual = 0
    for game in canonical_games
        turns = _as_int(_get(game, "turns", 0))
        total_candidates_expected += turns * aim_steps
    end

    # Build trials.csv & matches.csv
    trials_rows = Dict{String,Any}[]
    matches_rows = Dict{String,Any}[]

    for (order_idx, trial) in enumerate(trials_data)
        w = _as_int(trial["workers"])
        rep = _as_int(trial["repeat"])
        trial_id = "w$(w)_r$(rep)"

        process_memory = get(trial, "process_memory", Any[])
        rss_bytes = extract_rss_bytes(String[String(line) for line in process_memory])

        trial_row = Dict{String,Any}(
            "run_id" => run_id,
            "trial_id" => trial_id,
            "execution_order" => order_idx,
            "repeat_index" => rep,
            "mode" => String(_get(trial, "mode", w > 1 ? "parallel" : "sequential")),
            "workers" => w,
            "wall_seconds" => _as_float(trial["wall_seconds"]),
            "campaign_setup_and_sim_seconds" => _as_float(trial["campaign_setup_and_simulation_seconds"]),
            "verification_and_output_seconds" => _as_float(trial["verification_and_output_seconds"]),
            "sim_phase_seconds" => _as_float(trial["phase_worker_seconds"]["simulation"]),
            "candidate_reset_phase_seconds" => _as_float(trial["phase_worker_seconds"]["candidate_reset"]),
            "selection_phase_seconds" => _as_float(trial["phase_worker_seconds"]["selection"]),
            "actual_shot_phase_seconds" => _as_float(trial["phase_worker_seconds"]["actual_shot"]),
            "checkpoint_phase_seconds" => _as_float(trial["phase_worker_seconds"]["checkpoint"]),
            "completed_matches" => _as_int(trial["completed_matches"]),
            "candidates" => _as_int(trial["candidates"]),
            "candidates_per_second" => _as_float(trial["candidates_per_second"]),
            "completed_matches_per_hour" => _as_float(trial["completed_matches_per_hour"]),
            "decision_mean_seconds" => _as_float(trial["decision_mean_seconds"]),
            "decision_p50_seconds" => _as_float(trial["decision_p50_seconds"]),
            "decision_p95_seconds" => _as_float(trial["decision_p95_seconds"]),
            "process_rss_bytes" => rss_bytes,
            "process_peak_rss_bytes" => _as_int(_get(trial, "process_peak_rss_bytes", 0)),
            "allocated_bytes" => "",
            "gc_collections" => "",
            "gc_seconds" => "",
            "gameplay_sha256" => String(trial["gameplay_sha256"]),
        )
        push!(trials_rows, trial_row)
        total_candidates_actual += _as_int(trial["candidates"])

        # Build matches.csv
        h_rel = String(trial["history"])
        h_path = _rooted(root_dir, h_rel)
        if !ispath(h_path)
            h_path = joinpath(staging_raw_dir, basename(h_rel))
        end
        h_json = JSON.parse(read(h_path, String))
        g_list = get(h_json, "games", Any[])
        tm_list = get(h_json, "timings", Any[])

        for m_idx in eachindex(g_list)
            game = g_list[m_idx]
            tm = tm_list[m_idx]
            match_id = _as_int(game["game"])
            worker_idx = ((match_id - 1) % w) + 1
            turns = _as_int(game["turns"])
            cands = _as_int(tm["candidates"])
            match_wall = _as_float(tm["setup_seconds"]) +
                         sum((_as_float(x) for x in tm["decision_seconds"]); init = 0.0)
            sim_time = _as_float(tm["phases"]["simulation"])

            player_scores = get(game, "player_scores", Any[])
            p1_score = length(player_scores) > 0 ? _as_float(player_scores[1]) : 0.0
            p2_score = length(player_scores) > 1 ? _as_float(player_scores[2]) : 0.0
            bot_seeds = get(game, "bot_seeds", Any[])
            bot1 = length(bot_seeds) > 0 ? _as_int(bot_seeds[1]) : 0
            bot2 = length(bot_seeds) > 1 ? _as_int(bot_seeds[2]) : 0
            winner_val = get(game, "winner", nothing)
            winner = winner_val === nothing ? 0 : _as_int(winner_val)

            match_row = Dict{String,Any}(
                "run_id" => run_id,
                "trial_id" => trial_id,
                "repeat_index" => rep,
                "workers" => w,
                "match_id" => match_id,
                "worker_index" => worker_idx,
                "base_seed" => _as_int(game["base_seed"]),
                "bot_seed_1" => bot1,
                "bot_seed_2" => bot2,
                "gameplay_seed" => _as_int(game["gameplay_seed"]),
                "turns" => turns,
                "candidates" => cands,
                "wall_seconds" => match_wall,
                "sim_phase_seconds" => sim_time,
                "termination_reason" => String(_get(game, "termination_reason", "unknown")),
                "completed" => get(game, "completed", false),
                "winner" => winner,
                "player1_score" => p1_score,
                "player2_score" => p2_score,
                "gameplay_sha256" => String(trial["gameplay_sha256"]),
            )
            push!(matches_rows, match_row)
        end
    end

    # Candidate verification check
    candidates_match = total_candidates_actual == total_candidates_expected * length(trials_rows)
    push!(checks_records, _check(
        "candidate_count",
        candidates_match ? "passed" : "failed",
        nothing,
        nothing,
        nothing,
        Dict{String,Any}(
            "aim_steps" => aim_steps,
            "expected_per_trial" => total_candidates_expected,
            "actual_total" => total_candidates_actual,
            "trials_count" => length(trials_rows),
        ),
    ))

    write_csv_rows(joinpath(staging_dir, "trials.csv"), TRIALS_CSV_COLUMNS, trials_rows)
    println("Wrote $(length(trials_rows)) rows to $(joinpath(staging_dir, "trials.csv"))")

    write_csv_rows(joinpath(staging_dir, "matches.csv"), MATCHES_CSV_COLUMNS, matches_rows)
    println("Wrote $(length(matches_rows)) rows to $(joinpath(staging_dir, "matches.csv"))")

    # Write checks.json
    save_checks(joinpath(staging_dir, "checks.json"),
                Dict{String,Any}("schema_version" => SCHEMA_VERSION,
                                 "checks" => checks_records))
    println("Wrote $(length(checks_records)) checks to $(joinpath(staging_dir, "checks.json"))")

    # Save environment.json
    env_json_data = Dict{String,Any}(
        "uname" => host_meta,
        "os_release" => host_meta["os_release"],
        "lscpu" => host_meta["lscpu"],
        "allowed_cpus" => host_meta["allowed_cpus"],
        "cpu_governors" => host_meta["cpu_governors"],
        "cgroup_cpuset" => host_meta["cgroup_cpuset"],
        "requested_workers" => worker_counts,
        "matches_per_campaign" => Int(options["games"]),
        "mode" => String(options["mode"]),
    )
    env_json_path = joinpath(staging_dir, "environment.json")
    write(env_json_path, JSON.json(env_json_data, 2) * "\n")

    # 5. Create Compressed Artifact Archive
    archive_items = Tuple{String,String}[
        (String(raw_campaign_file), "campaign_raw.json"),
        (String(env_json_path), "environment.json"),
        (String(campaign_log_path), "campaign.log"),
    ]
    if snapshot_path !== nothing
        push!(archive_items, (String(snapshot_path), "source_snapshot.tar.gz"))
    end

    # Add all trial histories
    for hist_file in sort(readdir(staging_raw_dir; join = true))
        if endswith(hist_file, ".json") && isfile(hist_file) &&
           abspath(hist_file) != abspath(raw_campaign_file)
            push!(archive_items, (String(hist_file), basename(hist_file)))
        end
    end

    # Add verification evidence files
    for vf in sort(readdir(staging_verif_dir; join = true))
        if isfile(vf)
            push!(archive_items, (String(vf), "verification/" * basename(vf)))
        end
    end

    archive_bundle_path = joinpath(artifacts_dir, "$(run_id).tar.gz")
    bundle_sha, bundle_size = create_archive_exclusive(archive_bundle_path, archive_items)
    println("Created artifact archive: $archive_bundle_path ($(_group_digits(bundle_size)) bytes, SHA: $bundle_sha)")

    # 6. Build manifest.json
    raw_environment = get(raw_campaign_data, "environment", Dict{String,Any}())
    julia_version = _get(raw_environment, "julia", "1.12.6")
    manifest = Dict{String,Any}(
        "schema_version" => SCHEMA_VERSION,
        "protocol_version" => PROTOCOL_VERSION,
        "run_id" => run_id,
        "benchmark" => String(options["benchmark"]),
        "workload_id" => String(options["workload-id"]),
        "status" => "completed",
        "timestamp_utc" => ts_iso,
        "host" => Dict{String,Any}(
            "host_id" => host_meta["host_id"],
            "machine" => host_meta["machine"],
            "kernel" => host_meta["kernel"],
            "os_release" => host_meta["os_release"],
            "cpu_model" => host_meta["cpu_model"],
            "cpu_family" => host_meta["cpu_family"],
            "physical_cores" => host_meta["physical_cores"],
            "cpu_threads" => host_meta["cpu_threads"],
            "total_memory_bytes" => host_meta["total_memory_bytes"],
            "cpu_governors" => host_meta["cpu_governors"],
            "allowed_cpus" => host_meta["allowed_cpus"],
            "cgroup_cpuset" => host_meta["cgroup_cpuset"],
        ),
        "runtime" => Dict{String,Any}(
            "julia_version" => julia_version,
            "julia_threads" => julia_threads,
            "command" => join(julia_cmd, " "),
            "math_backend" => "system_libm",
        ),
        "source" => Dict{String,Any}(
            "git_revision" => git_rev,
            "git_dirty" => git_dirty,
            "git_status" => git_status_str,
            "harness_entry_point" => "julia/PeggleSim/bin/campaign.jl",
            "harness_fingerprint" => harness_fingerprint,
            "harness_files" => harness_file_hashes,
            "run_kind" => git_dirty ? "exploratory" : "official",
            "fingerprint_version" => "2",
            "source_snapshot" => (snapshot_path === nothing ? nothing : Dict{String,Any}(
                "archive_member" => "source_snapshot.tar.gz",
                "sha256" => sha256_file(snapshot_path),
                "size_bytes" => filesize(snapshot_path),
            )),
        ),
        "workload" => Dict{String,Any}(
            "mode" => String(options["mode"]),
            "games" => Int(options["games"]),
            "repeats" => Int(options["repeats"]),
            "worker_counts" => worker_counts,
            "base_seed" => Int(options["base-seed"]),
            "candidate_count" => aim_steps,
            "sector_size" => Int(options["sector-size"]),
            "epsilon" => Int(options["epsilon"]),
            "max_steps" => Int(options["max-steps"]),
            "max_turns" => Int(options["max-turns"]),
            "level_file" => relpath(level_path, root_dir),
            "level_sha256" => _get(raw_campaign_data, "level_sha256", sha256_file(level_path)),
            "config_file" => relpath(config_path, root_dir),
            "config_sha256" => _get(raw_campaign_data, "config_sha256", sha256_file(config_path)),
            "warmup" => String(options["warmup"]),
        ),
        "timing_boundaries" => Dict{String,Any}(
            "load_seconds" => _as_float(_get(raw_campaign_data, "load_seconds", 0.0)),
            "warmup_seconds" => _as_float(_get(raw_campaign_data, "warmup_seconds", 0.0)),
            "wall_boundary_description" => _get(
                raw_campaign_data,
                "timing_boundary",
                "wall includes checkpoint/grid validation, worker and engine setup, all decisions, history identity verification and history JSON output/close",
            ),
            "memory_boundary_description" => _get(
                raw_campaign_data,
                "memory_boundary",
                "process RSS sampled after history output; peak RSS is cumulative across warmup and all trials, not isolated per trial",
            ),
        ),
        "artifacts" => Dict{String,Any}(
            "canonical_gameplay_history" => Dict{String,Any}(
                "path" => relpath(history_file_path, root_dir),
                "sha256" => gameplay_sha256,
                "size_bytes" => filesize(history_file_path),
            ),
            "archive_bundle" => Dict{String,Any}(
                "path" => relpath(archive_bundle_path, root_dir),
                "sha256" => bundle_sha,
                "size_bytes" => bundle_size,
                "format" => "tar.gz",
                "retrieval_instructions" => "tar -xzf $(relpath(archive_bundle_path, root_dir))",
            ),
        ),
    )
    save_manifest(joinpath(staging_dir, "manifest.json"), manifest)

    # 7. Generate README.md
    readme_text = generate_run_readme(manifest, trials_rows, matches_rows)
    write(joinpath(staging_dir, "README.md"), readme_text)
    println("Generated $(joinpath(staging_dir, "README.md"))")

    # 9. Validate Staging Directory
    println(DASHES)
    println("Validating staged benchmark run...")
    validator = BenchmarkValidator(staging_dir; root_dir = root_dir)
    valid = validate!(validator)

    if !valid
        println(stderr, "[ERROR] Validation failed with $(length(validator.errors)) error(s):")
        for err in validator.errors
            println(stderr, "  [ERROR] $err")
        end
        # Update status to failed
        manifest["status"] = "failed"
        save_manifest(joinpath(staging_dir, "manifest.json"), manifest)
        return 1
    end

    println("Staged benchmark passed validation!")

    # 10. Atomic move staging -> runs/<run_id>
    final_run_dir = joinpath(runs_dir, run_id)
    if ispath(final_run_dir)
        error("Run appeared during execution: $final_run_dir")
    end
    # Clean only after evidence has passed hash/evidence validation.
    rm(staging_raw_dir; recursive = true, force = true)
    rm(staging_verif_dir; recursive = true, force = true)
    for item in Any[
        env_json_path,
        campaign_log_path,
        snapshot_path,
        joinpath(staging_dir, "git_diff.patch"),
        joinpath(staging_dir, "git_status.txt"),
        joinpath(staging_dir, "source_files.json"),
    ]
        if item !== nothing && ispath(item)
            rm(item; force = true)
        end
    end
    mv(staging_dir, final_run_dir)
    println("Committed benchmark run to: $final_run_dir")

    # 11. Update index.csv
    index_csv = joinpath(benchmarks_dir, "index.csv")
    generate_index(runs_dir, index_csv, root_dir; update_readme = false)
    println("Updated index at $index_csv")

    # 12. Final validation with index check
    final_validator = BenchmarkValidator(final_run_dir; index_path = index_csv, root_dir = root_dir)
    if !validate!(final_validator)
        println(stderr, "[ERROR] Post-index validation failed with $(length(final_validator.errors)) error(s):")
        for err in final_validator.errors
            println(stderr, "  [ERROR] $err")
        end
        return 1
    end

    println()
    println("[SUCCESS] Benchmark run $run_id completed, validated, and indexed successfully!")
    println("Run directory: $final_run_dir")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
