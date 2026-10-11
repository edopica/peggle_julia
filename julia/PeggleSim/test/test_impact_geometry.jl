# Focused tests for src/impact_geometry.jl, porting
# ../peggle_evolved/src/systems/impact_geometry.lua (dev tree @ da75225).
# `peg_transform_at_toi` is on the authoritative physics path (peg contact
# event payloads) and the other helpers are pure geometry.

using Test
using PeggleSim

function _impact_peg(id::Int, x::Float64, y::Float64, shape)
    return PeggleSim.Peg(id, x, y, x, y, shape, :blue, false, 0, 0, nothing)
end

@testset "impact geometry" begin
    @testset "static circle transform" begin
        peg = _impact_peg(1, 100.0, 200.0, PeggleSim.CircleShape(9.0))
        x, y, angle, theta =
            PeggleSim.peg_transform_at_toi(peg, 1.0 / 60.0, 0.5)
        @test x === 100.0
        @test y === 200.0
        @test angle === 0.0
        @test theta === nothing
    end

    @testset "rotated rectangle transform at toi" begin
        ang = pi / 3
        peg = _impact_peg(2, 100.0, 200.0,
                          PeggleSim.RectangleShape(40.0, 20.0, ang))
        @test peg.angle == ang
        peg.vx = 10.0
        peg.vy = -20.0
        peg.va = 0.5
        window = 0.4
        toi = 0.25
        back = window * (1 - toi)
        x, y, angle, theta = PeggleSim.peg_transform_at_toi(peg, window, toi)
        @test x == 100.0 - 10.0 * back
        @test y == 200.0 - (-20.0) * back
        @test angle == ang - 0.5 * back
        @test theta === nothing
    end

    @testset "annular transform theta follows theta_start" begin
        shape = PeggleSim.AnnularShape(20.0, 40.0, 0.3, 1.2, 16)
        peg = _impact_peg(3, 50.0, 60.0, shape)
        peg.vx = -4.0
        peg.vy = 8.0
        peg.va = 0.5
        window = 0.4
        toi = 0.25
        back = window * (1 - toi)
        x, y, angle, theta = PeggleSim.peg_transform_at_toi(peg, window, toi)
        @test x == 50.0 - (-4.0) * back
        @test y == 60.0 - 8.0 * back
        @test angle == 0.0 - 0.5 * back
        @test theta == 0.3 - 0.5 * back
    end

    @testset "surface separation signs" begin
        c = PeggleSim.load_config(
            joinpath(normpath(joinpath(@__DIR__, "..", "..", "..")),
                     "interchange", "config.v1.json"))
        r = c.ball_radius

        circle = _impact_peg(1, 100.0, 100.0, PeggleSim.CircleShape(9.0))
        # Center 20 px right of the peg: gap = 20 - 6 - 9 = 5.
        @test PeggleSim.surface_separation(circle, 100.0, 100.0, 0.0, nothing,
                                           120.0, 100.0, r) == 5.0
        # Center 10 px right: penetration = -5.
        @test PeggleSim.surface_separation(circle, 100.0, 100.0, 0.0, nothing,
                                           110.0, 100.0, r) == -5.0

        rect = _impact_peg(2, 200.0, 200.0,
                           PeggleSim.RectangleShape(40.0, 20.0, 0.0))
        # 20 px above the rect center, edge 10 px away: gap = 10 - 6 = 4.
        @test PeggleSim.surface_separation(rect, 200.0, 200.0, 0.0, nothing,
                                           200.0, 180.0, r) == 4.0
        # Ball center on the edge: penetration = -6.
        @test PeggleSim.surface_separation(rect, 200.0, 200.0, 0.0, nothing,
                                           200.0, 210.0, r) == -6.0

        annular = _impact_peg(3, 300.0, 300.0,
                              PeggleSim.AnnularShape(20.0, 40.0, 0.0,
                                                     Float64(pi), 16))
        # Outside the rim (angle pi/2 is inside the [0, pi] span):
        # 50 - 40 - 6 = 4.
        @test PeggleSim.surface_separation(annular, 300.0, 300.0, 0.0, 0.0,
                                           300.0, 350.0, r) == 4.0
        # Inside the hole: 20 - 10 - 6 = 4 (using |r_in - d| - r).
        @test PeggleSim.surface_separation(annular, 300.0, 300.0, 0.0, 0.0,
                                           310.0, 300.0, r) == 4.0
    end

    @testset "wall separation" begin
        @test PeggleSim.wall_separation(1.0, 0.0, 10.0, 50.0, 6.0, 1200.0) == 4.0
        @test PeggleSim.wall_separation(-1.0, 0.0, 1190.0, 50.0, 6.0, 1200.0) == 4.0
        @test PeggleSim.wall_separation(0.0, 1.0, 50.0, 10.0, 6.0, 1200.0) == 4.0
    end
end
