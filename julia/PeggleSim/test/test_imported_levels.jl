# Imported screenshot levels (b1, b2, g1, m1, m2): golden Lua-trace replay,
# ribbon geometry, and campaign color seeding.
#
# Four boards use the dev-tree `ribbon` gameplay peg; b2 is the
# annular/rectangle control. The corpus is captured with
# scripts/capture_imported_levels.sh.

using Test
using JSON
using PeggleSim

const IL_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const IL_DIR = joinpath(IL_REPO_ROOT, "fixtures", "imported_levels")
const IL_CONFIG = joinpath(IL_DIR, "config.dev.v1.json")
const IL_LEVELS = ("b1", "b2", "g1", "m1", "m2")
const IL_AIMS = ("right_wall", "right", "center", "left", "left_wall")

_il_artifact(level) = joinpath(IL_DIR, "artifact", level * ".v1.json")

function _il_styles_object(styles)::Dict{String,Int}
    out = Dict{String,Int}()
    for item in split(styles, ",")
        isempty(item) && continue
        parts = split(item, ":")
        out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
    end
    return out
end

function _il_provenance(level)
    return (
        reference_revision = String(level.provenance.reference_revision),
        reference_tree = String(level.provenance.reference_tree),
        config_sha256 = String(level.provenance.config_sha256),
        level_sha256 = String(level.level_sha256),
    )
end

function _il_replay(id::AbstractString)
    record = JSON.parsefile(joinpath(IL_DIR, "expected", id * ".json"))
    level = PeggleSim.load_level(_il_artifact(record["source"]["level"]))
    config = PeggleSim.load_config(IL_CONFIG)
    ckpt = PeggleSim.build_checkpoint(level, config; balls = Int(record["action"]["balls"]),
                                      mode = :solo, provenance = _il_provenance(level))
    callbacks = PeggleSim.harness_callbacks(clearing = record["completion"]["rule"] == "clearing")
    eng = PeggleSim.shot_engine(ckpt; callbacks, config,
        virtual_width = level.virtual_width, virtual_height = level.virtual_height)
    trace_path = joinpath(mktempdir(), id * ".jsonl")
    writer = PeggleSim.trace_open(trace_path; include_snapshot = false)
    eng.trace = writer
    PeggleSim.launch!(eng, Int(record["action"]["aim_index"]))
    PeggleSim.run_shot!(eng; max_steps = Int(record["completion"]["max_steps"]))
    PeggleSim.trace_close!(writer)
    eng.trace = nothing
    return record, PeggleSim.shot_summary(eng), read(trace_path), writer.steps_written
end

@testset "imported levels" begin
    @testset "golden trace replay: $(level)_$(aim)" for level in IL_LEVELS, aim in IL_AIMS
        id = "$(level)_$(aim)"
        record, summary, bytes, events = _il_replay(id)
        @test summary.completed == record["completion"]["completed"]
        @test summary.reason == record["completion"]["reason"]
        @test summary.steps == record["completion"]["steps"]
        actual = Dict{String,Any}(
            "score" => summary.score, "peg_score" => summary.peg_score,
            "bonus" => summary.bonus, "style_points" => summary.style_points,
            "styles" => _il_styles_object(summary.styles),
            "pegs_hit" => summary.pegs_hit, "reds_hit" => summary.reds_hit,
            "multiplier" => summary.multiplier, "is_fever" => summary.is_fever,
            "balls" => summary.balls, "balls_spawned" => summary.spawned)
        @test sort(collect(keys(actual))) == sort(collect(keys(record["result"])))
        for key in sort!(collect(keys(record["result"])))
            @test actual[key] == record["result"][key]
        end
        @test bytes == read(joinpath(IL_DIR, "traces", id * ".jsonl"))
        @test PeggleSim.sha256_hex(bytes) == record["trace"]["sha256"]
        @test events == record["trace"]["events"]
    end

    @testset "ribbon pegs" begin
        for name in IL_LEVELS
            level = PeggleSim.load_level(_il_artifact(name))
            for peg in level.pegs
                peg.shape isa PeggleSim.RibbonShape || continue
                parts = peg.shape.parts
                n = length(parts)
                # Exactly two caps stay exposed: the path entry and exit. With
                # mixed traversal directions (biarc inflections) both can be
                # sector-start or both sector-end caps.
                @test count(p -> !p.no_cap_start, parts) + count(p -> !p.no_cap_end, parts) == 2
                for (i, p) in enumerate(parts)
                    @test p.local_x == p.x - peg.x && p.local_y == p.y - peg.y
                    first_in_path = p.path_direction == 1 ? i == 1 : i == n
                    last_in_path = p.path_direction == 1 ? i == n : i == 1
                    @test p.no_cap_start == !first_in_path
                    @test p.no_cap_end == !last_in_path
                end
                @test peg.shape.path_end > peg.shape.path_start
                @test peg.line !== nothing && peg.line.gap == 0.0
            end
        end
    end

    @testset "physics expands ribbons into owned pieces" begin
        level = PeggleSim.load_level(_il_artifact("g1"))
        config = PeggleSim.load_config(IL_CONFIG)
        ckpt = PeggleSim.build_checkpoint(level, config; provenance = _il_provenance(level))
        eng = PeggleSim.shot_engine(ckpt; config, level)
        ctx = eng.scratch.physics
        owners = eng.annular_pegs
        pieces = PeggleSim.ribbon_collision_pieces!(ctx, owners, config.fixed_dt)
        nparts = sum(p.shape isa PeggleSim.RibbonShape ? length(p.shape.parts) : 1 for p in owners)
        @test pieces !== owners
        @test length(pieces) == nparts
        @test all(p -> p.shape isa PeggleSim.AnnularShape, pieces)
        @test all(p -> p.ribbon_owner === nothing || p.ribbon_owner in owners, pieces)
        # Repeated expansion reuses the pooled piece objects.
        again = PeggleSim.ribbon_collision_pieces!(ctx, owners, config.fixed_dt)
        @test again === pieces && length(again) == nparts
        # Boards without ribbons pass through untouched.
        b2 = PeggleSim.load_level(_il_artifact("b2"))
        e2 = PeggleSim.shot_engine(PeggleSim.build_checkpoint(b2, config;
            provenance = _il_provenance(b2)); config, level = b2)
        @test PeggleSim.ribbon_collision_pieces!(e2.scratch.physics, e2.annular_pegs,
                                                 config.fixed_dt) === e2.annular_pegs
    end

    @testset "campaign colors are drawn per game" begin
        config = PeggleSim.load_config(IL_CONFIG)
        for name in IL_LEVELS
            level = PeggleSim.load_level(_il_artifact(name))
            prov = merge(PeggleSim.campaign_provenance(level),
                         (; config_sha256 = config.source_sha256))
            shared = PeggleSim.build_checkpoint(level, config; mode = Symbol("1v1"), provenance = prov)
            per_game = PeggleSim.CampaignOptions(games = 2, workers = 1)
            fixed = PeggleSim.CampaignOptions(games = 2, workers = 1, colors = :level)
            layout(c) = [p.peg_type for p in c.engine.pegs]
            g1 = PeggleSim.game_checkpoint(shared, level, config, per_game, 1)
            g2 = PeggleSim.game_checkpoint(shared, level, config, per_game, 2)
            @test PeggleSim.game_checkpoint(shared, level, config, fixed, 1) === shared
            @test layout(g1) != layout(shared)
            @test layout(g1) != layout(g2)
            # Reproducible from base_seed, and the type counts are unchanged.
            @test layout(g1) == layout(PeggleSim.game_checkpoint(shared, level, config, per_game, 1))
            for t in (:red, :green, :purple, :blue)
                @test count(==(t), layout(g1)) == count(==(t), layout(shared))
            end
            # The level_seed layout reproduces the authored screenshot colors
            # (the level file orders its pegs for that); per-game layouts do not.
            authored = [Symbol(p["type"]) for p in JSON.parsefile(_il_artifact(name))["pegs"]]
            reds = findall(==(:red), authored)
            @test count(i -> layout(shared)[i] === :red, reds) == length(reds)
            @test count(i -> layout(g1)[i] === :red, reds) < length(reds)
        end
    end
end
