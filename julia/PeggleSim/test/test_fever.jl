# Focused tests for src/fever_buckets.jl (workstream D), porting
# src/entities/fever_buckets.lua from the dev tree. The constructor state is
# built by state.jl (mustache-sized 880x550 level): five segments of width
# 96 separated by six radius-40 dividers, values 10000/50000/100000.

using Test
using PeggleSim

const FEVER_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const FEVER_CONFIG_PATH =
    joinpath(FEVER_REPO_ROOT, "interchange", "config.v1.json")

@testset "fever buckets" begin
    c = PeggleSim.load_config(FEVER_CONFIG_PATH)
    vw, vh = 880.0, 550.0

    @testset "construction" begin
        f = PeggleSim.FeverBucketsState(c, vw, vh)
        @test f.top == vh
        @test f.target_top == vh
        @test !f.animating
        @test f.height == 40.0

        @test length(f.dividers) == 6
        @test [d.x for d in f.dividers] ==
              [0.0, 176.0, 352.0, 528.0, 704.0, 880.0]
        @test all(d.y == vh for d in f.dividers)
        @test all(d.radius == 40.0 for d in f.dividers)
        @test all(d.is_divider for d in f.dividers)

        @test length(f.buckets) == 5
        @test [b.x for b in f.buckets] ==
              [40.0, 216.0, 392.0, 568.0, 744.0]
        @test all(b.width == 96.0 for b in f.buckets)
        @test [b.value for b in f.buckets] ==
              [10000.0, 50000.0, 100000.0, 50000.0, 10000.0]
    end

    @testset "activation and raise animation" begin
        f = PeggleSim.FeverBucketsState(c, vw, vh)
        PeggleSim.fever_activate!(f)
        @test f.top == vh + f.height + 50.0
        @test f.top == 640.0
        @test f.animating
        @test all(d.y == f.top for d in f.dividers)

        # fever_bucket_raise_speed = 300 px/s at dt = 1/60 -> 5 px/step.
        # 640 -> 550 needs 18 steps; the final step clamps and stops.
        for step in 1:17
            PeggleSim.fever_update!(f, c.fixed_dt, c)
            @test f.top == 640.0 - 5.0 * step
            @test all(d.y == f.top for d in f.dividers)
            @test f.animating
        end
        PeggleSim.fever_update!(f, c.fixed_dt, c)
        @test f.top == f.target_top
        @test !f.animating
        @test all(d.y == f.target_top for d in f.dividers)

        # Once stopped, further updates are no-ops.
        PeggleSim.fever_update!(f, c.fixed_dt, c)
        @test f.top == f.target_top
        @test all(d.y == f.target_top for d in f.dividers)
    end

    @testset "resolve segment values" begin
        f = PeggleSim.FeverBucketsState(c, vw, vh)
        PeggleSim.fever_activate!(f)
        for _ in 1:18
            PeggleSim.fever_update!(f, c.fixed_dt, c)
        end
        @test !f.animating && f.top == 550.0

        caught(x, y, vy) = begin
            ball = PeggleSim.BallState(1, x, y, c.ball_radius)
            ball.vy = vy
            PeggleSim.fever_resolve!(f, ball)
        end

        # One representative x per segment (in order), plus both edges of the
        # second segment.
        for (x, value) in (
            (100.0, 10000.0),
            (300.0, 50000.0),
            (470.0, 100000.0),
            (650.0, 50000.0),
            (800.0, 10000.0),
            (216.0, 50000.0),
            (312.0, 50000.0),
        )
            r = caught(x, f.top + 1.0, 1.0)
            @test r.result == :caught
            @test r.value == value
        end

        # Divider gaps and the outer margins fall back to 10000.
        for x in (20.0, 200.0, 880.0, 312.0000001)
            r = caught(x, f.top + 1.0, 1.0)
            @test r.result == :caught
            @test r.value == 10000.0
        end

        # No interaction above the bank line or without downward velocity.
        r = caught(470.0, f.top, 1.0)
        @test r.result == :none
        @test r.value == 0.0
        r = caught(470.0, f.top + 100.0, 0.0)
        @test r.result == :none
        r = caught(470.0, f.top + 100.0, -1.0)
        @test r.result == :none
    end
end
