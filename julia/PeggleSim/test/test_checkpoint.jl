using Test
using Base64
using PeggleSim

const CKPT_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const CKPT_DIR = joinpath(CKPT_REPO_ROOT, "fixtures", "checkpoints")
const CKPT_LEVEL_DIR = joinpath(CKPT_REPO_ROOT, "interchange", "levels")
const CKPT_CONFIG_PATH = joinpath(CKPT_REPO_ROOT, "interchange", "config.v1.json")
const CKPT_PIN_PATH = joinpath(CKPT_REPO_ROOT, "reference", "PIN.md")

struct _CkFixture
    file::String
    level::String
    balls::Int
end

function _ck_fixtures()::Vector{_CkFixture}
    out = _CkFixture[]
    for file in sort(readdir(CKPT_DIR))
        endswith(file, ".v1.json") || continue
        base = replace(file, ".v1.json" => "")
        if base == "slide.multiball3"
            push!(out, _CkFixture(file, "slide", 3))
        else
            push!(out, _CkFixture(file, base, 1))
        end
    end
    return out
end

# Provenance is rebuilt from the pin document, the config artifact, and the
# level artifact bytes -- never from the fixture being checked.
function _ck_provenance(level_name::AbstractString)
    pin = read(CKPT_PIN_PATH, String)
    revision = match(r"Revision \(full\) \| `([0-9a-f]{40})`", pin)[1]
    tree = match(r"Tree hash \| `([0-9a-f]{40})`", pin)[1]
    config_sha = match(r"Config hash \(`src/config.lua`\) \| `([0-9a-f]{64})`", pin)[1]
    config_doc = load_json(CKPT_CONFIG_PATH)
    config_doc["source_sha256"] == config_sha || error(
        "PIN config hash does not match the config artifact source_sha256")
    level_path = joinpath(CKPT_LEVEL_DIR, level_name * ".v1.json")
    return (
        reference_revision = revision,
        reference_tree = tree,
        config_sha256 = config_sha,
        level_sha256 = PeggleSim.level_sha256(level_path),
    )
end

@testset "captured checkpoints are byte-identical" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    fixtures = _ck_fixtures()
    @test length(fixtures) == 9

    for fixture in fixtures
        level_path = joinpath(CKPT_LEVEL_DIR, fixture.level * ".v1.json")
        fixture_path = joinpath(CKPT_DIR, fixture.file)
        @test isfile(level_path)
        @test isfile(fixture_path)

        provenance = _ck_provenance(fixture.level)
        level = PeggleSim.load_level(level_path)
        checkpoint = PeggleSim.build_checkpoint(
            level, config;
            balls = fixture.balls, mode = :solo, provenance = provenance)
        encoded = canonical_json(checkpoint) * "\n"
        expected = read(fixture_path, String)
        @test encoded == expected

        # checkpoint_from_dict is the inverse of checkpoint_to_dict.
        decoded = PeggleSim.checkpoint_from_dict(load_json(fixture_path))
        @test canonical_json(decoded) * "\n" == expected
        @test PeggleSim.checkpoint_canonical(decoded) ==
              canonical_json(PeggleSim.checkpoint_to_dict(decoded))

        # state_b64 decodes to the ASCII getState() string.
        state = String(Base64.base64decode(decoded.rng.state_b64))
        @test startswith(state, "0x")
        @test length(state) == 18
    end
end

@testset "reset contract: capture -> advance -> restore" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    for level_name in ("circle_level", "slide", "squiggly_circle")
        level_path = joinpath(CKPT_LEVEL_DIR, level_name * ".v1.json")
        provenance = _ck_provenance(level_name)
        level = PeggleSim.load_level(level_path)
        checkpoint = PeggleSim.build_checkpoint(
            level, config; balls = 1, mode = :solo, provenance = provenance)
        witness = canonical_json(checkpoint)

        worker = PeggleSim.make_worker(checkpoint)
        before = PeggleSim.capture_checkpoint(worker.sim; provenance = provenance)
        @test canonical_json(before) == witness
        hash_before = PeggleSim.checkpoint_sha256(before)

        for _ in 1:2
            PeggleSim.test_advance!(
                worker; steps = 7, rng_draws = 5, purple_promotions = 1)
            mutated = PeggleSim.capture_checkpoint(worker.sim; provenance = provenance)
            @test PeggleSim.checkpoint_sha256(mutated) != hash_before

            PeggleSim.reset_worker!(worker, checkpoint)
            restored = PeggleSim.capture_checkpoint(worker.sim; provenance = provenance)
            @test PeggleSim.checkpoint_sha256(restored) == hash_before
            @test canonical_json(restored) == witness
        end
    end
end

@testset "restore and capture do not alias" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    level_path = joinpath(CKPT_LEVEL_DIR, "circle_level.v1.json")
    provenance = _ck_provenance("circle_level")
    level = PeggleSim.load_level(level_path)

    # Mutating the worker simulation must not touch the checkpoint.
    checkpoint = PeggleSim.build_checkpoint(
        level, config; balls = 1, mode = :solo, provenance = provenance)
    hash_checkpoint = PeggleSim.checkpoint_sha256(checkpoint)
    worker = PeggleSim.make_worker(checkpoint)
    PeggleSim.reset_worker!(worker, checkpoint)
    sim = worker.sim
    sim.engine.pegs[1].peg_type = :red
    sim.engine.pegs[1].x = -1234.0
    sim.engine.balls[1].x += 10.0
    push!(sim.engine.used_ball_ids, 987654)
    push!(sim.engine.turn_pegs_hit, 42)
    sim.colors.queue[1] = -1
    push!(sim.colors.active, 43)
    sim.trackers.style_shots.awarded[1] = Dict{String,Bool}("x" => true)
    sim.trackers.ball_state.idle[1] = true
    sim.trackers.ball_state.no_score_timer = 9.0
    @test PeggleSim.checkpoint_sha256(checkpoint) == hash_checkpoint

    # Mutating a captured checkpoint must not touch the originating sim.
    sim2 = PeggleSim.build_sim_state(level, config; balls = 1, mode = :solo)
    captured = PeggleSim.capture_checkpoint(sim2; provenance = provenance)
    hash_sim = PeggleSim.checkpoint_sha256(
        PeggleSim.capture_checkpoint(sim2; provenance = provenance))
    push!(captured.engine.pegs, captured.engine.pegs[1])
    push!(captured.engine.balls, captured.engine.balls[1])
    push!(captured.engine.used_ball_ids, 424242)
    captured.purple_queue.queue[1] = 999999
    push!(captured.purple_queue.active, 31337)
    captured.trackers.ball_state.idle[1] = true
    captured.trackers.ball_state.no_score_timeout_fired = true
    recaptured = PeggleSim.capture_checkpoint(sim2; provenance = provenance)
    @test PeggleSim.checkpoint_sha256(recaptured) == hash_sim
end

@testset "first_difference" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    level_path = joinpath(CKPT_LEVEL_DIR, "circle_level.v1.json")
    provenance = _ck_provenance("circle_level")
    level = PeggleSim.load_level(level_path)
    checkpoint = PeggleSim.build_checkpoint(
        level, config; balls = 1, mode = :solo, provenance = provenance)

    dict = PeggleSim.checkpoint_to_dict(checkpoint)
    @test PeggleSim.first_difference(dict, deepcopy(dict)) === nothing
    @test PeggleSim.first_difference(checkpoint, checkpoint) === nothing

    corrupted = deepcopy(dict)
    current = corrupted["engine"]["pegs"][2]["type"]
    corrupted["engine"]["pegs"][2]["type"] = current == "red" ? "green" : "red"
    @test PeggleSim.first_difference(dict, corrupted) == "engine.pegs[2].type"

    corrupted2 = deepcopy(dict)
    corrupted2["trackers"]["ball_state"]["no_score_timer"] = 3.5
    @test PeggleSim.first_difference(dict, corrupted2) ==
          "trackers.ball_state.no_score_timer"

    corrupted3 = deepcopy(dict)
    push!(corrupted3["engine"]["used_ball_ids"], 999)
    @test PeggleSim.first_difference(dict, corrupted3) ==
          "engine.used_ball_ids[2]"
end
