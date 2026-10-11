# Focused tests for src/bucket.jl (workstream D), porting src/entities/
# bucket.lua from the dev tree. Uses the pinned interchange config
# (`interchange/config.v1.json`) and the mustache level dimensions
# (880x550), which override Config.virtual_width -- the faithful
# bucket_update! overload takes that width explicitly.
#
# Pendulum hand-derivation (Lua formulas, vw = 880, pinned config):
#
#   half      = bucket.hole / 2 + bucket.edge      = 70/2 + 12   = 47
#   center    = vw / 2                             = 880/2      = 440
#   amplitude = center - half                      = 440 - 47   = 393
#   max_accel = bucket_accel_multiplier * vw       = 0.15 * 880 = 132
#   omega     = sqrt(max_accel / amplitude)        = sqrt(132/393)
#                                                  = 0.5795497067512154
#   phase_0   = pi / 2
#   phase_n   = (phase_{n-1} + omega * dt) % (2 * pi)    -- dt = 1/60
#   x_n       = center - amplitude * cos(phase_n)
#
# The reference values below were computed independently with the same
# formula and the same IEEE double operations (libm cos/sqrt, floored
# modulo). The test tolerance is 1e-9 so a non-libm math backend still
# passes; the phase wraps once before step 500 (step 488).

using Test
using PeggleSim

const BUCKET_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const BUCKET_CONFIG_PATH =
    joinpath(BUCKET_REPO_ROOT, "interchange", "config.v1.json")

@testset "bucket" begin
    c = PeggleSim.load_config(BUCKET_CONFIG_PATH)
    vw, vh = 880.0, 550.0

    @testset "construction" begin
        bucket = PeggleSim.BucketState(vw, vh, c)
        @test bucket.x == 440.0
        @test bucket.prev_x == 440.0
        @test bucket.top == vh - c.bucket_margin - c.bucket_height
        @test bucket.top == 494.0
        @test bucket.hole == 70.0
        @test bucket.edge == 12.0
        @test bucket.height == 26.0
        @test bucket.phase == pi / 2
    end

    @testset "pendulum sequence" begin
        bucket = PeggleSim.BucketState(vw, vh, c)
        x_ref = (
            443.79599155128494,
            447.5916289415656,
            451.3865580428802,
            455.1804247933497,
            458.9728752302107,
            462.7635555228403,
            466.5521120057674,
            470.3381912116698,
        )
        for expected in x_ref
            PeggleSim.bucket_update!(bucket, c.fixed_dt, c, vw)
            @test isapprox(bucket.x, expected; atol = 1e-9)
        end
        # After eight steps the wrapped phase is 1.6480696210283927.
        @test isapprox(bucket.phase, 1.6480696210283927; atol = 1e-9)

        # Continue to the first wrapped-phase reference point (step 500).
        for _ in 9:500
            PeggleSim.bucket_update!(bucket, c.fixed_dt, c, vw)
        end
        @test isapprox(bucket.x, 49.69563265564011; atol = 1e-9)
        @test isapprox(bucket.phase, 0.1171919092087143; atol = 1e-9)
        @test 0.0 <= bucket.phase < 2 * pi

        # prev_x is Engine:savePreviousState's job; update must not touch it.
        @test bucket.prev_x == 440.0
    end

    @testset "frozen three-argument interface" begin
        # The frozen signature maps the Lua LevelManager.virtual_width read to
        # c.virtual_width (pinned config: 1200 -> center 600, amplitude 553).
        bucket = PeggleSim.BucketState(vw, vh, c)
        PeggleSim.bucket_update!(bucket, c.fixed_dt, c)
        @test isapprox(bucket.x, 605.2582474910099; atol = 1e-9)
    end

    @testset "caught at the opening" begin
        bucket = PeggleSim.BucketState(vw, vh, c)

        ball = PeggleSim.BallState(1, 430.0, bucket.top + 10.0, c.ball_radius)
        ball.vy = 200.0
        @test PeggleSim.bucket_resolve!(bucket, ball, c) == :caught
        @test ball.x == 430.0 && ball.y == bucket.top + 10.0
        @test ball.vx == 0.0 && ball.vy == 200.0

        # Hole edge inclusive: ball center exactly hole/2 from the center.
        edge_ball =
            PeggleSim.BallState(2, bucket.x + bucket.hole / 2, bucket.top + 1.0,
                                c.ball_radius)
        edge_ball.vy = 50.0
        @test PeggleSim.bucket_resolve!(bucket, edge_ball, c) == :caught

        # Just outside the hole span misses the opening and hits the wall.
        outside_ball =
            PeggleSim.BallState(3, bucket.x + bucket.hole / 2 + 5.0,
                                bucket.top + 10.0, c.ball_radius)
        outside_ball.vy = 0.0
        @test PeggleSim.bucket_resolve!(bucket, outside_ball, c) == :bounced
    end

    @testset "bounced off the rim" begin
        bucket = PeggleSim.BucketState(vw, vh, c)

        # Falling onto the right wall's outer face.
        ball = PeggleSim.BallState(4, bucket.x + 50.0, bucket.top + 13.0,
                                   c.ball_radius)
        ball.vx = -100.0
        @test PeggleSim.bucket_resolve!(bucket, ball, c) == :bounced
        @test ball.x == bucket.x + 53.0
        @test isapprox(ball.vx, 80.0; atol = 1e-12)
        @test ball.vy == 0.0

        # Rising into the base's underside (the hole catches downward balls
        # inside the hole span, so the base is reachable only from below or
        # from the edge columns).
        base_ball = PeggleSim.BallState(5, bucket.x + 20.0,
                                        bucket.top + 39.0, c.ball_radius)
        base_ball.vy = -200.0
        @test PeggleSim.bucket_resolve!(bucket, base_ball, c) == :bounced
        @test base_ball.y == bucket.top + 44.0
        @test isapprox(base_ball.vy, 160.0; atol = 1e-12)
    end

    @testset "no interaction outside" begin
        bucket = PeggleSim.BucketState(vw, vh, c)

        # Far to the left of the bucket, below the opening line.
        far = PeggleSim.BallState(6, 100.0, bucket.top + 10.0, c.ball_radius)
        far.vy = 200.0
        @test PeggleSim.bucket_resolve!(bucket, far, c) == :none
        @test far.x == 100.0 && far.y == bucket.top + 10.0
        @test far.vx == 0.0 && far.vy == 200.0

        # Above the bucket: the opening has not been reached yet.
        above = PeggleSim.BallState(7, bucket.x, bucket.top - 50.0,
                                    c.ball_radius)
        above.vy = 200.0
        @test PeggleSim.bucket_resolve!(bucket, above, c) == :none

        # Rising ball inside the hole span: not caught (vy > 0 required).
        rising = PeggleSim.BallState(8, bucket.x, bucket.top + 10.0,
                                     c.ball_radius)
        rising.vy = -200.0
        @test PeggleSim.bucket_resolve!(bucket, rising, c) == :none
    end
end
