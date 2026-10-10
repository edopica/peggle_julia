# Cross-machine parity manifest (WP-F; repaired for WP-D).
#
# Two machines with the same pinned reference, config, artifacts, and level
# files must produce byte-identical `authoritative` sections. The
# `environment` section is explicitly non-authoritative and may differ
# (host label, kernel, CPU, libm identity).
#
# The authoritative section is recomputed from the repository itself:
#   * math census -- every recorded case is recomputed with DetMath and must
#     match the captured `0x%016x` float bits exactly;
#   * raw RNG draws and final generator states -- recomputed with LoveRandom
#     and compared to the captured fixture, plus a computed-value SHA-256;
#   * peg colors and every purple-queue rebuild round -- recomputed from the
#     level artifact and compared to the captured fixture, plus a
#     computed-value SHA-256;
#   * level artifact hashes -- raw file SHA-256;
#   * geometry -- checkpoint SHA-256 of build_checkpoint(level, config);
#   * reset -- capture (original) -> deterministic mutation -> reset ->
#     capture, twice; the restored hashes must equal the original checkpoint
#     hash and each other.
#
# The `identity` section carries the pinned provenance and the comparison
# prerequisites: config, census/RNG fixtures, level hashes, Julia source hash,
# package version, and the platform-independent native math component identity
# when selected (never the per-platform artifact bytes). Each platform's
# artifact hash is recorded as environment provenance and validated against
# `native/artifacts/<platform>/` before the manifest is emitted.
#
# The manifest contains no timestamps; `write_parity` emits canonical JSON.

const PARITY_FORMAT = "peggle.parity"
# Versions the bit-exact numeric contract that both manifests must implement;
# the authoritative comparison is only meaningful when both sides agree on it.
const PARITY_NUMERIC_CONTRACT_VERSION = 1
const PARITY_SCHEMA_VERSION = 2
# schemas/checkpoint.v1.schema.json, the boundary this manifest exercises.
const PARITY_CHECKPOINT_SCHEMA_VERSION = 1
const PARITY_MULTIBALL_LEVEL = "slide"
const PARITY_MULTIBALL_BALLS = 3
const PARITY_ADVANCE_STEPS = 7
const PARITY_ADVANCE_RNG_DRAWS = 5
const PARITY_ADVANCE_PURPLE_PROMOTIONS = 1

const PARITY_CENSUS_UNARY = (
    (name = "sin", det = DetMath.det_sin),
    (name = "cos", det = DetMath.det_cos),
    (name = "atan", det = DetMath.det_atan),
    (name = "asin", det = DetMath.det_asin),
    (name = "exp", det = DetMath.det_exp),
    (name = "log", det = DetMath.det_log),
    (name = "sqrt", det = DetMath.det_sqrt),
)

const PARITY_CENSUS_BINARY = (
    (name = "atan2", a = "atan2_y", b = "atan2_x",
        det = (y, x) -> DetMath.det_atan2(y, x)),
    (name = "pow", a = "pow_a", b = "pow_b",
        det = (a, b) -> DetMath.det_pow(a, b)),
    (name = "mod", a = "mod_a", b = "mod_b",
        det = (a, b) -> DetMath.lua_mod(a, b)),
)

# ---------------------------------------------------------------------------
# Repository layout and pinned provenance
# ---------------------------------------------------------------------------

function _parity_paths(repo::AbstractString)
    root = abspath(repo)
    return (
        root = root,
        pin = joinpath(root, "reference", "PIN.md"),
        config = joinpath(root, "interchange", "config.v1.json"),
        levels = joinpath(root, "interchange", "levels"),
        census = joinpath(root, "fixtures", "math_census", "math_census.v1.json"),
        rng_sequences = joinpath(root, "fixtures", "rng", "rng_sequences.v1.json"),
        peg_colors = joinpath(root, "fixtures", "rng", "peg_colors.v1.json"),
        project = joinpath(root, "julia", "PeggleSim", "Project.toml"),
    )
end

function _matched(text::AbstractString, pattern::Regex, what::AbstractString)
    m = match(pattern, text)
    m === nothing && throw(ArgumentError("parity: cannot parse $(what)"))
    return m[1]
end

function _parse_pin(path::AbstractString)
    text = read(path, String)
    return (
        revision = _matched(text, r"Revision \(full\) \| `([0-9a-f]{40})`",
                            "reference revision from $(path)"),
        tree = _matched(text, r"Tree hash \| `([0-9a-f]{40})`",
                        "reference tree from $(path)"),
        config_hash = _matched(text, r"Config hash \(`src/config.lua`\) \| `([0-9a-f]{64})`",
                               "config hash from $(path)"),
    )
end

function _project_version(path::AbstractString)
    text = read(path, String)
    return _matched(text, r"(?m)^version\s*=\s*\"([^\"]+)\"",
                    "package version from $(path)")
end

function _file_sha256(path::AbstractString)::String
    return sha256_hex(read(path))
end

function _config_source_sha256(path::AbstractString)
    doc = as_object(load_json(path), "config document")
    return as_string(doc["source_sha256"], "config.source_sha256")
end

# ---------------------------------------------------------------------------
# Prerequisite identities
# ---------------------------------------------------------------------------

# SHA-256 over the authoritative Julia package source: every `src/*.jl` plus
# Project.toml and Manifest.toml, in sorted relative-path order, hashed as
# "<relpath>\0<file sha256>\n" (the same construction the census uses for its
# corpus provenance). Tests and bin scripts are intentionally excluded.
function _julia_source_sha256(repo::AbstractString)::String
    package = joinpath(abspath(repo), "julia", "PeggleSim")
    src_dir = joinpath(package, "src")
    entries = Tuple{String,String}[]
    for file in sort(readdir(src_dir))
        endswith(file, ".jl") || continue
        rel = "julia/PeggleSim/src/" * file
        push!(entries, (rel, _file_sha256(joinpath(src_dir, file))))
    end
    for file in ("Project.toml", "Manifest.toml")
        path = joinpath(package, file)
        isfile(path) || continue
        push!(entries, ("julia/PeggleSim/" * file, _file_sha256(path)))
    end
    sort!(entries; by = first)
    io = IOBuffer()
    for (rel, hash) in entries
        write(io, rel, '\0', hash, '\n')
    end
    return sha256_hex(String(take!(io)))
end

# SHA-256 over the level artifact corpus: "<name>\0<file sha256>\n" sorted by
# name. This is the prerequisite that ties two manifests to the same boards.
function _levels_manifest_sha256(dir::AbstractString)::String
    entries = Tuple{String,String}[]
    for file in sort(readdir(dir))
        endswith(file, ".v1.json") || continue
        name = replace(file, ".v1.json" => "")
        push!(entries, (name, _file_sha256(joinpath(dir, file))))
    end
    io = IOBuffer()
    for (name, hash) in entries
        write(io, name, '\0', hash, '\n')
    end
    return sha256_hex(String(take!(io)))
end

# SHA-256 over the platform-independent native component sources:
# the peggle_math wrapper/sources and, via `native/core-math/files.sha256`,
# the pin of the whole vendored CORE-MATH tree. This is the component identity
# that must match between machines; the per-platform artifact bytes are
# recorded separately as environment provenance.
const PARITY_NATIVE_COMPONENT_SOURCES = (
    "native/peggle_math.c",
    "native/peggle_math.h",
    "native/peggle_math.map",
    "native/sqrt_shim.c",
    "native/core-math/files.sha256",
)

function _native_component_source_sha256(repo::AbstractString)::String
    root = abspath(repo)
    entries = Tuple{String,String}[]
    for rel in PARITY_NATIVE_COMPONENT_SOURCES
        path = joinpath(root, rel)
        isfile(path) ||
            throw(ArgumentError("parity: native component source missing: $(rel)"))
        push!(entries, (rel, _file_sha256(path)))
    end
    sort!(entries; by = first)
    io = IOBuffer()
    for (rel, hash) in entries
        write(io, rel, '\0', hash, '\n')
    end
    return sha256_hex(String(take!(io)))
end

# Expected artifact checksum recorded by the native build for this platform,
# or `nothing` when no build has been recorded under `native/artifacts/`.
function _expected_native_artifact_sha256(repo::AbstractString, platform::AbstractString)
    path = joinpath(abspath(repo), "native", "artifacts", String(platform),
                    "libpeggle_math.so.sha256")
    isfile(path) || return nothing
    for line in eachline(path)
        text = strip(line)
        isempty(text) && continue
        return String(first(split(text)))
    end
    return nothing
end

# Native math-component identity that must match before an authoritative
# comparison between two machines: the backend name always; for `core_math`
# the platform-independent component identity (pinned CORE-MATH revision/tag,
# ABI, numeric contract version, and component source hash). The artifact
# bytes are per-platform provenance and are deliberately excluded.
function _math_backend_prereq(repo::AbstractString)::Dict{String,Any}
    id = DetMath.math_backend_identity()
    d = Dict{String,Any}("backend" => String(id.backend))
    id.backend === :core_math || return d
    d["core_math_revision"] = String(id.core_math_revision)
    tag = id.core_math_tag === nothing ? "" : String(id.core_math_tag)
    isempty(tag) || (d["core_math_tag"] = tag)
    d["abi_version"] = Int(id.abi_version)
    d["numeric_contract_version"] = PARITY_NUMERIC_CONTRACT_VERSION
    d["component_source_sha256"] = _native_component_source_sha256(repo)
    return d
end

# ---------------------------------------------------------------------------
# RNG fixture verification (computed draws and generator states)
# ---------------------------------------------------------------------------

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
        error("parity: unknown RNG fixture op kind: $(kind)")
    end
    return out
end

_rng_value_json(v) = v isa Float64 ? float_bits_hex(v) : v

function _rng_fixture_verification(path::AbstractString)
    fixture = as_object(load_json(path), "RNG fixture")
    mismatches = 0
    first_mismatch = ""
    checked = 0
    note!(msg) = (mismatches += 1;
                  isempty(first_mismatch) && (first_mismatch = String(msg)))

    sequences = Any[]
    records = Dict{String,String}()
    for seq in as_array(get(fixture, "sequences", Any[]), "sequences")
        seed = as_int(seq["seed"], "seed")
        r = LoveRandom(seed)
        got = Any[]
        for op in as_array(seq["ops"], "ops")
            append!(got, _apply_rng_op!(r, op))
        end
        want = as_array(seq["results"], "results")
        length(got) == length(want) ||
            note!("sequences seed=$(seed): length $(length(got)) != $(length(want))")
        for i in 1:min(length(got), length(want))
            checked += 1
            w = want[i]
            g = got[i]
            ok = w isa Integer ? (g isa Integer && Int(g) == Int(w)) :
                 w isa AbstractString ? (g isa Float64 && float_bits_hex(g) == String(w)) :
                 g == w
            ok || note!("sequences seed=$(seed)[$(i)]: got $(g) want $(w)")
        end
        record = Dict{String,Any}(
            "seed" => seed,
            "results" => Any[_rng_value_json(g) for g in got],
            "state" => get_state(r),
        )
        push!(sequences, record)
        records["sequences[seed=$(seed)]"] = sha256_hex(canonical_json(record))
    end

    states = Any[]
    for st in as_array(get(fixture, "states", Any[]), "states")
        seed = as_int(st["seed"], "seed")
        r = LoveRandom(seed)
        for op in as_array(st["draws"], "draws")
            _apply_rng_op!(r, op)
        end
        checked += 1
        want_state = as_string(st["state"], "states.state")
        get_state(r) == want_state ||
            note!("states seed=$(seed): state $(get_state(r)) != $(want_state)")
        record = Dict{String,Any}("seed" => seed, "state" => get_state(r))
        nxt = get(st, "next", nothing)
        if nxt !== nothing
            vals = _apply_rng_op!(r, as_object(nxt, "states.next"))
            if haskey(nxt, "bits_hex")
                want_bits = [String(s) for s in as_array(nxt["bits_hex"], "bits_hex")]
                got_bits = [float_bits_hex(v) for v in vals]
                checked += length(want_bits)
                got_bits == want_bits ||
                    note!("states seed=$(seed).next: bits $(got_bits) != $(want_bits)")
            end
            if haskey(nxt, "results")
                want = as_array(nxt["results"], "states.next.results")
                length(vals) == length(want) ||
                    note!("states seed=$(seed).next: length mismatch")
                for i in 1:min(length(vals), length(want))
                    w = want[i]
                    g = vals[i]
                    ok = w isa Integer ? (g isa Integer && Int(g) == Int(w)) :
                         w isa AbstractString ? (g isa Float64 && float_bits_hex(g) == String(w)) :
                         g == w
                    checked += 1
                    ok || note!("states seed=$(seed).next[$(i)]: got $(g) want $(w)")
                end
            end
            record["next"] = Any[_rng_value_json(v) for v in vals]
            record["state_after"] = get_state(r)
        end
        push!(states, record)
        records["states[seed=$(seed)]"] = sha256_hex(canonical_json(record))
    end

    set_state_records = Any[]
    for item in as_array(get(fixture, "set_state", Any[]), "set_state")
        r = LoveRandom(0)
        initial = as_string(item["state"], "set_state.state")
        set_state!(r, initial)
        checked += 1
        get_state(r) == initial ||
            note!("set_state $(initial): state $(get_state(r)) != $(initial)")
        vals = _apply_rng_op!(r, as_object(item["then"], "set_state.then"))
        want = as_array(item["results"], "set_state.results")
        length(vals) == length(want) ||
            note!("set_state $(initial): length $(length(vals)) != $(length(want))")
        for i in 1:min(length(vals), length(want))
            w = want[i]
            g = vals[i]
            ok = w isa Integer ? (g isa Integer && Int(g) == Int(w)) :
                 w isa AbstractString ? (g isa Float64 && float_bits_hex(g) == String(w)) :
                 g == w
            checked += 1
            ok || note!("set_state $(initial)[$(i)]: got $(g) want $(w)")
        end
        record = Dict{String,Any}(
            "state" => initial,
            "results" => Any[_rng_value_json(v) for v in vals],
            "state_after" => get_state(r),
        )
        if haskey(item, "state_after")
            want_after = as_string(item["state_after"], "set_state.state_after")
            get_state(r) == want_after ||
                note!("set_state $(initial): state_after $(get_state(r)) != $(want_after)")
            record["state_after_expected"] = want_after
        end
        push!(set_state_records, record)
        records["set_state[$(initial)]"] = sha256_hex(canonical_json(record))
    end

    anchors = Any[]
    for anchor in as_array(get(fixture, "seed_anchors", Any[]), "seed_anchors")
        seed = as_int(anchor["seed"], "seed")
        r = LoveRandom(seed)
        record = Dict{String,Any}("seed" => seed)
        if haskey(anchor, "draws")
            want = [as_int(x, "anchors.draws") for x in anchor["draws"]]
            got = [random(r, 1, 10) for _ in 1:length(want)]
            checked += length(want)
            got == want || note!("anchors seed=$(seed).draws: $(got) != $(want)")
            record["draws"] = got
        end
        if haskey(anchor, "first_random_1_100")
            want = as_int(anchor["first_random_1_100"], "anchor")
            got = random(r, 1, 100)
            checked += 1
            got == want || note!("anchors seed=$(seed): $(got) != $(want)")
            record["first_random_1_100"] = got
        end
        if haskey(anchor, "first_random_1_10")
            r2 = LoveRandom(seed)
            want = as_int(anchor["first_random_1_10"], "anchor")
            got = random(r2, 1, 10)
            checked += 1
            got == want || note!("anchors seed=$(seed).first_1_10: $(got) != $(want)")
            record["first_random_1_10"] = got
        end
        record["state"] = get_state(r)
        if haskey(anchor, "state")
            want_state = as_string(anchor["state"], "anchor.state")
            get_state(r) == want_state ||
                note!("anchors seed=$(seed): state $(get_state(r)) != $(want_state)")
        end
        push!(anchors, record)
        records["seed_anchors[seed=$(seed)]"] = sha256_hex(canonical_json(record))
    end

    computed = Dict{String,Any}(
        "sequences" => sequences,
        "states" => states,
        "set_state" => set_state_records,
        "seed_anchors" => anchors,
    )
    return (
        fixture_sha256 = _file_sha256(path),
        verified = mismatches == 0,
        checked = checked,
        mismatches = mismatches,
        first_mismatch = first_mismatch,
        computed_sha256 = sha256_hex(canonical_json(computed)),
        record_sha256 = records,
    )
end

# ---------------------------------------------------------------------------
# Peg-color and purple-queue verification
# ---------------------------------------------------------------------------

function _compare_int_array!(got::Vector{Int}, want, what::AbstractString, note!)
    length(got) == length(want) ||
        note!("$(what): length $(length(got)) != $(length(want))")
    for i in 1:min(length(got), length(want))
        expected = as_int(want[i], what)
        got[i] == expected || note!("$(what)[$(i)]: $(got[i]) != $(expected)")
    end
    return nothing
end

function _compare_string_array!(got::Vector{String}, want, what::AbstractString, note!)
    length(got) == length(want) ||
        note!("$(what): length $(length(got)) != $(length(want))")
    for i in 1:min(length(got), length(want))
        expected = as_string(want[i], what)
        got[i] == expected || note!("$(what)[$(i)]: $(got[i]) != $(expected)")
    end
    return nothing
end

function _peg_colors_verification(path::AbstractString,
                                  level_defs::Dict{String,LevelDefinition},
                                  per_turn::Int)
    fixture = as_object(load_json(path), "peg colors fixture")
    mismatches = 0
    first_mismatch = ""
    checked = 0
    note!(msg) = (mismatches += 1;
                  isempty(first_mismatch) && (first_mismatch = String(msg)))

    computed_levels = Any[]
    records = Dict{String,String}()
    for entry in as_array(get(fixture, "levels", Any[]), "levels")
        name = as_string(entry["level"], "level")
        level = get(level_defs, name, nothing)
        if level === nothing
            note!("level $(name): no loaded level artifact")
            continue
        end
        pegs = deepcopy(level.pegs)
        rng = LoveRandom(level.level_seed)
        colors = init_colors!(pegs, level.type_counts, level.level_seed, rng)
        checked += 1
        if haskey(entry, "rng_state_after_init")
            want = as_string(entry["rng_state_after_init"], "rng_state_after_init")
            get_state(rng) == want ||
                note!("$(name).rng_state_after_init: $(get_state(rng)) != $(want)")
        end
        if haskey(entry, "peg_types")
            _compare_string_array!(
                [string(p.peg_type) for p in pegs], entry["peg_types"],
                "$(name).peg_types", note!)
        end
        if haskey(entry, "queue_after_init")
            _compare_int_array!(colors.queue, entry["queue_after_init"],
                                "$(name).queue_after_init", note!)
        end

        assign_next_purple_pegs!(pegs, colors, per_turn)
        checked += 1
        if haskey(entry, "active_after_first_promotion")
            _compare_int_array!(colors.active, entry["active_after_first_promotion"],
                                "$(name).active_after_first_promotion", note!)
        end
        if haskey(entry, "peg_types_after_first_promotion")
            _compare_string_array!(
                [string(p.peg_type) for p in pegs],
                entry["peg_types_after_first_promotion"],
                "$(name).peg_types_after_first_promotion", note!)
        end
        if haskey(entry, "queue_after_first_promotion")
            _compare_int_array!(colors.queue, entry["queue_after_first_promotion"],
                                "$(name).queue_after_first_promotion", note!)
        end
        if haskey(entry, "rng_state_after_first_promotion")
            want = as_string(entry["rng_state_after_first_promotion"], "state")
            get_state(rng) == want ||
                note!("$(name).rng_state_after_first_promotion: $(get_state(rng)) != $(want)")
        end

        rounds_record = Dict{String,Any}[]
        rounds = get(entry, "promotion_rounds", get(entry, "rounds", Any[]))
        if !isempty(rounds)
            pegs2 = deepcopy(level.pegs)
            rng2 = LoveRandom(level.level_seed)
            colors2 = init_colors!(pegs2, level.type_counts, level.level_seed, rng2)
            by_id = Dict(p.id => p for p in pegs2)
            for (ri, round) in enumerate(as_array(rounds, "rounds"))
                for id in as_array(get(round, "mark_hit", Any[]), "mark_hit")
                    by_id[as_int(id, "mark_hit")].hit = true
                end
                checked += 1
                assign_next_purple_pegs!(pegs2, colors2, per_turn)
                if haskey(round, "active")
                    _compare_int_array!(colors2.active, round["active"],
                                        "$(name).rounds[$(ri)].active", note!)
                end
                if haskey(round, "queue")
                    _compare_int_array!(colors2.queue, round["queue"],
                                        "$(name).rounds[$(ri)].queue", note!)
                end
                if haskey(round, "rng_state")
                    want = as_string(round["rng_state"], "rounds.rng_state")
                    get_state(rng2) == want ||
                        note!("$(name).rounds[$(ri)].rng_state: $(get_state(rng2)) != $(want)")
                end
                push!(rounds_record, Dict{String,Any}(
                    "active" => copy(colors2.active),
                    "queue" => copy(colors2.queue),
                    "rng_state" => get_state(rng2),
                ))
            end
        end

        record = Dict{String,Any}(
            "level" => name,
            "peg_types" => [string(p.peg_type) for p in pegs],
            "queue_after_init" => copy(colors.queue),
            "active_after_first_promotion" => copy(colors.active),
            "rng_state_after_first_promotion" => get_state(rng),
            "rounds" => rounds_record,
        )
        push!(computed_levels, record)
        records["level=$(name)"] = sha256_hex(canonical_json(record))
    end

    computed = Dict{String,Any}("levels" => computed_levels)
    return (
        fixture_sha256 = _file_sha256(path),
        verified = mismatches == 0,
        checked = checked,
        mismatches = mismatches,
        first_mismatch = first_mismatch,
        computed_sha256 = sha256_hex(canonical_json(computed)),
        record_sha256 = records,
    )
end

# Provenance namedtuple accepted by build_checkpoint / capture_checkpoint.
function parity_provenance(repo::AbstractString, level_name::AbstractString)
    paths = _parity_paths(repo)
    pin = _parse_pin(paths.pin)
    config_sha = _config_source_sha256(paths.config)
    return (
        reference_revision = pin.revision,
        reference_tree = pin.tree,
        config_sha256 = config_sha,
        level_sha256 = level_sha256(joinpath(paths.levels, level_name * ".v1.json")),
    )
end

# Static levels in artifact order plus the slide multiball3 configuration.
function parity_configurations(repo::AbstractString)
    dir = joinpath(abspath(repo), "interchange", "levels")
    configs = NamedTuple{(:label, :level, :balls),Tuple{String,String,Int}}[]
    for file in sort(readdir(dir))
        endswith(file, ".v1.json") || continue
        name = replace(file, ".v1.json" => "")
        push!(configs, (label = name, level = name, balls = 1))
    end
    if any(c -> c.level == PARITY_MULTIBALL_LEVEL && c.balls == 1, configs)
        push!(configs, (
            label = PARITY_MULTIBALL_LEVEL * ".multiball" * string(PARITY_MULTIBALL_BALLS),
            level = PARITY_MULTIBALL_LEVEL,
            balls = PARITY_MULTIBALL_BALLS,
        ))
    end
    return configs
end

# ---------------------------------------------------------------------------
# Math census verification
# ---------------------------------------------------------------------------

# Recomputes every census case with DetMath and requires exact `0x%016x`
# string equality. This is a deliberate copy of the math_census.jl check loop
# so the manifest does not depend on an executable script.
function _census_verification(path::AbstractString)
    fixture = JSON.parsefile(path; inttype = Float64)
    inputs = as_object(fixture["inputs"], "census.inputs")
    expected = as_object(fixture["expected"], "census.expected")
    counts = as_object(fixture["counts"], "census.counts")

    checked = 0
    mismatches = 0
    first_mismatch = ""
    for spec in PARITY_CENSUS_UNARY
        xs = as_array(inputs[spec.name], "inputs.$(spec.name)")
        want = as_array(expected[spec.name], "expected.$(spec.name)")
        length(xs) == length(want) ||
            error("parity: census '$(spec.name)' has mismatched input/expected lengths")
        for i in eachindex(xs)
            got = float_bits_hex(spec.det(Float64(xs[i])))
            checked += 1
            if got != String(want[i])
                mismatches += 1
                isempty(first_mismatch) && (first_mismatch =
                    "$(spec.name)[$(i)]: got $(got), want $(want[i])")
            end
        end
    end
    for spec in PARITY_CENSUS_BINARY
        as_ = as_array(inputs[spec.a], "inputs.$(spec.a)")
        bs_ = as_array(inputs[spec.b], "inputs.$(spec.b)")
        want = as_array(expected[spec.name], "expected.$(spec.name)")
        length(as_) == length(bs_) == length(want) ||
            error("parity: census '$(spec.name)' has mismatched operand lengths")
        for i in eachindex(as_)
            got = float_bits_hex(spec.det(Float64(as_[i]), Float64(bs_[i])))
            checked += 1
            if got != String(want[i])
                mismatches += 1
                isempty(first_mismatch) && (first_mismatch =
                    "$(spec.name)[$(i)]: got $(got), want $(want[i])")
            end
        end
    end

    expected_total = 0
    for (name, value) in counts
        expected_total += as_int(value, "counts.$(name)")
    end

    return (
        fixture_sha256 = _file_sha256(path),
        verified = mismatches == 0 && checked == expected_total,
        total_cases = checked,
        mismatches = mismatches,
        first_mismatch = first_mismatch,
    )
end

# ---------------------------------------------------------------------------
# Authoritative section
# ---------------------------------------------------------------------------

function _authoritative(paths, pin, config_sha, config)
    levels = Dict{String,Any}()
    level_defs = Dict{String,LevelDefinition}()
    for file in sort(readdir(paths.levels))
        endswith(file, ".v1.json") || continue
        name = replace(file, ".v1.json" => "")
        path = joinpath(paths.levels, file)
        levels[name] = level_sha256(path)
        level_defs[name] = load_level(path)
    end

    configs = parity_configurations(paths.root)
    provenances = Dict{String,Any}()
    checkpoints = Dict{String,Checkpoint}()
    geometry = Dict{String,Any}()
    for cfg in configs
        prov = (
            reference_revision = pin.revision,
            reference_tree = pin.tree,
            config_sha256 = config_sha,
            level_sha256 = levels[cfg.level],
        )
        provenances[cfg.label] = prov
        ckpt = build_checkpoint(level_defs[cfg.level], config;
                                balls = cfg.balls, mode = :solo, provenance = prov)
        checkpoints[cfg.label] = ckpt
        geometry[cfg.label] = checkpoint_sha256(ckpt)
    end

    reset = Dict{String,Any}()
    reset_deterministic = true
    for cfg in configs
        ckpt = checkpoints[cfg.label]
        original_hash = checkpoint_sha256(ckpt)
        restored_hashes = String[]
        mutated_hash = ""
        for run in 1:2
            worker = make_worker(ckpt)
            test_advance!(worker;
                steps = PARITY_ADVANCE_STEPS,
                rng_draws = PARITY_ADVANCE_RNG_DRAWS,
                purple_promotions = PARITY_ADVANCE_PURPLE_PROMOTIONS)
            if run == 1
                mutated = capture_checkpoint(worker.sim; provenance = provenances[cfg.label])
                mutated_hash = checkpoint_sha256(mutated)
            end
            reset_worker!(worker, ckpt)
            restored = capture_checkpoint(worker.sim; provenance = provenances[cfg.label])
            push!(restored_hashes, checkpoint_sha256(restored))
        end
        restored_matches_original =
            all(==(original_hash), restored_hashes) &&
            restored_hashes[1] == restored_hashes[2]
        restored_matches_original || (reset_deterministic = false)
        reset[cfg.label] = Dict{String,Any}(
            "checkpoint_sha256" => original_hash,
            "mutated_sha256" => mutated_hash,
            "restored_sha256" => restored_hashes,
            "restored_matches_original" => restored_matches_original,
        )
    end

    census = _census_verification(paths.census)
    census_dict = Dict{String,Any}(
        "fixture_sha256" => census.fixture_sha256,
        "verified" => census.verified,
        "total_cases" => census.total_cases,
        "mismatches" => census.mismatches,
    )
    isempty(census.first_mismatch) ||
        (census_dict["first_mismatch"] = census.first_mismatch)

    rng = _rng_fixture_verification(paths.rng_sequences)
    rng_dict = Dict{String,Any}(
        "fixture_sha256" => rng.fixture_sha256,
        "verified" => rng.verified,
        "checked" => rng.checked,
        "mismatches" => rng.mismatches,
        "computed_sha256" => rng.computed_sha256,
        "computed_record_sha256" => rng.record_sha256,
    )
    isempty(rng.first_mismatch) || (rng_dict["first_mismatch"] = rng.first_mismatch)

    per_turn = as_int(config.purple_pegs_per_turn, "config.purple_pegs_per_turn")
    colors = _peg_colors_verification(paths.peg_colors, level_defs, per_turn)
    colors_dict = Dict{String,Any}(
        "fixture_sha256" => colors.fixture_sha256,
        "verified" => colors.verified,
        "checked" => colors.checked,
        "mismatches" => colors.mismatches,
        "computed_sha256" => colors.computed_sha256,
        "computed_record_sha256" => colors.record_sha256,
    )
    isempty(colors.first_mismatch) ||
        (colors_dict["first_mismatch"] = colors.first_mismatch)

    return Dict{String,Any}(
        "math_census" => census_dict,
        "rng_sequences" => rng_dict,
        "peg_colors" => colors_dict,
        "levels" => levels,
        "geometry" => geometry,
        "reset" => reset,
        "reset_deterministic" => reset_deterministic,
    )
end

# ---------------------------------------------------------------------------
# Identity and environment
# ---------------------------------------------------------------------------

function _identity(paths, pin, config_sha)
    return Dict{String,Any}(
        "format" => PARITY_FORMAT,
        "schema_version" => PARITY_SCHEMA_VERSION,
        "reference_revision" => pin.revision,
        "reference_tree" => pin.tree,
        "config_sha256" => config_sha,
        "package_version" => _project_version(paths.project),
        "checkpoint_schema_version" => PARITY_CHECKPOINT_SCHEMA_VERSION,
        "julia_source_sha256" => _julia_source_sha256(paths.root),
        "prerequisites" => Dict{String,Any}(
            "config_artifact_sha256" => _file_sha256(paths.config),
            "census_fixture_sha256" => _file_sha256(paths.census),
            "rng_sequences_fixture_sha256" => _file_sha256(paths.rng_sequences),
            "peg_colors_fixture_sha256" => _file_sha256(paths.peg_colors),
            "levels_sha256" => _levels_manifest_sha256(paths.levels),
            "package_version" => _project_version(paths.project),
            "math_backend" => _math_backend_prereq(paths.root),
        ),
    )
end

function _cpu_model()
    path = "/proc/cpuinfo"
    isfile(path) || return nothing
    for line in eachline(path)
        startswith(line, "model name") || continue
        parts = split(line, ':'; limit = 2)
        length(parts) == 2 || continue
        return strip(parts[2])
    end
    return nothing
end

function _libm_identity(id)
    parts = String[String(id.backend), String(id.library)]
    id.glibc === nothing || push!(parts, "glibc-" * String(id.glibc))
    return join(parts, ":")
end

function _environment(label::AbstractString, expected_artifact_sha256 = nothing)
    id = DetMath.math_backend_identity()
    math_backend = DetMath.math_backend_identity_dict()
    if id.backend === :core_math
        math_backend["expected_artifact_sha256"] = String(expected_artifact_sha256)
        math_backend["artifact_validated"] = true
    end
    return Dict{String,Any}(
        "label" => String(label),
        "machine" => String(Sys.MACHINE),
        "kernel" => String(Sys.KERNEL),
        "julia" => string(VERSION),
        "math_backend" => math_backend,
        "libm" => _libm_identity(id),
        "cpu_model" => _cpu_model(),
        "logical_cores" => Sys.CPU_THREADS,
    )
end

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

function parity_manifest(; repo::AbstractString, label::AbstractString)::Dict{String,Any}
    paths = _parity_paths(repo)
    pin = _parse_pin(paths.pin)
    config_sha = _config_source_sha256(paths.config)
    config_sha == pin.config_hash || throw(ArgumentError(string(
        "parity: config artifact source_sha256 (", config_sha,
        ") does not match the pinned config hash (", pin.config_hash, ")")))
    config = load_config(paths.config)
    expected_artifact = nothing
    id = DetMath.math_backend_identity()
    if id.backend === :core_math
        platform = String(id.platform)
        artifact = id.artifact_sha256
        expected_artifact = _expected_native_artifact_sha256(paths.root, platform)
        expected_artifact === nothing && throw(ArgumentError(string(
            "parity: no expected checksum for the core_math artifact on platform ",
            platform, " at native/artifacts/", platform,
            "/libpeggle_math.so.sha256; build and record the artifact first")))
        artifact == expected_artifact || throw(ArgumentError(string(
            "parity: core_math artifact hash mismatch on platform ", platform,
            ": expected ", expected_artifact, ", got ",
            artifact === nothing ? "nothing" : artifact)))
    end
    return Dict{String,Any}(
        "identity" => _identity(paths, pin, config_sha),
        "authoritative" => _authoritative(paths, pin, config_sha, config),
        "environment" => _environment(label, expected_artifact),
    )
end

function parity_authoritative(man::AbstractDict)
    haskey(man, "authoritative") ||
        throw(ArgumentError("parity: manifest has no authoritative section"))
    return man["authoritative"]
end

function first_parity_difference(a, b)
    a_full = a isa AbstractDict && haskey(a, "authoritative")
    b_full = b isa AbstractDict && haskey(b, "authoritative")
    prefix = (a_full || b_full) ? "authoritative" : ""
    return first_difference(
        a_full ? a["authoritative"] : a,
        b_full ? b["authoritative"] : b;
        path = prefix,
    )
end

function write_parity(man, path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    open(path, "w") do io
        write(io, canonical_json(man))
        write(io, "\n")
    end
    return path
end
