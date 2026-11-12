using Test
using Base64
using PeggleSim

const CKPT_RL = PeggleSim.RealLevels
const CKPT_CONFIG_PATH = CKPT_RL.config_path()

# Provenance is rebuilt from the level artifact and the config, never from a
# checkpoint being checked.
function _ck_provenance(level, config)
    return (
        reference_revision = String(level.provenance.reference_revision),
        reference_tree = String(level.provenance.reference_tree),
        config_sha256 = config.source_sha256,
        level_sha256 = String(level.level_sha256),
    )
end

_ck_level(name) = PeggleSim.load_level(CKPT_RL.artifact_path(name))

@testset "checkpoint encoding round trip on the real levels" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    # Every real level with one ball, plus a three-ball m1 checkpoint.
    for (name, balls) in vcat([(n, 1) for n in CKPT_RL.NAMES], [("m1", 3)])
        level = _ck_level(name)
        provenance = _ck_provenance(level, config)
        checkpoint = PeggleSim.build_checkpoint(
            level, config; balls, mode = :solo, provenance)
        encoded = canonical_json(checkpoint) * "\n"
        # Building is deterministic.
        @test canonical_json(PeggleSim.build_checkpoint(
            level, config; balls, mode = :solo, provenance)) * "\n" == encoded
        @test length(checkpoint.engine.balls) == balls

        # checkpoint_from_dict is the inverse of checkpoint_to_dict.
        decoded = mktempdir() do dir
            path = joinpath(dir, "checkpoint.v1.json")
            write(path, encoded)
            PeggleSim.checkpoint_from_dict(load_json(path))
        end
        @test canonical_json(decoded) * "\n" == encoded
        @test PeggleSim.first_difference(decoded, checkpoint) === nothing
        @test PeggleSim.checkpoint_canonical(decoded) ==
              canonical_json(PeggleSim.checkpoint_to_dict(decoded))

        # The ramp bucket is encoded by key presence.
        bucket = PeggleSim.checkpoint_to_dict(decoded)["engine"]["bucket"]
        @test haskey(bucket, "rim_width") && !haskey(bucket, "edge")

        # state_b64 decodes to the ASCII getState() string.
        state = String(Base64.base64decode(decoded.rng.state_b64))
        @test startswith(state, "0x")
        @test length(state) == 18
    end
end

@testset "reset contract: capture -> advance -> restore" begin
    config = PeggleSim.load_config(CKPT_CONFIG_PATH)
    for level_name in ("b2", "g1", "ribbon_waves")
        level = _ck_level(level_name)
        provenance = _ck_provenance(level, config)
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
    level = _ck_level("b2")
    provenance = _ck_provenance(level, config)

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
    level = _ck_level("b2")
    provenance = _ck_provenance(level, config)
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
