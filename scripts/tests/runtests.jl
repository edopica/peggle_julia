# Julia tests for the benchmark-execution harness.
#
# Run with:
#   julia --project=julia/PeggleSim scripts/tests/runtests.jl
#   make julia-scripts-test
#
# Each test_*.jl file includes scripts/benchmark/BenchmarkHarness.jl itself so
# it can also be run on its own.
using Test

const TEST_DIR = @__DIR__

@testset "benchmark execution harness" begin
    for name in sort(readdir(TEST_DIR))
        startswith(name, "test_") || continue
        endswith(name, ".jl") || continue
        @testset "$name" begin
            include(joinpath(TEST_DIR, name))
        end
    end
end
