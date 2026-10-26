"""Tests for the Julia benchmark validator.

Port of scripts/tests/test_benchmark_validation.py: every case validates a copy
of a committed run under results/benchmarks/runs/ after mutating one piece of
evidence, plus the committed runs themselves.

Run with:
  julia --project=julia/PeggleSim scripts/tests/test_benchmark_validation.jl
"""

using Test
using JSON

const VALIDATION_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

include(joinpath(VALIDATION_ROOT, "scripts", "benchmark", "BenchmarkHarness.jl"))
using .BenchmarkHarness
using .BenchmarkHarness:
    BenchmarkValidator, validate!, read_csv_rows, write_csv_rows,
    sha256_bytes, archive_member_bytes

const VALIDATION_RUNS = joinpath(VALIDATION_ROOT, "results", "benchmarks", "runs")

function validation_committed_run()
    for path in sort(readdir(VALIDATION_RUNS; join=true))
        isdir(path) || continue
        endswith(basename(path), "beb3") && return path
    end
    error("no committed run ending in 'beb3' under $VALIDATION_RUNS")
end

const VALIDATION_ORIGINAL_RUN = validation_committed_run()

function validation_with_run_copy(f)
    return mktempdir() do tmp
        run = joinpath(tmp, basename(VALIDATION_ORIGINAL_RUN))
        cp(VALIDATION_ORIGINAL_RUN, run; force=true)
        f(run)
    end
end

function validation_validate(run; index_path=nothing, root_dir=VALIDATION_ROOT)
    validator = BenchmarkValidator(run; index_path=index_path, root_dir=root_dir)
    valid = validate!(validator)
    return valid, validator
end

function validation_change_json(change, run, name)
    path = joinpath(run, name)
    data = JSON.parsefile(path)
    change(data)
    open(path, "w") do io
        JSON.print(io, data)
    end
    return data
end

function validation_change_csv(change, run, name)
    path = joinpath(run, name)
    table = read_csv_rows(path)
    rows = [Dict{String,String}(row) for row in table.rows]
    change(rows)
    write_csv_rows(path, table.header, rows)
    return rows
end

# Rewrite a manifest as a v2 (fingerprint + run kind + dirty snapshot) record
# whose source_snapshot points at the campaign log archived in the run bundle.
function validation_use_v2_provenance(run)
    manifest = JSON.parsefile(joinpath(run, "manifest.json"))
    archive = joinpath(VALIDATION_ROOT, manifest["artifacts"]["archive_bundle"]["path"])
    member = archive_member_bytes(archive, "campaign.log")
    member === nothing && error("campaign.log missing from $(archive)")
    digest = sha256_bytes(member)
    fingerprint = sha256_bytes(collect(codeunits("a"^64 * "  test/source.py\n")))
    validation_change_json(run, "manifest.json") do data
        source = data["source"]
        source["fingerprint_version"] = "2"
        source["run_kind"] = "exploratory"
        source["git_dirty"] = true
        source["harness_files"] = Dict("test/source.py" => "a"^64)
        source["harness_fingerprint"] = fingerprint
        source["source_snapshot"] = Dict(
            "archive_member" => "campaign.log",
            "sha256" => digest,
            "size_bytes" => length(member),
        )
    end
    return digest, length(member)
end

function validation_report_unexpected(validator)
    @info "unexpected validation errors" validator.errors
    return nothing
end

@testset "benchmark validation" begin
    @testset "committed runs are valid" begin
        runs = sort(filter(isdir, readdir(VALIDATION_RUNS; join=true)))
        @test !isempty(runs)
        for run in runs
            @testset "$(basename(run))" begin
                valid, validator = validation_validate(run)
                @test valid
                valid || validation_report_unexpected(validator)
            end
        end
    end

    @testset "failed check rejects completed run" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"][1]["status"] = "failed"
            end
            valid, validator = validation_validate(run)
            @test !valid
            @test !isempty(validator.errors)
        end
    end

    @testset "missing checks rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"] = Any[]
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "required not_collected rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"][1]["status"] = "not_collected"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "evidence hash is verified inside archive" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"][1]["evidence_sha256"] = "f"^64
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "missing evidence rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"][1]["evidence_path"] = "missing.txt"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "missing evidence checksum rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["checks"][1]["evidence_sha256"] = nothing
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "duplicate checks rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                push!(data["checks"], deepcopy(data["checks"][1]))
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "unsupported manifest schema rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "manifest.json") do data
                data["schema_version"] = "999.0.0"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "unsupported checks schema rejected" begin
        validation_with_run_copy() do run
            validation_change_json(run, "checks.json") do data
                data["schema_version"] = "999.0.0"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "duplicate matches rejected" begin
        validation_with_run_copy() do run
            validation_change_csv(run, "matches.csv") do rows
                rows[2]["match_id"] = rows[1]["match_id"]
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "orphan match rejected" begin
        validation_with_run_copy() do run
            validation_change_csv(run, "matches.csv") do rows
                rows[1]["trial_id"] = "absent"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "table hash must reference artifact" begin
        validation_with_run_copy() do run
            for name in ("matches.csv", "trials.csv")
                validation_change_csv(run, name) do rows
                    for row in rows
                        row["gameplay_sha256"] = "f"^64
                    end
                end
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "match fields must match canonical games" begin
        validation_with_run_copy() do run
            validation_change_csv(run, "matches.csv") do rows
                rows[1]["base_seed"] = "123"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "invalid numeric values do not crash" begin
        for value in ("nan", "-1", "1.5", "nope", "")
            @testset "completed_matches='$value'" begin
                validation_with_run_copy() do run
                    validation_change_csv(run, "trials.csv") do rows
                        rows[1]["completed_matches"] = value
                    end
                    @test !validation_validate(run)[1]
                end
            end
        end
    end

    @testset "nonfinite match duration rejected" begin
        validation_with_run_copy() do run
            validation_change_csv(run, "matches.csv") do rows
                rows[1]["wall_seconds"] = "nan"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "completed run rejects incomplete match" begin
        validation_with_run_copy() do run
            validation_change_csv(run, "matches.csv") do rows
                rows[1]["completed"] = "false"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "failed attempt can retain minimal manifest" begin
        validation_with_run_copy() do run
            validation_change_json(run, "manifest.json") do data
                for key in ("host", "runtime", "source", "workload", "artifacts")
                    delete!(data, key)
                end
                data["status"] = "failed"
            end
            for name in ("trials.csv", "matches.csv", "checks.json")
                rm(joinpath(run, name))
            end
            valid, validator = validation_validate(run)
            @test valid
            valid || validation_report_unexpected(validator)
        end
    end

    @testset "v2 provenance checks archived snapshot" begin
        validation_with_run_copy() do run
            validation_use_v2_provenance(run)
            valid, validator = validation_validate(run)
            @test valid
            valid || validation_report_unexpected(validator)

            validation_change_json(run, "manifest.json") do data
                data["source"]["source_snapshot"]["sha256"] = "f"^64
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "v2 dirty source requires snapshot" begin
        validation_with_run_copy() do run
            validation_use_v2_provenance(run)
            validation_change_json(run, "manifest.json") do data
                delete!(data["source"], "source_snapshot")
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "v2 snapshot size is checked" begin
        validation_with_run_copy() do run
            validation_use_v2_provenance(run)
            validation_change_json(run, "manifest.json") do data
                data["source"]["source_snapshot"]["size_bytes"] = 0
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "v2 fingerprint manifest consistency" begin
        validation_with_run_copy() do run
            validation_use_v2_provenance(run)
            validation_change_json(run, "manifest.json") do data
                data["source"]["harness_fingerprint"] = "f"^64
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "official run cannot have dirty source" begin
        validation_with_run_copy() do run
            validation_use_v2_provenance(run)
            validation_change_json(run, "manifest.json") do data
                data["source"]["run_kind"] = "official"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "run directory identity must match" begin
        validation_with_run_copy() do run
            validation_change_json(run, "manifest.json") do data
                data["run_id"] = "different"
            end
            @test !validation_validate(run)[1]
        end
    end

    @testset "bad manifest type reports error" begin
        validation_with_run_copy() do run
            write(joinpath(run, "manifest.json"), "[]")
            valid, validator = validation_validate(run)
            @test !valid
            @test !isempty(validator.errors)
        end
    end

    @testset "short CSV row reports error" begin
        validation_with_run_copy() do run
            path = joinpath(run, "trials.csv")
            lines = readlines(path)
            fields = split(lines[2], ',')
            lines[2] = join(fields[1:(end - 2)], ',')
            write(path, join(lines, "\n") * "\n")
            @test !validation_validate(run)[1]
        end
    end

    @testset "optional index.csv consistency" begin
        index_path = joinpath(VALIDATION_ROOT, "results", "benchmarks", "index.csv")
        @test isfile(index_path)

        valid, validator = validation_validate(VALIDATION_ORIGINAL_RUN; index_path=index_path)
        @test valid
        valid || validation_report_unexpected(validator)

        validation_with_run_copy() do run
            validation_change_json(run, "manifest.json") do data
                data["benchmark"] = "other_benchmark"
            end
            @test !validation_validate(run; index_path=index_path)[1]
        end

        mktempdir() do tmp
            table = read_csv_rows(index_path)
            rows = [row for row in table.rows if get(row, "run_id", nothing) != basename(VALIDATION_ORIGINAL_RUN)]
            out_path = joinpath(tmp, "index.csv")
            write_csv_rows(out_path, table.header, rows)
            valid, validator = validation_validate(VALIDATION_ORIGINAL_RUN; index_path=out_path)
            @test !valid
            @test any(occursin("not found in index.csv", message) for message in validator.errors)
        end

        mktempdir() do tmp
            table = read_csv_rows(index_path)
            header = [h for h in table.header if h != "manifest_path"]
            out_path = joinpath(tmp, "index.csv")
            rows = [Dict{String,String}(row) for row in table.rows]
            write_csv_rows(out_path, header, rows)
            @test !validation_validate(VALIDATION_ORIGINAL_RUN; index_path=out_path)[1]
        end
    end
end
