using Test
using PeggleSim
import JSON

# Cross-machine parity manifest (WP-F; repaired for WP-D).
#
# The authoritative section must be recomputed identically on every run; the
# environment section is explicitly non-authoritative. These tests run the
# manifest twice and compare, verify the computed RNG/color evidence and the
# reset records, and exercise the first-difference reporter on deliberately
# flipped values.

const PARITY_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const PARITY_CENSUS = joinpath(
    PARITY_REPO_ROOT, "fixtures", "math_census", "math_census.v1.json")

@testset "Parity manifest" begin
    if !isfile(PARITY_CENSUS)
        println("test_parity: SKIP: fixture absent at $(PARITY_CENSUS); " *
                "run scripts/capture_math_census.sh first")
        @test_skip true
    else
        man1 = PeggleSim.parity_manifest(; repo = PARITY_REPO_ROOT, label = "test-a")
        man2 = PeggleSim.parity_manifest(; repo = PARITY_REPO_ROOT, label = "test-b")

        auth1 = PeggleSim.parity_authoritative(man1)
        auth2 = PeggleSim.parity_authoritative(man2)
        @test auth1 == auth2
        @test canonical_json(auth1) == canonical_json(auth2)

        @test man1["identity"]["format"] == "peggle.parity"
        @test man1["identity"]["schema_version"] == 2
        # Comparison prerequisites are identical across independent builds.
        prereq1 = man1["identity"]["prerequisites"]
        prereq2 = man2["identity"]["prerequisites"]
        @test prereq1 == prereq2
        # The prerequisite carries the platform-independent component identity
        # only; per-platform artifact bytes never enter it.
        @test !haskey(prereq1["math_backend"], "artifact_sha256")
        @test !haskey(prereq1["math_backend"], "platform")
        @test auth1["math_census"]["verified"] === true
        @test auth1["math_census"]["mismatches"] == 0
        @test auth1["math_census"]["total_cases"] > 0

        @test auth1["rng_sequences"]["verified"] === true
        @test auth1["rng_sequences"]["mismatches"] == 0
        @test auth1["rng_sequences"]["checked"] > 0
        @test auth1["peg_colors"]["verified"] === true
        @test auth1["peg_colors"]["mismatches"] == 0
        @test auth1["peg_colors"]["checked"] > 0
        @test length(auth1["levels"]) == 8
        @test length(auth1["geometry"]) == 9
        @test length(auth1["reset"]) == 9
        @test Set(keys(auth1["geometry"])) == Set(keys(auth1["reset"]))
        @test auth1["reset_deterministic"] === true

        for (label, record) in auth1["reset"]
            @test record["restored_matches_original"] === true
            @test length(record["restored_sha256"]) == 2
            @test record["restored_sha256"][1] == record["restored_sha256"][2]
            @test record["restored_sha256"][1] == record["checkpoint_sha256"]
            @test record["checkpoint_sha256"] == auth1["geometry"][label]
            @test record["mutated_sha256"] != record["checkpoint_sha256"]
        end

        # The environment carries the label and never enters authoritative.
        @test man1["environment"]["label"] == "test-a"
        @test man2["environment"]["label"] == "test-b"
        @test !haskey(auth1, "environment")
        @test !haskey(auth1, "hostname")

        # Flipped values are located at the expected JSON path.
        @test PeggleSim.first_parity_difference(man1, man1) === nothing

        flipped = deepcopy(man1)
        flipped["authoritative"]["math_census"]["verified"] = false
        @test PeggleSim.first_parity_difference(man1, flipped) ==
              "authoritative.math_census.verified"

        flipped2 = deepcopy(man1)
        flipped2["authoritative"]["geometry"]["circle_level"] = "0"^64
        @test PeggleSim.first_parity_difference(man1, flipped2) ==
              "authoritative.geometry.circle_level"

        flipped3 = deepcopy(auth1)
        flipped3["reset"]["slide"]["restored_sha256"][2] = "f"^64
        @test PeggleSim.first_parity_difference(auth1, flipped3) ==
              "reset.slide.restored_sha256[2]"

        flipped4 = deepcopy(man1)
        flipped4["authoritative"]["rng_sequences"]["computed_sha256"] = "0"^64
        @test PeggleSim.first_parity_difference(man1, flipped4) ==
              "authoritative.rng_sequences.computed_sha256"

        # write_parity emits canonical JSON plus one newline.
        mktempdir() do dir
            path = joinpath(dir, "nested", "manifest.json")
            PeggleSim.write_parity(man1, path)
            text = read(path, String)
            @test endswith(text, "\n")
            @test text == canonical_json(man1) * "\n"
            parsed = JSON.parsefile(path)
            @test parsed["authoritative"] == JSON.parse(canonical_json(auth1))
        end
    end
end

# Experimental fixture path overrides (WP-D parity manifest repair): a
# manifest built from override fixtures verifies them, hashes them, and
# records their effective path in identity.prerequisites so cross-host
# comparisons require identical inputs. The historical default records no
# path keys (byte-identical default behavior).
@testset "Parity fixture overrides" begin
    mktempdir() do dir
        census = joinpath(dir, "math_census.v1.json")
        rng = joinpath(dir, "rng_sequences.v1.json")
        colors = joinpath(dir, "peg_colors.v1.json")

        inputs = Dict{String,Any}()
        expected = Dict{String,Any}()
        counts = Dict{String,Any}()
        for spec in PeggleSim.PARITY_CENSUS_UNARY
            inputs[spec.name] = Any[0.5]
            expected[spec.name] = Any[PeggleSim.float_bits_hex(spec.det(0.5))]
            counts[spec.name] = 1
        end
        for spec in PeggleSim.PARITY_CENSUS_BINARY
            inputs[spec.a] = Any[0.5]
            inputs[spec.b] = Any[0.25]
            expected[spec.name] = Any[PeggleSim.float_bits_hex(spec.det(0.5, 0.25))]
            counts[spec.name] = 1
        end
        write(census, canonical_json(Dict{String,Any}(
            "format" => "peggle.math_census",
            "schema_version" => 1,
            "counts" => counts,
            "inputs" => inputs,
            "expected" => expected,
        )) * "\n")
        write(rng, "{}\n")
        write(colors, "{}\n")

        man = PeggleSim.parity_manifest(; repo = PARITY_REPO_ROOT,
                                        label = "override",
                                        census_path = census,
                                        rng_path = rng,
                                        colors_path = colors)
        auth = PeggleSim.parity_authoritative(man)
        @test auth["math_census"]["fixture_sha256"] == PeggleSim._file_sha256(census)
        @test auth["rng_sequences"]["fixture_sha256"] == PeggleSim._file_sha256(rng)
        @test auth["peg_colors"]["fixture_sha256"] == PeggleSim._file_sha256(colors)

        prereq = man["identity"]["prerequisites"]
        @test prereq["census_fixture_sha256"] == PeggleSim._file_sha256(census)
        @test prereq["rng_sequences_fixture_sha256"] == PeggleSim._file_sha256(rng)
        @test prereq["peg_colors_fixture_sha256"] == PeggleSim._file_sha256(colors)
        # temp fixtures live outside the repository: paths are absolute
        @test prereq["census_fixture_path"] == normpath(abspath(census))
        @test prereq["rng_sequences_fixture_path"] == normpath(abspath(rng))
        @test prereq["peg_colors_fixture_path"] == normpath(abspath(colors))

        # Paths under the repository are recorded repository-relative so two
        # hosts with different checkout roots record the same prerequisite.
        inside = joinpath(PARITY_REPO_ROOT, "tmp", "parity-test", "x.json")
        @test PeggleSim._recorded_fixture_path(PARITY_REPO_ROOT, inside) ==
              joinpath("tmp", "parity-test", "x.json")
        @test PeggleSim._recorded_fixture_path(PARITY_REPO_ROOT, inside) ==
              "tmp/parity-test/x.json"
        @test !occursin('\\', PeggleSim._recorded_fixture_path(PARITY_REPO_ROOT, inside))
        @test PeggleSim._recorded_fixture_path(PARITY_REPO_ROOT, census) ==
              normpath(abspath(census))

        # Recorded paths use `/` separators on every platform. A real
        # backslash path cannot exist under the repository on Linux, so the
        # separator normalizer is covered directly with a Windows spelling.
        @test PeggleSim._normalize_path_separators(
            "results\\core-math\\parity\\math_census.v1.json") ==
            "results/core-math/parity/math_census.v1.json"
        @test PeggleSim._normalize_path_separators(
            "C:\\repo\\results\\core-math\\parity") ==
            "C:/repo/results/core-math/parity"
        @test PeggleSim._normalize_path_separators("already/posix.json") ==
              "already/posix.json"

        # The historical default records no fixture path keys.
        paths = PeggleSim._parity_paths(PARITY_REPO_ROOT)
        pin = PeggleSim._parse_pin(paths.pin)
        config_sha = PeggleSim._config_source_sha256(paths.config)
        identity = PeggleSim._identity(paths, pin, config_sha)
        for key in ("census_fixture_path", "rng_sequences_fixture_path",
                    "peg_colors_fixture_path")
            @test !haskey(identity["prerequisites"], key)
        end
    end
end
