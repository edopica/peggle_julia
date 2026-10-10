using Test
using JSON
using PeggleSim

const LEVEL_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const LEVEL_ARTIFACT_DIR = joinpath(LEVEL_REPO_ROOT, "interchange", "levels")
const LEVEL_CONFIG_PATH = joinpath(LEVEL_REPO_ROOT, "interchange", "config.v1.json")
const LEVEL_MANIFEST_PATH =
    joinpath(LEVEL_REPO_ROOT, "interchange", "files.sha256")

const STATIC_LEVEL_NAMES = (
    "circle_level",
    "double_long_shot",
    "long_shot",
    "lucky_bounce",
    "off_the_wall",
    "slide",
    "squiggly_circle",
    "super_long_shot",
)

function _level_manifest_hashes()
    hashes = Dict{String,String}()
    for line in eachline(LEVEL_MANIFEST_PATH)
        m = match(r"^([0-9a-f]{64})\s+\./levels/([A-Za-z0-9_]+)\.v1\.json$", line)
        m === nothing && continue
        hashes[m.captures[2]] = m.captures[1]
    end
    return hashes
end

@testset "level artifacts" begin
    manifest = _level_manifest_hashes()
    @test length(manifest) == length(STATIC_LEVEL_NAMES)

    for name in STATIC_LEVEL_NAMES
        path = joinpath(LEVEL_ARTIFACT_DIR, name * ".v1.json")
        @test isfile(path)
        level = PeggleSim.load_level(path)

        @test level.name == name
        @test level.virtual_width > 0
        @test level.virtual_height > 0
        @test level.default_peg_type in (:blue, :green, :purple, :red)
        @test !isempty(level.pegs)

        # Contiguous ids in engine order.
        @test [p.id for p in level.pegs] == collect(1:length(level.pegs))
        @test all(p.base_x == p.x && p.base_y == p.y for p in level.pegs)

        # Effective type counts cover the whole board in the frozen order.
        tc = level.type_counts
        @test tc == (
            blue = tc.blue, green = tc.green, purple = tc.purple, red = tc.red)
        @test tc.blue + tc.green + tc.purple + tc.red == length(level.pegs)
        @test all(p.peg_type in (:blue, :green, :purple, :red) for p in level.pegs)
        @test all(!p.hit for p in level.pegs)

        for peg in level.pegs
            shape = peg.shape
            if shape isa PeggleSim.CircleShape
                @test shape.radius >= 0
            elseif shape isa PeggleSim.RectangleShape
                @test shape.width >= 0
                @test shape.height >= 0
                @test shape.angle isa Float64
            elseif shape isa PeggleSim.AnnularShape
                @test shape.r_in >= 0
                @test shape.r_out >= shape.r_in
                @test shape.segments >= 4
                @test shape.theta_end_abs > shape.theta_start
            else
                @test false
            end
            if peg.line !== nothing
                line = peg.line
                @test !isempty(line.id)
                @test 1 <= line.index <= line.count
                @test line.count >= 1
                @test line.gap >= 0
            end
        end

        # Artifact-byte hash matches the manifest and the parser's own hash.
        @test PeggleSim.level_sha256(path) == manifest[name]
        @test level.level_sha256 == manifest[name]
    end

    # Shape coverage: slide has all three shapes; squiggly_circle is annular.
    slide = PeggleSim.load_level(joinpath(LEVEL_ARTIFACT_DIR, "slide.v1.json"))
    @test any(p.shape isa PeggleSim.CircleShape for p in slide.pegs)
    @test any(p.shape isa PeggleSim.RectangleShape for p in slide.pegs)
    @test any(p.shape isa PeggleSim.AnnularShape for p in slide.pegs)
    @test any(p.line !== nothing for p in slide.pegs)
    squiggly =
        PeggleSim.load_level(joinpath(LEVEL_ARTIFACT_DIR, "squiggly_circle.v1.json"))
    @test all(p.shape isa PeggleSim.AnnularShape for p in squiggly.pegs)
end

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
    for key in PeggleSim.CONFIG_VALUE_KEYS
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

    # Convenience constants used by the construction path.
    @test config.purple_pegs_per_turn isa Int
    @test config.starting_balls isa Int
    @test config.fixed_dt > 0

    # Every level artifact records the same pinned config hash.
    for name in STATIC_LEVEL_NAMES
        level = PeggleSim.load_level(joinpath(LEVEL_ARTIFACT_DIR, name * ".v1.json"))
        @test level.provenance.config_sha256 == config.source_sha256
        @test endswith(level.provenance.level_source, "levels/" * name * ".lua")
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
