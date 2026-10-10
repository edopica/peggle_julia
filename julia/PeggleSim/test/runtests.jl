using Test
using PeggleSim

@testset "PeggleSim" begin
    testdir = @__DIR__
    testfiles = sort(filter(
        f -> startswith(f, "test_") && endswith(f, ".jl") && isfile(joinpath(testdir, f)),
        readdir(testdir),
    ))
    @test !isempty(testfiles)
    for f in testfiles
        include(joinpath(testdir, f))
    end
end
