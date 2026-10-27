using Test
using PeggleSim

# Frozen broad-phase formula from before the shared query. isequal below also
# checks the sign of zero in every returned transform and displacement.
function _unshared_broad_phase(ctx, px, py, peg_vx, peg_vy, br)
    ball = ctx.ball
    peg_iter_x = px - peg_vx * ctx.time_remaining
    peg_iter_y = py - peg_vy * ctx.time_remaining
    rel_move_x = ctx.move_x - peg_vx * ctx.time_remaining
    rel_move_y = ctx.move_y - peg_vy * ctx.time_remaining
    dx = ball.x - peg_iter_x
    dy = ball.y - peg_iter_y
    rel_move_len = PeggleSim.DetMath.det_sqrt(
        rel_move_x * rel_move_x + rel_move_y * rel_move_y)
    reach = ball.radius + br + rel_move_len
    dx * dx + dy * dy > reach * reach && return nothing
    return (; dx, dy, rel_move_x, rel_move_y, peg_iter_x, peg_iter_y)
end

@testset "shared static CCD query" begin
    config = PeggleSim.load_config(joinpath(@__DIR__, "..", "..", "..",
                                           "interchange", "config.v1.json"))
    ball = PeggleSim.BallState(1, 0.0, 0.0, 6.0)
    journal = PeggleSim.GameplayJournal()
    ctx = PeggleSim.PhysicsContext([ball], config, 1200.0, journal)
    ctx.ball = ball

    @testset "bit-exact static and moving transforms" begin
        # Includes both zero signs, stationary windows, and nonzero relative
        # motion on either axis. Negative-zero peg velocity must retain the
        # original arithmetic even when it cannot share the positive-zero query.
        motions = (0.0, -0.0, 1.25, -3.5)
        velocities = (0.0, -0.0, 25.0, -40.0)
        for mx in motions, my in motions, dt in (0.0, 1 / 60, 0.25)
            ctx.move_x, ctx.move_y, ctx.time_remaining = mx, my, dt
            PeggleSim.prepare_static_query!(ctx)
            for vx in velocities, vy in velocities, px in (0.0, -0.0, 10.0, 1000.0)
                actual = PeggleSim.broad_phase_common(ctx, px, -0.0, vx, vy, 9.0)
                expected = _unshared_broad_phase(ctx, px, -0.0, vx, vy, 9.0)
                @test isequal(actual, expected)
            end
        end
    end

    @testset "inclusive reach boundary and divider path" begin
        ctx.move_x, ctx.move_y, ctx.time_remaining = 3.0, 4.0, 1 / 60
        PeggleSim.prepare_static_query!(ctx)
        reach = ball.radius + 9.0 + 5.0
        for x in (prevfloat(reach), reach, nextfloat(reach))
            divider = PeggleSim.FeverDivider(x, 0.0, 9.0, true)
            actual = PeggleSim.broad_phase_pass(ctx, divider)
            @test isequal(actual, _unshared_broad_phase(ctx, x, 0.0, 0.0, 0.0, 9.0))
            @test (actual === nothing) == (x > reach)
        end
    end

    @testset "refresh after collision and ball change" begin
        # Successive windows vary displacement, remaining time, and the ball.
        # These are precisely the inputs that change after a CCD collision or
        # when the outer physics loop advances to another ball.
        other = PeggleSim.BallState(2, 12.0, -4.0, 3.0)
        for (active_ball, mx, my, dt) in (
                (ball, 100.0, -20.0, 1 / 60),
                (ball, -8.0, 3.0, 1 / 120),
                (other, 0.0, -0.0, 1 / 60))
            ctx.ball = active_ball
            ctx.move_x, ctx.move_y, ctx.time_remaining = mx, my, dt
            PeggleSim.prepare_static_query!(ctx)
            for (x, y) in ((0.0, 0.0), (15.0, -5.0), (200.0, 100.0))
                @test isequal(PeggleSim.broad_phase_common(ctx, x, y, 0.0, 0.0, 9.0),
                              _unshared_broad_phase(ctx, x, y, 0.0, 0.0, 9.0))
            end
        end
    end
end
