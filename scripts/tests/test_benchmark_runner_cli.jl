# CLI contract tests for scripts/run_campaign_benchmark.jl. Full campaign
# execution is covered by the opt-in integration script; these tests are fast
# and exercise pre-run validation.

using Test

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JULIA_EXE = joinpath(Sys.BINDIR, Base.julia_exename())
const RUNNER = joinpath(REPO_ROOT, "scripts", "run_campaign_benchmark.jl")
const PROJECT = joinpath(REPO_ROOT, "julia", "PeggleSim")

function run_runner(args::Vector{String})
    cmd = Cmd(vcat(String[JULIA_EXE, "--project=$PROJECT", RUNNER], args))
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = true)
    return proc.exitcode, String(take!(out)), String(take!(err))
end

@testset "runner validates inputs before reserving a run" begin
    mktempdir() do dir
        code, _, stderr = run_runner(String[
            "--level", joinpath(dir, "absent.json"),
            "--benchmarks-dir", joinpath(dir, "bench"),
        ])
        @test code == 1
        @test occursin("level artifact not found", stderr)
        @test !ispath(joinpath(dir, "bench", ".staging"))
    end

    mktempdir() do dir
        code, _, stderr = run_runner(String[
            "--worker-counts", "1,zero",
            "--benchmarks-dir", joinpath(dir, "bench"),
        ])
        @test code == 1
        @test occursin("invalid worker counts", stderr)
        @test !ispath(joinpath(dir, "bench", ".staging"))
    end
end
