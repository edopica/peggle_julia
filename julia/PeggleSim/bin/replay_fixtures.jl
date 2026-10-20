#!/usr/bin/env julia
# M4 fixture-replay driver: replay every shot fixture in the frozen M1 corpus
# from its own expected JSON record and compare the Julia shot engine exactly.
#
# The expected record is the manifest. For each fixtures/expected/*.json with
# kind == "shot":
#
#   level       source.level   -> interchange/levels/<level>.v1.json
#   config      interchange/config.v1.json
#   action      action.aim_index, action.balls (default 1)
#   completion  completion.rule ("bench"/"clearing"), completion.max_steps
#
# Provenance is verified before the shot runs:
#   source.level_sha256  == sha256 of the level artifact bytes
#   source.config_sha256 == the loaded config's source_sha256 identity
# A mismatch is a hard error (exit 2), never a skip.
#
# Every expected completion field and every expected result field is compared
# exactly: completion.completed/reason/steps and result.score/peg_score/bonus/
# style_points/styles/pegs_hit/reds_hit/multiplier/is_fever/balls/
# balls_spawned (Julia shot_summary.spawned). No tolerance is applied.
#
# For the fixtures that carry a `trace` block, the driver also:
#   * regenerates the snapshot-free trace with the default system_libm backend
#     and compares it byte-for-byte with fixtures/traces/<id>.jsonl (and the
#     recorded SHA-256 and event count);
#   * compares the traced run's summary with the untraced run's summary.
#
# Scenario fixtures (kind == "scenario") are listed in the report but are not
# replayed here; see wiki/context/m4-validation.md for the scenario decision.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/replay_fixtures.jl \
#       [--expected-dir DIR] [--level-dir DIR] [--config PATH] \
#       [--out PATH] [--trace-report PATH] [--trace-out-dir DIR] \
#       [--only id1,id2] [--skip-traces]
#
# Exit status: 0 iff every shot fixture matches on every compared field and
# every traced fixture is byte-identical; 1 on any parity failure; 2 on a
# malformed corpus or provenance mismatch.

using PeggleSim

# dirname chain (not normpath("..")): normpath keeps a trailing separator after
# three ".." components, which would make the repo prefix ".../julia_clone//"
# and defeat _display_path below.
const REPO_ROOT = dirname(dirname(dirname(@__DIR__)))

const FLAG_ARGS = Set(["--skip-traces"])
const VALUE_ARGS = Set([
    "--expected-dir", "--level-dir", "--config", "--out", "--trace-report",
    "--trace-out-dir", "--only",
])

# Fixed comparison order; the first difference is reported in this order.
const COMPLETION_FIELDS = ("completed", "reason", "steps")
const RESULT_FIELDS = (
    "score", "peg_score", "bonus", "style_points", "styles", "pegs_hit",
    "reds_hit", "multiplier", "is_fever", "balls", "balls_spawned",
)

function usage()
    println("usage: replay_fixtures.jl [--expected-dir DIR] [--level-dir DIR] " *
            "[--config PATH] [--out PATH] [--trace-report PATH] " *
            "[--trace-out-dir DIR] [--only id1,id2] [--skip-traces]")
end

function parse_args(argv)
    opts = Dict{String,String}()
    flags = Set{String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--help" || arg == "-h"
            usage()
            exit(0)
        elseif arg in FLAG_ARGS
            push!(flags, arg)
        elseif arg in VALUE_ARGS
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg] = argv[i]
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts, flags
end

function _ensure_parent(path::AbstractString)
    dir = dirname(abspath(path))
    isempty(dir) || mkpath(dir)
    return nothing
end

# Repo-relative where possible so committed reports are host independent.
function _display_path(path::AbstractString)
    absolute = normpath(abspath(path))
    prefix = REPO_ROOT * "/"
    return startswith(absolute, prefix) ? absolute[length(prefix) + 1:end] : absolute
end

# shot_summary.styles is a "name:count,..." string; the expected corpus uses a
# JSON object. Normalize both to {String => Int} for an exact comparison.
function _styles_object(styles)
    out = Dict{String,Any}()
    if styles === nothing
        return out
    elseif styles isa AbstractDict
        for (k, v) in styles
            out[string(k)] = as_int(v, "styles.$(k)")
        end
    elseif styles isa NamedTuple
        for (k, v) in pairs(styles)
            out[String(k)] = as_int(v, "styles.$(k)")
        end
    elseif styles isa AbstractString
        for item in split(styles, ",")
            isempty(item) && continue
            parts = split(item, ":")
            out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
        end
    elseif styles isa AbstractVector
        for item in styles
            parts = split(String(item), ":")
            out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
        end
    else
        error("unsupported shot_summary.styles type: $(typeof(styles))")
    end
    return out
end

function _values_equal(a, b)
    if a isa AbstractDict && b isa AbstractDict
        keys(a) == keys(b) || return false
        return all(_values_equal(a[k], b[k]) for k in keys(a))
    elseif a isa Bool || b isa Bool
        return a isa Bool && b isa Bool && a == b
    elseif a isa Real && b isa Real
        return a == b
    else
        return a == b
    end
end

# Flattened observation with the same keys on both sides. Expected values are
# read strictly: a missing expected field is a malformed corpus (hard error),
# never an implicit pass.
function _expected_observation(doc)
    completion = as_object(doc["completion"], "completion")
    result = as_object(doc["result"], "result")
    obs = Dict{String,Any}()
    obs["completion.completed"] = as_bool(completion["completed"], "completion.completed")
    obs["completion.reason"] = as_string(completion["reason"], "completion.reason")
    obs["completion.steps"] = as_int(completion["steps"], "completion.steps")
    obs["result.score"] = as_f64(result["score"], "result.score")
    obs["result.peg_score"] = as_f64(result["peg_score"], "result.peg_score")
    obs["result.bonus"] = as_f64(result["bonus"], "result.bonus")
    obs["result.style_points"] = as_f64(result["style_points"], "result.style_points")
    obs["result.styles"] = _styles_object(as_object(result["styles"], "result.styles"))
    obs["result.pegs_hit"] = as_int(result["pegs_hit"], "result.pegs_hit")
    obs["result.reds_hit"] = as_int(result["reds_hit"], "result.reds_hit")
    obs["result.multiplier"] = as_int(result["multiplier"], "result.multiplier")
    obs["result.is_fever"] = as_bool(result["is_fever"], "result.is_fever")
    obs["result.balls"] = as_int(result["balls"], "result.balls")
    obs["result.balls_spawned"] = as_int(result["balls_spawned"], "result.balls_spawned")
    return obs
end

function _actual_observation(summary)
    obs = Dict{String,Any}()
    obs["completion.completed"] = summary.completed
    obs["completion.reason"] = String(summary.reason)
    obs["completion.steps"] = summary.steps
    obs["result.score"] = summary.score
    obs["result.peg_score"] = summary.peg_score
    obs["result.bonus"] = summary.bonus
    obs["result.style_points"] = summary.style_points
    obs["result.styles"] = _styles_object(summary.styles)
    obs["result.pegs_hit"] = summary.pegs_hit
    obs["result.reds_hit"] = summary.reds_hit
    obs["result.multiplier"] = summary.multiplier
    obs["result.is_fever"] = summary.is_fever
    obs["result.balls"] = summary.balls
    obs["result.balls_spawned"] = summary.spawned
    return obs
end

function _compare_observations(expected, actual)
    differences = Dict{String,Any}()
    for field in COMPLETION_FIELDS
        key = "completion." * field
        _values_equal(expected[key], actual[key]) ||
            (differences[key] = Dict{String,Any}(
                "expected" => expected[key], "actual" => actual[key]))
    end
    for field in RESULT_FIELDS
        key = "result." * field
        _values_equal(expected[key], actual[key]) ||
            (differences[key] = Dict{String,Any}(
                "expected" => expected[key], "actual" => actual[key]))
    end
    first_difference = nothing
    for field in ("completion." .* COMPLETION_FIELDS..., "result." .* RESULT_FIELDS...)
        if haskey(differences, field)
            first_difference = Dict{String,Any}(
                "field" => field,
                "expected" => differences[field]["expected"],
                "actual" => differences[field]["actual"],
            )
            break
        end
    end
    return differences, first_difference
end

first_difference_bytes(a::Vector{UInt8}, b::Vector{UInt8}) =
    first_difference_bytes(a, b, min(length(a), length(b)))

function first_difference_bytes(a::Vector{UInt8}, b::Vector{UInt8}, limit::Int)
    for i in 1:limit
        a[i] == b[i] || return i
    end
    return length(a) == length(b) ? nothing : limit + 1
end

function _first_differing_line(reference::Vector{UInt8}, regenerated::Vector{UInt8})
    offset = first_difference_bytes(reference, regenerated)
    offset === nothing && return nothing
    line = 1
    for i in 1:min(offset - 1, length(reference))
        reference[i] == UInt8('\n') && (line += 1)
    end
    return Dict{String,Any}(
        "byte_offset" => offset - 1,  # zero-based offset of the common prefix
        "line" => line,               # 1-based line in the corpus trace
        "reference_byte" => offset <= length(reference) ? Int(reference[offset]) : nothing,
        "regenerated_byte" => offset <= length(regenerated) ? Int(regenerated[offset]) : nothing,
        "reference_length" => length(reference),
        "regenerated_length" => length(regenerated),
    )
end

function _run_shot(ckpt, level, config, clearing::Bool, max_steps::Int, aim::Int;
                   trace_path::Union{Nothing,AbstractString} = nothing)
    callbacks = PeggleSim.harness_callbacks(clearing = clearing)
    eng = PeggleSim.shot_engine(
        ckpt; callbacks = callbacks, config = config,
        virtual_width = level.virtual_width, virtual_height = level.virtual_height)
    writer = nothing
    if trace_path !== nothing
        writer = PeggleSim.trace_open(trace_path; include_snapshot = false)
        eng.trace = writer
    end
    PeggleSim.reset_shot_engine!(eng, ckpt)
    PeggleSim.launch!(eng, aim)
    PeggleSim.run_shot!(eng; max_steps = max_steps)
    if writer !== nothing
        PeggleSim.trace_close!(writer)
        eng.trace = nothing
    end
    return eng, writer
end

function _check_provenance(doc, level, config)
    source = as_object(doc["source"], "source")
    expected_level_sha = as_string(source["level_sha256"], "source.level_sha256")
    expected_config_sha = as_string(source["config_sha256"], "source.config_sha256")
    actual_config_sha = PeggleSim.config_source_sha256(config)
    checks = Dict{String,Any}(
        "level_sha256" => Dict{String,Any}(
            "expected" => expected_level_sha,
            "actual" => level.level_sha256,
            "match" => expected_level_sha == level.level_sha256,
        ),
        "config_sha256" => Dict{String,Any}(
            "expected" => expected_config_sha,
            "actual" => actual_config_sha,
            "match" => expected_config_sha == actual_config_sha,
        ),
    )
    if !checks["level_sha256"]["match"]
        error("provenance mismatch for " * as_string(doc["id"], "id") *
              ": source.level_sha256=" * expected_level_sha *
              " but level artifact hashes to " * level.level_sha256)
    end
    if !checks["config_sha256"]["match"]
        error("provenance mismatch for " * as_string(doc["id"], "id") *
              ": source.config_sha256=" * expected_config_sha *
              " but loaded config identity is " * actual_config_sha)
    end
    return checks
end

function _load_shot_records(expected_dir, only)
    paths = sort!(filter(p -> endswith(p, ".json"), readdir(expected_dir; join = true)))
    isempty(paths) && error("no expected records under " * expected_dir)
    shots = Dict{String,Any}[]
    scenarios = String[]
    for path in paths
        doc = as_object(load_json(path), "fixture record")
        id = as_string(doc["id"], "id")
        kind = as_string(doc["kind"], "kind")
        if only !== nothing && !(id in only)
            continue
        end
        if kind == "shot"
            push!(shots, doc)
        elseif kind == "scenario"
            push!(scenarios, id)
        else
            error("$(path): unknown fixture kind '$(kind)'")
        end
    end
    if only !== nothing
        found = Set(as_string(doc["id"], "id") for doc in shots)
        missing = sort!(collect(setdiff(only, found)))
        isempty(missing) || error("--only ids not found as shot fixtures: " *
                                  join(missing, ", "))
    end
    return shots, scenarios, paths
end

function run_replay(opts, flags)
    expected_dir = get(opts, "--expected-dir", joinpath(REPO_ROOT, "fixtures", "expected"))
    level_dir = get(opts, "--level-dir", joinpath(REPO_ROOT, "interchange", "levels"))
    config_path = get(opts, "--config", joinpath(REPO_ROOT, "interchange", "config.v1.json"))
    out_path = get(opts, "--out", joinpath(REPO_ROOT, "results", "m4", "fixture-parity.json"))
    trace_report_path = get(opts, "--trace-report",
                            joinpath(REPO_ROOT, "results", "m4", "trace-parity.json"))
    trace_out_dir = get(opts, "--trace-out-dir",
                        joinpath(REPO_ROOT, "results", "m4", "traces"))
    skip_traces = "--skip-traces" in flags
    only = haskey(opts, "--only") ?
        Set(String(strip(part)) for part in split(opts["--only"], ",") if !isempty(strip(part))) :
        nothing

    config = PeggleSim.load_config(config_path)
    shots, scenarios, all_paths = _load_shot_records(expected_dir, only)
    isempty(shots) && error("no shot fixtures selected")
    sort!(shots; by = doc -> as_string(doc["id"], "id"))

    mkpath(trace_out_dir)
    fixture_reports = Dict{String,Any}[]
    trace_reports = Dict{String,Any}[]
    failure_count = 0
    trace_failure_count = 0

    for doc in shots
        id = as_string(doc["id"], "id")
        source = as_object(doc["source"], "source")
        level_name = as_string(source["level"], "source.level")
        level_path = joinpath(level_dir, level_name * ".v1.json")
        isfile(level_path) || error("missing level artifact for $(id): $(level_path)")
        level = PeggleSim.load_level(level_path)
        provenance = _check_provenance(doc, level, config)

        action = as_object(doc["action"], "action")
        aim = as_int(action["aim_index"], "action.aim_index")
        balls = haskey(action, "balls") ? as_int(action["balls"], "action.balls") : 1
        completion = as_object(doc["completion"], "completion")
        rule = as_string(completion["rule"], "completion.rule")
        (rule == "bench" || rule == "clearing") ||
            error("$(id): completion.rule must be bench or clearing, got '$(rule)'")
        max_steps = as_int(completion["max_steps"], "completion.max_steps")
        clearing = rule == "clearing"

        ckpt_provenance = (
            reference_revision = String(level.provenance.reference_revision),
            reference_tree = String(level.provenance.reference_tree),
            config_sha256 = String(level.provenance.config_sha256),
            level_sha256 = String(level.level_sha256),
        )
        ckpt = PeggleSim.build_checkpoint(
            level, config; balls = balls, mode = :solo, provenance = ckpt_provenance)

        eng, _ = _run_shot(ckpt, level, config, clearing, max_steps, aim)
        untraced_summary = PeggleSim.shot_summary(eng)
        expected_obs = _expected_observation(doc)
        actual_obs = _actual_observation(untraced_summary)
        differences, first_difference = _compare_observations(expected_obs, actual_obs)
        matched = isempty(differences)
        matched || (failure_count += 1)
        fields_compared = length(expected_obs)

        fixture_report = Dict{String,Any}(
            "id" => id,
            "category" => as_string(doc["category"], "category"),
            "level" => level_name,
            "level_path" => _display_path(level_path),
            "level_sha256" => level.level_sha256,
            "config_sha256" => PeggleSim.config_source_sha256(config),
            "aim_index" => aim,
            "balls" => balls,
            "completion_rule" => rule,
            "max_steps" => max_steps,
            "provenance" => provenance,
            "status" => matched ? "match" : "mismatch",
            "fields_compared" => fields_compared,
            "field_names" => vcat(["completion." * f for f in COMPLETION_FIELDS],
                                  ["result." * f for f in RESULT_FIELDS]),
            "differences" => differences,
            "first_difference" => first_difference,
            "expected" => expected_obs,
            "actual" => actual_obs,
        )
        push!(fixture_reports, fixture_report)

        if haskey(doc, "trace") && !skip_traces
            trace_block = as_object(doc["trace"], "trace")
            trace_rel = as_string(trace_block["path"], "trace.path")
            corpus_trace_path = joinpath(REPO_ROOT, trace_rel)
            regenerated_path = joinpath(trace_out_dir, id * ".jsonl")
            old_backend = PeggleSim.DetMath.MATH_BACKEND[]
            if old_backend !== :system_libm
                error("$(id): trace parity requires the default system_libm backend, " *
                      "got :$(old_backend)")
            end

            traced_eng, writer = _run_shot(
                ckpt, level, config, clearing, max_steps, aim;
                trace_path = regenerated_path)
            traced_summary = PeggleSim.shot_summary(traced_eng)
            traced_obs = _actual_observation(traced_summary)
            summary_differences, summary_first = _compare_observations(
                actual_obs, traced_obs)
            summary_identical = isempty(summary_differences)

            actual_bytes = read(regenerated_path)
            corpus_bytes = read(corpus_trace_path)
            actual_sha = PeggleSim.sha256_hex(actual_bytes)
            corpus_sha = PeggleSim.sha256_hex(corpus_bytes)
            expected_sha = as_string(trace_block["sha256"], "trace.sha256")
            expected_events = as_int(trace_block["events"], "trace.events")
            bytes_match = actual_bytes == corpus_bytes
            sha_match = actual_sha == expected_sha && corpus_sha == expected_sha
            events_match = writer.steps_written == expected_events
            byte_difference = bytes_match ? nothing :
                _first_differing_line(corpus_bytes, actual_bytes)
            trace_matched = bytes_match && sha_match && events_match && summary_identical
            trace_matched || (trace_failure_count += 1)
            push!(trace_reports, Dict{String,Any}(
                "id" => id,
                "corpus_trace" => trace_rel,
                "regenerated_trace" => _display_path(regenerated_path),
                "math_backend" => "system_libm",
                "include_snapshot" => false,
                "expected_sha256" => expected_sha,
                "corpus_sha256" => corpus_sha,
                "regenerated_sha256" => actual_sha,
                "sha256_match" => sha_match,
                "expected_bytes" => length(corpus_bytes),
                "regenerated_bytes" => length(actual_bytes),
                "bytes_match" => bytes_match,
                "expected_events" => expected_events,
                "regenerated_events" => writer.steps_written,
                "events_match" => events_match,
                "first_difference" => byte_difference,
                "status" => trace_matched ? "match" : "mismatch",
                "summary_equivalence" => Dict{String,Any}(
                    "identical" => summary_identical,
                    "traced_vs_untraced_fields_compared" => length(actual_obs),
                    "differences" => summary_differences,
                    "first_difference" => summary_first,
                ),
            ))
        end

        println("replay_fixtures: $(rpad(id, 32)) ",
                matched ? "match" : "MISMATCH",
                haskey(doc, "trace") && !skip_traces ? " (traced)" : "")
    end

    sorted_trace_reports = sort(trace_reports; by = d -> d["id"])
    traced_count = count(doc -> haskey(doc, "trace"), shots)
    trace_identical = count(d -> d["status"] == "match", sorted_trace_reports)
    summaries_identical = count(
        d -> d["summary_equivalence"]["identical"], sorted_trace_reports)
    all_match = failure_count == 0
    all_traces_match = trace_failure_count == 0 &&
        trace_identical == length(sorted_trace_reports)

    fixture_report = Dict{String,Any}(
        "format" => "peggle.m4_fixture_parity",
        "schema_version" => 1,
        "math_backend" => string(PeggleSim.DetMath.MATH_BACKEND[]),
        "corpus" => Dict{String,Any}(
            "expected_dir" => _display_path(expected_dir),
            "level_dir" => _display_path(level_dir),
            "config" => _display_path(config_path),
            "config_sha256" => PeggleSim.config_source_sha256(config),
            "records_total" => length(all_paths),
            "shot_records" => length(shots),
            "scenario_records" => length(scenarios),
            "scenario_ids" => scenarios,
        ),
        "compared_fields" => Dict{String,Any}(
            "completion" => collect(COMPLETION_FIELDS),
            "result" => collect(RESULT_FIELDS),
        ),
        "fixtures" => fixture_reports,
        "summary" => Dict{String,Any}(
            "fixtures" => length(fixture_reports),
            "matched" => count(d -> d["status"] == "match", fixture_reports),
            "failed" => failure_count,
            "fields_compared_per_fixture" => isempty(fixture_reports) ? 0 :
                fixture_reports[1]["fields_compared"],
            "fields_compared_total" => sum(
                d["fields_compared"] for d in fixture_reports; init = 0),
            "all_match" => all_match,
        ),
    )

    trace_report = Dict{String,Any}(
        "format" => "peggle.m4_trace_parity",
        "schema_version" => 1,
        "math_backend" => string(PeggleSim.DetMath.MATH_BACKEND[]),
        "include_snapshot" => false,
        "fixture_traces_dir" => _display_path(joinpath(REPO_ROOT, "fixtures", "traces")),
        "regenerated_dir" => _display_path(trace_out_dir),
        "fixtures" => sorted_trace_reports,
        "summary" => Dict{String,Any}(
            "traced_fixtures" => traced_count,
            "regenerated" => length(sorted_trace_reports),
            "identical" => trace_identical,
            "failed" => trace_failure_count,
            "all_byte_identical" => all_traces_match,
            "summaries_identical" => summaries_identical,
            "summary_equivalence_all" => summaries_identical == length(sorted_trace_reports),
        ),
    )

    _ensure_parent(out_path)
    open(out_path, "w") do io
        write(io, PeggleSim.canonical_json(fixture_report))
        write(io, "\n")
    end
    _ensure_parent(trace_report_path)
    open(trace_report_path, "w") do io
        write(io, PeggleSim.canonical_json(trace_report))
        write(io, "\n")
    end

    println("replay_fixtures: fixtures ", fixture_report["summary"]["matched"], "/",
            fixture_report["summary"]["fixtures"], " match; report ", out_path)
    println("replay_fixtures: traces   ", trace_identical, "/",
            length(sorted_trace_reports), " byte-identical; report ", trace_report_path)
    if skip_traces
        println("replay_fixtures: --skip-traces; traced fixtures were not regenerated")
    end
    for report in fixture_reports
        if report["first_difference"] !== nothing
            diff = report["first_difference"]
            println(stderr, "replay_fixtures: first difference in ", report["id"],
                    ": ", diff["field"], " expected=", diff["expected"],
                    " actual=", diff["actual"])
        end
    end
    for report in sorted_trace_reports
        if report["status"] != "match"
            println(stderr, "replay_fixtures: trace mismatch for ", report["id"], ": ",
                    "sha256_match=", report["sha256_match"],
                    " bytes_match=", report["bytes_match"],
                    " events_match=", report["events_match"],
                    " summary_identical=", report["summary_equivalence"]["identical"])
        end
    end
    return all_match && (skip_traces || all_traces_match)
end

function main(argv)
    opts, flags = parse_args(argv)
    ok = run_replay(opts, flags)
    ok || exit(1)
    return nothing
end

main(ARGS)
