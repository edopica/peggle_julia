# Focused tests for src/bucket.jl (workstream D), porting src/entities/
# bucket.lua from the dev tree. The classic-rules section uses the pinned
# interchange config (`interchange/config.v1.json`, RULES_CLASSIC) on a
# synthetic 880x550 board, which overrides Config.virtual_width -- the
# faithful bucket_update! overload takes that width explicitly.
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

# ---------------------------------------------------------------------------
# 10ee3a0 ramp bucket (RULES_RAMP_BUCKET). Mirrors peggle_evolved
# tests/test_bucket.lua @ 10ee3a0 with the synced campaign config
# (campaigns/ribbon/config.v1.json, exported from 10ee3a0 src/config.lua).
# Bit-exactness against Lua was checked separately with a 20,000-case
# resolve oracle (wiki/context/bucket-ramps.md).
# ---------------------------------------------------------------------------

const RAMP_CONFIG_PATH = PeggleSim.RealLevels.config_path()

function _ramp_config(; overrides...)
    base = PeggleSim.load_config(RAMP_CONFIG_PATH)
    fields = fieldnames(PeggleSim.SimConfig)
    vals = Any[getfield(base, f) for f in fields]
    for (key, value) in pairs(overrides)
        vals[findfirst(==(key), fields)] = value
    end
    return PeggleSim.SimConfig(vals...)
end

function _ramp_setup(c)
    bucket = PeggleSim.BucketState(c.virtual_width, c.virtual_height, c)
    bucket.x = 600.0
    bucket.prev_x = 600.0
    return bucket
end

# Ball moving (x0, y0) -> (x1, y1) this step with velocity (vx, vy).
function _ramp_ball(c, x0, y0, x1, y1, vx, vy)
    b = PeggleSim.BallState(1, Float64(x1), Float64(y1), c.ball_radius)
    b.prev_x = Float64(x0)
    b.prev_y = Float64(y0)
    b.vx = Float64(vx)
    b.vy = Float64(vy)
    b.launched = true
    return b
end

_piece_xs(p) = [p.verts[i] for i in 1:2:(2 * p.nverts)]
_piece_ys(p) = [p.verts[i] for i in 2:2:(2 * p.nverts)]

function _find_piece(bucket, kind, side)
    for p in bucket.pieces
        p.kind == kind || continue
        (side === :left) == (minimum(_piece_xs(p)) < 0) && return p
    end
    return nothing
end

_bounds(p) = (minimum(_piece_xs(p)), maximum(_piece_xs(p)),
              minimum(_piece_ys(p)), maximum(_piece_ys(p)))

@testset "ramp bucket (10ee3a0)" begin
    c = _ramp_config()
    R = c.ball_radius
    @test c.rules === PeggleSim.RULES_RAMP_BUCKET
    BODY, RIM = PeggleSim.BUCKET_PIECE_BODY, PeggleSim.BUCKET_PIECE_RIM

    @testset "geometry follows config" begin
        bucket = _ramp_setup(c)
        @test bucket.ramps
        @test length(bucket.pieces) == 7
        @test bucket.rim_width == c.bucket_rim_width
        drop = c.bucket_height + c.bucket_margin
        @test bucket.top + drop == c.virtual_height
        slope = rad2deg(atan(drop / bucket.ramp_width))
        @test abs(slope - c.bucket_ramp_slope_deg) < 1e-6
        hh = c.bucket_hole / 2
        x0, x1, y0, y1 = _bounds(_find_piece(bucket, RIM, :left))
        @test x1 == -hh
        @test x1 - x0 == c.bucket_rim_width
        @test y0 == 0
        @test y1 == c.bucket_rim_height
        bx0, _, _, by1 = _bounds(_find_piece(bucket, BODY, :left))
        @test bx0 == -hh - c.bucket_rim_width - bucket.ramp_width
        @test by1 == drop
        @test PeggleSim.bucket_half_span(bucket) == hh + c.bucket_rim_width + bucket.ramp_width
        rx0, rx1, _, _ = _bounds(_find_piece(bucket, RIM, :right))
        @test rx0 == hh
        @test rx1 == hh + c.bucket_rim_width
    end

    @testset "ramp starts flush with the rim top (no step)" begin
        bucket = _ramp_setup(c)
        xo = -c.bucket_hole / 2 - c.bucket_rim_width
        ramp = _find_piece(bucket, BODY, :left)
        @test _bounds(ramp)[3] == 0
        @test any(ramp.verts[i] == xo && ramp.verts[i + 1] == 0 for i in 1:2:(2 * ramp.nverts))
        px, py = xo - 0.01, c.bucket_rim_height / 2
        for k in 1:ramp.nedges
            e = ramp.edges[k]
            @test (px - e.ax) * e.nx + (py - e.ay) * e.ny <= 1e-9
        end
    end

    @testset "ball on the ridge slides off outward" begin
        bucket = _ramp_setup(c)
        x = 600 - c.bucket_hole / 2 - c.bucket_rim_width - 3
        b = _ramp_ball(c, x, bucket.top - 20, x, bucket.top + 4, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
        @test b.vx < 0
        @test b.vy < 0
    end

    @testset "config parameters change the shape" begin
        c20 = _ramp_config(bucket_rim_width = 20.0)
        x0, x1, _, _ = _bounds(_find_piece(_ramp_setup(c20), RIM, :left))
        @test x1 - x0 == 20
        c45 = _ramp_config(bucket_ramp_slope_deg = 45.0)
        b45 = _ramp_setup(c45)
        @test abs(b45.ramp_width - (c.bucket_height + c.bucket_margin)) < 1e-9
        shallow = _ramp_setup(_ramp_config(bucket_ramp_slope_deg = 10.0))
        steep = _ramp_setup(_ramp_config(bucket_ramp_slope_deg = 30.0))
        @test shallow.ramp_width > steep.ramp_width
        # A zero rim height removes the (degenerate) rim pieces, as Lua does.
        flat = _ramp_setup(_ramp_config(bucket_rim_height = 0.0))
        @test length(flat.pieces) == 5
        @test _find_piece(flat, RIM, :left) === nothing
    end

    @testset "drop through the opening is caught" begin
        bucket = _ramp_setup(c)
        b = _ramp_ball(c, 600, bucket.top - 20, 600, bucket.top - 2, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :caught
    end

    @testset "drop onto the rim bounces" begin
        bucket = _ramp_setup(c)
        rim_center = 600 - c.bucket_hole / 2 - c.bucket_rim_width / 2
        b = _ramp_ball(c, rim_center, bucket.top - 20, rim_center, bucket.top + 1, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
        @test b.vy < 0
        @test abs(b.vx) < 1e-9
        @test b.y + R <= bucket.top + 1e-6
    end

    @testset "fast ball does not tunnel through the rim" begin
        bucket = _ramp_setup(c)
        rim_center = 600 - c.bucket_hole / 2 - c.bucket_rim_width / 2
        b = _ramp_ball(c, rim_center, bucket.top - 12, rim_center, bucket.top + 18, 0, 1800)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
        @test b.vy < 0
        @test b.y < bucket.top
    end

    @testset "ramps deflect outward, mirrored" begin
        bucket = _ramp_setup(c)
        hh = c.bucket_hole / 2
        x = 600 - hh - c.bucket_rim_width - bucket.ramp_width / 2
        b = _ramp_ball(c, x, bucket.top - 10, x, bucket.top + 20, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
        @test b.vx < 0
        rb = _ramp_ball(c, 1200 - x, bucket.top - 10, 1200 - x, bucket.top + 20, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, rb, c) === :bounced
        @test rb.vx > 0
        @test rb.vx == -b.vx
    end

    @testset "inner corner with the center over the opening is caught" begin
        bucket = _ramp_setup(c)
        x = 600 - c.bucket_hole / 2 + 2
        b = _ramp_ball(c, x, bucket.top - 20, x, bucket.top + 2, 0, 900)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :caught
    end

    @testset "moving bucket pushes a resting ball" begin
        bucket = _ramp_setup(c)
        x0 = c.bucket_hole / 2 + c.bucket_rim_width
        rw, drop = bucket.ramp_width, bucket.ramp_height
        L = sqrt(rw * rw + drop * drop)
        nx, ny = drop / L, -rw / L
        mx, my = x0 + rw / 2, drop / 2
        bx = 600 + mx + nx * (R + 1)
        by = bucket.top + my + ny * (R + 1)
        b = _ramp_ball(c, bx, by, bx, by, 0, 0)
        bucket.prev_x, bucket.x = 600.0, 605.0
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
        dist = (b.x - bucket.x - x0) * nx + (b.y - bucket.top) * ny
        @test dist >= R - 1e-6
    end

    @testset "broad phase misses leave the ball unchanged" begin
        bucket = _ramp_setup(c)
        half = PeggleSim.bucket_half_span(bucket)
        for delta in (-1e-7, 0.0, 1e-7)
            for side in (-1, 1)
                x = bucket.x + side * (half + R + 1 + delta)
                y = bucket.top + bucket.height / 2
                b = _ramp_ball(c, x, y, x, y, -side * 120, 200)
                @test PeggleSim.bucket_resolve!(bucket, b, c) === :none
                @test (b.x, b.y, b.vx, b.vy) == (x, y, -side * 120, 200)
            end
            for gap in (R + 1 + delta, 2 * R + 1 + delta)
                x, y = bucket.x, bucket.top - gap
                b = _ramp_ball(c, x, y - 20, x, y, 120, 200)
                @test PeggleSim.bucket_resolve!(bucket, b, c) === :none
                @test (b.x, b.y, b.vx, b.vy) == (x, y, 120, 200)
            end
        end
    end

    @testset "broad phase keeps crossings and start overlaps" begin
        bucket = _ramp_setup(c)
        half = PeggleSim.bucket_half_span(bucket)
        for side in (-1, 1)
            # Both endpoints miss, but the swept circle crosses the bucket.
            x0 = bucket.x + side * (half + R + 10)
            x1 = bucket.x - side * (half + R + 10)
            y = bucket.top + bucket.height / 2
            b = _ramp_ball(c, x0, y, x1, y, -side * 9000, 0)
            @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
            # An overlap at the start suppresses the sweep even when the
            # current position has moved safely above the broad phase box.
            x = bucket.x + side * (bucket.hole / 2 + bucket.rim_width / 2)
            b = _ramp_ball(c, x, bucket.top + 1, x, bucket.top - R - 2, 0, -900)
            @test PeggleSim.bucket_resolve!(bucket, b, c) === :none
        end
        # A stationary ball crossed by a moving bucket uses bucket.prev_x.
        bucket.prev_x = bucket.x - 2 * (half + R + 10)
        x = (bucket.x + bucket.prev_x) / 2
        y = bucket.top + bucket.height / 2
        b = _ramp_ball(c, x, y, x, y, 0, 0)
        @test PeggleSim.bucket_resolve!(bucket, b, c) === :bounced
    end

    @testset "resolution is deterministic and allocation-free" begin
        function run()
            bucket = _ramp_setup(c)
            out = Tuple{Symbol,Float64,Float64,Float64,Float64}[]
            for i in 0:40
                x = 520 + i * 4
                b = _ramp_ball(c, x - 3, bucket.top - 15, x, bucket.top + 9, 180, 1200)
                r = PeggleSim.bucket_resolve!(bucket, b, c)
                push!(out, (r, b.x, b.y, b.vx, b.vy))
            end
            return out
        end
        @test isequal(run(), run())
        bucket = _ramp_setup(c)
        b = _ramp_ball(c, 597, bucket.top - 15, 600, bucket.top + 9, 180, 1200)
        PeggleSim.bucket_resolve!(bucket, b, c)
        b2 = _ramp_ball(c, 547, bucket.top - 15, 550, bucket.top + 9, 180, 1200)
        @test (@allocated PeggleSim.bucket_resolve!(bucket, b2, c)) == 0
        @test (@allocated PeggleSim.bucket_update!(bucket, c.fixed_dt, c, 1200.0)) == 0
    end

    @testset "checkpoint round trip keeps the model and rebuilds nothing" begin
        level = PeggleSim.load_level(PeggleSim.RealLevels.artifact_path("b2"))
        prov = (reference_revision = "r", reference_tree = "t",
                config_sha256 = c.source_sha256, level_sha256 = level.level_sha256)
        ckpt = PeggleSim.build_checkpoint(level, c; provenance = prov)
        d = PeggleSim.checkpoint_to_dict(ckpt)["engine"]["bucket"]
        @test sort(collect(keys(d))) == sort(["x", "prev_x", "top", "hole", "rim_width",
            "rim_height", "ramp_width", "ramp_height", "height", "floor", "phase"])
        parsed = PeggleSim.checkpoint_from_dict(PeggleSim.checkpoint_to_dict(ckpt))
        @test PeggleSim.first_difference(parsed, ckpt) === nothing
        sim = PeggleSim.sim_from_checkpoint(parsed)
        fresh = PeggleSim.BucketState(level.virtual_width, level.virtual_height, c)
        @test sim.engine.bucket.ramps
        @test sim.engine.bucket.pieces == fresh.pieces
        @test sim.engine.bucket.collision_half_span == PeggleSim.bucket_half_span(fresh)
        pieces = sim.engine.bucket.pieces
        PeggleSim.restore!(sim, parsed)
        @test sim.engine.bucket.pieces === pieces
        @test pieces == fresh.pieces
        # A different checkpoint's dimensions rebuild the derived bounds too.
        wide_c = _ramp_config(bucket_rim_width = 30.0)
        wide_ckpt = PeggleSim.build_checkpoint(level, wide_c; provenance = prov)
        PeggleSim.restore!(sim, wide_ckpt)
        @test sim.engine.bucket.collision_half_span == PeggleSim.bucket_half_span(sim.engine.bucket)
        @test sim.engine.bucket.collision_half_span > fresh.collision_half_span
        PeggleSim.restore!(sim, parsed)
        @test sim.engine.bucket.collision_half_span == fresh.collision_half_span
        # Classic config and ramp checkpoint are refused together.
        classic = PeggleSim.load_config(BUCKET_CONFIG_PATH)
        @test_throws ArgumentError PeggleSim.shot_engine(ckpt; config = classic, level = level)
    end
end
