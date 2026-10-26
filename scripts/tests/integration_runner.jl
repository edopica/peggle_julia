#!/usr/bin/env julia
# End-to-end integration check for the Julia benchmark-execution harness.
#
# Runs the real orchestration path once in ignored scratch storage:
# pre-checks, one 1v1 match with no warmup, canonical history, archive,
# manifest, README, staged validation, publish, index, final validation.
#
#   julia --project=julia/PeggleSim scripts/tests/integration_runner.jl
#   make julia-scripts-integration
#
# This is intentionally not part of `runtests.jl`: a campaign takes ~30 s.

using JSON
using Test

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const PROJECT = joinpath(REPO_ROOT, "julia", "PeggleSim")
const JULIA_EXE = joinpath(Sys.BINDIR, Base.julia_exename())

include(joinpath(REPO_ROOT, "scripts", "benchmark", "BenchmarkHarness.jl"))
using .BenchmarkHarness

function run_integration()
    scratch = joinpath(REPO_ROOT, "tmp")
    mkpath(scratch)
    mktempdir(scratch; prefix = "benchmark-integration-") do root
        benchmarks = joinpath(root, "benchmarks")
        run_id = "julia-integration-" * string(getpid())
        cmd = Cmd(String[
            JULIA_EXE, "--project=$PROJECT",
            joinpath(REPO_ROOT, "scripts", "run_campaign_benchmark.jl"),
            "--allow-dirty", "--worker-counts", "1", "--games", "1",
            "--repeats", "1", "--warmup", "none",
            "--mode", "1v1", "--max-turns", "8", "--max-steps", "3600",
            "--workload-id", "ribbon_julia_integration",
            "--benchmark", "ribbon_julia_integration",
            "--run-id", run_id, "--benchmarks-dir", benchmarks,
        ])
        proc = run(pipeline(ignorestatus(cmd); stdout = stdout, stderr = stderr); wait = true)
        @test proc.exitcode == 0

        run_dir = joinpath(benchmarks, "runs", run_id)
        @test isdir(run_dir)
        for required in ("manifest.json", "trials.csv", "matches.csv", "checks.json", "README.md")
            @test isfile(joinpath(run_dir, required))
        end
        @test !ispath(joinpath(benchmarks, ".staging", run_id))
        @test isfile(joinpath(benchmarks, "index.csv"))

        validator = BenchmarkValidator(run_dir; root_dir = REPO_ROOT,
                                       index_path = joinpath(benchmarks, "index.csv"))
        @test validate!(validator)
        @test isempty(validator.errors)

        manifest = load_manifest(joinpath(run_dir, "manifest.json"))
        @test manifest["status"] == "completed"
        @test manifest["source"]["run_kind"] == "exploratory"
        @test manifest["source"]["source_snapshot"] !== nothing
        @test isfile(joinpath(REPO_ROOT, manifest["artifacts"]["archive_bundle"]["path"]))
        println("integration run committed to ", run_dir)
    end
end

@testset "benchmark execution harness integration" begin
    run_integration()
end
