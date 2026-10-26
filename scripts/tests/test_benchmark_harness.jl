# Tests for the benchmark-execution harness helpers: reservations, exclusive
# archive publication, source snapshots, host metadata, and the harness
# manifest. Ported from scripts/tests/test_benchmark_runner.py (runner-only
# scope; legacy-import tests stay outside the execution harness).

using Test
using JSON

include(joinpath(@__DIR__, "..", "benchmark", "BenchmarkHarness.jl"))
using .BenchmarkHarness

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

@testset "reserve_run collisions do not modify evidence" begin
    for location in ("runs", ".staging", "artifacts")
        mktempdir() do dir
            root = dir
            if location == "artifacts"
                existing = joinpath(root, location, "run.tar.gz")
                mkpath(dirname(existing))
                write(existing, "original")
            else
                existing = joinpath(root, location, "run")
                mkpath(existing)
                write(joinpath(existing, "evidence"), "original")
            end
            @test_throws ErrorException reserve_run(root, "run")
            evidence = location == "artifacts" ? existing : joinpath(existing, "evidence")
            @test read(evidence, String) == "original"
        end
    end
end

@testset "unsafe run ids are rejected" begin
    mktempdir() do dir
        for run_id in ("../old", "/tmp/old", "", ".", "has space", "a/b", "-lead")
            @test_throws ArgumentError reserve_run(dir, run_id)
        end
    end
end

@testset "archive publish never replaces an existing target" begin
    mktempdir() do dir
        source = joinpath(dir, "source")
        write(source, "new")
        target = joinpath(dir, "archive.tar.gz")
        write(target, "old")
        @test_throws Exception create_archive_exclusive(target, [(source, "source")])
        @test read(target, String) == "old"
        @test !ispath(target * ".partial")
    end
end

@testset "archive round-trip and exclusive publish" begin
    mktempdir() do dir
        source = joinpath(dir, "source")
        write(source, "payload")
        target = joinpath(dir, "archive.tar.gz")
        sha, size = create_archive_exclusive(target, [(source, "nested/source.txt")])
        @test isfile(target)
        @test filesize(target) == size
        @test sha256_file(target) == sha
        @test String(archive_member_bytes(target, "nested/source.txt")) == "payload"
        @test archive_member_size(target, "nested/source.txt") == 7
        @test archive_member_bytes(target, "missing") === nothing
        @test !ispath(target * ".partial")
    end
end

@testset "source snapshot retains binary diff and untracked helpers" begin
    mktempdir() do dir
        run(`git init -q $dir`)
        run(`git -C $dir config user.email test@example.com`)
        run(`git -C $dir config user.name Test`)
        mkpath(joinpath(dir, "scripts"))
        tracked = joinpath(dir, "scripts", "tracked.dat")
        write(tracked, UInt8[0x00, 'o', 'l', 'd'])
        run(`git -C $dir add .`)
        run(`git -C $dir commit -qm base`)
        write(tracked, UInt8[0x00, 'n', 'e', 'w'])
        helper = joinpath(dir, "scripts", "new_helper.jl")
        write(helper, "println(\"retained\")\n")

        staging = joinpath(dir, "staging")
        mkpath(staging)
        snapshot, hashes = capture_source_snapshot(dir, staging)

        patch = String(archive_member_bytes(snapshot, "git_diff.patch"))
        @test occursin("GIT binary patch", patch)
        @test String(archive_member_bytes(snapshot, "source/scripts/new_helper.jl")) ==
              read(helper, String)
        inventory = JSON.parse(String(archive_member_bytes(snapshot, "source_files.json")))
        @test inventory["files"] == hashes
        @test hashes["scripts/new_helper.jl"] == sha256_file(helper)
        @test read(joinpath(staging, "git_status.txt"), String) ==
              read(`git -C $dir status --porcelain`, String)
        @test sha256_file(joinpath(staging, "git_diff.patch")) ==
              inventory["git_diff_sha256"]
    end
end

@testset "harness manifest covers simulator and orchestrator" begin
    files = harness_files(REPO_ROOT)
    @test issorted(files)
    @test length(files) == length(unique(files))
    for required in (
        "scripts/run_campaign_benchmark.jl",
        "scripts/bench_process.jl",
        "scripts/bench_process_resource.py",
        "scripts/sync_campaign_config.jl",
        "scripts/benchmark/schema.jl",
        "scripts/benchmark/harness.jl",
        "scripts/benchmark/validator.jl",
        "scripts/benchmark/index.jl",
        "julia/PeggleSim/src/campaign.jl",
        "julia/PeggleSim/src/PeggleSim.jl",
        "julia/PeggleSim/bin/campaign.jl",
        "julia/PeggleSim/Project.toml",
        "campaigns/ribbon/config.source.lua",
        "fixtures/matches/rules.v1.json",
    )
        @test required in files
    end
    # Every manifest entry must exist in this checkout.
    @test all(isfile(joinpath(REPO_ROOT, f)) for f in files)
end

@testset "host metadata fields and RSS extraction" begin
    host = collect_host_metadata()
    for key in ("host_id", "machine", "kernel", "os_release", "cpu_model",
                "cpu_family", "physical_cores", "cpu_threads",
                "total_memory_bytes", "cpu_governors", "allowed_cpus",
                "cgroup_cpuset", "lscpu")
        @test haskey(host, key)
    end
    @test host["physical_cores"] >= 1
    @test host["cpu_threads"] >= host["physical_cores"]
    @test !isempty(host["host_id"])

    @test extract_rss_bytes(["Name:\tcampaign", "VmRSS:\t  2048 kB", "VmHWM:\t4096 kB"]) ==
          string(2048 * 1024)
    @test extract_rss_bytes(String[]) == ""
    @test extract_rss_bytes(["VmRSS:\tnope kB"]) == ""
end

@testset "canonical history and CSV round-trip" begin
    run_dir = joinpath(REPO_ROOT, "results", "benchmarks", "runs",
                       "20261025T093415Z_omarchy_v_beb3")
    if isdir(run_dir)
        manifest = load_manifest(joinpath(run_dir, "manifest.json"))
        history = joinpath(REPO_ROOT, manifest["artifacts"]["canonical_gameplay_history"]["path"])
        expected = basename(history)[1:end-5]
        @test sha256_file(history) == expected
        mktempdir() do dir
            sha, path = save_canonical_gameplay_history(dir, JSON.parsefile(history))
            @test sha == expected
            @test read(path) == read(history)
        end
        for name in ("trials.csv", "matches.csv")
            table = read_csv_rows(joinpath(run_dir, name))
            rows = [Dict{String,Any}(k => v for (k, v) in row) for row in table.rows]
            mktempdir() do dir
                out = joinpath(dir, name)
                write_csv_rows(out, table.header, rows)
                @test read(out) == read(joinpath(run_dir, name))
            end
        end
    else
        @test_skip "committed benchmark run is unavailable"
    end
end
