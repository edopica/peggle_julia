# Contract tests for scripts/bench_process.jl: measurement fields, exit-code
# propagation, GNU time preference, and error handling.

using Test
using JSON

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JULIA_EXE = joinpath(Sys.BINDIR, Base.julia_exename())
const BENCH_PROCESS = joinpath(REPO_ROOT, "scripts", "bench_process.jl")
const PROJECT = joinpath(REPO_ROOT, "julia", "PeggleSim")

function run_bench_process(args::Vector{String})
    cmd = Cmd(vcat(String[JULIA_EXE, "--project=$PROJECT", BENCH_PROCESS], args))
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = true)
    return proc.exitcode, String(take!(out)), String(take!(err))
end

@testset "bench_process measures a child and propagates success" begin
    mktempdir() do dir
        out = joinpath(dir, "measurement.json")
        code, stdout, stderr = run_bench_process(String[
            "--out", out, "--label", "smoke", "--",
            JULIA_EXE, "--startup-file=no", "-e", "println(\"child-ok\")",
        ])
        @test code == 0
        @test occursin("child-ok", stdout)
        @test isempty(strip(stderr))
        @test isfile(out)
        measurement = JSON.parsefile(out)
        @test measurement["label"] == "smoke"
        @test measurement["exit_code"] == 0
        @test measurement["command"][end-1:end] == ["-e", "println(\"child-ok\")"]
        @test measurement["peak_rss_kb"] isa Integer
        @test measurement["peak_rss_kb"] > 0
        @test measurement["peak_rss_mb"] > 0
        @test measurement["method"] in ("gnu_time_v", "julia_resource_ru_maxrss")
        @test measurement["wall_seconds"] >= 0
        @test endswith(read(out, String), "\n")
    end
end

@testset "bench_process propagates a failing child exit code" begin
    mktempdir() do dir
        out = joinpath(dir, "measurement.json")
        code, _, _ = run_bench_process(String[
            "--out", out, "--label", "fail", "--",
            JULIA_EXE, "--startup-file=no", "-e", "exit(7)",
        ])
        @test code == 7
        measurement = JSON.parsefile(out)
        @test measurement["exit_code"] == 7
    end
end

@testset "bench_process honors a GNU time-like instrument" begin
    mktempdir() do dir
        fake_time = joinpath(dir, "fake-time")
        write(fake_time, """
        #!/usr/bin/env bash
        # Emulate: time -v -o FILE -- cmd
        [ "\$1" = "-v" ] || exit 90
        [ "\$2" = "-o" ] || exit 91
        out="\$3"
        shift 4
        "\$@"
        code=\$?
        printf 'Maximum resident set size (kbytes): 12345\\n' > "\$out"
        exit \$code
        """)
        chmod(fake_time, 0o755)
        out = joinpath(dir, "measurement.json")
        code, _, _ = run_bench_process(String[
            "--out", out, "--label", "gnu", "--time-bin", fake_time, "--",
            JULIA_EXE, "--startup-file=no", "-e", "exit(0)",
        ])
        @test code == 0
        measurement = JSON.parsefile(out)
        @test measurement["method"] == "gnu_time_v"
        @test measurement["peak_rss_kb"] == 12345
        @test measurement["peak_rss_mb"] == 12.056
        @test measurement["time_tool"] == fake_time
        @test measurement["gnu_time_output"] == out * ".gnu-time.txt"
    end
end

@testset "bench_process usage errors" begin
    code, _, stderr = run_bench_process(String[])
    @test code == 2
    @test occursin("--out", stderr)

    mktempdir() do dir
        code, _, stderr = run_bench_process(String["--out", joinpath(dir, "m.json")])
        @test code == 2
        @test occursin("missing command", stderr)
    end
end

@testset "sync_campaign_config --check is byte-exact" begin
    if Sys.which("luajit") === nothing
        @test_skip "luajit unavailable"
    else
        script = joinpath(REPO_ROOT, "scripts", "sync_campaign_config.jl")
        proc = run(pipeline(ignorestatus(Cmd(String[
            JULIA_EXE, "--project=$PROJECT", script, "--check",
        ])); stdout = devnull, stderr = devnull); wait = true)
        @test proc.exitcode == 0
    end
end
