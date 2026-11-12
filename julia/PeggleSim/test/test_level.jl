using Test
using JSON
using PeggleSim

const LEVEL_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const LEVEL_ARTIFACT_DIR = joinpath(LEVEL_REPO_ROOT, "interchange", "levels")
const LEVEL_CONFIG_PATH = joinpath(LEVEL_REPO_ROOT, "interchange", "config.v1.json")
@testset "non-static levels are rejected" begin
    source = joinpath(LEVEL_ARTIFACT_DIR, "long_shot.v1.json")
    mktempdir() do dir
        doc = JSON.parsefile(source)

        moving = deepcopy(doc)
        moving["motion"] = "moving"
        moving_path = joinpath(dir, "moving.v1.json")
        open(moving_path, "w") do io
            JSON.print(io, moving)
        end
        @test_throws ArgumentError PeggleSim.load_level(moving_path)

        with_circuits = deepcopy(doc)
        with_circuits["circuits"] = Dict{String,Any}()
        circuits_path = joinpath(dir, "circuits.v1.json")
        open(circuits_path, "w") do io
            JSON.print(io, with_circuits)
        end
        @test_throws ArgumentError PeggleSim.load_level(circuits_path)

        bad_ids = deepcopy(doc)
        bad_ids["pegs"][2]["id"] = 7
        bad_ids_path = joinpath(dir, "bad_ids.v1.json")
        open(bad_ids_path, "w") do io
            JSON.print(io, bad_ids)
        end
        @test_throws ArgumentError PeggleSim.load_level(bad_ids_path)
    end
end

@testset "config artifact" begin
    doc = JSON.parsefile(LEVEL_CONFIG_PATH)
    config = PeggleSim.load_config(LEVEL_CONFIG_PATH)

    @test doc["format"] == "peggle.config"
    @test doc["schema_version"] == 1
    @test config.source_sha256 == doc["source_sha256"]
    @test PeggleSim.config_source_sha256(config) == doc["source_sha256"]

    # Every value key is represented bit-exactly (float fields via canonical
    # encoding, which emits %.17g for non-integral doubles).
    @test config.rules === PeggleSim.RULES_CLASSIC
    @test config.bucket_catch_hold_steps == 0
    for key in (PeggleSim.CONFIG_VALUE_KEYS..., PeggleSim.CONFIG_CLASSIC_BUCKET_KEYS...)
        raw = doc["values"][String(key)]
        value = getfield(config, key)
        if key === :peg_types
            for type_name in (:blue, :green, :purple, :red)
                raw_type = raw[String(type_name)]
                parsed = value[type_name]
                @test parsed.value == raw_type["value"]
                for i in 1:3
                    @test float_bits_hex(parsed.color[i]) ==
                          float_bits_hex(Float64(raw_type["color"][i]))
                end
            end
        elseif value isa NTuple{3,Float64}
            for i in 1:3
                @test float_bits_hex(value[i]) == float_bits_hex(Float64(raw[i]))
            end
        elseif value isa Symbol
            @test String(value) == raw
        elseif value isa AbstractFloat
            @test float_bits_hex(value) == float_bits_hex(Float64(raw))
        else
            @test value == raw
        end
    end

    mktempdir() do dir
        unknown = deepcopy(doc)
        unknown["values"]["definitely_not_a_config_key"] = 1
        unknown_path = joinpath(dir, "unknown.v1.json")
        open(unknown_path, "w") do io
            JSON.print(io, unknown)
        end
        @test_throws ArgumentError PeggleSim.load_config(unknown_path)

        missing = deepcopy(doc)
        delete!(missing["values"], "gravity")
        missing_path = joinpath(dir, "missing.v1.json")
        open(missing_path, "w") do io
            JSON.print(io, missing)
        end
        @test_throws ArgumentError PeggleSim.load_config(missing_path)

        bad_top = deepcopy(doc)
        bad_top["extra_section"] = true
        bad_top_path = joinpath(dir, "bad_top.v1.json")
        open(bad_top_path, "w") do io
            JSON.print(io, bad_top)
        end
        @test_throws ArgumentError PeggleSim.load_config(bad_top_path)
    end
end

@testset "config rule-set selection (10ee3a0 bucket keys)" begin
    classic_doc = JSON.parsefile(LEVEL_CONFIG_PATH)
    ramp_path = joinpath(LEVEL_REPO_ROOT, "campaigns", "ribbon", "config.v1.json")
    ramp_doc = JSON.parsefile(ramp_path)
    ramp = PeggleSim.load_config(ramp_path)
    @test ramp.rules === PeggleSim.RULES_RAMP_BUCKET
    @test ramp.bucket_edge == 0.0
    # core.lua: math.ceil(bucket_catch_hold / fixed_dt) = ceil(1.5 * 60) = 90.
    @test ramp.bucket_catch_hold_steps == Int(ceil(ramp.bucket_catch_hold / ramp.fixed_dt))
    @test ramp.bucket_catch_hold_steps == 90
    for key in PeggleSim.CONFIG_RAMP_BUCKET_KEYS
        @test float_bits_hex(getfield(ramp, key)) ==
              float_bits_hex(Float64(ramp_doc["values"][String(key)]))
    end
    # Render-only key accepted, never stored.
    @test haskey(ramp_doc["values"], "bucket_rim_color")
    @test !hasfield(PeggleSim.SimConfig, :bucket_rim_color)

    function write_doc(dir, name, doc)
        path = joinpath(dir, name)
        open(io -> JSON.print(io, doc), path, "w")
        return path
    end
    mktempdir() do dir
        both = deepcopy(ramp_doc)
        both["values"]["bucket_edge"] = 12
        @test_throws ArgumentError PeggleSim.load_config(write_doc(dir, "both.json", both))
        partial = deepcopy(ramp_doc)
        delete!(partial["values"], "bucket_catch_hold")
        @test_throws ArgumentError PeggleSim.load_config(write_doc(dir, "partial.json", partial))
        neither = deepcopy(classic_doc)
        delete!(neither["values"], "bucket_edge")
        @test_throws ArgumentError PeggleSim.load_config(write_doc(dir, "neither.json", neither))
        added = deepcopy(classic_doc)
        added["values"]["bucket_rim_width"] = 12
        @test_throws ArgumentError PeggleSim.load_config(write_doc(dir, "added.json", added))
    end
end
