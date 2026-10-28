# Golden Lua-trace replay for the three ribbon_waves shots.
# Frozen geometry is exercised through the resulting simulation and trace.

using Test
using JSON
using PeggleSim

const RW_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const RW_DIR = joinpath(RW_REPO_ROOT, "fixtures", "ribbon_waves")
const RW_ARTIFACT = joinpath(RW_DIR, "artifact", "ribbon_waves.v1.json")
const RW_CONFIG = joinpath(RW_DIR, "config.dev.v1.json")
const RW_EXPECTED = joinpath(RW_DIR, "expected")
const RW_TRACES = joinpath(RW_DIR, "traces")
const RW_IDS = ("ribbon_waves_center", "ribbon_waves_left_wall", "ribbon_waves_ribbon")

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
    @testset "golden trace replay: $id" for id in RW_IDS
        record, summary, bytes, events = _rw_replay(id)

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
        corpus_path = _rw_require_file(joinpath(RW_TRACES, id * ".jsonl"))
        corpus = read(corpus_path)
        @test bytes == corpus
        @test PeggleSim.sha256_hex(bytes) == record["trace"]["sha256"]
        @test events == record["trace"]["events"]
    end
end
