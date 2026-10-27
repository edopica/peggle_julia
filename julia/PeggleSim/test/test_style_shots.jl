# Focused tests for src/style_shots.jl (workstream E), porting the dev-tree
# unit tests ../peggle_evolved/tests/test_style_shots.lua to the real
# GameplayJournal / GameplayCommands API. A real SimConfig is loaded from the
# mustache dev fixture; distances/points in the assertions come from it.

using Test
using PeggleSim

const STYLE_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const STYLE_CONFIG_PATH =
    joinpath(STYLE_REPO_ROOT, "fixtures", "mustache", "config.dev.v1.json")

# A line metadata dict in the payload shape produced by the Engine reducer.
_sline(id, index, count; closed = false, gap = 0) = Dict{String,Any}(
    "id" => id, "index" => index, "count" => count,
    "closed" => closed, "gap" => gap)

function _style_trackers()
    t = PeggleSim.StyleShotTrackers()
    PeggleSim.reset_shot!(t)
    return t
end

# Open a fresh journal + commands for a step.
function _style_begin(step_id::Int)
    j = PeggleSim.GameplayJournal()
    cmds = PeggleSim.GameplayCommands()
    PeggleSim.begin_step!(j, step_id, 1)
    PeggleSim.begin_step!(cmds, step_id, 1)
    return j, cmds
end

# Emit one raw ball_contacted_peg; returns its envelope sequence.
function _style_raw_contact!(j, ball_id, ix, iy, peg_type; peg_id = 1,
                             line = nothing, kind = "sweep", did_bounce = true)
    fields = Dict{String,Any}(
        "ball_id" => ball_id, "peg_id" => peg_id, "peg_type" => peg_type,
        "contact_kind" => kind, "did_bounce" => did_bounce,
        "impact_x" => Float64(ix), "impact_y" => Float64(iy))
    line === nothing || (fields["line"] = line)
    PeggleSim.emit_raw!(j, "ball_contacted_peg", fields)
    return j.sequence
end

function _style_raw_wall!(j, ball_id; wall = "left", did_bounce = true)
    PeggleSim.emit_raw!(j, "ball_contact_wall", Dict{String,Any}(
        "ball_id" => ball_id, "wall" => wall, "did_bounce" => did_bounce,
        "impact_x" => 0.0, "impact_y" => 100.0))
    return j.sequence
end

function _style_raw_bucket_bounced!(j, ball_id)
    PeggleSim.emit_raw!(j, "bucket_bounced_ball",
                        Dict{String,Any}("ball_id" => ball_id))
    return j.sequence
end

function _style_raw_bucket_caught!(j, ball_id)
    PeggleSim.emit_raw!(j, "bucket_caught_ball",
                        Dict{String,Any}("ball_id" => ball_id))
    return j.sequence
end

function _style_raw_ball_contact!(j, ball_id, other_ball_id; did_bounce = true)
    PeggleSim.emit_raw!(j, "ball_contact_ball", Dict{String,Any}(
        "ball_id" => ball_id, "other_ball_id" => other_ball_id,
        "did_bounce" => did_bounce, "impact_x" => 0.0, "impact_y" => 0.0))
    return j.sequence
end

function _style_raw_divider!(j, ball_id; did_bounce = true)
    PeggleSim.emit_raw!(j, "ball_contact_fever_divider", Dict{String,Any}(
        "ball_id" => ball_id, "did_bounce" => did_bounce,
        "impact_x" => 0.0, "impact_y" => 0.0))
    return j.sequence
end

# Emit the derived peg_scored for a raw contact sequence.
function _style_scored!(j, src, ball_id, ix, iy, peg_type; peg_id = 1,
                        line = nothing)
    fields = Dict{String,Any}(
        "source_sequence" => src, "ball_id" => ball_id, "peg_id" => peg_id,
        "peg_type" => peg_type,
        "impact_x" => Float64(ix), "impact_y" => Float64(iy))
    line === nothing || (fields["line"] = line)
    PeggleSim.emit_derived!(j, "peg_scored", fields)
    return j.sequence
end

function _style_process!(t, j, cmds, c)
    PeggleSim.seal_raw!(j)
    PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
    PeggleSim.finish_step!(j)
    return cmds.commands
end

# A scored raw contact + its derived peg_scored, in one call before sealing is
# impossible (derived must follow seal), so tests emit raw contacts first,
# seal, then call _style_scored! for each.

@testset "style shots" begin
    c = PeggleSim.load_config(STYLE_CONFIG_PATH)
    long_d = Float64(c.long_shot_distance)
    super_d = Float64(c.super_long_shot_distance)
    d410 = long_d + 10.0

    @testset "reused scoring index follows the current journal" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        scored_by_source = Dict{Int,Int}()
        for step in 1:8
            PeggleSim.reset_shot!(t)
            PeggleSim.begin_step!(j, step, 1)
            PeggleSim.begin_step!(cmds, step, 1)
            _style_raw_wall!(j, 1)
            source = _style_raw_contact!(j, 1, 100.0, 100.0, "purple")
            PeggleSim.seal_raw!(j)
            if step % 3 == 1
                # Derived indices differ from event sequences, and the final
                # score for a duplicate source must win (purple over blue).
                PeggleSim.emit_derived!(j, "unrelated", Dict{String,Any}())
                _style_scored!(j, source, 1, 100.0, 100.0, "blue"; peg_id = 10)
                _style_scored!(j, source, 1, 100.0, 100.0, "purple"; peg_id = 11)
            end
            PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c,
                                          scored_by_source)
            if step % 3 == 1
                @test scored_by_source[source] == 3
                @test length(cmds.commands) == 1
                @test cmds.commands[1]["style"] == "off_the_wall"
                @test cmds.commands[1]["peg_id"] == 11
            else
                # Raw sequences restart, so retaining an old derived index
                # could award a stale score or access outside the new journal.
                @test isempty(scored_by_source)
                @test isempty(cmds.commands)
            end
            PeggleSim.finish_step!(j)
        end
    end

    @testset "long shot thresholds" begin
        # Just below the long threshold: no award, but the tracker keeps the
        # chain base (last_impact is set from the first contact).
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, long_d - 1.0, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, long_d - 1.0, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test haskey(t.last_impact, 1)
        @test t.qualifying_streak[1] == 0

        # Exactly at the long threshold: awards long_shot with the exact
        # distance and source sequences.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, long_d, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, long_d, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        cmd = cmds.commands[1]
        @test cmd["type"] == "award_style_points"
        @test cmd["style"] == "long_shot"
        @test cmd["points"] == c.long_shot_points
        @test cmd["distance"] == long_d
        @test cmd["ball_id"] == 1
        @test cmd["source_sequences"] == [s1, s2]
        @test !haskey(cmd, "peg_id") && !haskey(cmd, "line_id")
        @test t.qualifying_streak[1] == 1
        @test t.last_qualifying_seq[1] == s2

        # Just below super: long only. At super: super, not long.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, super_d - 1.0, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, super_d - 1.0, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "long_shot"

        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, super_d, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, super_d, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        cmd = cmds.commands[1]
        @test cmd["style"] == "super_long_shot"
        @test cmd["points"] == c.super_long_shot_points
        @test cmd["distance"] == super_d
        @test cmd["source_sequences"] == [s1, s2]
    end

    @testset "double long shot" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        s3 = _style_raw_contact!(j, 1, d410 * 2.0, 0.0, "red")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410, 0.0, "purple")
        _style_scored!(j, s3, 1, d410 * 2.0, 0.0, "red")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 2
        @test cmds.commands[1]["style"] == "long_shot"
        @test cmds.commands[1]["source_sequences"] == [s1, s2]
        cmd = cmds.commands[2]
        @test cmd["style"] == "double_long_shot"
        @test cmd["points"] == c.double_long_shot_points
        @test cmd["source_sequences"] == [s2, s3]
        @test t.qualifying_streak[1] == 2
        @test t.last_qualifying_seq[1] == s3

        # A third qualifying segment must not re-award long or double.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        s3 = _style_raw_contact!(j, 1, d410 * 2.0, 0.0, "red")
        s4 = _style_raw_contact!(j, 1, d410 * 3.0, 0.0, "green")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410, 0.0, "purple")
        _style_scored!(j, s3, 1, d410 * 2.0, 0.0, "red")
        _style_scored!(j, s4, 1, d410 * 3.0, 0.0, "green")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test [cmd["style"] for cmd in cmds.commands] ==
              ["long_shot", "double_long_shot"]
    end

    @testset "short segment resets the streak" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        s3 = _style_raw_contact!(j, 1, d410 + 5.0, 0.0, "red")
        s4 = _style_raw_contact!(j, 1, d410 + 5.0 + d410, 0.0, "green")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410, 0.0, "purple")
        _style_scored!(j, s3, 1, d410 + 5.0, 0.0, "red")
        _style_scored!(j, s4, 1, d410 + 5.0 + d410, 0.0, "green")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        # Segment 2 (s2->s3) is short: streak resets; segment 3 (s3->s4) is
        # the new chain's first qualifying segment: long once, no double.
        @test [cmd["style"] for cmd in cmds.commands] == ["long_shot"]
        @test cmds.commands[1]["source_sequences"] == [s1, s2]
    end

    @testset "chain breaks" begin
        # Blue peg between two specials breaks the chain.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410 / 2.0, 0.0, "blue")
        s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410 / 2.0, 0.0, "blue")
        _style_scored!(j, s3, 1, d410, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test t.qualifying_streak[1] == 0
        @test !haskey(t.last_qualifying_seq, 1)
        # The breaking purple peg becomes the base of the next chain.
        @test t.last_impact[1].seq == s3

        # An already-hit peg (raw contact without peg_scored) breaks too.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        _style_raw_contact!(j, 1, d410 / 2.0, 0.0, "red")
        s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s3, 1, d410, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test t.qualifying_streak[1] == 0
        @test t.last_impact[1].seq == s3

        # A wall bounce breaks the distance chain.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        j, cmds = _style_begin(2)
        _style_raw_wall!(j, 1, wall = "left", did_bounce = true)
        s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s3, 1, d410, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test t.qualifying_streak[1] == 0
        @test !haskey(t.last_qualifying_seq, 1)
        @test t.last_impact[1].seq == s3
    end

    @testset "graze completes / blue graze breaks" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410, 0.0, "purple", kind = "graze")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "long_shot"

        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 1, d410 / 2.0, 0.0, "blue", kind = "graze")
        s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 1, d410 / 2.0, 0.0, "blue")
        _style_scored!(j, s3, 1, d410, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
    end

    @testset "overlap/depenetrate do not complete or break" begin
        for kind in ("overlap", "depenetrate")
            t = _style_trackers()
            j, cmds = _style_begin(1)
            s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
            s2 = _style_raw_contact!(j, 1, d410 / 2.0, 0.0, "blue", kind = kind)
            s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
            PeggleSim.seal_raw!(j)
            _style_scored!(j, s1, 1, 0.0, 0.0, "red")
            _style_scored!(j, s2, 1, d410 / 2.0, 0.0, "blue")
            _style_scored!(j, s3, 1, d410, 0.0, "purple")
            PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
            @test length(cmds.commands) == 1
            @test cmds.commands[1]["style"] == "long_shot"
            @test cmds.commands[1]["source_sequences"] == [s1, s3]
        end
    end

    @testset "two balls stay isolated" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "red")
        s2 = _style_raw_contact!(j, 2, 0.0, 0.0, "red")
        s3 = _style_raw_contact!(j, 1, d410, 0.0, "purple")
        s4 = _style_raw_contact!(j, 2, 10.0, 0.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "red")
        _style_scored!(j, s2, 2, 0.0, 0.0, "red")
        _style_scored!(j, s3, 1, d410, 0.0, "purple")
        _style_scored!(j, s4, 2, 10.0, 0.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["ball_id"] == 1
        @test cmds.commands[1]["style"] == "long_shot"
        @test cmds.commands[1]["source_sequences"] == [s1, s3]
    end

    @testset "lucky bounce" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        sb = _style_raw_bucket_bounced!(j, 1)
        _style_raw_contact!(j, 1, 0.0, 0.0, "blue")
        sc = _style_raw_bucket_caught!(j, 1)
        @test length(_style_process!(t, j, cmds, c)) == 1
        cmd = cmds.commands[1]
        @test cmd["type"] == "award_style_points"
        @test cmd["style"] == "lucky_bounce"
        @test cmd["points"] == c.lucky_bounce_points
        @test cmd["ball_id"] == 1
        @test cmd["source_sequences"] == [sb, sc]
        @test !haskey(cmd, "distance") && !haskey(cmd, "peg_id") &&
              !haskey(cmd, "line_id")
        @test t.awarded[1]["lucky"] === true

        # Catch with no bounce before it: no award.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_bucket_caught!(j, 1)
        @test isempty(_style_process!(t, j, cmds, c))

        # Bounce then catch with no peg/wall contact in between: no award.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_bucket_bounced!(j, 1)
        _style_raw_bucket_caught!(j, 1)
        @test isempty(_style_process!(t, j, cmds, c))

        # A wall bounce between bounce and catch satisfies the "after" flag.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        sb = _style_raw_bucket_bounced!(j, 1)
        _style_raw_wall!(j, 1, wall = "left")
        sc = _style_raw_bucket_caught!(j, 1)
        _style_process!(t, j, cmds, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["source_sequences"] == [sb, sc]

        # A second bucket bounce resets bounced_after_bucket; peg hit then
        # catch still awards once.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_bucket_bounced!(j, 1)
        _style_raw_bucket_bounced!(j, 1)
        _style_raw_contact!(j, 1, 0.0, 0.0, "blue")
        _style_raw_bucket_caught!(j, 1)
        _style_process!(t, j, cmds, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "lucky_bounce"
    end

    @testset "off the wall" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        sw = _style_raw_wall!(j, 1, wall = "left")
        s2 = _style_raw_contact!(j, 1, 200.0, 100.0, "red", peg_id = 7)
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s2, 1, 200.0, 100.0, "red", peg_id = 7)
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        cmd = cmds.commands[1]
        @test cmd["style"] == "off_the_wall"
        @test cmd["points"] == c.off_the_wall_points
        @test cmd["peg_id"] == 7
        @test cmd["source_sequences"] == [sw, s2]
        @test !haskey(t.side_wall_hit, 1)   # consumed by the award
        @test t.awarded[1]["off_wall"] === true

        # Ceiling is not a side wall.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_wall!(j, 1, wall = "top")
        s2 = _style_raw_contact!(j, 1, 200.0, 100.0, "red")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s2, 1, 200.0, 100.0, "red")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # A blue peg consumes and fails the attempt.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_wall!(j, 1, wall = "left")
        s2 = _style_raw_contact!(j, 1, 200.0, 100.0, "blue")
        s3 = _style_raw_contact!(j, 1, 400.0, 100.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s2, 1, 200.0, 100.0, "blue")
        _style_scored!(j, s3, 1, 400.0, 100.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test !haskey(t.side_wall_hit, 1)

        # An already-hit peg (no peg_scored) consumes and fails as well.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_wall!(j, 1, wall = "left")
        _style_raw_contact!(j, 1, 200.0, 100.0, "red")
        s3 = _style_raw_contact!(j, 1, 400.0, 100.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s3, 1, 400.0, 100.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # A wall contacted after the ball has hit a peg does not arm the award.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        s1 = _style_raw_contact!(j, 1, 0.0, 0.0, "blue")
        _style_raw_wall!(j, 1, wall = "left")
        s3 = _style_raw_contact!(j, 1, 400.0, 100.0, "purple")
        PeggleSim.seal_raw!(j)
        _style_scored!(j, s1, 1, 0.0, 0.0, "blue")
        _style_scored!(j, s3, 1, 400.0, 100.0, "purple")
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
    end

    @testset "slide awards" begin
        # Five adjacent zero-gap graze scores.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:5
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:5
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        cmd = cmds.commands[1]
        @test cmd["type"] == "award_style_points"
        @test cmd["style"] == "slide"
        @test cmd["points"] == c.slide_points
        @test cmd["line_id"] == "rail"
        @test cmd["ball_id"] == 1
        @test cmd["source_sequences"] == srcs
        @test t.slide_awarded[1]["rail"] === true

        # Descending direction awards as well.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 5:-1:1
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 5:-1:1
            _style_scored!(j, srcs[6 - i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"

        # Closed line: 6,7,8 wrap to 1,2.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for (seq, i) in enumerate((6, 7, 8, 1, 2))
            line = _sline("ring", i, 8; closed = true)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = line, kind = "graze", did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate((6, 7, 8, 1, 2))
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("ring", i, 8; closed = true))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["line_id"] == "ring"
        @test cmds.commands[1]["source_sequences"] == srcs

        # Short run (4 pegs) awards nothing.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:4
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:4
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test t.slide_runs[1]["rail"].len == 4
    end

    @testset "slide run invalidation and reseeding" begin
        # Non-adjacent index restarts the run: 1,2,8,3,4,5 never reaches five.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in (1, 2, 8, 3, 4, 5)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate((1, 2, 8, 3, 4, 5))
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # A direction flip does not extend: 2,3 then 3 again invalidates.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in (2, 3, 4, 3, 5)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate((2, 3, 4, 3, 5))
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # A scoring landing bounce reseeds: bounce at 3 then 4,5,6,7 = five.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        sb = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 3, line = _sline("rail", 3, 9), did_bounce = true)
        srcs = Int[sb]
        for i in 4:7
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        _style_scored!(j, sb, 1, 0.0, 0.0, "blue";
            peg_id = 3, line = _sline("rail", 3, 9))
        for i in 4:7
            _style_scored!(j, srcs[i - 2], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"
        @test cmds.commands[1]["source_sequences"] == srcs

        # Grazes 1,2 then a bounce at 3 then 4,5,6: only four in the new run.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in (1, 2)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        sb = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 3, line = _sline("rail", 3, 9), did_bounce = true)
        for i in (4, 5, 6)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate((1, 2))
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        _style_scored!(j, sb, 1, 0.0, 0.0, "blue";
            peg_id = 3, line = _sline("rail", 3, 9))
        for (seq, i) in enumerate((4, 5, 6))
            _style_scored!(j, srcs[seq + 2], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
    end

    @testset "slide resets" begin
        # Wall bounce resets: 1-4 then wall then 5 = no award.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:4
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        _style_raw_wall!(j, 1, wall = "left", did_bounce = true)
        s5 = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9), kind = "graze",
            did_bounce = false)
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate(1:4)
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        _style_scored!(j, s5, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9))
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # Non-bouncing wall contact does not reset: award fires.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:4
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        _style_raw_wall!(j, 1, wall = "left", did_bounce = false)
        s5 = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9), kind = "graze",
            did_bounce = false)
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate(1:4)
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        _style_scored!(j, s5, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9))
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"

        # A ball-ball bounce resets both balls' runs.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs1 = Int[]
        srcs2 = Int[]
        for i in 1:4
            push!(srcs1, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
            push!(srcs2, _style_raw_contact!(j, 2, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail2", i, 9), kind = "graze",
                did_bounce = false))
        end
        _style_raw_ball_contact!(j, 1, 2, did_bounce = true)
        s5 = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9), kind = "graze",
            did_bounce = false)
        s6 = _style_raw_contact!(j, 2, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail2", 5, 9), kind = "graze",
            did_bounce = false)
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate(1:4)
            _style_scored!(j, srcs1[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
            _style_scored!(j, srcs2[seq], 2, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail2", i, 9))
        end
        _style_scored!(j, s5, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9))
        _style_scored!(j, s6, 2, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail2", 5, 9))
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)

        # Non-bouncing divider/wall and positive-gap lines do not touch runs.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:4
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        _style_raw_divider!(j, 1, did_bounce = false)
        s5 = _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9), kind = "graze",
            did_bounce = false)
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate(1:4)
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        _style_scored!(j, s5, 1, 0.0, 0.0, "blue";
            peg_id = 5, line = _sline("rail", 5, 9))
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"

        # Positive-gap lines never qualify.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:5
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("loose", i, 9; gap = 6),
                kind = "graze", did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:5
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("loose", i, 9; gap = 6))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
    end

    @testset "slide once per ball and line" begin
        # A nine-peg run awards once; a second line awards independently.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:9
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 12), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:9
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 12))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1

        j, cmds = _style_begin(2)
        srcs = Int[]
        for i in 1:5
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = 20 + i, line = _sline("beta", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:5
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = 20 + i, line = _sline("beta", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["line_id"] == "beta"

        # The same ball on the same line can never award twice per shot.
        j, cmds = _style_begin(3)
        srcs = Int[]
        for i in 9:1:-1
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 12), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 9:1:-1
            _style_scored!(j, srcs[10 - i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 12))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
    end

    @testset "slide runs persist across steps" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in 1:3
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 1:3
            _style_scored!(j, srcs[i], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test isempty(cmds.commands)
        @test t.slide_runs[1]["rail"].len == 3

        j, cmds = _style_begin(2)
        srcs = Int[]
        for i in 4:5
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for i in 4:5
            _style_scored!(j, srcs[i - 3], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"

        # A non-scoring, non-bouncing contact neither resets nor extends.
        t = _style_trackers()
        j, cmds = _style_begin(1)
        srcs = Int[]
        for i in (1, 2)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
            peg_id = 2, line = _sline("rail", 2, 9), kind = "graze",
            did_bounce = false)   # already hit: no peg_scored
        for i in (3, 4, 5)
            push!(srcs, _style_raw_contact!(j, 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9), kind = "graze",
                did_bounce = false))
        end
        PeggleSim.seal_raw!(j)
        for (seq, i) in enumerate((1, 2))
            _style_scored!(j, srcs[seq], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        for (seq, i) in enumerate((3, 4, 5))
            _style_scored!(j, srcs[seq + 2], 1, 0.0, 0.0, "blue";
                peg_id = i, line = _sline("rail", i, 9))
        end
        PeggleSim.style_shots_process!(t, j, cmds, c.virtual_width, c)
        @test length(cmds.commands) == 1
        @test cmds.commands[1]["style"] == "slide"
    end

    @testset "reset_shot clears all state" begin
        t = _style_trackers()
        j, cmds = _style_begin(1)
        _style_raw_bucket_bounced!(j, 1)
        _style_raw_contact!(j, 1, 0.0, 0.0, "blue")
        _style_raw_bucket_caught!(j, 1)
        _style_process!(t, j, cmds, c)
        @test length(cmds.commands) == 1

        PeggleSim.reset_shot!(t)
        @test isempty(t.last_impact)
        @test isempty(t.qualifying_streak)
        @test isempty(t.last_qualifying_seq)
        @test isempty(t.bucket_bounced)
        @test isempty(t.bounced_after_bucket)
        @test isempty(t.side_wall_hit)
        @test isempty(t.hit_any_peg)
        @test isempty(t.awarded)
        @test isempty(t.slide_runs)
        @test isempty(t.slide_awarded)

        j, cmds = _style_begin(1)
        _style_raw_bucket_caught!(j, 1)
        _style_process!(t, j, cmds, c)
        @test isempty(cmds.commands)
    end
end
