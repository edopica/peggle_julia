#!/usr/bin/env julia
# WP-D2 cross-backend state summary.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_state_summary.jl \
#       --repo . --out tmp/core-math/state-summary.json
#
# Reads the two comparator outputs (state-compare-<backend>.json) and the two
# captured level directories (state-<backend>/levels/) and writes:
#   * pass/fail per backend and per section,
#   * the control: system_libm level artifacts vs historical interchange/levels
#     (must be exactly equal),
#   * cross-backend geometry difference counts: core_math vs system_libm and
#     core_math vs historical,
#   * SHA-256 for every capture/compare file.
#
# Exits nonzero when the control differs or a comparator did not verify.

using PeggleSim
import JSON

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--repo", "--state-root", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg[3:end]] = argv[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: wpd_state_summary.jl --repo PATH --state-root PATH --out PATH")
            exit(0)
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

# ---------------------------------------------------------------------------
# Bit-exact JSON helpers (same rules as wpd_state_compare.jl)
# ---------------------------------------------------------------------------

function _leaf_equal(a, b)::Bool
    if a isa Real && b isa Real && !(a isa Bool) && !(b isa Bool)
        return reinterpret(UInt64, Float64(a)) == reinterpret(UInt64, Float64(b))
    end
    return isequal(a, b)
end

function _flatten!(out::Dict{String,Any}, value, prefix::String)
    if value isa AbstractDict
        for key in sort!(collect(keys(value)))
            child = isempty(prefix) ? String(key) : prefix * "." * String(key)
            _flatten!(out, value[key], child)
        end
    elseif value isa AbstractVector
        for (i, v) in enumerate(value)
            _flatten!(out, v, prefix * "[" * string(i) * "]")
        end
    else
        out[prefix] = value
    end
    return nothing
end

function _load_levels(dir::String)
    out = Dict{String,Any}()
    isdir(dir) || return out
    for file in sort(filter(f -> endswith(f, ".v1.json"), readdir(dir)))
        name = replace(file, ".v1.json" => "")
        out[name] = JSON.parsefile(joinpath(dir, file); inttype = Float64)
    end
    return out
end

_drop_provenance(doc::AbstractDict) = begin
    copy = Dict{String,Any}(doc)
    delete!(copy, "provenance")
    copy
end

# Compare two name -> level-document maps. Counts differing levels, pegs, and
# leaf fields; the first difference is recorded in sorted order.
function _compare_level_sets(a_docs::Dict{String,Any}, b_docs::Dict{String,Any})
    names = sort!(collect(union(keys(a_docs), keys(b_docs))))
    levels_differing = 0
    pegs_differing = 0
    fields_differing = 0
    first = nothing
    for name in names
        if !haskey(a_docs, name) || !haskey(b_docs, name)
            levels_differing += 1
            fields_differing += 1
            if first === nothing
                first = Dict{String,Any}(
                    "level" => name, "path" => "\$",
                    "expected" => haskey(a_docs, name) ? "present" : "missing",
                    "actual" => haskey(b_docs, name) ? "present" : "missing")
            end
            continue
        end
        fa = Dict{String,Any}()
        _flatten!(fa, a_docs[name], "")
        fb = Dict{String,Any}()
        _flatten!(fb, b_docs[name], "")
        pegs = Set{Int}()
        level_differs = false
        for path in sort!(collect(union(keys(fa), keys(fb))))
            equal = haskey(fa, path) && haskey(fb, path) && _leaf_equal(fa[path], fb[path])
            equal && continue
            level_differs = true
            fields_differing += 1
            m = match(r"^pegs\[(\d+)\]", path)
            m !== nothing && push!(pegs, parse(Int, m.captures[1]))
            if first === nothing
                first = Dict{String,Any}(
                    "level" => name, "path" => path,
                    "expected" => get(fa, path, nothing),
                    "actual" => get(fb, path, nothing))
            end
        end
        level_differs && (levels_differing += 1)
        pegs_differing += length(pegs)
    end
    return Dict{String,Any}(
        "levels_checked" => length(names),
        "levels_differing" => levels_differing,
        "pegs_differing" => pegs_differing,
        "fields_differing" => fields_differing,
        "first_difference" => first,
    )
end

# ---------------------------------------------------------------------------
# Comparator outputs, hashes
# ---------------------------------------------------------------------------

function _load_compare(path::String)
    isfile(path) || return nothing
    return JSON.parsefile(path)
end

function _backend_passed(cmp)::Bool
    cmp === nothing && return false
    for section in ("levels", "rng", "colors", "checkpoints")
        sec = get(cmp, section, nothing)
        (sec isa AbstractDict && sec["verified"] === true) || return false
    end
    return true
end

function _hash_tree!(hashes::Dict{String,Any}, base::String, dir::String)
    isdir(dir) || return nothing
    for (root, dirs, files) in walkdir(dir)
        sort!(dirs)
        sort!(files)
        for file in files
            path = joinpath(root, file)
            hashes[relpath(path, base)] = sha256_hex(read(path))
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function main(argv)
    opts = parse_args(argv)
    repo = normpath(get(opts, "repo", pwd()))
    state_root = abspath(get(opts, "state-root", joinpath(repo, "tmp", "core-math")))
    out = get(opts, "out", joinpath(state_root, "state-summary.json"))

    system_state = joinpath(state_root, "state-system_libm")
    core_state = joinpath(state_root, "state-core_math")
    cmp_sys_path = joinpath(state_root, "state-compare-system_libm.json")
    cmp_core_path = joinpath(state_root, "state-compare-core_math.json")
    cmp_sys = _load_compare(cmp_sys_path)
    cmp_core = _load_compare(cmp_core_path)

    # Backend engagement evidence: each state dir carries a probe written by
    # tools/wpd_backend_probe.lua under the same environment as the capture.
    probe_sys_path = joinpath(system_state, "backend-identity.json")
    probe_core_path = joinpath(core_state, "backend-identity.json")
    probe_sys = isfile(probe_sys_path) ? load_json(probe_sys_path) : nothing
    probe_core = isfile(probe_core_path) ? load_json(probe_core_path) : nothing
    probe_info = Dict{String,Any}()
    for (name, probe) in (("system_libm", probe_sys), ("core_math", probe_core))
        if probe === nothing
            probe_info[name] = Dict{String,Any}("present" => false)
            continue
        end
        probe_info[name] = Dict{String,Any}(
            "present" => true,
            "backend" => as_string(probe["backend"], "backend"),
            "backend_matches_dir" =>
                as_string(probe["backend"], "backend") == name,
            "library" => as_string(probe["library"], "library"),
            "native_identity" => as_string(probe["native_identity"], "native_identity"),
            "probes" => probe["probes"],
        )
    end
    probe_differences = Dict{String,Any}()
    if probe_sys !== nothing && probe_core !== nothing
        for (key, value) in as_object(probe_sys["probes"], "probes")
            other = get(probe_core["probes"], key, nothing)
            if other !== nothing && other != value
                probe_differences[key] = Dict{String,Any}(
                    "system_libm" => value, "core_math" => other)
            end
        end
    end

    hist = _load_levels(joinpath(repo, "interchange", "levels"))
    sys = _load_levels(joinpath(system_state, "levels"))
    core = _load_levels(joinpath(core_state, "levels"))

    # Control: system_libm level artifacts must equal the historical corpus
    # exactly (provenance included).
    control = _compare_level_sets(hist, sys)
    control["system_libm_vs_historical_exact"] =
        control["levels_differing"] == 0 && control["fields_differing"] == 0
    control["note"] =
        "system_libm levels/checkpoints are the control and must equal the historical corpus exactly"

    # Control: the raw RNG/color fixture files and every checkpoint written by
    # the system_libm capture must be byte-identical to the historical corpus.
    function _files_equal(a::String, b::String)::Bool
        isfile(a) && isfile(b) && read(a) == read(b)
    end
    control["rng_fixture_exact"] = _files_equal(
        joinpath(system_state, "rng", "rng_sequences.v1.json"),
        joinpath(repo, "fixtures", "rng", "rng_sequences.v1.json"))
    control["colors_fixture_exact"] = _files_equal(
        joinpath(system_state, "rng", "peg_colors.v1.json"),
        joinpath(repo, "fixtures", "rng", "peg_colors.v1.json"))
    hist_checkpoint_dir = joinpath(repo, "fixtures", "checkpoints")
    checkpoint_files = isdir(hist_checkpoint_dir) ?
        sort(filter(f -> endswith(f, ".json"), readdir(hist_checkpoint_dir))) :
        String[]
    missing_checkpoints = String[]
    for file in checkpoint_files
        _files_equal(joinpath(system_state, "checkpoints", file),
                     joinpath(hist_checkpoint_dir, file)) ||
            push!(missing_checkpoints, file)
    end
    control["checkpoints_checked"] = length(checkpoint_files)
    control["checkpoints_differing"] = missing_checkpoints
    control["checkpoints_exact"] = isempty(missing_checkpoints)

    # Geometry comparison ignores provenance (revision/config hashes are not
    # geometry) and compares the level content bit-exactly.
    sys_geom = Dict{String,Any}(name => _drop_provenance(doc) for (name, doc) in sys)
    core_geom = Dict{String,Any}(name => _drop_provenance(doc) for (name, doc) in core)
    hist_geom = Dict{String,Any}(name => _drop_provenance(doc) for (name, doc) in hist)
    cross = Dict{String,Any}(
        "core_math_vs_system_libm" => _compare_level_sets(sys_geom, core_geom),
        "core_math_vs_historical" => _compare_level_sets(hist_geom, core_geom),
    )

    backends = Dict{String,Any}()
    for (name, cmp, path) in (
        ("system_libm", cmp_sys, cmp_sys_path),
        ("core_math", cmp_core, cmp_core_path),
    )
        entry = Dict{String,Any}("passed" => _backend_passed(cmp))
        if cmp !== nothing
            for section in ("levels", "rng", "colors", "checkpoints")
                entry[section] = get(cmp, section, nothing)
            end
        end
        isfile(path) && (entry["compare_sha256"] = sha256_hex(read(path)))
        backends[name] = entry
    end

    hashes = Dict{String,Any}()
    _hash_tree!(hashes, repo, system_state)
    _hash_tree!(hashes, repo, core_state)
    for path in (cmp_sys_path, cmp_core_path)
        isfile(path) && (hashes[relpath(path, repo)] = sha256_hex(read(path)))
    end
    hist_dir = joinpath(repo, "interchange", "levels")
    if isdir(hist_dir)
        for file in sort(filter(f -> endswith(f, ".v1.json"), readdir(hist_dir)))
            path = joinpath(hist_dir, file)
            hashes[relpath(path, repo)] = sha256_hex(read(path))
        end
    end

    failures = String[]
    for backend in ("system_libm", "core_math")
        backends[backend]["passed"] === true ||
            push!(failures, "$(backend): comparator did not verify every section")
        info = probe_info[backend]
        info["present"] === true ||
            push!(failures, "$(backend): backend-identity.json is missing")
        if info["present"] === true && info["backend_matches_dir"] !== true
            push!(failures, "$(backend): probe backend does not match the state dir")
        end
    end
    isempty(probe_differences) &&
        push!(failures,
              "backend engagement: both backends returned identical probe bits")
    control["system_libm_vs_historical_exact"] === true ||
        push!(failures, "control: system_libm levels differ from the historical corpus")
    control["rng_fixture_exact"] === true ||
        push!(failures,
              "control: system_libm RNG fixture differs from the historical corpus")
    control["colors_fixture_exact"] === true ||
        push!(failures,
              "control: system_libm peg-colors fixture differs from the historical corpus")
    control["checkpoints_exact"] === true ||
        push!(failures,
              "control: system_libm checkpoints differ from the historical corpus")

    doc = Dict{String,Any}(
        "format" => "peggle.wpd_state_summary",
        "schema_version" => 1,
        "backends" => backends,
        "backend_probes" => Dict{String,Any}(
            "per_backend" => probe_info,
            "differences" => probe_differences,
        ),
        "control" => control,
        "cross_backend" => cross,
        "hashes" => hashes,
        "failures" => failures,
    )

    dir = dirname(out)
    isempty(dir) || mkpath(dir)
    open(out, "w") do io
        write(io, canonical_json(doc))
        write(io, "\n")
    end

    println("wpd_state_summary: -> ", out)
    for backend in ("system_libm", "core_math")
        println("  ", rpad(backend, 12), " ",
                backends[backend]["passed"] === true ? "PASS" : "FAIL")
    end
    if control["system_libm_vs_historical_exact"] === true
        println("  control system_libm vs historical: EXACTLY EQUAL (",
                control["levels_checked"], " levels, 0 field differences)")
    else
        println("  control system_libm vs historical: DIFFERS (",
                control["levels_differing"], " levels, ",
                control["fields_differing"], " fields)")
    end
    println("  control fixtures: rng=",
            control["rng_fixture_exact"] === true ? "exact" : "DIFFERS",
            " colors=", control["colors_fixture_exact"] === true ? "exact" : "DIFFERS",
            " checkpoints=", control["checkpoints_exact"] === true ? "exact" : "DIFFERS",
            " (", control["checkpoints_checked"], " files)")
    for name in ("core_math_vs_system_libm", "core_math_vs_historical")
        c = cross[name]
        println("  ", name, ": levels_differing=", c["levels_differing"],
                " pegs_differing=", c["pegs_differing"],
                " fields_differing=", c["fields_differing"])
    end
    println("  backend probes differing: ", length(probe_differences),
            " of ", probe_sys === nothing ? 0 : length(as_object(probe_sys["probes"], "probes")))
    for (key, values) in sort(collect(probe_differences); by = first)
        println("    ", key, ": system=", values["system_libm"],
                " core=", values["core_math"])
    end

    if !isempty(failures)
        for failure in failures
            println(stderr, "wpd_state_summary: FAILURE: ", failure)
        end
        exit(1)
    end
    return nothing
end

main(ARGS)
