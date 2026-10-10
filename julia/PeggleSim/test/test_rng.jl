using Test
using Printf
using PeggleSim

const RNG_FIXTURE_DIR =
    normpath(joinpath(@__DIR__, "..", "..", "..", "fixtures", "rng"))
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

# Apply one fixture operation to a generator and return the raw results.
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

function _check_rng_results(got::Vector{Any}, want, context::String)
    @test length(got) == length(want)
    for (i, (g, w)) in enumerate(zip(got, want))
        if w isa Integer
            @test g isa Integer && g == Int(w)
        elseif w isa AbstractString
            @test g isa Float64 && float_bits_hex(g) == String(w)
        else
            @test g == w
        end
    end
    return nothing
end

@testset "RNG" begin
    @testset "wang_hash64" begin
        # Values captured from the LÖVE 11.5 C++ implementation compiled
        # against glibc on this machine.
        @test wang_hash64(UInt64(0)) == 0x77cfa1eef01bca90
        @test wang_hash64(UInt64(1)) == 0x5bca7c69b794f8ce
        @test wang_hash64(UInt64(2)) == 0xb795033f6f2a0674
        @test wang_hash64(UInt64(345)) == 0xc117d21b822f9ce4
        @test wang_hash64(UInt64(0xFFFFFFFFFFFFFFFF)) == 0x1f89206e3f8ec794
        @test wang_hash64(UInt64(0x0139408DCBBF7A44)) == 0x0c2ea4bab1fa6908
    end

    @testset "seeding" begin
        r345 = LoveRandom(345)
        @test get_state(r345) == "0xc117d21b822f9ce4"
        @test get_seed(r345) == (UInt32(345), UInt32(0))
        @test r345.last_randomnormal == Inf

        r0 = LoveRandom(0)
        @test get_state(r0) == "0x77cfa1eef01bca90"

        # A raw seed of zero must still produce a nonzero state.
        @test LoveRandom(0).state != 0

        # Two-part seed constructor (low, high) is the same as the combined value.
        r2 = LoveRandom(UInt32(0xCBBF7A44), UInt32(0x0139408D))
        @test get_state(r2) == get_state(LoveRandom(0x0139408DCBBF7A44))
    end

    @testset "LÖVE 11.5 seed 345 anchors" begin
        r = LoveRandom(345)
        draws = Int[]
        for _ in 1:8
            push!(draws, random(r, 1, 10))
        end
        @test draws == [4, 7, 2, 9, 1, 2, 5, 10]
        @test get_state(r) == "0x7837ac8e69b05bb3"

        bits = [float_bits_hex(random01(r)) for _ in 1:4]
        @test bits == [
            "0x3fe652e07b5df6a0",
            "0x3fbbd6ac235b6f80",
            "0x3fc7a02f72398680",
            "0x3f9c35a895b7b400",
        ]
        # The decimal forms from the frozen brief must also match.
        r2 = LoveRandom(345)
        for _ in 1:8
            random(r2, 1, 10)
        end
        decimals = [@sprintf("%.17g", random01(r2)) for _ in 1:4]
        @test decimals == [
            "0.69761680693746442",
            "0.10874439109050904",
            "0.18457596852663372",
            "0.027548441064869422",
        ]
    end

    @testset "seed 0 anchor" begin
        r = LoveRandom(0)
        @test random(r, 1, 100) == 22
        @test get_state(r) == "0x5e15348974525b7a"
    end

    @testset "single-argument integer mapping" begin
        r = LoveRandom(345)
        @test random(r, 10) == 4
        @test random(r, 10) == 7
        r3 = LoveRandom(345)
        @test [random(r3, 10) for _ in 1:8] == [4, 7, 2, 9, 1, 2, 5, 10]
    end

    @testset "set_state! and get_state round trip" begin
        source = LoveRandom(345)
        for _ in 1:3
            random01(source)
        end
        saved = get_state(source)
        @test occursin(r"^0x[0-9a-f]{16}$", saved)

        restored = LoveRandom(0)
        set_state!(restored, saved)
        @test get_state(restored) == saved
        @test get_state(source) == get_state(restored)
        @test random01(source) == random01(restored)
        @test get_state(source) == get_state(restored)

        # set_state! resets the cached normal deviate.
        restored.last_randomnormal = 1.25
        set_state!(restored, saved)
        @test restored.last_randomnormal == Inf

        @test_throws ArgumentError set_state!(restored, "7837ac8e69b05bb3")
        @test_throws ArgumentError set_state!(restored, "0x")
        @test_throws ArgumentError set_state!(restored, "0xzz")
        @test_throws ArgumentError set_state!(restored, "0x" * "1"^17)
    end

    @testset "random_normal formula and cache" begin
        r = LoveRandom(345)
        @test r.last_randomnormal == Inf

        # First call must match the LÖVE Box-Muller formula exactly.
        check = LoveRandom(345)
        u1 = random01(check)
        u2 = random01(check)
        rad = DetMath.det_sqrt(-2.0 * DetMath.det_log(1.0 - u1))
        phi = (2.0 * Float64(pi)) * (1.0 - u2)
        expected = rad * DetMath.det_sin(phi)
        got = random_normal(r)
        @test reinterpret(UInt64, got) == reinterpret(UInt64, expected)
        @test r.last_randomnormal == rad * DetMath.det_cos(phi)

        # First call consumed exactly two uniforms.
        @test get_state(r) == get_state(check)

        # Second call returns the cached deviate scaled by stddev and consumes
        # no new uniforms.
        cached_value = r.last_randomnormal
        state_before = get_state(r)
        cached_scaled = random_normal(r, 2.0)
        @test cached_scaled == cached_value * 2.0
        @test get_state(r) == state_before
        @test r.last_randomnormal == Inf

        # Third call consumes two more uniforms and caches again.
        third = random_normal(r)
        @test r.last_randomnormal != Inf
        @test get_state(r) != state_before
        @test third isa Float64

        # snapshot / restore! round trip including the cached deviate.
        s_cached = snapshot(r)
        from_cache = random_normal(r)
        restore!(r, s_cached)
        @test random_normal(r) == from_cache

        # And a round trip with an empty cache.
        s_fresh = snapshot(r)
        fresh_next = random_normal(r)
        restore!(r, s_fresh)
        @test get_state(r) == get_state(s_fresh)
        @test random_normal(r) == fresh_next

        # Default argument is stddev = 1.0.
        a = LoveRandom(77)
        b = LoveRandom(77)
        @test random_normal(a) == random_normal(b, 1.0)
    end

    @testset "rng_sequences fixture" begin
        path = joinpath(RNG_FIXTURE_DIR, "rng_sequences.v1.json")
        if !isfile(path)
            println("test_rng: fixture not present yet, skipping: ", path)
            @test_skip "rng_sequences.v1.json not present"
        else
            doc = load_json(path)
            @test as_string(doc["format"]) == "peggle.rng_fixtures"
            @test as_int(doc["schema_version"]) == 1

            for seq in doc["sequences"]
                r = LoveRandom(as_int(seq["seed"], "seed"))
                got = Any[]
                for op in seq["ops"]
                    append!(got, _apply_rng_op!(r, op))
                end
                _check_rng_results(got, seq["results"], "sequences")
                if haskey(seq, "state")
                    @test get_state(r) == as_string(seq["state"])
                end
            end

            for st in get(doc, "states", [])
                r = LoveRandom(as_int(st["seed"], "seed"))
                for op in st["draws"]
                    _apply_rng_op!(r, op)
                end
                @test get_state(r) == as_string(st["state"])
                nxt = get(st, "next", nothing)
                if nxt !== nothing
                    vals = _apply_rng_op!(r, nxt)
                    if haskey(nxt, "bits_hex")
                        @test [float_bits_hex(v) for v in vals] ==
                              [String(s) for s in nxt["bits_hex"]]
                    end
                    if haskey(nxt, "results")
                        _check_rng_results(vals, nxt["results"], "states.next")
                    end
                    if haskey(st, "state_after")
                        @test get_state(r) == as_string(st["state_after"])
                    end
                end
            end

            for item in get(doc, "set_state", [])
                r = LoveRandom(0)
                set_state!(r, as_string(item["state"]))
                @test get_state(r) == as_string(item["state"])
                vals = _apply_rng_op!(r, item["then"])
                _check_rng_results(vals, item["results"], "set_state.results")
                if haskey(item, "state_after")
                    @test get_state(r) == as_string(item["state_after"])
                end
            end

            for anchor in get(doc, "seed_anchors", [])
                r = LoveRandom(as_int(anchor["seed"], "seed"))
                if haskey(anchor, "draws")
                    got = [random(r, 1, 10) for _ in 1:length(anchor["draws"])]
                    @test got == [as_int(x) for x in anchor["draws"]]
                end
                if haskey(anchor, "first_random_1_100")
                    @test random(r, 1, 100) == as_int(anchor["first_random_1_100"])
                end
                if haskey(anchor, "first_random_1_10")
                    r2 = LoveRandom(as_int(anchor["seed"], "seed"))
                    @test random(r2, 1, 10) == as_int(anchor["first_random_1_10"])
                end
                if haskey(anchor, "state")
                    @test get_state(r) == as_string(anchor["state"])
                end
            end
        end
    end

    @testset "peg_colors fixture" begin
        path = joinpath(RNG_FIXTURE_DIR, "peg_colors.v1.json")
        needed = (:load_level, :load_config, :init_colors!, :assign_next_purple_pegs!)
        missing_modules = [n for n in needed if !isdefined(PeggleSim, n)]
        if !isfile(path)
            println("test_rng: fixture not present yet, skipping: ", path)
            @test_skip "peg_colors.v1.json not present"
        elseif !isempty(missing_modules)
            println(
                "test_rng: peg_colors fixture present but these symbols are not ",
                "implemented yet: ",
                join(string.(missing_modules), ", "),
            )
            @test_skip "peg_colors requires the level/colorstate workstream"
        else
            doc = load_json(path)
            @test startswith(as_string(doc["format"]), "peggle.peg_colors")
            entries = haskey(doc, "levels") ? doc["levels"] : Any[doc]
            config_path = joinpath(REPO_ROOT, "interchange", "config.v1.json")
            @test isfile(config_path)
            config = PeggleSim.load_config(config_path)
            per_turn = as_int(config.purple_pegs_per_turn, "purple_pegs_per_turn")

            for entry in entries
                level_name = as_string(entry["level"], "level")
                level_path = joinpath(
                    REPO_ROOT, "interchange", "levels", level_name * ".v1.json")
                @test isfile(level_path)
                if !isfile(level_path)
                    continue
                end
                if haskey(entry, "level_sha256") && isdefined(PeggleSim, :level_sha256)
                    @test PeggleSim.level_sha256(level_path) ==
                          as_string(entry["level_sha256"])
                end
                level = PeggleSim.load_level(level_path)
                if haskey(entry, "type_counts")
                    tc = as_object(entry["type_counts"], "type_counts")
                    @test level.type_counts == (
                        blue = as_int(tc["blue"]),
                        green = as_int(tc["green"]),
                        purple = as_int(tc["purple"]),
                        red = as_int(tc["red"]),
                    )
                end

                rng = LoveRandom(level.level_seed)
                pegs = level.pegs
                cs = PeggleSim.init_colors!(
                    pegs, level.type_counts, level.level_seed, rng)
                if haskey(entry, "rng_state_after_init")
                    @test get_state(rng) == as_string(entry["rng_state_after_init"])
                end
                if haskey(entry, "peg_types")
                    @test [string(p.peg_type) for p in pegs] ==
                          [as_string(t) for t in entry["peg_types"]]
                end
                if haskey(entry, "queue_after_init")
                    @test [Int(x) for x in cs.queue] ==
                          [as_int(x) for x in entry["queue_after_init"]]
                end

                PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)
                if haskey(entry, "active_after_first_promotion")
                    @test [Int(x) for x in cs.active] ==
                          [as_int(x) for x in entry["active_after_first_promotion"]]
                end
                if haskey(entry, "peg_types_after_first_promotion")
                    @test [string(p.peg_type) for p in pegs] ==
                          [as_string(t) for t in entry["peg_types_after_first_promotion"]]
                end
                if haskey(entry, "rng_state_after_first_promotion")
                    @test get_state(rng) ==
                          as_string(entry["rng_state_after_first_promotion"])
                end

                # The captured rounds start from a fresh post-init state
                # (round 1 records active_before = [] and the full queue),
                # so replay them on a fresh init instead of continuing from
                # the first promotion checked above.
                rng = LoveRandom(level.level_seed)
                cs = PeggleSim.init_colors!(
                    pegs, level.type_counts, level.level_seed, rng)

                by_id = Dict(p.id => p for p in pegs)
                rounds = get(entry, "promotion_rounds", get(entry, "rounds", []))
                for round in rounds
                    for id in get(round, "mark_hit", [])
                        by_id[as_int(id, "mark_hit")].hit = true
                    end
                    PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)
                    if haskey(round, "active")
                        @test [Int(x) for x in cs.active] ==
                              [as_int(x) for x in round["active"]]
                    end
                    if haskey(round, "queue")
                        @test [Int(x) for x in cs.queue] ==
                              [as_int(x) for x in round["queue"]]
                    end
                    if haskey(round, "rng_state")
                        @test get_state(rng) == as_string(round["rng_state"])
                    end
                end
            end
        end
    end
end
