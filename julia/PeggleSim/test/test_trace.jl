# Focused tests for src/trace.jl (workstream F), the canonical gameplay
# trace JSONL port of ../peggle_evolved/src/systems/gameplay_trace_exporter.lua.
#
# The encoder rules are byte-level: sorted object keys, %.17g floats,
# integral |v| < 1e15 emitted as integer tokens (including "-0"), NaN/Inf ->
# null, and the Lua string escape order.

using Test
using PeggleSim
using JSON

@testset "trace" begin
    @testset "number and scalar encoding" begin
        @test PeggleSim.trace_json(nothing) == "null"
        @test PeggleSim.trace_json(true) == "true"
        @test PeggleSim.trace_json(false) == "false"
        @test PeggleSim.trace_json(1) == "1"
        @test PeggleSim.trace_json(2.0) == "2"
        @test PeggleSim.trace_json(-0.0) == "-0"
        @test PeggleSim.trace_json(2.5) == "2.5"
        @test PeggleSim.trace_json(0.1) == "0.10000000000000001"
        @test PeggleSim.trace_json(1.0e-14) == "1e-14"
        @test PeggleSim.trace_json(1 / 3) == "0.33333333333333331"
        @test PeggleSim.trace_json(NaN) == "null"
        @test PeggleSim.trace_json(Inf) == "null"
        @test PeggleSim.trace_json(-Inf) == "null"
    end

    @testset "containers and keys" begin
        @test PeggleSim.trace_json(Dict{String,Any}("b" => 1, "a" => 2)) ==
              "{\"a\":2,\"b\":1}"
        @test PeggleSim.trace_json(Any[1, 2.5, nothing]) == "[1,2.5,null]"
        @test PeggleSim.trace_json(Dict{String,Any}()) == "[]"
        @test PeggleSim.trace_json(Any[]) == "[]"
        @test PeggleSim.trace_json(Dict{String,Any}("x" => Any[])) ==
              "{\"x\":[]}"
        nested = Dict{String,Any}(
            "outer" => Dict{String,Any}("inner" => Any[true, 3.0]))
        @test PeggleSim.trace_json(nested) == "{\"outer\":{\"inner\":[true,3]}}"
    end

    @testset "string escaping follows the Lua gsub order" begin
        @test PeggleSim.trace_json("plain") == "\"plain\""
        @test PeggleSim.trace_json("a\"b") == "\"a\\\"b\""
        @test PeggleSim.trace_json("a\\b") == "\"a\\\\b\""
        @test PeggleSim.trace_json("a\nb\tc\rd\be\ff") ==
              "\"a\\nb\\tc\\rd\\be\\ff\""
    end

    @testset "writer header and step records" begin
        directory = mktempdir()
        path = joinpath(directory, "trace.jsonl")
        writer = PeggleSim.trace_open(path; include_snapshot = true)
        @test writer.include_snapshot
        @test writer.steps_written == 0

        record = Dict{String,Any}(
            "schema_version" => 1,
            "kind" => "step",
            "step" => 1,
            "shot_id" => 1,
            "raw_events" => Any[Dict{String,Any}("type" => "ball_launched")],
            "derived_events" => Any[],
            "requested_commands" => Any[],
            "applied_commands" => Any[],
            "snapshot" => Dict{String,Any}("schema_version" => 2),
        )
        PeggleSim.trace_write_step!(writer, record)
        PeggleSim.trace_write_step!(writer, record)
        @test writer.steps_written == 2
        PeggleSim.trace_close!(writer)

        lines = readlines(path)
        @test length(lines) == 3
        header = JSON.parse(lines[1])
        @test header["kind"] == "gameplay_trace"
        @test header["schema_version"] == 1
        @test header["include_snapshot"] === true
        if DetMath.math_backend_identity().backend === :system_libm
            @test lines[1] ==
                  "{\"include_snapshot\":true,\"kind\":\"gameplay_trace\"," *
                  "\"schema_version\":1}"
        else
            @test haskey(header, "math_backend")
        end
        parsed = JSON.parse(lines[2])
        @test parsed["kind"] == "step"
        @test parsed["step"] == 1
        @test parsed["snapshot"]["schema_version"] == 2

        no_snapshot = joinpath(directory, "trace_ns.jsonl")
        writer_ns = PeggleSim.trace_open(no_snapshot; include_snapshot = false)
        PeggleSim.trace_close!(writer_ns)
        @test startswith(readline(no_snapshot), "{\"include_snapshot\":false,")
    end
end
