#!/usr/bin/env julia
#
# Tests for scripts/benchmark/index.jl (generate_index).
#
# Run with:
#   julia --project=julia/PeggleSim scripts/tests/test_benchmark_index.jl
#
# These tests deliberately use tiny synthetic runs: they need no reference
# data, no external commands, and no benchmark validation.

using Test
using JSON

include(joinpath(@__DIR__, "..", "benchmark", "BenchmarkHarness.jl"))
using .BenchmarkHarness

const H = BenchmarkHarness

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

function write_manifest(run_dir::AbstractString, manifest)
    mkpath(run_dir)
    write(joinpath(run_dir, "manifest.json"), JSON.json(manifest) * "\n")
    return joinpath(run_dir, "manifest.json")
end

function manifest_for(
    run_id::AbstractString;
    timestamp_utc::AbstractString = "2026-10-25T00:00:00Z",
    benchmark::AbstractString = "ribbon_1v1_campaign",
    workload_id::AbstractString = "unit_workload",
    host_id::AbstractString = "testhost",
    git_revision::AbstractString = "0123456789abcdef",
    status::AbstractString = "completed",
)
    return Dict{String,Any}(
        "schema_version" => "1.0.0",
        "protocol_version" => "1.0.0",
        "run_id" => run_id,
        "benchmark" => benchmark,
        "workload_id" => workload_id,
        "status" => status,
        "timestamp_utc" => timestamp_utc,
        "host" => Dict{String,Any}("host_id" => host_id),
        "source" => Dict{String,Any}("git_revision" => git_revision),
        "runtime" => Dict{String,Any}("julia_version" => "1.12.6", "julia_threads" => 1),
        "workload" => Dict{String,Any}(
            "mode" => "1v1",
            "games" => 1,
            "base_seed" => 20261025,
            "candidate_count" => 1801,
            "level_file" => "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json",
            "level_sha256" => "level-sha",
            "config_file" => "campaigns/ribbon/config.v1.json",
            "config_sha256" => "config-sha",
        ),
        "artifacts" => Dict{String,Any}(),
    )
end

# Values for every TRIALS_CSV_COLUMNS / MATCHES_CSV_COLUMNS field, so README
# regeneration never has to guess a missing table cell.
const TRIAL_VALUES = Dict{String,Any}(
    "trial_id" => "t0000",
    "execution_order" => "0",
    "repeat_index" => "0",
    "mode" => "1v1",
    "workers" => "1",
    "wall_seconds" => "12.500",
    "campaign_setup_and_sim_seconds" => "10.000",
    "verification_and_output_seconds" => "0.2500",
    "sim_phase_seconds" => "8.000",
    "candidate_reset_phase_seconds" => "0.500",
    "selection_phase_seconds" => "0.125",
    "actual_shot_phase_seconds" => "1.500",
    "checkpoint_phase_seconds" => "0.0625",
    "completed_matches" => "1",
    "candidates" => "1801",
    "candidates_per_second" => "144.08",
    "completed_matches_per_hour" => "288.0",
    "decision_mean_seconds" => "0.0125",
    "decision_p50_seconds" => "0.0100",
    "decision_p95_seconds" => "0.0200",
    "process_rss_bytes" => "104857600",
    "process_peak_rss_bytes" => "209715200",
    "allocated_bytes" => "1073741824",
    "gc_collections" => "42",
    "gc_seconds" => "0.500",
    "gameplay_sha256" => "trial-sha",
)

const MATCH_VALUES = Dict{String,Any}(
    "trial_id" => "t0000",
    "repeat_index" => "0",
    "workers" => "1",
    "match_id" => "0",
    "worker_index" => "0",
    "base_seed" => "20261025",
    "bot_seed_1" => "11",
    "bot_seed_2" => "22",
    "gameplay_seed" => "33",
    "turns" => "10",
    "candidates" => "1801",
    "wall_seconds" => "1.500",
    "sim_phase_seconds" => "1.000",
    "termination_reason" => "completed",
    "completed" => "true",
    "winner" => "1",
    "player1_score" => "10",
    "player2_score" => "5",
    "gameplay_sha256" => "match-sha",
)

function write_run_tables(run_dir::AbstractString, run_id::AbstractString)
    trial_row = Dict{String,Any}("run_id" => run_id)
    merge!(trial_row, TRIAL_VALUES)
    match_row = Dict{String,Any}("run_id" => run_id)
    merge!(match_row, MATCH_VALUES)
    H.write_csv_rows(joinpath(run_dir, "trials.csv"), H.TRIALS_CSV_COLUMNS, [trial_row])
    H.write_csv_rows(joinpath(run_dir, "matches.csv"), H.MATCHES_CSV_COLUMNS, [match_row])
    return run_dir
end

# Capture stdout (redirect_stdout needs a real stream, not an IOBuffer).
function capture_stdout(f::Function)
    captured = Ref{Any}(nothing)
    text = mktemp() do path, io
        redirect_stdout(io) do
            captured[] = f()
        end
        flush(io)
        seekstart(io)
        read(io, String)
    end
    return captured[], text
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@testset "benchmark index" begin

    @testset "sorts rows and writes relative manifest paths" begin
        mktempdir() do root
            runs_dir = joinpath(root, "results", "benchmarks", "runs")
            out_path = joinpath(root, "results", "benchmarks", "index.csv")
            mkpath(runs_dir)

            # beta and alpha share a timestamp, so run_id breaks the tie.
            alpha = "20260101T000000Z_alpha"
            beta = "20260101T000000Z_beta"
            gamma = "20260102T000000Z_gamma"
            write_manifest(
                joinpath(runs_dir, beta),
                manifest_for(
                    beta;
                    timestamp_utc = "2026-01-01T00:00:00Z",
                    workload_id = "beta_workload",
                    host_id = "host-beta",
                ),
            )
            write_manifest(
                joinpath(runs_dir, alpha),
                manifest_for(
                    alpha;
                    timestamp_utc = "2026-01-01T00:00:00Z",
                    workload_id = "alpha_workload",
                    host_id = "host-alpha",
                ),
            )
            write_manifest(
                joinpath(runs_dir, gamma),
                manifest_for(gamma; timestamp_utc = "2026-01-02T00:00:00Z"),
            )

            # An existing README must survive update_readme=false.
            write(joinpath(runs_dir, alpha, "README.md"), "keep me\n")

            rows = H.generate_index(runs_dir, out_path, root; update_readme = false)

            @test length(rows) == 3
            @test [row["run_id"] for row in rows] == [alpha, beta, gamma]
            @test [row["workload_id"] for row in rows] ==
                  ["alpha_workload", "beta_workload", "unit_workload"]
            @test [row["host_id"] for row in rows] ==
                  ["host-alpha", "host-beta", "testhost"]

            for row in rows
                @test Set(keys(row)) == Set(H.INDEX_CSV_COLUMNS)
                @test length(row) == length(H.INDEX_CSV_COLUMNS)
                @test row["benchmark"] == "ribbon_1v1_campaign"
                @test row["protocol_version"] == "1.0.0"
                @test row["schema_version"] == "1.0.0"
                @test row["status"] == "completed"
                @test row["git_revision"] == "0123456789abcdef"
            end

            # manifest_path is relative to root_dir.
            @test rows[2]["manifest_path"] ==
                  joinpath("results", "benchmarks", "runs", beta, "manifest.json")

            table = H.read_csv_rows(out_path)
            @test table.header == H.INDEX_CSV_COLUMNS
            @test [row["run_id"] for row in table.rows] == [alpha, beta, gamma]
            @test table.rows[2]["manifest_path"] == rows[2]["manifest_path"]
            @test table.rows[2]["timestamp_utc"] == "2026-01-01T00:00:00Z"

            # update_readme=false leaves existing READMEs alone and creates none.
            @test read(joinpath(runs_dir, alpha, "README.md"), String) == "keep me\n"
            @test !isfile(joinpath(runs_dir, beta, "README.md"))
            @test !isfile(joinpath(runs_dir, gamma, "README.md"))

            # The index is byte-for-byte reproducible and leaves no temp files.
            original = read(out_path)
            H.generate_index(runs_dir, out_path, root; update_readme = false)
            @test read(out_path) == original
            @test sort(readdir(dirname(out_path))) == ["index.csv", "runs"]
        end
    end

    @testset "missing runs directory returns no rows and writes nothing" begin
        mktempdir() do root
            runs_dir = joinpath(root, "does-not-exist")
            out_path = joinpath(root, "index.csv")
            rows, captured = capture_stdout() do
                H.generate_index(runs_dir, out_path, root; update_readme = false)
            end
            @test isempty(rows)
            @test !isfile(out_path)
            @test occursin("Runs directory does not exist", captured)
            @test occursin(runs_dir, captured)
        end
    end

    @testset "empty runs directory writes a header-only index" begin
        mktempdir() do root
            runs_dir = joinpath(root, "runs")
            mkpath(runs_dir)
            out_path = joinpath(root, "index.csv")
            rows = H.generate_index(runs_dir, out_path, root; update_readme = false)
            @test isempty(rows)
            @test isfile(out_path)
            table = H.read_csv_rows(out_path)
            @test table.header == H.INDEX_CSV_COLUMNS
            @test isempty(table.rows)
        end
    end

    @testset "rejects duplicate run IDs and preserves the old index" begin
        mktempdir() do root
            runs_dir = joinpath(root, "runs")
            out_path = joinpath(root, "index.csv")
            # Both directories claim run_id "a": the second is a duplicate.
            write_manifest(joinpath(runs_dir, "a"), manifest_for("a"))
            write_manifest(joinpath(runs_dir, "b"), manifest_for("a"))
            write(out_path, "previous index\n")

            err = try
                H.generate_index(runs_dir, out_path, root; update_readme = false)
                nothing
            catch exception
                exception
            end
            @test err isa ArgumentError
            @test occursin(
                "Duplicate run_id",
                err isa Exception ? sprint(showerror, err) : "",
            )
            @test read(out_path, String) == "previous index\n"
            @test sort(readdir(root)) == ["index.csv", "runs"]
        end
    end

    @testset "rejects run ID / directory mismatches" begin
        mktempdir() do root
            runs_dir = joinpath(root, "runs")
            out_path = joinpath(root, "index.csv")
            write_manifest(joinpath(runs_dir, "directory_name"), manifest_for("other_run_id"))
            write(out_path, "previous index\n")

            err = try
                H.generate_index(runs_dir, out_path, root; update_readme = false)
                nothing
            catch exception
                exception
            end
            @test err isa ArgumentError
            @test occursin(
                "does not match directory",
                err isa Exception ? sprint(showerror, err) : "",
            )
            @test read(out_path, String) == "previous index\n"
        end
    end

    @testset "unreadable manifest preserves the old index" begin
        mktempdir() do root
            runs_dir = joinpath(root, "runs")
            out_path = joinpath(root, "index.csv")
            write_manifest(joinpath(runs_dir, "a"), manifest_for("a"))
            broken_dir = joinpath(runs_dir, "b")
            mkpath(broken_dir)
            write(joinpath(broken_dir, "manifest.json"), "{\n")
            write(out_path, "previous index\n")

            @test_throws ArgumentError H.generate_index(
                runs_dir, out_path, root; update_readme = false
            )
            @test read(out_path, String) == "previous index\n"
        end
    end

    @testset "regenerates README from trials.csv and matches.csv" begin
        mktempdir() do root
            runs_dir = joinpath(root, "runs")
            out_path = joinpath(root, "index.csv")
            run_id = "20260101T000000Z_readme"
            run_dir = joinpath(runs_dir, run_id)
            write_manifest(run_dir, manifest_for(run_id))
            write_run_tables(run_dir, run_id)

            rows = H.generate_index(runs_dir, out_path, root)  # update_readme=true
            @test length(rows) == 1
            @test rows[1]["run_id"] == run_id

            readme_path = joinpath(run_dir, "README.md")
            @test isfile(readme_path)
            text = read(readme_path, String)
            @test !isempty(text)
            @test occursin("Benchmark Run", text)
            @test occursin(run_id, text)
        end
    end

end
