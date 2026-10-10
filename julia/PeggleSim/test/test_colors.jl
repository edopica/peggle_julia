using Test
using Base64
using PeggleSim

const COLORS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const COLORS_FIXTURE_PATH =
    joinpath(COLORS_REPO_ROOT, "fixtures", "rng", "peg_colors.v1.json")
const COLORS_CONFIG_PATH =
    joinpath(COLORS_REPO_ROOT, "interchange", "config.v1.json")
const COLORS_CHECKPOINT_DIR =
    joinpath(COLORS_REPO_ROOT, "fixtures", "checkpoints")

function _colors_level_path(name::String)
    return joinpath(COLORS_REPO_ROOT, "interchange", "levels", name * ".v1.json")
end

@testset "peg colors fixtures" begin
    @test isfile(COLORS_FIXTURE_PATH)
    doc = load_json(COLORS_FIXTURE_PATH)
    @test as_string(doc["format"]) == "peggle.peg_colors_fixtures"
    @test as_int(doc["schema_version"]) == 1

    config = PeggleSim.load_config(COLORS_CONFIG_PATH)
    per_turn = config.purple_pegs_per_turn

    levels = doc["levels"]
    @test !isempty(levels)

    for entry in levels
        level_name = as_string(entry["level"], "level")
        level_path = _colors_level_path(level_name)
        @test isfile(level_path)
        level = PeggleSim.load_level(level_path)

        @test level.level_seed == as_int(entry["level_seed"], "level_seed")
        if haskey(entry, "type_counts")
            tc = as_object(entry["type_counts"], "type_counts")
            @test level.type_counts == (
                blue = as_int(tc["blue"]),
                green = as_int(tc["green"]),
                purple = as_int(tc["purple"]),
                red = as_int(tc["red"]),
            )
        end
        if haskey(entry, "level_sha256")
            @test PeggleSim.level_sha256(level_path) ==
                  as_string(entry["level_sha256"])
        end

        # init: pool + queue shuffle on the seeded generator.
        rng = LoveRandom(level.level_seed)
        pegs = level.pegs
        cs = PeggleSim.init_colors!(
            pegs, level.type_counts, level.level_seed, rng)

        @test [string(p.peg_type) for p in pegs] ==
              [as_string(t) for t in entry["peg_types"]]
        @test cs.queue == [as_int(x) for x in entry["queue_after_init"]]
        @test isempty(cs.active)
        @test get_state(rng) == as_string(entry["rng_state_after_init"])

        # First promotion inside resetTurn.
        PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)
        @test cs.active == [as_int(x) for x in entry["active_after_first_promotion"]]
        @test cs.queue == [as_int(x) for x in entry["queue_after_first_promotion"]]
        @test [string(p.peg_type) for p in pegs] ==
              [as_string(t) for t in entry["peg_types_after_first_promotion"]]
        @test get_state(rng) == as_string(entry["rng_state_after_first_promotion"])

        # The scripted rounds were captured from a fresh post-init state
        # (before the first promotion), so replay them on a fresh init.
        rng = LoveRandom(level.level_seed)
        cs = PeggleSim.init_colors!(
            pegs, level.type_counts, level.level_seed, rng)
        @test get_state(rng) == as_string(entry["rng_state_after_init"])
        @test cs.queue == [as_int(x) for x in entry["queue_after_init"]]

        by_id = Dict(p.id => p for p in pegs)
        rounds = get(entry, "rounds", Any[])
        @test !isempty(rounds)
        for round in rounds
            for id in get(round, "mark_hit", Any[])
                by_id[as_int(id, "mark_hit")].hit = true
            end
            # Snapshots are taken after mark_hit is applied (fixture contract).
            if haskey(round, "queue_before")
                @test cs.queue == [as_int(x) for x in round["queue_before"]]
            end
            if haskey(round, "active_before")
                @test cs.active == [as_int(x) for x in round["active_before"]]
            end
            if haskey(round, "rng_state_before")
                @test get_state(rng) == as_string(round["rng_state_before"])
            end

            pre_queue = copy(cs.queue)
            all_hit = all(by_id[id].hit for id in pre_queue)
            survivors = count(p -> p.peg_type === :blue && !p.hit, pegs)
            if haskey(round, "rebuilt")
                @test (all_hit && survivors > 0) == as_bool(round["rebuilt"])
            end

            PeggleSim.assign_next_purple_pegs!(pegs, cs, per_turn)

            @test cs.active == [as_int(x) for x in round["active"]]
            @test cs.queue == [as_int(x) for x in round["queue"]]
            @test get_state(rng) == as_string(round["rng_state"])
        end

        # Levels with blue pegs must exercise the empty-queue rebuild path.
        if level.type_counts.blue > 0
            @test any(as_bool(r["rebuilt"]) for r in rounds)
        end
    end

    # rng.state_b64 is the base64 of the ASCII getState() string. Verify the
    # encoding against a captured checkpoint for the same level seed/state.
    ckpt_path = joinpath(COLORS_CHECKPOINT_DIR, "circle_level.v1.json")
    @test isfile(ckpt_path)
    ckpt_doc = load_json(ckpt_path)
    decoded_state = String(base64decode(as_string(ckpt_doc["rng"]["state_b64"])))
    entry = only(filter(e -> as_string(e["level"]) == "circle_level", levels))
    @test decoded_state == as_string(entry["rng_state_after_init"])
    @test base64encode(decoded_state) == as_string(ckpt_doc["rng"]["state_b64"])
end
