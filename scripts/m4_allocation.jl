#!/usr/bin/env julia
# M4 allocation profiler.
#
# Measures the three phases defined by wiki/benchmarks/m4-perf.md section 1:
# reset, launch, and steady-state stepping. Steady state is the per-step
# `update!(eng, config.fixed_dt)` loop (save_previous_state! +
# step_simulation!/finalize_step! + fever bucket update + steps_run
# bookkeeping), identical in shape to `run_shot!`.
#
# Measurement method (same structure as tmp/m4-session2/step_probe.jl):
#   * one warmed process, one thread for gate-comparable runs;
#   * GC.gc() and all reset/launch preparation outside the measured region;
#   * Base.gc_bytes() deltas around the region;
#   * tracing disabled (eng.trace = nothing), summary callbacks only;
#   * sites from Profile.Allocs at sample_rate = 1.0 over a separate warmed
#     run of the same steady-state loop, aggregated by the first frame whose
#     file is under julia/PeggleSim/src.
#
# Usage (from the repository root, single-threaded):
#   export JULIA_DEPOT_PATH="$PWD/tmp/julia-depot:$HOME/.julia"
#   julia --startup-file=no --project=julia/PeggleSim -t 1 \
#     scripts/m4_allocation.jl --workload all --threads 1 \
#     --out results/m4/allocation-profile.pre.json --print
#
# Options:
#   --workload ID   "all" (representative five rows), a catalog id, or a
#                   comma-separated list of ids. Default: all.
#   --aim N         run this aim for every selected workload. Default: each
#                   workload's catalog profile aims (mustache 900 and 570,
#                   the others 900).
#   --threads N     must match the Julia thread count; default: current.
#   --shots N       per-shot step cap for every measured loop. Default: 4000
#                   (step_probe.jl's stepwise cap).
#   --warmups N     full warmup shots per row; must be >= 3. Default: 3.
#   --out PATH      output JSON. Default: results/m4/allocation-profile.pre.json
#   --top N         allocation sites per workload. Default: 25.
#   --print         print a human-readable summary to stdout.
#   --snapshot-note TEXT
#                   optional run note stored in the document (for example,
#                   "measured mid-refactor ..."; omitted when empty).
#   --help, -h
#
# The output is canonical: keys sorted, two-space indent, finite numbers only,
# one trailing newline, and no timestamps, wall-clock values, hostnames, or
# absolute paths. Re-running on the same tree must produce byte-identical
# JSON. Only the --out path is written.

using PeggleSim
using Profile
using SHA

const REPO_ROOT = dirname(@__DIR__)
const SRC_DIR = joinpath(REPO_ROOT, "julia", "PeggleSim", "src")
const FORMAT = "peggle.m4_allocation_profile"
const SCHEMA_VERSION = 1
const DEFAULT_OUT = "results/m4/allocation-profile.pre.json"
const DEFAULT_SHOTS = 4000
const DEFAULT_WARMUPS = 3
const DEFAULT_TOP = 25

# ---------------------------------------------------------------------------
# Workload catalog
# ---------------------------------------------------------------------------

struct CatalogEntry
    id::String
    level::String
    config::String
    balls::Int
    profile_aims::Vector{Int}
    representative::Bool
end

const CATALOG = [
    CatalogEntry("mustache", "fixtures/mustache/artifact/mustache.v1.json",
                 "fixtures/mustache/config.dev.v1.json", 1, [900, 570], true),
    CatalogEntry("circles_small", "interchange/levels/circle_level.v1.json",
                 "interchange/config.v1.json", 1, [900], true),
    CatalogEntry("lines_rect_annular", "interchange/levels/slide.v1.json",
                 "interchange/config.v1.json", 1, [900], true),
    CatalogEntry("annular_dense", "interchange/levels/squiggly_circle.v1.json",
                 "interchange/config.v1.json", 1, [900], true),
    CatalogEntry("lines_rect_annular_multi3", "interchange/levels/slide.v1.json",
                 "interchange/config.v1.json", 3, [900], false),
]

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

_round6(x::Real) = isfinite(float(x)) ? round(float(x), digits = 6) : 0.0

function _bytes_per_step(bytes::Integer, steps::Integer)
    steps > 0 || return 0.0
    return _round6(bytes / steps)
end

function _sum_bytes(v::AbstractVector{Int})
    total = 0
    for x in v
        total += x
    end
    return total
end

# Nearest-rank percentile, matching tmp/m4-session2/step_probe.jl's pct().
function _percentile(sorted::Vector{Int}, p::Float64)
    n = length(sorted)
    n == 0 && return 0
    idx = clamp(ceil(Int, p * n), 1, n)
    return sorted[idx]
end

function _max_step(bytes::Vector{Int})
    mx = 0
    for x in bytes
        x > mx && (mx = x)
    end
    return mx
end

function _count_nonzero(bytes::Vector{Int})
    n = 0
    for x in bytes
        x != 0 && (n += 1)
    end
    return n
end

# ---------------------------------------------------------------------------
# Canonical JSON writer (sorted keys, two-space indent, finite numbers only)
# ---------------------------------------------------------------------------

function _json_escape(io::IO, s::AbstractString)
    write(io, '"')
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif c == '\b'
            write(io, "\\b")
        elseif c == '\f'
            write(io, "\\f")
        elseif Int(c) < 0x20
            write(io, "\\u")
            write(io, lpad(string(Int(c); base = 16), 4, '0'))
        else
            write(io, c)
        end
    end
    write(io, '"')
    return nothing
end

function _json_value(io::IO, v, indent::Int)
    pad = " " ^ indent
    child = " " ^ (indent + 2)
    if v === nothing
        write(io, "null")
    elseif v isa Bool
        write(io, v ? "true" : "false")
    elseif v isa Integer
        write(io, string(Int64(v)))
    elseif v isa AbstractFloat
        x = Float64(v)
        isfinite(x) || error("canonical JSON refuses NaN/Inf at value $(x)")
        write(io, string(x))
    elseif v isa AbstractString
        _json_escape(io, v)
    elseif v isa AbstractDict
        keys_sorted = sort!(collect(keys(v)); by = k -> String(k))
        if isempty(keys_sorted)
            write(io, "{}")
            return nothing
        end
        write(io, "{\n")
        for (i, k) in enumerate(keys_sorted)
            write(io, child)
            _json_escape(io, String(k))
            write(io, ": ")
            _json_value(io, v[k], indent + 2)
            i < length(keys_sorted) && write(io, ',')
            write(io, '\n')
        end
        write(io, pad)
        write(io, '}')
    elseif v isa AbstractVector || v isa Tuple
        if isempty(v)
            write(io, "[]")
            return nothing
        end
        write(io, "[\n")
        for (i, x) in enumerate(v)
            write(io, child)
            _json_value(io, x, indent + 2)
            i < length(v) && write(io, ',')
            write(io, '\n')
        end
        write(io, pad)
        write(io, ']')
    else
        error("canonical JSON cannot encode $(typeof(v))")
    end
    return nothing
end

function _write_json(path::AbstractString, value)
    mkpath(dirname(path))
    open(path, "w") do io
        _json_value(io, value, 0)
        write(io, '\n')
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Environment and source-tree identity
# ---------------------------------------------------------------------------

function _git(args...)
    try
        cmd = `git -C $(REPO_ROOT) $(collect(String, args))`
        return strip(read(cmd, String))
    catch
        return ""
    end
end

function _git_dirty()
    try
        out = read(`git -C $(REPO_ROOT) status --porcelain --untracked-files=all -- julia/PeggleSim/src`,
                   String)
        return !isempty(strip(out))
    catch
        return false
    end
end

function _cpu_model()
    try
        for line in eachline("/proc/cpuinfo")
            occursin("model name", line) || continue
            parts = split(line, ':'; limit = 2)
            length(parts) == 2 && return strip(parts[2])
        end
    catch
    end
    return Sys.CPU_NAME
end

function _src_files()
    paths = String[]
    for (root, _dirs, files) in walkdir(SRC_DIR; follow_symlinks = false)
        for f in files
            p = joinpath(root, f)
            isfile(p) && push!(paths, p)
        end
    end
    sort!(paths; by = p -> relpath(p, SRC_DIR))
    return paths
end

function _concat_sha256(paths::Vector{String})
    data = UInt8[]
    for p in paths
        try
            append!(data, read(p))
        catch
            # A file that disappears mid-edit simply does not contribute; the
            # resulting hash change is what flags the moving tree.
        end
    end
    return bytes2hex(SHA.sha256(data))
end

function _src_hashes()
    files = _src_files()
    jl = String[p for p in files if endswith(p, ".jl")]
    return (tree = _concat_sha256(files), jl = _concat_sha256(jl),
            tree_files = length(files), jl_files = length(jl))
end

function _environment(requested_threads::Int)
    h = _src_hashes()
    return Dict{String,Any}(
        "julia_version" => string(VERSION),
        "machine" => Sys.MACHINE,
        "cpu_model" => _cpu_model(),
        "nthreads" => Threads.nthreads(),
        "requested_threads" => requested_threads,
        "git_head" => _git("rev-parse", "HEAD"),
        "dirty" => _git_dirty(),
        "git_dirty_scope" => "julia/PeggleSim/src",
        "src_tree_sha256" => h.tree,
        "src_jl_sha256" => h.jl,
        "src_file_count" => h.tree_files,
        "src_jl_file_count" => h.jl_files,
        "src_tree_sha256_method" =>
            "sha256 of the concatenated contents of every regular file under " *
            "julia/PeggleSim/src, files sorted by relative path; src_jl_sha256 " *
            "applies the same method to *.jl files only",
    )
end

function _method_string(nthreads::Int)
    threading = nthreads == 1 ?
        "Measured single-threaded (nthreads=1)." :
        "Measured with nthreads=$(nthreads); allocation accounting is process-wide, so this is not gate-comparable."
    return "Base.gc_bytes() deltas around one measured region; GC.gc() and any reset/launch " *
           "preparation run outside the region, never inside it. The engine is warmed with " *
           "full shots at the measured aim and trace is disabled (eng.trace = nothing); " *
           "summary callbacks only, no snapshots, result extraction, JSONL writing, or " *
           "tracing inside any measured region. reset is reset_shot_engine!(eng, ckpt) only. " *
           "launch is launch!(eng, aim) after a reset outside the region (staged launch " *
           "events are flushed by the first steady-state step). run is run_shot!(eng; " *
           "max_steps=step_cap) after reset+launch outside the region. steady_state is " *
           "update!(eng, config.fixed_dt) per step in the same loop shape as run_shot! " *
           "(save_previous_state!, step_simulation!/finalize_step!, fever bucket update, " *
           "steps_run bookkeeping) until shot_done or the step cap, starting from a fresh " *
           "reset and recording step 1. Sites come from Profile.Allocs at sample_rate=1.0 " *
           "over a separate warmed run of the same steady-state loop, aggregated by the " *
           "first stack frame whose file is under julia/PeggleSim/src. " * threading
end

# ---------------------------------------------------------------------------
# Measurement primitives
# ---------------------------------------------------------------------------

function _measure_reset!(eng, ckpt)
    GC.gc()
    b0 = Int64(Base.gc_bytes())
    PeggleSim.reset_shot_engine!(eng, ckpt; static_geometry = ckpt isa PeggleSim.PreparedCheckpoint)
    b1 = Int64(Base.gc_bytes())
    return Int(b1 - b0)
end

# The engine must already be reset (by _measure_reset! or a caller reset).
function _measure_launch!(eng, aim::Int)
    GC.gc()
    b0 = Int64(Base.gc_bytes())
    PeggleSim.launch!(eng, aim)
    b1 = Int64(Base.gc_bytes())
    return Int(b1 - b0)
end

# The engine must already be launched (by _measure_launch! or a caller launch).
function _measure_run!(eng, max_steps::Int)
    GC.gc()
    b0 = Int64(Base.gc_bytes())
    PeggleSim.run_shot!(eng; max_steps = max_steps)
    b1 = Int64(Base.gc_bytes())
    return (bytes = Int(b1 - b0), steps = eng.steps_run, done = eng.shot_done)
end

function _measure_steady!(eng, ckpt, aim::Int, max_steps::Int)
    PeggleSim.reset_shot_engine!(eng, ckpt; static_geometry = ckpt isa PeggleSim.PreparedCheckpoint)
    PeggleSim.launch!(eng, aim)
    dt = eng.config.fixed_dt
    bytes = Vector{Int}(undef, max_steps)
    n = 0
    GC.gc()
    while !eng.shot_done && n < max_steps
        b0 = Int64(Base.gc_bytes())
        PeggleSim.update!(eng, dt)
        b1 = Int64(Base.gc_bytes())
        n += 1
        bytes[n] = Int(b1 - b0)
    end
    return (bytes = bytes[1:n], steps = n, done = eng.shot_done)
end

function _steady_phase(measured, max_steps::Int)
    bytes = measured.bytes
    steps = measured.steps
    sorted = sort(bytes)
    total = _sum_bytes(bytes)
    mx = _max_step(bytes)
    nz = _count_nonzero(bytes)
    return Dict{String,Any}(
        "steps" => steps,
        "total_bytes" => total,
        "bytes_per_step" => _bytes_per_step(total, steps),
        "max_step_bytes" => mx,
        "p50" => _percentile(sorted, 0.5),
        "p99" => _percentile(sorted, 0.99),
        "nonzero_steps" => nz,
        "zero_steps" => steps - nz,
        "first_step_bytes" => isempty(bytes) ? 0 : bytes[1],
        "budget_bytes" => 0,
        "gate" => true,
        "pass" => total == 0 && mx == 0,
        "shot_completed" => measured.done,
        "step_cap" => max_steps,
        "includes" =>
            "per-step update!(eng, config.fixed_dt): save_previous_state!, " *
            "step_simulation!/finalize_step! (including the fever bucket update), " *
            "and steps_run bookkeeping; loop condition identical to run_shot!",
        "criterion" =>
            "m4-perf section 1.1: sum(Base.gc_bytes() deltas) == 0 AND max " *
            "single-step delta == 0 over a warmed pass starting from a fresh reset",
    )
end

# ---------------------------------------------------------------------------
# Profile.Allocs attribution
# ---------------------------------------------------------------------------

mutable struct SiteAcc
    bytes::Int
    count::Int
    funcs::Dict{String,Int}
    types::Dict{String,Int}
    inlined::Int
end

SiteAcc() = SiteAcc(0, 0, Dict{String,Int}(), Dict{String,Int}(), 0)

struct SiteFrame
    file::String
    line::Int
    func::String
    inlined::Bool
end

struct ProfileAgg
    sites::Dict{Tuple{String,Int},SiteAcc}
    profiled_bytes::Int
    profiled_count::Int
    attributed_bytes::Int
    attributed_count::Int
    unattributed_bytes::Int
    unattributed_count::Int
    dropped_profiler_bytes::Int
    dropped_profiler_count::Int
end

function _frame_file(f)
    try
        return String(f.file)
    catch
        return ""
    end
end

function _frame_func(f)
    try
        return String(f.func)
    catch
        return ""
    end
end

function _frame_inlined(f)
    try
        return f.inlined === true
    catch
        return false
    end
end

function _src_relative(path::AbstractString)
    s = String(path)
    i = findfirst("PeggleSim/src/", s)
    i === nothing && return nothing
    return "julia/" * s[first(i):end]
end

function _first_src_frame(a)
    frames = a.stacktrace
    for f in frames
        rel = _src_relative(_frame_file(f))
        rel === nothing && continue
        line = try
            Int(f.line)
        catch
            0
        end
        return SiteFrame(rel, line, _frame_func(f), _frame_inlined(f))
    end
    return nothing
end

function _is_profiler_alloc(a)
    frames = a.stacktrace
    isempty(frames) && return false
    # Every recorded allocation has the gc allocation hook at the top. A
    # profiler-internal allocation reaches Profile/src before any engine
    # frame; an engine allocation reaches a PeggleSim/src frame first (the
    # Allocs.jl macro wrapper appears only after the engine frames).
    #
    # Do not trust a.type === Profile.Allocs.BufferType alone: Julia 1.12's
    # allocator hook also labels some real large array growth
    # (jl_gc_managed_malloc) as BufferType. The stack decides.
    for f in frames
        ff = _frame_file(f)
        if occursin("/Profile/src/", ff) || occursin("Profile/src/", ff) ||
           occursin("Allocs.jl", ff)
            return true
        end
        _src_relative(ff) === nothing || return false
    end
    return false
end

function _aggregate_allocs(res)
    sites = Dict{Tuple{String,Int},SiteAcc}()
    profiled_bytes = 0
    profiled_count = 0
    attributed_bytes = 0
    attributed_count = 0
    unattributed_bytes = 0
    unattributed_count = 0
    dropped_bytes = 0
    dropped_count = 0
    for a in res.allocs
        size = try
            Int(a.size)
        catch
            0
        end
        if _is_profiler_alloc(a)
            dropped_bytes += size
            dropped_count += 1
            continue
        end
        profiled_bytes += size
        profiled_count += 1
        fr = _first_src_frame(a)
        if fr === nothing
            unattributed_bytes += size
            unattributed_count += 1
            continue
        end
        key = (fr.file, fr.line)
        acc = get!(sites, key) do
            SiteAcc()
        end
        acc.bytes += size
        acc.count += 1
        acc.funcs[fr.func] = get(acc.funcs, fr.func, 0) + size
        tn = try
            string(a.type)
        catch
            "unknown"
        end
        acc.types[tn] = get(acc.types, tn, 0) + size
        fr.inlined && (acc.inlined += 1)
        attributed_bytes += size
        attributed_count += 1
    end
    return ProfileAgg(sites, profiled_bytes, profiled_count, attributed_bytes,
                      attributed_count, unattributed_bytes, unattributed_count,
                      dropped_bytes, dropped_count)
end

function _profile_steady!(eng, ckpt, aim::Int, max_steps::Int)
    PeggleSim.reset_shot_engine!(eng, ckpt; static_geometry = ckpt isa PeggleSim.PreparedCheckpoint)
    PeggleSim.launch!(eng, aim)
    dt = eng.config.fixed_dt
    bytes = Vector{Int}(undef, max_steps)
    n = 0
    GC.gc()
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate = 1.0 begin
        while !eng.shot_done && n < max_steps
            b0 = Int64(Base.gc_bytes())
            PeggleSim.update!(eng, dt)
            b1 = Int64(Base.gc_bytes())
            n += 1
            bytes[n] = Int(b1 - b0)
        end
    end
    res = Profile.Allocs.fetch()
    return (agg = _aggregate_allocs(res), bytes = bytes[1:n], steps = n,
            done = eng.shot_done)
end

function _dominant_func(funcs::Dict{String,Int})
    isempty(funcs) && return ""
    ordered = sort!(collect(funcs); by = kv -> (-kv.second, kv.first))
    return ordered[1].first
end

function _classify_site(file::String, func::String, in_repeat::Bool)
    fn = Symbol(func)
    if occursin("checkpoint.jl", file) || fn in (:restore!, :_match_from_checkpoint)
        return "reset"
    elseif occursin("trace.jl", file) || occursin("snapshot.jl", file) ||
           occursin("canonical.jl", file) || occursin("jsonio.jl", file) ||
           fn in (:trace_encode, :trace_json)
        return "export_only"
    elseif !in_repeat
        return "one_time_capacity_growth"
    else
        return "in_scope_steady_state"
    end
end

function _site_entries(full::ProfileAgg, repeat::ProfileAgg,
                       steps::Int, topn::Int)
    ordered = sort!(collect(full.sites);
                    by = kv -> (-kv[2].bytes, kv[1][1], kv[1][2]))
    out = Dict{String,Any}[]
    for (key, acc) in first(ordered, topn)
        file, line = key
        func = _dominant_func(acc.funcs)
        in_repeat = haskey(repeat.sites, key)
        notes = String[]
        if acc.inlined > 0
            push!(notes,
                  "at least one contributing allocation's first PeggleSim/src frame is " *
                  "inlined; the reported file:line is the inlining site Julia recorded " *
                  "and may not be the physical caller")
        end
        if length(acc.funcs) > 1
            names = sort!(collect(keys(acc.funcs)))
            push!(notes, "multiple functions aggregate at this file:line: " *
                         join(names, ", "))
        end
        if line == 0
            push!(notes,
                  "profiler reported line 0 (macro or inlined frame); only " *
                  "file-level attribution is available")
        end
        if !in_repeat
            push!(notes,
                  "absent from a second steady-state pass on the same engine; a " *
                  "one-time allocation rather than a per-step cost (the " *
                  "container has already grown in the measured pass)")
        end
        push!(out, Dict{String,Any}(
            "file" => file,
            "line" => line,
            "func" => func,
            "bytes" => acc.bytes,
            "bytes_per_step" => _bytes_per_step(acc.bytes, steps),
            "count" => acc.count,
            "types" => [Dict{String,Any}("type" => t, "bytes" => b)
                        for (t, b) in first(sort!(collect(acc.types);
                                                  by = kv -> (-kv.second, kv.first)), 3)],
            "classification" => _classify_site(file, func, in_repeat),
            "note" => join(notes, "; "),
        ))
    end
    return out
end

function _profile_metadata(full, repeat, measured_total::Int)
    denom = measured_total > 0 ? measured_total : 1
    return Dict{String,Any}(
        "sample_rate" => 1.0,
        "full_pass" => Dict{String,Any}(
            "steps" => full.steps,
            "measured_total_bytes" => _sum_bytes(full.bytes),
            "profiled_bytes" => full.agg.profiled_bytes,
            "profiled_count" => full.agg.profiled_count,
            "attributed_bytes" => full.agg.attributed_bytes,
            "attributed_count" => full.agg.attributed_count,
        ),
        "repeat_pass" => Dict{String,Any}(
            "description" =>
                "second steady-state pass on the same engine immediately after " *
                "the full pass; used only to separate one-time growth from " *
                "per-step sites",
            "steps" => repeat.steps,
            "measured_total_bytes" => _sum_bytes(repeat.bytes),
            "profiled_bytes" => repeat.agg.profiled_bytes,
            "profiled_count" => repeat.agg.profiled_count,
        ),
        "attributed_bytes" => full.agg.attributed_bytes,
        "attributed_count" => full.agg.attributed_count,
        "profiled_bytes" => full.agg.profiled_bytes,
        "profiled_count" => full.agg.profiled_count,
        "measured_total_bytes" => measured_total,
        "attributed_to_measured_ratio" => _round6(full.agg.attributed_bytes / denom),
        "profiled_to_measured_ratio" => _round6(full.agg.profiled_bytes / denom),
        "measured_pass_delta_bytes" => measured_total - _sum_bytes(full.bytes),
        "unattributed_bytes" => full.agg.unattributed_bytes,
        "unattributed_count" => full.agg.unattributed_count,
        "dropped_profiler_bytes" => full.agg.dropped_profiler_bytes,
        "dropped_profiler_count" => full.agg.dropped_profiler_count,
        "classification_basis" =>
            "sites are measured in the full steady-state pass at the same shot " *
            "index as the measured pass; a site absent from a second pass on " *
            "the same engine is classified " *
            "one_time_capacity_growth, because it does not recur after the " *
            "container has grown; checkpoint.jl/restore frames are reset and " *
            "trace/snapshot/canonical/jsonio frames are export_only; everything " *
            "else is in_scope_steady_state",
        "coverage_note" =>
            "Profile.Allocs records payload sizes; Base.gc_bytes() also counts GC " *
            "object headers and padding, so profiled bytes are expected to be " *
            "below the measured total. A nonzero measured_pass_delta_bytes also " *
            "means the separate profiled pass allocated differently from the clean " *
            "measured pass; that delta is not attributed to any site. Ratios are " *
            "reported, not corrected.",
    )
end

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

function _new_engine(level, config, ckpt)
    eng = PeggleSim.shot_engine(ckpt;
        callbacks = PeggleSim.harness_callbacks(clearing = false),
        config = config, virtual_width = level.virtual_width,
        virtual_height = level.virtual_height)
    eng.trace = nothing
    return eng
end

function _warm!(eng, ckpt, aim::Int, warmups::Int, shots::Int)
    for _ in 1:warmups
        PeggleSim.reset_shot_engine!(eng, ckpt; static_geometry = ckpt isa PeggleSim.PreparedCheckpoint)
        PeggleSim.launch!(eng, aim)
        PeggleSim.run_shot!(eng; max_steps = shots)
    end
    return nothing
end

function _measure_row(entry::CatalogEntry, aim::Int, opts)
    level_path = joinpath(REPO_ROOT, entry.level)
    config_path = joinpath(REPO_ROOT, entry.config)
    isfile(level_path) || error("level file not found: $(level_path)")
    isfile(config_path) || error("config file not found: $(config_path)")

    level = PeggleSim.load_level(level_path)
    config = PeggleSim.load_config(config_path)
    ckpt = PeggleSim.build_checkpoint(level, config; balls = entry.balls, mode = :solo,
        provenance = (reference_revision = level.provenance.reference_revision,
            reference_tree = level.provenance.reference_tree,
            config_sha256 = level.provenance.config_sha256,
            level_sha256 = level.level_sha256))
    opts["prepared"] && (ckpt = PeggleSim.prepare_checkpoint(ckpt))

    shots = opts["shots"]
    warmups = opts["warmups"]

    # Engine A: unprofiled gate measurement. Phase order matches
    # tmp/m4-session2/step_probe.jl: reset, launch, a full run shot, then the
    # stepwise pass that is the gate measurement.
    eng = _new_engine(level, config, ckpt)
    _warm!(eng, ckpt, aim, warmups, shots)
    reset_bytes = _measure_reset!(eng, ckpt)
    launch_bytes = _measure_launch!(eng, aim)
    run = _measure_run!(eng, shots)
    steady = _measure_steady!(eng, ckpt, aim, shots)

    # Engine B: site attribution at the same shot index as the measured pass.
    # A warm container can grow exactly once (section 1.2 capacity growth) on
    # the measured shot; profiling a later shot on engine A would miss it.
    # Engine B repeats the same warmup + run-shot history and profiles the same
    # stepwise pass, so its measured total should match engine A's.
    eng_b = _new_engine(level, config, ckpt)
    _warm!(eng_b, ckpt, aim, warmups, shots)
    PeggleSim.reset_shot_engine!(eng_b, ckpt; static_geometry = ckpt isa PeggleSim.PreparedCheckpoint)
    PeggleSim.launch!(eng_b, aim)
    PeggleSim.run_shot!(eng_b; max_steps = shots)
    full = _profile_steady!(eng_b, ckpt, aim, shots)
    repeat = _profile_steady!(eng_b, ckpt, aim, shots)

    sites = _site_entries(full.agg, repeat.agg, steady.steps, opts["top"])
    phases = Dict{String,Any}(
        "reset" => Dict{String,Any}(
            "bytes" => reset_bytes,
            "budget_bytes" => 0,
            "gate" => false,
            "pass" => reset_bytes == 0,
            "includes" => "reset_shot_engine!(eng, ckpt) only; GC.gc() before the region",
            "note" =>
                "m4-perf section 1.3: reset is per-shot overhead, not the " *
                "zero-allocation stepping gate; budget 0 is the near-zero target",
        ),
        "launch" => Dict{String,Any}(
            "bytes" => launch_bytes,
            "budget_bytes" => 0,
            "gate" => false,
            "pass" => launch_bytes == 0,
            "includes" => "launch!(eng, aim) after a reset outside the region",
            "note" =>
                "m4-perf section 1.4: launch is per-shot overhead, not the " *
                "stepping gate; staged launch events are flushed by the first " *
                "steady_state step",
        ),
        "run" => Dict{String,Any}(
            "bytes" => run.bytes,
            "steps" => run.steps,
            "bytes_per_step" => _bytes_per_step(run.bytes, run.steps),
            "shot_completed" => run.done,
            "gate" => false,
            "includes" => "run_shot!(eng; max_steps=step_cap) after reset+launch outside the region",
            "note" => "whole-shot context; not part of the steady-state gate",
        ),
        "steady_state" => _steady_phase(steady, shots),
    )

    return Dict{String,Any}(
        "id" => string(entry.id, "@", aim),
        "workload" => entry.id,
        "aim" => aim,
        "balls" => entry.balls,
        "level" => entry.level,
        "config" => entry.config,
        "warmups" => warmups,
        "shot_step_cap" => shots,
        "method" => opts["method"],
        "environment" => opts["environment"],
        "phases" => phases,
        "sites" => sites,
        "profile" => _profile_metadata(full, repeat, _sum_bytes(steady.bytes)),
    )
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

function _usage(io::IO = stdout)
    println(io, "usage: julia --project=julia/PeggleSim -t 1 scripts/m4_allocation.jl [options]")
    println(io, "  --prepared     use prepared checkpoints and compact geometry")
    println(io, "  --workload ID   all, a catalog id, or comma-separated ids (default: all)")
    println(io, "  --aim N         aim index for every selected workload (default: catalog aims)")
    println(io, "  --threads N     must match the Julia thread count (default: current)")
    println(io, "  --shots N       per-shot step cap (default: ", DEFAULT_SHOTS, ")")
    println(io, "  --warmups N     full warmup shots per row, >= 3 (default: ", DEFAULT_WARMUPS, ")")
    println(io, "  --out PATH      default: ", DEFAULT_OUT)
    println(io, "  --top N         allocation sites per workload (default: ", DEFAULT_TOP, ")")
    println(io, "  --print         print a human-readable summary to stdout")
    println(io, "  --snapshot-note TEXT  optional run note stored in the document")
    println(io, "  --help, -h")
    println(io)
    println(io, "catalog: ", join([e.id for e in CATALOG], ", "))
    println(io, "  representative (used by --workload all): ",
            join([e.id for e in CATALOG if e.representative], ", "))
end

function _parse_int(flag::String, value::String)
    v = try
        parse(Int, value)
    catch
        error("$(flag) expects an integer, got $(repr(value))")
    end
    return v
end

function _parse_cli(argv)
    opts = Dict{String,Any}(
        "workload" => "all",
        "aim" => nothing,
        "threads" => Threads.nthreads(),
        "shots" => DEFAULT_SHOTS,
        "warmups" => DEFAULT_WARMUPS,
        "out" => DEFAULT_OUT,
        "top" => DEFAULT_TOP,
        "print" => false,
        "prepared" => false,
        "snapshot_note" => "",
    )
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in ("--help", "-h")
            _usage()
            exit(0)
        elseif a == "--prepared"
            opts["prepared"] = true
        elseif a == "--print"
            opts["print"] = true
        elseif a in ("--workload", "--aim", "--threads", "--shots", "--warmups",
                     "--out", "--top", "--snapshot-note")
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            v = argv[i]
            if a == "--workload"
                opts["workload"] = v
            elseif a == "--aim"
                opts["aim"] = _parse_int(a, v)
            elseif a == "--threads"
                opts["threads"] = _parse_int(a, v)
            elseif a == "--shots"
                opts["shots"] = _parse_int(a, v)
            elseif a == "--warmups"
                opts["warmups"] = _parse_int(a, v)
            elseif a == "--top"
                opts["top"] = _parse_int(a, v)
            elseif a == "--out"
                opts["out"] = v
            elseif a == "--snapshot-note"
                opts["snapshot_note"] = v
            end
        else
            error("unknown argument $(repr(a)); see --help")
        end
        i += 1
    end

    opts["aim"] !== nothing && opts["aim"] < 0 && error("--aim must be >= 0")
    opts["shots"] >= 1 || error("--shots must be >= 1")
    opts["warmups"] >= 3 || error("--warmups must be >= 3 (m4-perf section 1.1 warmup)")
    opts["top"] >= 1 || error("--top must be >= 1")
    opts["threads"] >= 1 || error("--threads must be >= 1")
    if opts["threads"] != Threads.nthreads()
        error("--threads $(opts["threads"]) does not match the Julia thread count " *
              "$(Threads.nthreads()); start Julia with -t $(opts["threads"])")
    end
    return opts
end

function _select_rows(opts)
    wanted = String[]
    if opts["workload"] == "all"
        wanted = String[e.id for e in CATALOG if e.representative]
    else
        wanted = String[strip(s) for s in split(opts["workload"], ",") if !isempty(strip(s))]
        isempty(wanted) && error("--workload is empty")
    end
    rows = Tuple{CatalogEntry,Int}[]
    for id in wanted
        idx = findfirst(e -> e.id == id, CATALOG)
        idx === nothing && error("unknown workload $(repr(id)); catalog: " *
                                 join([e.id for e in CATALOG], ", "))
        entry = CATALOG[idx]
        aims = opts["aim"] === nothing ? entry.profile_aims : Int[opts["aim"]]
        for aim in aims
            push!(rows, (entry, aim))
        end
    end
    return rows
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function _print_summary(results::Vector{Dict{String,Any}})
    for r in results
        ph = r["phases"]
        ss = ph["steady_state"]
        println(r["id"], "  reset=", ph["reset"]["bytes"], "B  launch=",
                ph["launch"]["bytes"], "B  steady=", ss["total_bytes"], "B / ",
                ss["steps"], " steps = ", ss["bytes_per_step"], " B/step  max=",
                ss["max_step_bytes"], "B  p50=", ss["p50"], "B  p99=", ss["p99"],
                "B  nonzero=", ss["nonzero_steps"], "/", ss["steps"],
                "  pass=", ss["pass"])
        for s in r["sites"]
            println("  ", lpad(string(s["bytes_per_step"]), 10), " B/step  ",
                    s["file"], ":", s["line"], "  [", s["classification"], "]",
                    isempty(s["note"]) ? "" : "  note: " * s["note"])
        end
    end
end

function main()
    opts = _parse_cli(ARGS)
    out_abs = abspath(opts["out"])
    repo_prefix = REPO_ROOT * "/"
    if !(out_abs == REPO_ROOT || startswith(out_abs, repo_prefix))
        error("--out must be inside the repository $(REPO_ROOT), got $(out_abs)")
    end

    rows = _select_rows(opts)
    env = _environment(opts["threads"])
    opts["environment"] = env
    opts["method"] = _method_string(Threads.nthreads())

    results = Dict{String,Any}[]
    first_hash = ""
    last_hash = ""
    source_moving = false
    for (entry, aim) in rows
        println(stderr, "m4_allocation: measuring ", entry.id, " aim=", aim,
                " (warmups=", opts["warmups"], ", step_cap=", opts["shots"], ")")
        h_start = _src_hashes().jl
        row = _measure_row(entry, aim, opts)
        h_end = _src_hashes().jl
        row["src_jl_sha256_at_start"] = h_start
        row["src_jl_sha256_at_end"] = h_end
        row["src_changed_during_row"] = h_start != h_end
        isempty(first_hash) && (first_hash = h_start)
        last_hash = h_end
        if h_start != h_end
            source_moving = true
        end
        push!(results, row)
    end

    # Deterministic output order, independent of measurement order.
    sort!(results; by = r -> (r["workload"], r["aim"]))

    # Detect a source move between the first and last workload. The measured
    # tree is the start hash; if the *.jl hash changed, record both ends and
    # flag it instead of hiding it.
    end_hashes = _src_hashes()
    if first_hash != last_hash || end_hashes.jl != env["src_jl_sha256"]
        source_moving = true
    end
    env["source_moving"] = source_moving
    env["src_jl_sha256_at_first_workload"] = first_hash
    env["src_jl_sha256_at_last_workload"] = last_hash
    env["tree_changed_during_run"] = source_moving
    if source_moving
        env["src_jl_sha256_end"] = end_hashes.jl
        env["src_tree_sha256_end"] = end_hashes.tree
    end

    notes = String[
        "Phases are measured in a separate process pass each; allocation bytes are deterministic for a fixed tree.",
        "Profile.Allocs sizes are payload sizes and exclude GC headers/padding; site bytes_per_step therefore do not sum to the measured steady_state total (see each workload's profile ratios).",
        "The zero-allocation verdict is the orchestrator's; this file only reports the per-phase pass flags for the stated criterion.",
    ]
    if !isempty(opts["snapshot_note"])
        pushfirst!(notes, opts["snapshot_note"])
    end
    if source_moving
        push!(notes,
              "source_moving: julia/PeggleSim/src changed while this run was in progress; environment.src_*_sha256 are the start hashes and environment.*_end are the end hashes, and each workload records its own start/end *.jl hash. Rows measured before and after the change may not describe one tree.")
    end

    doc = Dict{String,Any}(
        "format" => FORMAT,
        "schema_version" => SCHEMA_VERSION,
        "generator" => "scripts/m4_allocation.jl",
        "method" => opts["method"],
        "environment" => env,
        "source_moving" => source_moving,
        "classification_vocabulary" => [
            "in_scope_steady_state",
            "one_time_capacity_growth",
            "reset",
            "export_only",
        ],
        "workloads" => results,
        "notes" => notes,
    )
    if !isempty(opts["snapshot_note"])
        doc["snapshot_note"] = opts["snapshot_note"]
    end
    _write_json(out_abs, doc)
    println(stderr, "m4_allocation: wrote ", out_abs)
    opts["print"] && _print_summary(results)
    return nothing
end

main()
