# Focused tests for src/powers.jl (workstream D), porting
# src/systems/powers.lua from the dev tree. The Lua source is deterministic
# arithmetic: no `love.math.random` call site, no Config read. Each green peg
# hit spawns exactly two balls 10 px above the peg at (+/-150, -200).

using Test
using PeggleSim

const POWERS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const POWERS_CONFIG_PATH =
    joinpath(POWERS_REPO_ROOT, "interchange", "config.v1.json")

function _powers_test_peg(id::Int, x::Float64, y::Float64)
    return PeggleSim.Peg(
        id, x, y, x, y, PeggleSim.CircleShape(12.0), :green, false, 0, 0,
        nothing)
end

@testset "powers" begin
    c = PeggleSim.load_config(POWERS_CONFIG_PATH)

    @testset "green peg spawns two deterministic balls" begin
        peg = _powers_test_peg(1, 440.5, 310.25)
        specs = PeggleSim.powers_activate(peg, c)

        @test specs isa Vector{PeggleSim.PowerSpawnSpec}
        @test length(specs) == 2
        @test specs[1].x == 440.5
        @test specs[1].y == 300.25
        @test specs[1].vx == 150.0
        @test specs[1].vy == -200.0
        @test specs[2].x == 440.5
        @test specs[2].y == 300.25
        @test specs[2].vx == -150.0
        @test specs[2].vy == -200.0

        # The peg itself is not mutated.
        @test peg.x == 440.5 && peg.y == 310.25 && !peg.hit
    end

    @testset "representative peg positions" begin
        for (x, y) in ((0.0, 0.0), (100.0, 200.0), (879.75, 549.5))
            specs = PeggleSim.powers_activate(
                _powers_test_peg(2, x, y), c)
            @test length(specs) == 2
            @test specs[1].x == x && specs[2].x == x
            @test specs[1].y == y - 10.0 && specs[2].y == y - 10.0
            @test specs[1].vx == 150.0 && specs[2].vx == -150.0
            @test specs[1].vy == -200.0 && specs[2].vy == -200.0
        end
    end
end
