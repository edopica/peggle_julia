#!/usr/bin/env julia
# Shot bench driver (M3 workstream G): single-shot trace + candidate sweep.
#
# Trace mode replays one aim index from the M2 ready-to-aim checkpoint,
# writes a canonical gameplay trace (optionally with per-step snapshots), and
# emits a fixture expected record in the exact shape of
# fixtures/mustache/expected/*.json. The expected record's trace block always
# describes the snapshot-free serialization (the corpus convention), so the
# driver runs a second, snapshot-free pass when --snapshots is given.
#
# Sweep mode evaluates candidates from one checkpoint. The serial path reuses
# a single ShotEngine reset via reset_shot_engine!; the parallel path uses one
# ShotEngine per Julia thread, each reset from the same checkpoint, and
# returns rows in candidate order. --verify-serial runs both and requires
# bit-identical result rows.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/shot_bench.jl \
#       --fixture ID --level PATH --config PATH --aim INDEX \
#       [--balls N] [--clearing] [--max-steps N] [--snapshots] \
#       [--category NAME] --trace-out PATH --expected-out PATH
#
#   julia --project=julia/PeggleSim -t 4 julia/PeggleSim/bin/shot_bench.jl \
#       --sweep --level PATH --config PATH \
#       (--indices 0,900,1800 | --stride N) \
#       [--balls N] [--clearing] [--max-steps N] [--threads N] \
#       [--verify-serial] [--alloc] [--trace-dir DIR] \
#       --out PATH.jsonl --summary PATH.json
#
# --trace-dir enables eng.trace for every measured candidate and writes one
# snapshot-free gameplay trace per candidate into DIR (serial-candidate-NNNN
# and parallel-candidate-NNNN for the two passes of --verify-serial). The
# returned rows are byte-identical to an untraced run; the diagnostic cost is
# the trace writer I/O only. Without --trace-dir no tracing is attached and
# the summary/rows are unchanged.
#
# --alloc measures bytes allocated per candidate after warmup with a
# Base.gc_bytes() delta around reset+launch+run+extract on the serial path
# (allocation accounting is per-process, so parallel runs cannot attribute
# bytes to one candidate). An extra untimed serial pass compiles every
# candidate code path first; the summary records `alloc_method` and an
# `alloc` block with per-candidate bytes and stats.
#
# --category is optional: when omitted the driver reads the reference expected
# record at fixtures/mustache/expected/<id>.json if it exists, and otherwise
# uses "completion".

using PeggleSim

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const DEFAULT_MAX_STEPS = 3600
const DEFAULT_THREADS = Threads.nthreads()

const FLAG_ARGS = Set(["--clearing", "--snapshots", "--sweep", "--verify-serial", "--alloc"])
const VALUE_ARGS = Set([
    "--fixture", "--level", "--config", "--aim", "--balls", "--max-steps",
    "--indices", "--stride", "--threads", "--out", "--summary",
    "--trace-out", "--expected-out", "--category", "--trace-dir",
])

function usage()
    println("usage:")
    println("  shot_bench.jl --fixture ID --level PATH --config PATH --aim INDEX " *
            "[--balls N] [--clearing] [--max-steps N] [--snapshots] " *
            "[--category NAME] --trace-out PATH --expected-out PATH")
    println("  shot_bench.jl --sweep --level PATH --config PATH " *
            "(--indices 0,900,1800 | --stride N) [--balls N] [--clearing] " *
            "[--max-steps N] [--threads N] [--verify-serial] [--alloc] " *
            "[--trace-dir DIR] --out PATH.jsonl --summary PATH.json")
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

function _require(opts, key::String)
    haskey(opts, key) || error("missing required argument $(key)")
    return opts[key]
end

function _ensure_parent(path::AbstractString)
    dir = dirname(abspath(path))
    isempty(dir) || mkpath(dir)
    return nothing
end

function _checkpoint_provenance(level)
    return (
        reference_revision = String(level.provenance.reference_revision),
        reference_tree = String(level.provenance.reference_tree),
        config_sha256 = String(level.provenance.config_sha256),
        level_sha256 = String(level.level_sha256),
    )
end

# shot_summary.styles may be a Dict, a NamedTuple, a "name:count" vector, or a
# comma-joined string (the harness feature encoding). Normalize to an object.
function _styles_object(styles)
    out = Dict{String,Any}()
    if styles === nothing
        return out
    elseif styles isa AbstractDict
        for (k, v) in styles
            out[string(k)] = v
        end
    elseif styles isa NamedTuple
        for (k, v) in pairs(styles)
            out[String(k)] = v
        end
    elseif styles isa AbstractString
        for item in split(styles, ",")
            isempty(item) && continue
            parts = split(item, ":")
            out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
        end
    elseif styles isa AbstractVector
        for item in styles
            text = String(item)
            parts = split(text, ":")
            out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
        end
    else
        error("unsupported shot_summary.styles type: $(typeof(styles))")
    end
    return out
end

function _category_for(fixture::AbstractString, opts)
    haskey(opts, "--category") && return opts["--category"]
    ref_path = joinpath(REPO_ROOT, "fixtures", "mustache", "expected", fixture * ".json")
    if isfile(ref_path)
        doc = load_json(ref_path)
        if doc isa AbstractDict && doc["category"] isa AbstractString
            return String(doc["category"])
        end
    end
    return "completion"
end

function _run_traced_shot(ckpt, level, config, clearing::Bool, max_steps::Int,
                          aim::Int, trace_path::AbstractString,
                          include_snapshot::Bool)
    callbacks = PeggleSim.harness_callbacks(clearing = clearing)
    eng = PeggleSim.shot_engine(
        ckpt; callbacks = callbacks, config = config,
        virtual_width = level.virtual_width, virtual_height = level.virtual_height)
    writer = PeggleSim.trace_open(trace_path; include_snapshot = include_snapshot)
    eng.trace = writer
    PeggleSim.launch!(eng, aim)
    PeggleSim.run_shot!(eng; max_steps = max_steps)
    PeggleSim.trace_close!(writer)
    eng.trace = nothing
    return eng, writer
end

function run_trace(opts, flags)
    fixture = _require(opts, "--fixture")
    level_path = _require(opts, "--level")
    config_path = _require(opts, "--config")
    aim = parse(Int, _require(opts, "--aim"))
    trace_out = _require(opts, "--trace-out")
    expected_out = _require(opts, "--expected-out")
    balls = parse(Int, get(opts, "--balls", "1"))
    max_steps = parse(Int, get(opts, "--max-steps", string(DEFAULT_MAX_STEPS)))
    clearing = "--clearing" in flags
    snapshots = "--snapshots" in flags

    level = PeggleSim.load_level(level_path)
    config = PeggleSim.load_config(config_path)
    provenance = _checkpoint_provenance(level)
    ckpt = PeggleSim.build_checkpoint(
        level, config; balls = balls, mode = :solo, provenance = provenance)

    _ensure_parent(trace_out)
    eng, writer = _run_traced_shot(
        ckpt, level, config, clearing, max_steps, aim, trace_out, snapshots)
    summary = PeggleSim.shot_summary(eng)

    # The corpus records the snapshot-free trace hash (see the Lua fixture
    # capture); with --snapshots the snapshot-free bytes come from a second
    # deterministic pass over the same checkpoint.
    if snapshots
        hash_path = tempname()
        _, hash_writer = _run_traced_shot(
            ckpt, level, config, clearing, max_steps, aim, hash_path, false)
        data = read(hash_path)
        rm(hash_path; force = true)
        events = hash_writer.steps_written
        trace_sha = PeggleSim.sha256_hex(data)
    else
        data = read(trace_out)
        events = writer.steps_written
        trace_sha = PeggleSim.sha256_hex(data)
    end

    angle = PeggleSim.angle_for_index(aim, config)
    record = Dict{String,Any}(
        "format" => "peggle.fixture",
        "schema_version" => 1,
        "id" => fixture,
        "category" => _category_for(fixture, opts),
        "kind" => "shot",
        "source" => Dict{String,Any}(
            "reference_revision" => String(level.provenance.reference_revision),
            "reference_tree" => String(level.provenance.reference_tree),
            "config_sha256" => String(level.provenance.config_sha256),
            "level" => level.name,
            "level_sha256" => level.level_sha256,
        ),
        "seed" => Dict{String,Any}(
            "level_seed" => level.level_seed,
            "type_counts" => Dict{String,Any}(
                "blue" => level.type_counts.blue,
                "green" => level.type_counts.green,
                "purple" => level.type_counts.purple,
                "red" => level.type_counts.red,
            ),
        ),
        "action" => Dict{String,Any}(
            "kind" => "shot",
            "aim_index" => aim,
            "angle" => angle,
            "delay" => 0,
            "balls" => balls,
        ),
        "completion" => Dict{String,Any}(
            "rule" => clearing ? "clearing" : "bench",
            "completed" => summary.completed,
            "reason" => summary.reason,
            "steps" => summary.steps,
            "max_steps" => max_steps,
        ),
        "result" => Dict{String,Any}(
            "score" => summary.score,
            "peg_score" => summary.peg_score,
            "bonus" => summary.bonus,
            "style_points" => summary.style_points,
            "styles" => _styles_object(summary.styles),
            "pegs_hit" => summary.pegs_hit,
            "reds_hit" => summary.reds_hit,
            "multiplier" => summary.multiplier,
            "is_fever" => summary.is_fever,
            "balls" => summary.balls,
            "balls_spawned" => summary.spawned,
        ),
        "trace" => Dict{String,Any}(
            "path" => "fixtures/traces/" * fixture * ".jsonl",
            "events" => events,
            "sha256" => trace_sha,
        ),
    )

    _ensure_parent(expected_out)
    open(expected_out, "w") do io
        write(io, PeggleSim.canonical_json(record))
        write(io, "\n")
    end
    println("shot_bench: trace   ", trace_out, " (", events, " events)")
    println("shot_bench: expected ", expected_out)
    return nothing
end

# ---------------------------------------------------------------------------
# Sweep mode
# ---------------------------------------------------------------------------

function _candidate_indices(opts, config)
    if haskey(opts, "--indices")
        raw = strip(opts["--indices"])
        isempty(raw) && error("--indices must not be empty")
        return [parse(Int, strip(part)) for part in split(raw, ",") if !isempty(strip(part))]
    elseif haskey(opts, "--stride")
        stride = parse(Int, opts["--stride"])
        stride >= 1 || error("--stride must be >= 1, got $(stride)")
        return collect(0:stride:config.aim_discretization_steps)
    end
    error("sweep mode requires --indices LIST or --stride N")
end

function _result_row(eng, index::Int, config)
    summary = PeggleSim.shot_summary(eng)
    return Dict{String,Any}(
        "index" => index,
        "angle" => PeggleSim.angle_for_index(index, config),
        "steps" => summary.steps,
        "completed" => summary.completed,
        "reason" => summary.reason,
        "score" => summary.score,
        "peg_score" => summary.peg_score,
        "bonus" => summary.bonus,
        "style_points" => summary.style_points,
        "style_total" => summary.style_total,
        "styles" => _styles_object(summary.styles),
        "pegs_hit" => summary.pegs_hit,
        "reds_hit" => summary.reds_hit,
        "multiplier" => summary.multiplier,
        "is_fever" => summary.is_fever,
        "balls" => summary.balls,
        "spawned" => summary.spawned,
    )
end

function _evaluate!(eng, ckpt, index::Int, config, max_steps::Int;
                    trace_path::Union{Nothing,AbstractString} = nothing)
    t0 = time_ns()
    PeggleSim.reset_shot_engine!(eng, ckpt)
    t1 = time_ns()
    writer = nothing
    if trace_path !== nothing
        writer = PeggleSim.trace_open(trace_path; include_snapshot = false)
        eng.trace = writer
    end
    PeggleSim.launch!(eng, index)
    PeggleSim.run_shot!(eng; max_steps = max_steps)
    t2 = time_ns()
    if writer !== nothing
        PeggleSim.trace_close!(writer)
        eng.trace = nothing
    end
    row = _result_row(eng, index, config)
    t3 = time_ns()
    return row, (Int(t1 - t0), Int(t2 - t1), Int(t3 - t2))
end

function _trace_candidate_path(trace_dir::AbstractString, pass::AbstractString,
                               index::Int)
    return joinpath(trace_dir, pass * "-candidate-" * lpad(index, 4, '0') * ".jsonl")
end

function _new_engine(ckpt, level, config, clearing::Bool)
    callbacks = PeggleSim.harness_callbacks(clearing = clearing)
    return PeggleSim.shot_engine(
        ckpt; callbacks = callbacks, config = config,
        virtual_width = level.virtual_width, virtual_height = level.virtual_height)
end

function _sweep_serial!(ckpt, level, config, clearing::Bool, max_steps::Int, indices;
                        measure_alloc::Bool = false,
                        trace_dir::Union{Nothing,AbstractString} = nothing)
    eng = _new_engine(ckpt, level, config, clearing)
    rows = Vector{Any}(undef, length(indices))
    timings = Matrix{Int}(undef, 3, length(indices))
    alloc_bytes = measure_alloc ? Vector{Int}(undef, length(indices)) : Int[]
    start = time_ns()
    for (pos, index) in enumerate(indices)
        trace_path = trace_dir === nothing ? nothing :
            _trace_candidate_path(trace_dir, "serial", index)
        if measure_alloc
            gb0 = Base.gc_bytes()
            row, timing = _evaluate!(eng, ckpt, index, config, max_steps;
                                     trace_path = trace_path)
            alloc_bytes[pos] = Int(Base.gc_bytes() - gb0)
        else
            row, timing = _evaluate!(eng, ckpt, index, config, max_steps;
                                     trace_path = trace_path)
        end
        rows[pos] = row
        timings[1, pos] = timing[1]
        timings[2, pos] = timing[2]
        timings[3, pos] = timing[3]
    end
    wall_ns = Int(time_ns() - start)
    return rows, timings, wall_ns, alloc_bytes
end

function _sweep_parallel!(ckpt, level, config, clearing::Bool, max_steps::Int, indices;
                          trace_dir::Union{Nothing,AbstractString} = nothing)
    n = length(indices)
    engines = Vector{Any}(nothing, Threads.maxthreadid())
    rows = Vector{Any}(undef, n)
    timings = Matrix{Int}(undef, 3, n)

    start = time_ns()
    Threads.@threads for pos in 1:n
        tid = Threads.threadid()
        eng = engines[tid]
        if eng === nothing
            eng = _new_engine(ckpt, level, config, clearing)
            engines[tid] = eng
        end
        index = indices[pos]
        trace_path = trace_dir === nothing ? nothing :
            _trace_candidate_path(trace_dir, "parallel", index)
        row, timing = _evaluate!(eng, ckpt, index, config, max_steps;
                                 trace_path = trace_path)
        rows[pos] = row
        timings[1, pos] = timing[1]
        timings[2, pos] = timing[2]
        timings[3, pos] = timing[3]
    end
    wall_ns = Int(time_ns() - start)
    return rows, timings, wall_ns
end

function _phase_stats(ns::AbstractVector{Int})
    n = length(ns)
    n == 0 && return Dict{String,Any}(
        "count" => 0, "total_ns" => 0, "mean_ns" => 0.0, "p50_ns" => 0, "p99_ns" => 0)
    sorted = sort(ns)
    total = sum(ns)
    return Dict{String,Any}(
        "count" => n,
        "total_ns" => total,
        "mean_ns" => total / n,
        "p50_ns" => sorted[clamp(cld(n, 2), 1, n)],
        "p99_ns" => sorted[clamp(ceil(Int, 0.99 * n), 1, n)],
    )
end

function _candidate_stats(values::AbstractVector{Int})
    n = length(values)
    n == 0 && return Dict{String,Any}(
        "mean" => 0.0, "p50" => 0, "p99" => 0, "min" => 0, "max" => 0)
    sorted = sort(values)
    return Dict{String,Any}(
        "mean" => sum(values) / n,
        "p50" => sorted[clamp(cld(n, 2), 1, n)],
        "p99" => sorted[clamp(ceil(Int, 0.99 * n), 1, n)],
        "min" => sorted[1],
        "max" => sorted[end],
    )
end

function _alloc_block(bytes::AbstractVector{Int})
    stats = _candidate_stats(bytes)
    return Dict{String,Any}(
        "count" => length(bytes),
        "total_bytes" => sum(bytes),
        "mean_bytes" => stats["mean"],
        "p50_bytes" => stats["p50"],
        "p99_bytes" => stats["p99"],
        "min_bytes" => stats["min"],
        "max_bytes" => stats["max"],
        "bytes" => collect(bytes),
    )
end

const ALLOC_METHOD =
    "Base.gc_bytes() delta around reset+launch+run+extract per candidate on a " *
    "post-warmup serial sweep (extra untimed serial pass compiles all code paths first)"

function _phases_block(timings::Matrix{Int})
    return Dict{String,Any}(
        "reset" => _phase_stats(timings[1, :]),
        "sim" => _phase_stats(timings[2, :]),
        "extract" => _phase_stats(timings[3, :]),
    )
end

function _throughput_block(rows, timings::Matrix{Int}, wall_ns::Int)
    steps = Int[row["steps"] for row in rows]
    total_steps = sum(steps)
    wall_seconds = wall_ns / 1e9
    candidates = length(rows)
    return Dict{String,Any}(
        "wall_seconds" => wall_seconds,
        "candidates_per_second" => candidates / max(wall_seconds, 1e-9),
        "steps_per_second" => total_steps / max(wall_seconds, 1e-9),
        "steps" => _candidate_stats(steps),
        "phases" => _phases_block(timings),
    )
end

function run_sweep(opts, flags)
    level_path = _require(opts, "--level")
    config_path = _require(opts, "--config")
    out_path = _require(opts, "--out")
    summary_path = _require(opts, "--summary")
    balls = parse(Int, get(opts, "--balls", "1"))
    max_steps = parse(Int, get(opts, "--max-steps", string(DEFAULT_MAX_STEPS)))
    clearing = "--clearing" in flags
    verify_serial = "--verify-serial" in flags
    alloc = "--alloc" in flags
    trace_dir = get(opts, "--trace-dir", nothing)
    if trace_dir !== nothing
        isempty(strip(trace_dir)) && error("--trace-dir must not be empty")
        mkpath(trace_dir)
    end
    requested_threads = parse(Int, get(opts, "--threads", string(DEFAULT_THREADS)))
    requested_threads >= 1 || error("--threads must be >= 1, got $(requested_threads)")
    if requested_threads > Threads.nthreads()
        println(stderr, "shot_bench: warning: --threads ", requested_threads,
                " exceeds Julia threads ", Threads.nthreads(),
                "; using ", Threads.nthreads())
    end
    use_parallel = min(requested_threads, Threads.nthreads()) > 1

    level = PeggleSim.load_level(level_path)
    config = PeggleSim.load_config(config_path)
    provenance = _checkpoint_provenance(level)
    ckpt = PeggleSim.build_checkpoint(
        level, config; balls = balls, mode = :solo, provenance = provenance)
    indices = _candidate_indices(opts, config)
    isempty(indices) && error("no candidates selected")

    # Untimed JIT warmup so the measured phases contain no compilation.
    warm = _new_engine(ckpt, level, config, clearing)
    _evaluate!(warm, ckpt, indices[1], config, max_steps)

    # Trace mode has its own code path (writer open/encode/close); compile it
    # outside the timed passes so traced-vs-untraced diagnostics measure I/O,
    # not first-call compilation. The warmup trace file is discarded.
    if trace_dir !== nothing
        warm_trace = joinpath(
            trace_dir, "warmup-candidate-" * lpad(indices[1], 4, '0') * ".jsonl")
        try
            _evaluate!(warm, ckpt, indices[1], config, max_steps;
                       trace_path = warm_trace)
        finally
            rm(warm_trace; force = true)
        end
    end

    # Allocation measurement needs a fully compiled sweep: an extra untimed
    # serial pass keeps JIT/library allocations out of the per-candidate
    # counts (they would otherwise dominate the first candidate).
    if alloc
        _sweep_serial!(ckpt, level, config, clearing, max_steps, indices)
    end

    serial_rows = nothing
    serial_timings = nothing
    serial_wall_ns = 0
    parallel_rows = nothing
    parallel_timings = nothing
    parallel_wall_ns = 0
    alloc_bytes = nothing

    if verify_serial
        serial_rows, serial_timings, serial_wall_ns, alloc_bytes =
            _sweep_serial!(ckpt, level, config, clearing, max_steps, indices;
                           measure_alloc = alloc, trace_dir = trace_dir)
        parallel_rows, parallel_timings, parallel_wall_ns =
            _sweep_parallel!(ckpt, level, config, clearing, max_steps, indices;
                             trace_dir = trace_dir)
    elseif use_parallel
        parallel_rows, parallel_timings, parallel_wall_ns =
            _sweep_parallel!(ckpt, level, config, clearing, max_steps, indices;
                             trace_dir = trace_dir)
        if alloc
            _, _, _, alloc_bytes =
                _sweep_serial!(ckpt, level, config, clearing, max_steps, indices;
                               measure_alloc = true, trace_dir = trace_dir)
        end
    else
        serial_rows, serial_timings, serial_wall_ns, alloc_bytes =
            _sweep_serial!(ckpt, level, config, clearing, max_steps, indices;
                           measure_alloc = alloc, trace_dir = trace_dir)
    end

    rows = serial_rows === nothing ? parallel_rows : serial_rows
    timings = serial_timings === nothing ? parallel_timings : serial_timings
    wall_ns = serial_rows === nothing ? parallel_wall_ns : serial_wall_ns

    identical = true
    mismatch_index = nothing
    if verify_serial
        for pos in eachindex(rows)
            if PeggleSim.canonical_json(rows[pos]) !=
               PeggleSim.canonical_json(parallel_rows[pos])
                identical = false
                mismatch_index = pos
                break
            end
        end
    end

    _ensure_parent(out_path)
    open(out_path, "w") do io
        for row in rows
            write(io, PeggleSim.canonical_json(row))
            write(io, "\n")
        end
    end

    primary = _throughput_block(rows, timings, wall_ns)
    summary = Dict{String,Any}(
        "format" => "peggle.shot_sweep",
        "schema_version" => 1,
        "level" => level.name,
        "level_sha256" => level.level_sha256,
        "balls" => balls,
        "clearing" => clearing,
        "max_steps" => max_steps,
        "candidates" => length(indices),
        "threads" => Threads.nthreads(),
        "requested_threads" => requested_threads,
        "verify_serial" => verify_serial,
        "serial_parallel_identical" => verify_serial ? identical : nothing,
        "wall_seconds" => primary["wall_seconds"],
        "candidates_per_second" => primary["candidates_per_second"],
        "steps_per_second" => primary["steps_per_second"],
        "steps" => primary["steps"],
        "phases" => primary["phases"],
        "alloc_requested" => alloc,
        "alloc_method" => alloc ? ALLOC_METHOD : nothing,
    )
    if serial_rows !== nothing
        summary["serial"] = _throughput_block(serial_rows, serial_timings, serial_wall_ns)
    end
    if parallel_rows !== nothing
        summary["parallel"] = _throughput_block(
            parallel_rows, parallel_timings, parallel_wall_ns)
    end
    if alloc && alloc_bytes !== nothing
        summary["alloc"] = _alloc_block(alloc_bytes)
    end
    if trace_dir !== nothing
        summary["trace"] = Dict{String,Any}(
            "dir" => abspath(trace_dir),
            "include_snapshot" => false,
            "note" => ("diagnostic mode: one snapshot-free trace per candidate " *
                       "per measured pass (serial-/parallel- prefix); result " *
                       "rows are unaffected"),
        )
    end

    _ensure_parent(summary_path)
    open(summary_path, "w") do io
        write(io, PeggleSim.canonical_json(summary))
        write(io, "\n")
    end

    println("shot_bench: sweep   ", out_path, " (", length(indices), " candidates)")
    println("shot_bench: summary ", summary_path)
    println("shot_bench: threads=", Threads.nthreads(),
            " candidates/s=", round(summary["candidates_per_second"]; digits = 2),
            " steps/s=", round(summary["steps_per_second"]; digits = 2),
            " serial_parallel_identical=",
            verify_serial ? string(identical) : "n/a")
    if verify_serial
        serial = summary["serial"]
        parallel = summary["parallel"]
        println("shot_bench: serial   ",
                round(serial["candidates_per_second"]; digits = 2), " candidates/s (",
                round(serial["wall_seconds"]; digits = 3), " s)")
        println("shot_bench: parallel ",
                round(parallel["candidates_per_second"]; digits = 2), " candidates/s (",
                round(parallel["wall_seconds"]; digits = 3), " s)")
    end
    if alloc && haskey(summary, "alloc")
        ab = summary["alloc"]
        println("shot_bench: alloc   mean=", round(Int, ab["mean_bytes"]),
                " bytes/candidate (p50=", ab["p50_bytes"],
                ", p99=", ab["p99_bytes"], ", max=", ab["max_bytes"], ")")
    end
    if trace_dir !== nothing
        println("shot_bench: trace   ", abspath(trace_dir),
                " (one trace per candidate per measured pass)")
    end

    if verify_serial && !identical
        println(stderr, "shot_bench: serial and parallel rows differ at position ",
                mismatch_index)
        println(stderr, "  serial:   ",
                PeggleSim.canonical_json(rows[mismatch_index]))
        println(stderr, "  parallel: ",
                PeggleSim.canonical_json(parallel_rows[mismatch_index]))
        exit(1)
    end
    return nothing
end

function main(argv)
    opts, flags = parse_args(argv)
    if "--sweep" in flags
        run_sweep(opts, flags)
    else
        run_trace(opts, flags)
    end
    return nothing
end

main(ARGS)
