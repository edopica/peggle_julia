# Focused tests for src/slide_inversion.jl (workstream E), porting the
# dev-tree unit tests ../peggle_evolved/tests/test_slide_inversion.lua to the
# real GameplayJournal / GameplayCommands API. A real SimConfig is loaded from
# the mustache dev fixture.

using Test
using PeggleSim

const SI_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const SI_CONFIG_PATH =
    joinpath(SI_REPO_ROOT, "fixtures", "mustache", "config.dev.v1.json")

_si_line(id; index = 1, count = 3, closed = false, gap = 0) = Dict{String,Any}(
    "id" => id, "index" => index, "count" => count,
    "closed" => closed, "gap" => gap)

function _si_trackers()
    t = PeggleSim.SlideInversionTrackers()
    PeggleSim.reset_shot!(t)
    return t
end

function _si_ball(id::Int; vx = 0.0, vy = 0.0, launched = true)
    b = PeggleSim.BallState(id, 0.0, 0.0, 6.0)
    b.vx = vx
    b.vy = vy
    b.launched = launched
    return b
end

function _si_contact(peg_id::Int; line = _si_line("arc"), normal_x = 1.0,
                     normal_y = 0.0, did_bounce = false)
    return (; peg_id, line, normal_x, normal_y, did_bounce)
end

function _si_scored(peg_id::Int, impact_y; line = _si_line("arc"))
    return (; peg_id, impact_y, line)
end

# Run one processor step over a fresh journal/commands pair.
function _si_step!(t, ball, contacts, scored, c)
    j = PeggleSim.GameplayJournal()
    cmds = PeggleSim.GameplayCommands()
    PeggleSim.begin_step!(j, 1, 1)
    PeggleSim.begin_step!(cmds, 1, 1)
    for ct in contacts
        PeggleSim.emit_raw!(j, "ball_contacted_peg", Dict{String,Any}(
            "ball_id" => ball.id, "peg_id" => ct.peg_id, "line" => ct.line,
            "normal_x" => ct.normal_x, "normal_y" => ct.normal_y,
            "did_bounce" => ct.did_bounce,
            "impact_x" => 0.0, "impact_y" => 0.0))
    end
    PeggleSim.seal_raw!(j)
    for s in scored
        fields = Dict{String,Any}(
            "ball_id" => ball.id, "peg_id" => s.peg_id,
            "line" => s.line)
        s.impact_y === nothing || (fields["impact_y"] = Float64(s.impact_y))
        PeggleSim.emit_derived!(j, "peg_scored", fields)
    end
    PeggleSim.slide_inversion_process!(t, j, cmds, [ball], c.fixed_dt, c)
    PeggleSim.finish_step!(j)
    return cmds
end

const SI_CONTACTS = [_si_contact(11), _si_contact(12), _si_contact(13)]
_si_hits(y1, y2, y3) = [_si_scored(11, y1), _si_scored(12, y2), _si_scored(13, y3)]

@testset "slide inversion" begin
    c = PeggleSim.load_config(SI_CONFIG_PATH)

    @testset "inversion removes the lowest hit peg" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        @test t.track[1]["line_id"] == "arc"
        @test t.track[1]["tangent_sign"] == 1
        @test length(t.line_hits["arc"]) == 3

        b.vy = 50.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["tangent_sign"] == 1

        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test length(cmds.commands) == 1
        cmd = cmds.commands[1]
        @test cmd["type"] == "remove_slide_pegs"
        @test cmd["ball_id"] == 1
        @test cmd["line_id"] == "arc"
        @test cmd["reason"] == "slide_direction_inversion"
        @test cmd["peg_ids"] == [12]
        @test t.removed[12] === true
        @test !haskey(t.removed, 11) && !haskey(t.removed, 13)
        @test t.track[1]["tangent_sign"] == -1
    end

    @testset "ties within lowest_tie are all removed" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 200.5), c)
        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["peg_ids"] == [12, 13]
        @test t.removed[12] === true && t.removed[13] === true
    end

    @testset "same direction slow-down does not trigger" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        b.vy = 50.0
        _si_step!(t, b, SI_CONTACTS, [], c)
        b.vy = 300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["tangent_sign"] == 1
    end

    @testset "a genuine bounce resyncs instead of triggering" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        b.vy = -300.0
        bounced = [_si_contact(11; did_bounce = true),
                   _si_contact(12; did_bounce = true),
                   _si_contact(13; did_bounce = true)]
        cmds = _si_step!(t, b, bounced, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["tangent_sign"] == -1
        @test isempty(t.removed)
    end

    @testset "tangent epsilon holds the direction" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        # |tang| below the epsilon: sign unknown, direction held.
        b.vy = 1.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["tangent_sign"] == 1
        # The opposite sign after the held apex is a reversal.
        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test length(cmds.commands) == 1
    end

    @testset "contact timeout clears the slide" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        @test haskey(t.track, 1)
        b.vy = 100.0
        _si_step!(t, b, [], [], c)
        @test t.track[1]["no_contact_time"] == c.fixed_dt
        @test t.track[1]["no_contact_time"] <= c.slide_invert_contact_timeout

        steps = ceil(Int, c.slide_invert_contact_timeout / c.fixed_dt) + 2
        for _ in 1:steps
            _si_step!(t, b, [], [], c)
        end
        @test !haskey(t.track, 1)

        # A new slide after the gap starts fresh: no inversion.
        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["tangent_sign"] == -1
    end

    @testset "switching lines restarts tracking" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        b.vy = -300.0
        other = [_si_contact(11; line = _si_line("rail")),
                 _si_contact(12; line = _si_line("rail"))]
        cmds = _si_step!(t, b, other, [], c)
        @test isempty(cmds.commands)
        @test t.track[1]["line_id"] == "rail"
        @test t.track[1]["tangent_sign"] == -1
    end

    @testset "already-removed pegs are skipped" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        b.vy = -300.0
        first = _si_step!(t, b, SI_CONTACTS, [], c)
        @test first.commands[1]["peg_ids"] == [12]

        # Second apex: the lowest remaining hit peg is 13 (y 150).
        b.vy = -50.0
        _si_step!(t, b, SI_CONTACTS, [], c)
        b.vy = 300.0
        second = _si_step!(t, b, SI_CONTACTS, [], c)
        @test length(second.commands) == 1
        @test second.commands[1]["peg_ids"] == [13]
        @test t.removed[13] === true
    end

    @testset "no eligible pegs means no command" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, [], c)
        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
        @test isempty(t.removed)
        # The direction was still updated by the reversal.
        @test t.track[1]["tangent_sign"] == -1
    end

    @testset "first-hit scoring records each peg once" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        dup = [_si_scored(11, 100.0), _si_scored(11, 101.0),
               _si_scored(12, 200.0)]
        _si_step!(t, b, SI_CONTACTS, dup, c)
        @test length(t.line_hits["arc"]) == 2
        @test t.line_hits["arc"][1]["peg_id"] == 11
        @test t.line_hits["arc"][1]["impact_y"] == 100.0
        @test t.hit_seen[11] === true

        # A later step cannot re-record the same peg.
        _si_step!(t, b, SI_CONTACTS, [_si_scored(11, 999.0)], c)
        @test length(t.line_hits["arc"]) == 2
    end

    @testset "impact_y defaults to zero" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, [_si_scored(11, nothing)], c)
        @test t.line_hits["arc"][1]["impact_y"] == 0.0
    end

    @testset "non-zero-gap lines are not tracked" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        gapped = [_si_contact(11; line = _si_line("loose"; gap = 6))]
        scored = [_si_scored(11, 100.0; line = _si_line("loose"; gap = 6))]
        _si_step!(t, b, gapped, scored, c)
        @test isempty(t.line_hits)
        @test isempty(t.track)
    end

    @testset "on_ball_removed prunes the track" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        @test haskey(t.track, 1)
        PeggleSim.slide_inversion_on_ball_removed!(t, 1)
        @test !haskey(t.track, 1)

        # A fresh contact after removal cannot inherit the old direction.
        b.vy = -300.0
        cmds = _si_step!(t, b, SI_CONTACTS, [], c)
        @test isempty(cmds.commands)
    end

    @testset "unlaunched balls are ignored" begin
        t = _si_trackers()
        b = _si_ball(1; vy = 300.0, launched = false)
        _si_step!(t, b, SI_CONTACTS, _si_hits(100.0, 200.0, 150.0), c)
        @test isempty(t.track)
        @test length(t.line_hits["arc"]) == 3
    end

    @testset "direction is tracked per ball" begin
        t = _si_trackers()
        b1 = _si_ball(1; vy = 300.0)
        b2 = _si_ball(2; vy = -300.0)
        _si_step!(t, b1, [_si_contact(11)], [_si_scored(11, 100.0)], c)
        _si_step!(t, b2, [_si_contact(11)], [], c)
        @test t.track[1]["tangent_sign"] == 1
        @test t.track[2]["tangent_sign"] == -1
    end
end
