# ribbon_waves fixture: static artifact checks against the pinned source
# geometry, and golden Lua-trace replay for the captured shots.
#
# The corpus lives in fixtures/ribbon_waves/ and is captured by
# scripts/capture_ribbon_waves.sh.  The artifact is in world space
# (virtual_width = 1545 * 10/22), so the level uses the engine's default
# peg radius 10 and ball radius 6.  `source/ribbon_waves_geometry.json` is the
# pinned extraction input: the test reads its `world` block to verify the
# transform and its counts to verify the export, while hardcoding the plan's
# scale/shooter numbers as a regression pin.
#
# The expected records' `trace.path` values are stale metadata (the Lua
# harness hard-codes `fixtures/traces/<id>.jsonl` for every corpus); the
# durable traces are read from this fixture's own `traces/` directory instead,
# exactly like the M3 mustache tests.

using Test
using JSON
using PeggleSim

const RW_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const RW_DIR = joinpath(RW_REPO_ROOT, "fixtures", "ribbon_waves")
const RW_ARTIFACT = joinpath(RW_DIR, "artifact", "ribbon_waves.v1.json")
const RW_CONFIG = joinpath(RW_DIR, "config.dev.v1.json")
const RW_SOURCE = joinpath(RW_DIR, "source", "ribbon_waves_geometry.json")
const RW_EXPECTED = joinpath(RW_DIR, "expected")
const RW_TRACES = joinpath(RW_DIR, "traces")
const RW_IDS = ("ribbon_waves_center", "ribbon_waves_left_wall", "ribbon_waves_ribbon")

# Plan pins (FIX_PLAN.md): scale 10/22 about the native shooter.
const RW_SCALE = 10.0 / 22.0
const RW_SHOOTER_NATIVE = (772.5, 50.0)
const RW_NATIVE_WIDTH = 1545.0
const RW_NATIVE_HEIGHT = 1289.0
const RW_WORLD_PEG_RADIUS = 10.0
const RW_WORLD_BALL_RADIUS = 6.0
const RW_CIRCLES = 53
const RW_LINE_IDS = ("wave_1", "wave_2", "wave_3", "wave_4", "wave_5")
const RW_LINE_COUNTS = (20, 20, 26, 28, 20)
const RW_ANNULAR = 114
const RW_SEGMENTS = 16
const RW_RED = 25
const RW_GREEN = 1
const RW_REVISION = "da752257f613abbd209f1aa1acdd37a5f9be05f5"
const RW_TREE = "61278edc5467bf8399c24f4af0fcf36d75cac6a2"
const RW_CONFIG_SHA256 = "a17e60b43b1437510a59ba59c8791b27600a4b7fd7d56bc5f9c18d3e94f114d9"

function _rw_require_file(path::AbstractString)::String
    isfile(path) || error("missing ribbon_waves fixture file: $path")
    return path
end

function _rw_styles_object(styles)::Dict{String,Int}
    out = Dict{String,Int}()
    isempty(styles) && return out
    for item in split(styles, ",")
        isempty(item) && continue
        parts = split(item, ":")
        out[String(parts[1])] = length(parts) > 1 ? parse(Int, parts[2]) : 1
    end
    return out
end

# Reproduce bin/shot_bench.jl::run_trace in-process: same checkpoint, same
# callbacks, same snapshot-free trace, same summary.
function _rw_replay(id::AbstractString)
    expected_path = _rw_require_file(joinpath(RW_EXPECTED, id * ".json"))
    record = JSON.parsefile(expected_path)
    level = PeggleSim.load_level(RW_ARTIFACT)
    config = PeggleSim.load_config(RW_CONFIG)

    provenance = (
        reference_revision = String(level.provenance.reference_revision),
        reference_tree = String(level.provenance.reference_tree),
        config_sha256 = String(level.provenance.config_sha256),
        level_sha256 = String(level.level_sha256),
    )
    balls = Int(record["action"]["balls"])
    ckpt = PeggleSim.build_checkpoint(
        level, config; balls = balls, mode = :solo, provenance = provenance)

    clearing = record["completion"]["rule"] == "clearing"
    callbacks = PeggleSim.harness_callbacks(clearing = clearing)
    eng = PeggleSim.shot_engine(
        ckpt; callbacks = callbacks, config = config,
        virtual_width = level.virtual_width, virtual_height = level.virtual_height)

    directory = mktempdir()
    trace_path = joinpath(directory, id * ".jsonl")
    writer = PeggleSim.trace_open(trace_path; include_snapshot = false)
    eng.trace = writer
    PeggleSim.launch!(eng, Int(record["action"]["aim_index"]))
    PeggleSim.run_shot!(eng; max_steps = Int(record["completion"]["max_steps"]))
    PeggleSim.trace_close!(writer)
    eng.trace = nothing

    summary = PeggleSim.shot_summary(eng)
    bytes = read(trace_path)
    return record, summary, bytes, writer.steps_written
end

@testset "ribbon_waves fixture" begin
    @testset "static artifact and pinned transform" begin
        source = JSON.parsefile(_rw_require_file(RW_SOURCE))
        level = PeggleSim.load_level(_rw_require_file(RW_ARTIFACT))

        @test level.name == "ribbon_waves"
        @test JSON.parsefile(RW_ARTIFACT)["motion"] == "static"
        @test level.default_peg_type == :blue

        # The plan's world transform, pinned exactly.
        world = source["world"]
        @test world["scale"] ≈ RW_SCALE
        @test world["shooter_native"][1] ≈ RW_SHOOTER_NATIVE[1]
        @test world["shooter_native"][2] ≈ RW_SHOOTER_NATIVE[2]
        @test world["virtual_width"] ≈ RW_NATIVE_WIDTH * RW_SCALE
        @test world["virtual_height"] ≈
              RW_SHOOTER_NATIVE[2] + (RW_NATIVE_HEIGHT - RW_SHOOTER_NATIVE[2]) * RW_SCALE
        @test world["peg_radius"] ≈ RW_WORLD_PEG_RADIUS
        @test world["ball_radius"] ≈ RW_WORLD_BALL_RADIUS
        source_size = haskey(source, "image_size") ?
            source["image_size"] :
            [source["native_width"], source["native_height"]]
        @test source_size == [Int(RW_NATIVE_WIDTH), Int(RW_NATIVE_HEIGHT)]
        @test level.virtual_width ≈ world["virtual_width"]
        @test level.virtual_height ≈ world["virtual_height"]

        # The pinned source geometry defines the single-slide path contract.
        # Its legacy ``pieces`` array is extraction diagnostics, not the
        # level's collision pieces; the level uses one smooth path per ribbon.
        @test length(source["circles"]) == RW_CIRCLES
        @test length(source["ribbons"]) == 5
        for (index, ribbon) in enumerate(source["ribbons"])
            @test ribbon["id"] == RW_LINE_IDS[index]
            @test haskey(ribbon, "path")
            path = ribbon["path"]
            @test path["model"] == "cubic-hermite-lsq-spline-v1"
            @test path["segment_count"] == 10
            @test length(path["segments"]) == 10
            @test path["trim_px"] ≈ 8.0
            @test path["knot_spacing_px"] >= 35.0
            @test path["fit_rms_px"] >= 0
            @test path["fit_max_px"] >= path["fit_rms_px"]
            @test path["min_curvature_radius_px"] >
                  ribbon["thickness"] * 0.5 * 1.05
            for segment in 1:9
                @test path["segments"][segment]["p1"] ==
                      path["segments"][segment + 1]["p0"]
            end
        end

        circles = [p for p in level.pegs if p.shape isa PeggleSim.CircleShape]
        annular = [p for p in level.pegs if p.shape isa PeggleSim.AnnularShape]
        @test length(circles) == RW_CIRCLES
        @test length(annular) == RW_ANNULAR
        @test length(circles) + length(annular) == length(level.pegs)

        # Ids are contiguous in engine/color-assignment order.
        @test [p.id for p in level.pegs] == collect(1:length(level.pegs))

        # Every annular peg belongs to exactly one of the five generated
        # zero-gap lines.  The line metadata is the single-slide contract:
        # gap 0, open path, contiguous indices, one shared count.
        line_indices = Dict{String,Vector{Int}}()
        for peg in annular
            @test peg.line !== nothing
            line = peg.line
            @test line.id in RW_LINE_IDS
            @test line.count >= 1
            @test 1 <= line.index <= line.count
            @test line.closed == false
            @test line.gap == 0.0
            push!(get!(line_indices, line.id, Int[]), line.index)
        end
        @test length(line_indices) == length(RW_LINE_IDS)
        for (id, expected_count) in zip(RW_LINE_IDS, RW_LINE_COUNTS)
            @test haskey(line_indices, id)
            @test sort(line_indices[id]) == collect(1:expected_count)
            members = [p for p in annular if p.line.id == id]
            @test length(members) == expected_count
            @test all(p.line.count == expected_count for p in members)
            @test all(p.shape.segments == RW_SEGMENTS for p in members)
        end
        @test all(p.line === nothing for p in circles)

        # Colors are NOT part of this fixture's contract: the engine assigns
        # peg types from type_counts, so only count bookkeeping is checked.
        # The static artifact is the authored / pre-promotion board, hence no
        # purple yet (the turn-1 promotion happens at resetTurn, not at load).
        tc = level.type_counts
        @test tc.purple == 0
        @test tc.red == RW_RED
        @test tc.green == RW_GREEN
        @test tc.blue == length(level.pegs) - RW_RED - RW_GREEN
        @test tc.blue + tc.green + tc.purple + tc.red == length(level.pegs)
        @test all(p.peg_type != :purple for p in level.pegs)
        @test all(p.peg_type in (:blue, :green, :purple, :red) for p in level.pegs)
        @test count(p -> p.peg_type == :blue, level.pegs) == tc.blue
        @test count(p -> p.peg_type == :green, level.pegs) == tc.green
        @test count(p -> p.peg_type == :red, level.pegs) == tc.red
        @test count(p -> p.peg_type == :purple, level.pegs) == tc.purple

        for peg in level.pegs
            shape = peg.shape
            if shape isa PeggleSim.CircleShape
                @test shape.radius ≈ RW_WORLD_PEG_RADIUS
                # Circles are bounded by their centre +/- radius.
                @test 0 <= peg.x - shape.radius
                @test peg.x + shape.radius <= level.virtual_width
                @test 0 <= peg.y - shape.radius
                @test peg.y + shape.radius <= level.virtual_height
                @test peg.line === nothing
            else
                @test shape isa PeggleSim.AnnularShape
                @test 0 <= shape.r_in < shape.r_out
                @test shape.theta_end_abs > shape.theta_start
                @test shape.theta_end_abs - shape.theta_start <= 2 * pi + 1e-9
                @test shape.segments == RW_SEGMENTS
                @test peg.line !== nothing
                # An annular peg's (x, y) is the arc's CIRCLE CENTRE, which
                # may legitimately lie outside the board while the arc itself
                # is inside.  Bound the sampled arc, not the centre.
                xs = Float64[]
                ys = Float64[]
                for radius in (shape.r_in, shape.r_out)
                    for i in 0:64
                        theta = shape.theta_start +
                                (shape.theta_end_abs - shape.theta_start) * i / 64
                        push!(xs, peg.x + radius * cos(theta))
                        push!(ys, peg.y + radius * sin(theta))
                    end
                end
                @test 0 <= minimum(xs) <= maximum(xs) <= level.virtual_width
                @test 0 <= minimum(ys) <= maximum(ys) <= level.virtual_height
            end
            @test peg.base_x == peg.x
            @test peg.base_y == peg.y
            @test !peg.hit
        end

        # Provenance hashes match the committed fixture files.
        @test level.provenance.reference_revision == RW_REVISION
        @test level.provenance.reference_tree == RW_TREE
        @test level.provenance.config_sha256 == RW_CONFIG_SHA256
        @test level.level_sha256 == PeggleSim.level_sha256(RW_ARTIFACT)
        config_doc = JSON.parsefile(_rw_require_file(RW_CONFIG))
        @test config_doc["source_sha256"] == RW_CONFIG_SHA256
        @test config_doc["values"]["aim_discretization_steps"] == 1800
    end

    @testset "fixture records agree with the artifact" begin
        level = PeggleSim.load_level(RW_ARTIFACT)
        for id in RW_IDS
            record = JSON.parsefile(_rw_require_file(joinpath(RW_EXPECTED, id * ".json")))
            @test record["format"] == "peggle.fixture"
            @test record["id"] == id
            @test record["kind"] == "shot"
            @test record["source"]["level"] == "ribbon_waves"
            @test record["source"]["level_sha256"] == level.level_sha256
            @test record["seed"]["level_seed"] == level.level_seed
            @test record["seed"]["type_counts"]["blue"] == level.type_counts.blue
            @test record["seed"]["type_counts"]["green"] == level.type_counts.green
            @test record["seed"]["type_counts"]["purple"] == level.type_counts.purple
            @test record["seed"]["type_counts"]["red"] == level.type_counts.red
        end
    end

    @testset "golden trace replay: $id" for id in RW_IDS
        record, summary, bytes, events = _rw_replay(id)

        @test 0 <= record["action"]["aim_index"] <= 1800
        @test record["completion"]["rule"] == "bench"
        @test record["completion"]["max_steps"] == 3600
        @test record["source"]["level_sha256"] ==
              PeggleSim.level_sha256(RW_ARTIFACT)

        # Completion.
        @test summary.completed == record["completion"]["completed"]
        @test summary.reason == record["completion"]["reason"]
        @test summary.steps == record["completion"]["steps"]

        # Every result field, exactly (same shape as the expected record).
        actual = Dict{String,Any}(
            "score" => summary.score,
            "peg_score" => summary.peg_score,
            "bonus" => summary.bonus,
            "style_points" => summary.style_points,
            "styles" => _rw_styles_object(summary.styles),
            "pegs_hit" => summary.pegs_hit,
            "reds_hit" => summary.reds_hit,
            "multiplier" => summary.multiplier,
            "is_fever" => summary.is_fever,
            "balls" => summary.balls,
            "balls_spawned" => summary.spawned,
        )
        @test sort(collect(keys(actual))) == sort(collect(keys(record["result"])))
        for key in sort!(collect(keys(record["result"])))
            @test actual[key] == record["result"][key]
        end

        # Byte-for-byte trace parity against the durable Lua capture. The
        # expected record's trace.path is stale (hard-coded to
        # fixtures/traces/...); read this corpus's actual file instead.
        @test record["trace"]["path"] == "fixtures/traces/" * id * ".jsonl"
        corpus_path = _rw_require_file(joinpath(RW_TRACES, id * ".jsonl"))
        corpus = read(corpus_path)
        @test bytes == corpus
        @test PeggleSim.sha256_hex(bytes) == record["trace"]["sha256"]
        @test events == record["trace"]["events"]
        @test count(==(UInt8('\n')), corpus) == events + 1
    end
end
