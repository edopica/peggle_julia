#!/usr/bin/env julia
# WP-D2 state comparator: verify one math backend's LÖVE capture against
# independent Julia recomputation.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_state_compare.jl \
#       --repo . \
#       --state-dir tmp/core-math/state-system_libm \
#       --backend system_libm \
#       --out tmp/core-math/state-compare-system_libm.json
#
# Sections:
#   levels      -- experimental state-<backend>/levels/*.v1.json vs the
#                  historical interchange/levels/*.v1.json, bit-exact with the
#                  `provenance` object removed;
#   rng         -- replay state-<backend>/rng/rng_sequences.v1.json with
#                  LoveRandom (sequences, states, set_state, seed_anchors);
#   colors      -- replay state-<backend>/rng/peg_colors.v1.json (init, first
#                  promotion, and every promotion round from a fresh init);
#   checkpoints -- rebuild each state-<backend>/checkpoints/*.v1.json from the
#                  experimental level artifact with the same seed/provenance/
#                  ball count and require canonical equality.
#
# The output is canonical JSON ("peggle.wpd_state_comparison", schema 1) with
# a per-section {verified, checked, mismatches, first_mismatch,
# computed_sha256} block. The process exits nonzero on any mismatch.

using PeggleSim
import JSON

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--repo", "--state-dir", "--backend", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg[3:end]] = argv[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: wpd_state_compare.jl --repo PATH --state-dir PATH " *
                    "--backend NAME --out PATH")
            exit(0)
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

# ---------------------------------------------------------------------------
# Bit-exact JSON diffing
# ---------------------------------------------------------------------------

# JSON numbers parsed with inttype=Float64 are compared as IEEE-754 bit
# patterns so signed zero and every payload never compare equal by accident.
function _leaf_equal(a, b)::Bool
    if a isa Real && b isa Real && !(a isa Bool) && !(b isa Bool)
        return reinterpret(UInt64, Float64(a)) == reinterpret(UInt64, Float64(b))
    end
    return isequal(a, b)
end

# Return nothing when equal, else (path, expected, actual).
function _first_json_difference(a, b, path::String)
    if a isa AbstractDict && b isa AbstractDict
        keys_a = Set(String.(collect(keys(a))))
        keys_b = Set(String.(collect(keys(b))))
        for key in sort!(collect(union(keys_a, keys_b)))
            child = isempty(path) ? key : path * "." * key
            if !(key in keys_a)
                return (child, nothing, b[key])
            elseif !(key in keys_b)
                return (child, a[key], nothing)
            end
            diff = _first_json_difference(a[key], b[key], child)
            diff === nothing || return diff
        end
        return nothing
    elseif a isa AbstractVector && b isa AbstractVector
        n = min(length(a), length(b))
        for i in 1:n
            diff = _first_json_difference(a[i], b[i], path * "[" * string(i) * "]")
            diff === nothing || return diff
        end
        length(a) == length(b) && return nothing
        return (path * "[" * string(n + 1) * "]", length(a), length(b))
    else
        return _leaf_equal(a, b) ? nothing : (path, a, b)
    end
end

# Record a (path, expected, actual) tuple in a section's mismatch counters.
function _note!(section::Dict{String,Any}, diff)
    diff === nothing && return nothing
    section["mismatches"] = section["mismatches"] + 1
    if section["first_mismatch"] === nothing
        section["first_mismatch"] = Dict{String,Any}(
            "path" => diff[1], "expected" => diff[2], "actual" => diff[3])
    end
    return nothing
end

_new_section() = Dict{String,Any}(
    "verified" => false, "checked" => 0, "mismatches" => 0,
    "first_mismatch" => nothing, "computed_sha256" => nothing)

# ---------------------------------------------------------------------------
# Levels
# ---------------------------------------------------------------------------

function check_levels(repo::String, state_dir::String)
    section = _new_section()
    hist_dir = joinpath(repo, "interchange", "levels")
    exp_dir = joinpath(state_dir, "levels")
    exp_files = sort(filter(f -> endswith(f, ".v1.json"), readdir(exp_dir)))
    hist_files = sort(filter(f -> endswith(f, ".v1.json"), readdir(hist_dir)))
    if exp_files != hist_files
        section["mismatches"] = section["mismatches"] + 1
        section["first_mismatch"] = Dict{String,Any}(
            "level" => "<file-set>", "path" => "levels",
            "expected" => hist_files, "actual" => exp_files)
    end

    recomputed = Dict{String,Any}()
    for file in exp_files
        name = replace(file, ".v1.json" => "")
        # inttype=Float64 forces every JSON number to binary64 so the
        # comparison is a pure bit-pattern comparison.
        exp = JSON.parsefile(joinpath(exp_dir, file); inttype = Float64)
        hist = JSON.parsefile(joinpath(hist_dir, file); inttype = Float64)
        delete!(exp, "provenance")
        delete!(hist, "provenance")
        recomputed[name] = exp
        section["checked"] = section["checked"] + 1
        diff = _first_json_difference(hist, exp, "")
        if diff !== nothing
            section["mismatches"] = section["mismatches"] + 1
            if section["first_mismatch"] === nothing
                section["first_mismatch"] = Dict{String,Any}(
                    "level" => name, "path" => diff[1],
                    "expected" => diff[2], "actual" => diff[3])
            end
        end
    end
    section["verified"] = section["mismatches"] == 0
    section["computed_sha256"] = sha256_hex(canonical_json(recomputed))
    return section
end

# ---------------------------------------------------------------------------
# RNG sequences
# ---------------------------------------------------------------------------

# Mirror test_rng.jl `_apply_rng_op!`.
function _apply_rng_op!(r::LoveRandom, op::AbstractDict)
    out = Any[]
    kind = get(op, "kind", "random")
    count = as_int(get(op, "count", 1), "count")
    if kind == "random"
        hi = as_int(op["hi"], "hi")
        if haskey(op, "lo")
            lo = as_int(op["lo"], "lo")
            for _ in 1:count
                push!(out, random(r, lo, hi))
            end
        else
            for _ in 1:count
                push!(out, random(r, hi))
            end
        end
    elseif kind == "random01"
        for _ in 1:count
            push!(out, random01(r))
        end
    else
        error("unknown RNG fixture op kind: $(kind)")
    end
    return out
end

# Fixture results are integers or "0x%016x" bit-hex strings (random01).
function _result_diff(got::Vector{Any}, want, path::String)
    length(got) == length(want) || return (path, length(want), length(got))
    for (i, (g, w)) in enumerate(zip(got, want))
        child = path * "[" * string(i) * "]"
        if w isa Integer
            (g isa Integer && g == Int(w)) || return (child, Int(w), g)
        elseif w isa AbstractString
            (g isa Float64 && float_bits_hex(g) == String(w)) ||
                return (child, String(w), g)
        else
            isequal(g, w) || return (child, w, g)
        end
    end
    return nothing
end

function check_rng(_repo::String, state_dir::String)
    section = _new_section()
    doc = load_json(joinpath(state_dir, "rng", "rng_sequences.v1.json"))
    as_string(doc["format"], "format") == "peggle.rng_fixtures" ||
        error("unexpected RNG fixture format: $(doc["format"])")
    recomputed = Dict{String,Any}(
        "sequences" => Any[], "states" => Any[],
        "set_state" => Any[], "seed_anchors" => Any[])

    for seq in get(doc, "sequences", Any[])
        seed = as_int(seq["seed"], "seed")
        r = LoveRandom(seed)
        got = Any[]
        for op in seq["ops"]
            append!(got, _apply_rng_op!(r, op))
        end
        rec = Dict{String,Any}("seed" => seed, "results" => got)
        section["checked"] = section["checked"] + 1
        _note!(section, _result_diff(
            got, seq["results"], "sequences[seed=$(seed)].results"))
        if haskey(seq, "state")
            state = get_state(r)
            rec["state"] = state
            want = as_string(seq["state"], "state")
            state == want || _note!(section,
                ("sequences[seed=$(seed)].state", want, state))
        end
        push!(recomputed["sequences"], rec)
    end

    for st in get(doc, "states", Any[])
        seed = as_int(st["seed"], "seed")
        r = LoveRandom(seed)
        for op in st["draws"]
            _apply_rng_op!(r, op)
        end
        state = get_state(r)
        rec = Dict{String,Any}("seed" => seed, "state" => state)
        section["checked"] = section["checked"] + 1
        want = as_string(st["state"], "state")
        state == want || _note!(section, ("states[seed=$(seed)].state", want, state))
        nxt = get(st, "next", nothing)
        if nxt !== nothing
            vals = _apply_rng_op!(r, nxt)
            if haskey(nxt, "bits_hex")
                bits = [float_bits_hex(v) for v in vals]
                want_bits = [String(s) for s in nxt["bits_hex"]]
                rec["next_bits_hex"] = bits
                bits == want_bits || _note!(section,
                    ("states[seed=$(seed)].next.bits_hex", want_bits, bits))
            end
            if haskey(nxt, "results")
                rec["next_results"] = vals
                _note!(section, _result_diff(
                    vals, nxt["results"], "states[seed=$(seed)].next.results"))
            end
            if haskey(st, "state_after")
                state_after = get_state(r)
                rec["state_after"] = state_after
                want_after = as_string(st["state_after"], "state_after")
                state_after == want_after || _note!(section,
                    ("states[seed=$(seed)].state_after", want_after, state_after))
            end
        end
        push!(recomputed["states"], rec)
    end

    for item in get(doc, "set_state", Any[])
        want_state = as_string(item["state"], "state")
        r = LoveRandom(0)
        set_state!(r, want_state)
        state = get_state(r)
        rec = Dict{String,Any}("state" => want_state, "state_after_set" => state)
        section["checked"] = section["checked"] + 1
        state == want_state || _note!(section,
            ("set_state[...].state_after_set", want_state, state))
        vals = _apply_rng_op!(r, item["then"])
        rec["results"] = vals
        _note!(section, _result_diff(vals, item["results"], "set_state[...].results"))
        if haskey(item, "state_after")
            state_after = get_state(r)
            rec["state_after"] = state_after
            want_after = as_string(item["state_after"], "state_after")
            state_after == want_after || _note!(section,
                ("set_state[...].state_after", want_after, state_after))
        end
        push!(recomputed["set_state"], rec)
    end

    for anchor in get(doc, "seed_anchors", Any[])
        seed = as_int(anchor["seed"], "seed")
        r = LoveRandom(seed)
        rec = Dict{String,Any}("seed" => seed)
        section["checked"] = section["checked"] + 1
        if haskey(anchor, "draws")
            want = [as_int(x, "draws") for x in anchor["draws"]]
            got = [random(r, 1, 10) for _ in 1:length(want)]
            rec["draws"] = got
            got == want || _note!(section,
                ("seed_anchors[seed=$(seed)].draws", want, got))
        end
        if haskey(anchor, "first_random_1_100")
            want = as_int(anchor["first_random_1_100"], "first_random_1_100")
            got = random(r, 1, 100)
            rec["first_random_1_100"] = got
            got == want || _note!(section,
                ("seed_anchors[seed=$(seed)].first_random_1_100", want, got))
        end
        if haskey(anchor, "first_random_1_10")
            want = as_int(anchor["first_random_1_10"], "first_random_1_10")
            got = random(LoveRandom(seed), 1, 10)
            rec["first_random_1_10"] = got
            got == want || _note!(section,
                ("seed_anchors[seed=$(seed)].first_random_1_10", want, got))
        end
        if haskey(anchor, "state")
            want = as_string(anchor["state"], "state")
            got = get_state(r)
            rec["state"] = got
            got == want || _note!(section,
                ("seed_anchors[seed=$(seed)].state", want, got))
        end
        push!(recomputed["seed_anchors"], rec)
    end

    section["verified"] = section["mismatches"] == 0
    section["computed_sha256"] = sha256_hex(canonical_json(recomputed))
    return section
end

# ---------------------------------------------------------------------------
# Peg colors
# ---------------------------------------------------------------------------

function check_colors(repo::String, state_dir::String)
    section = _new_section()
    doc = load_json(joinpath(state_dir, "rng", "peg_colors.v1.json"))
    startswith(as_string(doc["format"], "format"), "peggle.peg_colors") ||
        error("unexpected peg_colors fixture format: $(doc["format"])")
    entries = haskey(doc, "levels") ? doc["levels"] : Any[doc]
    config = PeggleSim.load_config(joinpath(repo, "interchange", "config.v1.json"))
    per_turn = config.purple_pegs_per_turn

    recomputed = Any[]
    for entry in entries
        level_name = as_string(entry["level"], "level")
        level = PeggleSim.load_level(joinpath(state_dir, "levels", level_name * ".v1.json"))
        pegs = level.pegs
        seed = level.level_seed
        section["checked"] = section["checked"] + 1

        rng = LoveRandom(seed)
        cs = PeggleSim.init_colors!(pegs, level.type_counts, seed, rng)
        got_types = [string(p.peg_type) for p in pegs]
        got_queue = [Int(x) for x in cs.queue]
        got_state = get_state(rng)
        rec = Dict{String,Any}(
            "level" => level_name, "level_seed" => seed,
            "peg_types" => got_types, "queue_after_init" => got_queue,
            "rng_state_after_init" => got_state)
        if haskey(entry, "rng_state_after_init")
            want = as_string(entry["rng_state_after_init"], "rng_state_after_init")
            got_state == want || _note!(section,
                ("peg_colors[$(level_name)].rng_state_after_init", want, got_state))
        end
        if haskey(entry, "peg_types")
            want = [as_string(t, "peg_types") for t in entry["peg_types"]]
            got_types == want || _note!(section,
                ("peg_colors[$(level_name)].peg_types", want, got_types))
        end
        if haskey(entry, "queue_after_init")
            want = [as_int(x, "queue_after_init") for x in entry["queue_after_init"]]
            got_queue == want || _note!(section,
                ("peg_colors[$(level_name)].queue_after_init", want, got_queue))
        end

        PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)
        got_active1 = [Int(x) for x in cs.active]
        got_queue1 = [Int(x) for x in cs.queue]
        got_types1 = [string(p.peg_type) for p in pegs]
        got_state1 = get_state(rng)
        rec["active_after_first_promotion"] = got_active1
        rec["queue_after_first_promotion"] = got_queue1
        rec["peg_types_after_first_promotion"] = got_types1
        rec["rng_state_after_first_promotion"] = got_state1
        if haskey(entry, "active_after_first_promotion")
            want = [as_int(x, "active_after_first_promotion")
                    for x in entry["active_after_first_promotion"]]
            got_active1 == want || _note!(section,
                ("peg_colors[$(level_name)].active_after_first_promotion", want, got_active1))
        end
        if haskey(entry, "queue_after_first_promotion")
            want = [as_int(x, "queue_after_first_promotion")
                    for x in entry["queue_after_first_promotion"]]
            got_queue1 == want || _note!(section,
                ("peg_colors[$(level_name)].queue_after_first_promotion", want, got_queue1))
        end
        if haskey(entry, "peg_types_after_first_promotion")
            want = [as_string(t, "peg_types_after_first_promotion")
                    for t in entry["peg_types_after_first_promotion"]]
            got_types1 == want || _note!(section,
                ("peg_colors[$(level_name)].peg_types_after_first_promotion", want, got_types1))
        end
        if haskey(entry, "rng_state_after_first_promotion")
            want = as_string(entry["rng_state_after_first_promotion"],
                             "rng_state_after_first_promotion")
            got_state1 == want || _note!(section,
                ("peg_colors[$(level_name)].rng_state_after_first_promotion", want, got_state1))
        end

        # The captured rounds start from a fresh post-init state, so replay
        # them on a second fresh init instead of continuing after the first
        # promotion.
        rng = LoveRandom(seed)
        cs = PeggleSim.init_colors!(pegs, level.type_counts, seed, rng)
        by_id = Dict(p.id => p for p in pegs)
        rounds = get(entry, "rounds", get(entry, "promotion_rounds", Any[]))
        rec_rounds = Any[]
        for (ri, round) in enumerate(rounds)
            mark_hit = [as_int(x, "mark_hit") for x in get(round, "mark_hit", Any[])]
            for id in mark_hit
                by_id[id].hit = true
            end
            PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)
            got_active = [Int(x) for x in cs.active]
            got_queue = [Int(x) for x in cs.queue]
            got_round_state = get_state(rng)
            rrec = Dict{String,Any}(
                "mark_hit" => mark_hit, "active" => got_active,
                "queue" => got_queue, "rng_state" => got_round_state)
            if haskey(round, "active")
                want = [as_int(x, "active") for x in round["active"]]
                got_active == want || _note!(section,
                    ("peg_colors[$(level_name)].rounds[$ri].active", want, got_active))
            end
            if haskey(round, "queue")
                want = [as_int(x, "queue") for x in round["queue"]]
                got_queue == want || _note!(section,
                    ("peg_colors[$(level_name)].rounds[$ri].queue", want, got_queue))
            end
            if haskey(round, "rng_state")
                want = as_string(round["rng_state"], "rng_state")
                got_round_state == want || _note!(section,
                    ("peg_colors[$(level_name)].rounds[$ri].rng_state", want, got_round_state))
            end
            push!(rec_rounds, rrec)
        end
        rec["rounds"] = rec_rounds
        push!(recomputed, rec)
    end

    section["verified"] = section["mismatches"] == 0
    section["computed_sha256"] =
        sha256_hex(canonical_json(Dict{String,Any}("levels" => recomputed)))
    return section
end

# ---------------------------------------------------------------------------
# Checkpoints
# ---------------------------------------------------------------------------

function check_checkpoints(repo::String, state_dir::String)
    section = _new_section()
    dir = joinpath(state_dir, "checkpoints")
    files = sort(filter(f -> endswith(f, ".v1.json"), readdir(dir)))
    config = PeggleSim.load_config(joinpath(repo, "interchange", "config.v1.json"))
    recomputed = Any[]

    for file in files
        doc = load_json(joinpath(dir, file))
        lua_ckpt = PeggleSim.checkpoint_from_dict(doc)
        level_name = lua_ckpt.engine.level_name
        balls = startswith(file, "slide.multiball3") ? 3 : 1
        level_path = joinpath(state_dir, "levels", level_name * ".v1.json")
        level = PeggleSim.load_level(level_path)
        provenance = (
            reference_revision = lua_ckpt.provenance.reference_revision,
            reference_tree = lua_ckpt.provenance.reference_tree,
            config_sha256 = lua_ckpt.provenance.config_sha256,
            # The experimental artifact is the input being validated; the
            # historical artifact's hash would mask a geometry difference.
            level_sha256 = PeggleSim.level_sha256(level_path),
        )
        sim = PeggleSim.build_sim_state(level, config; balls = balls, mode = :solo)
        julia_ckpt = PeggleSim.capture_checkpoint(sim; provenance = provenance)
        section["checked"] = section["checked"] + 1

        diff = PeggleSim.first_difference(lua_ckpt, julia_ckpt)
        if diff !== nothing
            section["mismatches"] = section["mismatches"] + 1
            if section["first_mismatch"] === nothing
                value_diff = _first_json_difference(
                    PeggleSim.checkpoint_to_dict(lua_ckpt),
                    PeggleSim.checkpoint_to_dict(julia_ckpt), "")
                section["first_mismatch"] = Dict{String,Any}(
                    "checkpoint" => file, "path" => diff,
                    "expected" => value_diff === nothing ? nothing : value_diff[2],
                    "actual" => value_diff === nothing ? nothing : value_diff[3])
            end
        end
        push!(recomputed, Dict{String,Any}(
            "checkpoint" => file,
            "checkpoint_canonical" => PeggleSim.checkpoint_to_dict(julia_ckpt)))
    end

    section["verified"] = section["mismatches"] == 0
    section["computed_sha256"] =
        sha256_hex(canonical_json(Dict{String,Any}("checkpoints" => recomputed)))
    return section
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function main(argv)
    opts = parse_args(argv)
    repo = normpath(get(opts, "repo", pwd()))
    state_dir = abspath(get(opts, "state-dir",
        joinpath(repo, "tmp", "core-math", "state-system_libm")))
    backend = get(opts, "backend", "system_libm")
    out = get(opts, "out",
        joinpath(repo, "tmp", "core-math", "state-compare-$(backend).json"))

    sections = [
        ("levels", check_levels(repo, state_dir)),
        ("rng", check_rng(repo, state_dir)),
        ("colors", check_colors(repo, state_dir)),
        ("checkpoints", check_checkpoints(repo, state_dir)),
    ]

    doc = Dict{String,Any}(
        "format" => "peggle.wpd_state_comparison",
        "schema_version" => 1,
        "backend" => backend,
        "state_dir" => relpath(state_dir, repo),
        "levels" => sections[1][2],
        "rng" => sections[2][2],
        "colors" => sections[3][2],
        "checkpoints" => sections[4][2],
    )

    dir = dirname(out)
    isempty(dir) || mkpath(dir)
    open(out, "w") do io
        write(io, canonical_json(doc))
        write(io, "\n")
    end

    all_ok = true
    for (name, section) in sections
        ok = section["verified"] === true
        all_ok &= ok
        println(rpad(name, 12), " checked=", section["checked"],
                " mismatches=", section["mismatches"],
                " sha256=", section["computed_sha256"], " ",
                ok ? "PASS" : "FAIL")
    end
    println("wpd_state_compare: backend=", backend, " -> ", out)

    if !all_ok
        for (name, section) in sections
            section["first_mismatch"] === nothing && continue
            println(stderr, "first mismatch (", name, "): ",
                    canonical_json(section["first_mismatch"]))
        end
        exit(1)
    end
    return nothing
end

main(ARGS)
