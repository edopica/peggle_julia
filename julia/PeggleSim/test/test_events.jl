# Focused tests for the M3 event journal and command buffer (workstream A).
# Mirrors the reference unit tests tests/test_gameplay_events.lua and
# tests/test_gameplay_commands.lua for the exported-behaviour subset, plus the
# Peg live-field and BallState.scored_fever defaults.

using Test
using PeggleSim

@testset "events" begin
    @testset "staging order and flush" begin
        j = PeggleSim.GameplayJournal()
        # Plain dict literals (not Dict{String,Any}) must be accepted too.
        fields_a = Dict("ball_id" => 1, "x" => 100)
        fields_b = Dict("ball_id" => 2, "x" => 200)
        PeggleSim.stage!(j, "ball_launched", fields_a)
        PeggleSim.stage!(j, "ball_launched", fields_b)

        # Staged payloads are copied at stage time.
        fields_a["ball_id"] = 999
        fields_b["x"] = -1.0
        @test isempty(j.raw)
        @test length(j.staged) == 2

        PeggleSim.begin_step!(j, 1, 7)
        @test isempty(j.staged)
        @test length(j.raw) == 2
        @test j.raw[1].type == "ball_launched"
        @test j.raw[2].type == "ball_launched"
        @test j.raw[1].step == 1 && j.raw[1].shot_id == 7
        @test j.raw[1].sequence == 1 && j.raw[2].sequence == 2
        @test j.raw[1].phase == :raw
        @test j.raw[1].fields["ball_id"] == 1
        @test j.raw[1].fields["x"] == 100
        @test j.raw[2].fields["ball_id"] == 2
        @test j.raw[2].fields["x"] == 200

        # Nothing leaks into the next step.
        PeggleSim.seal_raw!(j)
        PeggleSim.finish_step!(j)
        PeggleSim.begin_step!(j, 2, 7)
        @test isempty(j.raw)
        @test isempty(j.derived)

        # Staging mid-step flushes only at the next begin_step!.
        PeggleSim.stage!(j, "late", nothing)
        @test isempty(j.raw)
        @test length(j.staged) == 1
        PeggleSim.seal_raw!(j)
        PeggleSim.finish_step!(j)
        PeggleSim.begin_step!(j, 3, 7)
        @test length(j.raw) == 1
        @test j.raw[1].type == "late"
        @test j.raw[1].step == 3
        @test isempty(j.raw[1].fields)
    end

    @testset "raw/derived phase errors" begin
        j = PeggleSim.GameplayJournal()
        @test_throws ArgumentError PeggleSim.emit_raw!(j, "x", nothing)
        @test_throws ArgumentError PeggleSim.emit_derived!(j, "x", nothing)
        @test_throws ArgumentError PeggleSim.seal_raw!(j)

        PeggleSim.begin_step!(j, 1, 1)
        # derived before seal_raw is an error.
        @test_throws ArgumentError PeggleSim.emit_derived!(j, "d", nothing)
        PeggleSim.emit_raw!(j, "a", nothing)
        PeggleSim.emit_raw!(j, "b", Dict{String,Any}("n" => 1))
        PeggleSim.seal_raw!(j)
        err = try
            PeggleSim.emit_raw!(j, "c", nothing)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("after seal_raw", sprint(showerror, err))
        @test length(j.raw) == 2
        @test isempty(j.derived)

        PeggleSim.emit_derived!(j, "d", Dict{String,Any}("peg_id" => 3))
        @test length(j.derived) == 1
        PeggleSim.finish_step!(j)
        @test_throws ArgumentError PeggleSim.emit_raw!(j, "x", nothing)
        @test_throws ArgumentError PeggleSim.emit_derived!(j, "x", nothing)
        @test_throws ArgumentError PeggleSim.seal_raw!(j)
    end

    @testset "sequence numbering and envelope" begin
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 42, 9)
        PeggleSim.emit_raw!(j, "a", nothing)
        PeggleSim.emit_raw!(j, "b", nothing)
        PeggleSim.seal_raw!(j)
        PeggleSim.emit_derived!(j, "c", nothing)
        PeggleSim.emit_derived!(j, "d", nothing)

        # Per-step sequence is shared between raw and derived.
        @test [e.sequence for e in j.raw] == [1, 2]
        @test [e.sequence for e in j.derived] == [3, 4]
        @test all(e.phase == :raw for e in j.raw)
        @test all(e.phase == :derived for e in j.derived)

        env = PeggleSim.event_dict(j.raw[1])
        @test env["schema_version"] == 1
        @test env["step"] == 42
        @test env["shot_id"] == 9
        @test env["sequence"] == 1
        @test env["phase"] == "raw"
        @test env["type"] == "a"
        denv = PeggleSim.event_dict(j.derived[1])
        @test denv["phase"] == "derived"
        @test denv["sequence"] == 3

        # Sequence restarts at 1 for the next step.
        PeggleSim.finish_step!(j)
        PeggleSim.begin_step!(j, 43, 9)
        PeggleSim.emit_raw!(j, "a", nothing)
        @test j.raw[1].sequence == 1
    end

    @testset "payload deep-copy isolation" begin
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 1, 1)
        producer = Dict{String,Any}(
            "ball_id" => 1,
            "source_sequences" => [1, 2, 3],
            "meta" => Dict{String,Any}("peg_id" => 5),
        )
        PeggleSim.emit_raw!(j, "ball_contacted_peg", producer)
        producer["ball_id"] = 999
        producer["source_sequences"][1] = 999
        push!(producer["source_sequences"], 4)
        producer["meta"]["peg_id"] = 999

        stored = j.raw[1]
        @test stored.fields["ball_id"] == 1
        @test stored.fields["source_sequences"] == [1, 2, 3]
        @test stored.fields["source_sequences"] !== producer["source_sequences"]
        @test stored.fields["meta"] !== producer["meta"]
        @test stored.fields["meta"]["peg_id"] == 5

        PeggleSim.seal_raw!(j)
        dproducer = Dict{String,Any}("peg_id" => 7, "seqs" => [1, 2])
        PeggleSim.emit_derived!(j, "peg_scored", dproducer)
        dproducer["peg_id"] = 999
        dproducer["seqs"][1] = 999
        @test j.derived[1].fields["peg_id"] == 7
        @test j.derived[1].fields["seqs"] == [1, 2]

        # event_dict() returns a detached copy as well.
        d = PeggleSim.event_dict(stored)
        d["ball_id"] = 999
        d["meta"]["peg_id"] = 999
        @test stored.fields["ball_id"] == 1
        @test stored.fields["meta"]["peg_id"] == 5
        PeggleSim.finish_step!(j)
    end

    @testset "journal_snapshot detachment" begin
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 3, 5)
        PeggleSim.emit_raw!(j, "ball_contacted_peg",
            Dict{String,Any}("ball_id" => 1, "meta" => Dict{String,Any}("a" => 1)))
        PeggleSim.seal_raw!(j)
        PeggleSim.emit_derived!(j, "peg_scored", Dict{String,Any}("peg_id" => 3))

        snap = PeggleSim.journal_snapshot(j)
        @test snap.schema_version == 1
        @test snap.step == 3
        @test snap.shot_id == 5
        @test snap.event_count == 2
        @test length(snap.raw) == 1 && length(snap.derived) == 1
        @test snap.raw[1]["phase"] == "raw"
        @test snap.derived[1]["phase"] == "derived"

        # Mutating the snapshot (including nested payloads) leaves the journal
        # and any later snapshot untouched.
        snap.raw[1]["ball_id"] = 999
        snap.raw[1]["meta"]["a"] = 999
        push!(snap.raw, Dict{String,Any}("type" => "injected"))
        snap.derived[1]["peg_id"] = 999
        @test j.raw[1].fields["ball_id"] == 1
        @test j.raw[1].fields["meta"]["a"] == 1
        @test length(j.raw) == 1 && length(j.derived) == 1

        snap2 = PeggleSim.journal_snapshot(j)
        @test snap2.event_count == 2
        @test snap2.raw[1]["ball_id"] == 1
        @test snap2.raw[1]["meta"]["a"] == 1
        @test snap2.derived[1]["peg_id"] == 3

        # Empty step is valid.
        PeggleSim.finish_step!(j)
        PeggleSim.begin_step!(j, 4, 5)
        empty_snap = PeggleSim.journal_snapshot(j)
        @test empty_snap.event_count == 0
        @test isempty(empty_snap.raw) && isempty(empty_snap.derived)
    end

    @testset "journal reset!" begin
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 2, 3)
        PeggleSim.emit_raw!(j, "x", nothing)
        PeggleSim.stage!(j, "y", nothing)
        PeggleSim.reset!(j)
        @test j.step_id == 0 && j.shot_id == 0 && j.sequence == 0
        @test !j.raw_sealed && !j.open
        @test isempty(j.raw) && isempty(j.derived) && isempty(j.staged)
    end

    @testset "commands push/record/snapshot" begin
        c = PeggleSim.GameplayCommands()
        PeggleSim.begin_step!(c, 5, 2)
        PeggleSim.push_command!(c, "award_style_points",
                                Dict{String,Any}("points" => 100))
        PeggleSim.push_command!(c, "start_midturn_clearing",
                                Dict{String,Any}("reason" => "all_balls_became_idle"))
        @test c.sequence == 2
        cmd1 = c.commands[1]
        @test cmd1["step"] == 5
        @test cmd1["shot_id"] == 2
        @test cmd1["sequence"] == 1
        @test cmd1["type"] == "award_style_points"
        @test cmd1["points"] == 100
        @test c.commands[2]["sequence"] == 2

        # Deep copy at push time.
        seqs = [3, 7]
        PeggleSim.push_command!(c, "award_style_points",
            Dict{String,Any}("style" => "double_long_shot", "source_sequences" => seqs))
        seqs[1] = 999
        push!(seqs, 5)
        @test c.commands[3]["source_sequences"] == [3, 7]

        # command_snapshot is an independent copy.
        snap = PeggleSim.command_snapshot(c)
        snap[1]["points"] = 999
        snap[3]["source_sequences"][1] = 999
        @test c.commands[1]["points"] == 100
        @test c.commands[3]["source_sequences"] == [3, 7]

        # record_applied! stores an independent copy plus the status; plain
        # dict literals are accepted as well.
        PeggleSim.record_applied!(c, c.commands[1])
        PeggleSim.record_applied!(c, Dict("type" => "literal", "points" => 5), "applied")
        PeggleSim.record_applied!(c, c.commands[2], "ignored_duplicate")
        applied = PeggleSim.applied_snapshot(c)
        @test length(applied) == 3
        @test applied[1]["status"] == "applied"
        @test applied[2]["status"] == "applied"
        @test applied[2]["points"] == 5
        @test applied[3]["status"] == "ignored_duplicate"
        @test applied[1]["points"] == 100
        applied[1]["points"] = 999
        applied[3]["status"] = "mutated"
        applied2 = PeggleSim.applied_snapshot(c)
        @test applied2[1]["points"] == 100
        @test applied2[1]["status"] == "applied"
        @test applied2[3]["status"] == "ignored_duplicate"

        # begin_step! and reset! clear both buffers and the sequence.
        PeggleSim.begin_step!(c, 6, 2)
        @test c.sequence == 0
        @test isempty(PeggleSim.command_snapshot(c))
        @test isempty(PeggleSim.applied_snapshot(c))
        PeggleSim.push_command!(c, "x", nothing)
        @test c.commands[1]["sequence"] == 1
        PeggleSim.clear!(c)
        @test isempty(PeggleSim.command_snapshot(c))
        @test isempty(PeggleSim.applied_snapshot(c))

        PeggleSim.reset!(c)
        @test c.step_id == 0 && c.shot_id == 0 && c.sequence == 0
        @test isempty(c.commands) && isempty(c.applied)
    end

    @testset "Peg live-field defaults" begin
        circle = PeggleSim.CircleShape(15.0)
        p = PeggleSim.Peg(1, 10.0, 20.0, 10.0, 20.0, circle, :blue, false, 0, 0, nothing)
        @test p.base_angle == 0.0
        @test p.angle == 0.0
        @test p.vx == 0.0 && p.vy == 0.0 && p.va == 0.0
        @test p.prev_x == 10.0 && p.prev_y == 20.0
        @test p.prev_angle == 0.0
        @test p.bounding_radius === 15.0

        rect = PeggleSim.RectangleShape(40.0, 20.0, 1.25)
        r = PeggleSim.Peg(2, 30.0, 40.0, 30.0, 40.0, rect, :green, true, 3, 2, nothing)
        @test r.base_angle == 1.25
        @test r.angle == 1.25
        @test r.prev_angle == 1.25
        @test r.hit && r.hit_order == 3 && r.multiplier_at_hit == 2
        @test r.bounding_radius === PeggleSim.DetMath.det_sqrt(40.0 * 40.0 + 20.0 * 20.0) / 2
        @test r.bounding_radius === rect.bounding_radius

        ann = PeggleSim.AnnularShape(10.0, 20.0, 0.0, 1.5, 8)
        a = PeggleSim.Peg(3, 50.0, 60.0, 50.0, 60.0, ann, :purple, false, 0, 0, nothing)
        @test a.base_angle == 0.0
        @test a.angle == 0.0
        @test a.prev_angle == 0.0
        @test a.vx == 0.0 && a.vy == 0.0 && a.va == 0.0
        @test a.prev_x == 50.0 && a.prev_y == 60.0
        @test a.bounding_radius === 20.0

        # Live fields are mutable and independent per instance.
        p.vx = 5.0
        p.bounding_radius = 15.0
        p.angle = 0.5
        @test p.vx == 5.0 && p.bounding_radius == 15.0 && p.angle == 0.5
        @test a.vx == 0.0 && a.bounding_radius === 20.0

        # New per-worker pegs reuse the immutable geometry across resets.
        replacement = PeggleSim.Peg(2, 30.0, 40.0, 30.0, 40.0,
                                   rect, :green, false, 0, 0, nothing)
        r.bounding_radius = nothing
        @test replacement.shape === rect
        @test replacement.bounding_radius === rect.bounding_radius
    end

    @testset "BallState scored_fever default" begin
        b = PeggleSim.BallState(1, 10.0, 50.0, 8.0)
        @test b.id == 1
        @test b.x == 10.0 && b.y == 50.0
        @test b.prev_x == 10.0 && b.prev_y == 50.0
        @test b.vx == 0.0 && b.vy == 0.0
        @test b.radius == 8.0
        @test !b.launched
        @test b.scored_fever === false

        b.scored_fever = true
        @test b.scored_fever

        full = PeggleSim.BallState(2, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, true, true)
        @test full.scored_fever
    end
end
