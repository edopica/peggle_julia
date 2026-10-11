using Test
using PeggleSim

# Independent legacy dictionary builder: protects key presence and trace bytes,
# including Lua's nil omission. The separate graze test covers its key set.
function _legacy_contact_payload(ball, rec, bounced, peg, kind, event_type)
    d = Dict{String,Any}(
        "ball_id" => ball.id, "contact_kind" => kind, "did_bounce" => bounced,
        "impact_x" => rec.isx + rec.move_x * rec.toi,
        "impact_y" => rec.isy + rec.move_y * rec.toi,
        "frame_t" => ((rec.total_dt - rec.window) + rec.toi * rec.window) / rec.total_dt,
        "toi" => rec.toi, "iteration" => rec.iter,
        "normal_x" => rec.nx, "normal_y" => rec.ny,
        "incoming_vx" => rec.vin_x, "incoming_vy" => rec.vin_y,
        "outgoing_vx" => rec.vout_x, "outgoing_vy" => rec.vout_y,
    )
    if rec.other_ball !== nothing
        d["other_ball_id"] = rec.other_ball.id
        rec.other_vout_x === nothing || (d["other_outgoing_vx"] = rec.other_vout_x)
        rec.other_vout_y === nothing || (d["other_outgoing_vy"] = rec.other_vout_y)
    end
    if peg !== nothing
        d["peg_id"] = peg.id
        d["peg_type"] = String(peg.peg_type)
        d["peg_shape"] = PeggleSim.peg_shape_name(peg.shape)
        if peg.line !== nothing
            l = peg.line
            d["line"] = Dict{String,Any}("id" => l.id, "index" => l.index,
                "count" => l.count, "closed" => l.closed, "gap" => l.gap)
        end
        px, py, pa, theta = PeggleSim.peg_transform_at_toi(peg, rec.window, rec.toi)
        d["peg_x"], d["peg_y"], d["peg_angle"] = px, py, pa
        theta === nothing || (d["peg_theta"] = theta)
    elseif event_type == "ball_contact_wall"
        d["wall"] = rec.nx > 0 ? "left" : (rec.nx < 0 ? "right" : "top")
    end
    return d
end

@testset "typed contact payload ownership and trace compatibility" begin
    ball = PeggleSim.BallState(1, 10.0, 20.0, 6.0)
    other = PeggleSim.BallState(2, 30.0, 20.0, 6.0)
    line = PeggleSim.LineMetadata("rail\"\\\n", 1, 3, false, -0.0)
    shapes = (PeggleSim.CircleShape(9.0),
              PeggleSim.RectangleShape(20.0, 10.0, 0.25),
              PeggleSim.AnnularShape(10.0, 20.0, 0.0, 1.5, 8))
    cases = Tuple[]
    for shape in shapes, metadata in (nothing, line)
        peg = PeggleSim.Peg(3, 40.0, 50.0, 40.0, 50.0,
                            shape, :green, false, 0, 0, metadata)
        push!(cases, (peg, "ball_contacted_peg", 0.0, nothing, nothing, nothing))
    end
    for nx in (-1.0, 0.0, 1.0)
        push!(cases, (nothing, "ball_contact_wall", nx, nothing, nothing, nothing))
    end
    for vx in (nothing, -0.0), vy in (nothing, 7.0)
        push!(cases, (nothing, "ball_contact_ball", 1.0, other, vx, vy))
    end
    push!(cases, (nothing, "ball_contact_extra", 1.0, nothing, nothing, nothing))

    retained = nothing
    for (peg, event_type, nx, other_ball, vx, vy) in cases
        rec = PeggleSim.ContactRecord(10.0, 20.0, 3.0, -4.0, 0.125, 0.25,
            0.5, 2, nx, -0.0, 13.0, -17.0, -0.0, 19.0, other_ball, vx, vy)
        for kind in ("sweep", "overlap", "depenetration"), bounced in (false, true)
            j = PeggleSim.GameplayJournal()
            legacy = PeggleSim.GameplayJournal()
            PeggleSim.begin_step!(j, 4, 7)
            PeggleSim.begin_step!(legacy, 4, 7)
            expected = _legacy_contact_payload(ball, rec, bounced, peg, kind, event_type)
            PeggleSim.emit_contact!(j, event_type, ball, rec, bounced, peg, kind)
            PeggleSim.emit_raw!(legacy, event_type, expected)
            ev = only(j.raw)
            @test ev.fields isa PeggleSim.ContactPayload
            @test only(legacy.raw).fields isa Dict{String,Any}
            @test Set(keys(ev.fields)) == Set(keys(expected))
            @test length(ev.fields) == length(expected)
            @test get(ev.fields, "absent", nothing) === nothing
            @test !haskey(ev.fields, "absent")
            @test_throws KeyError ev.fields["absent"]
            @test PeggleSim.trace_json(PeggleSim.event_dict(ev)) ==
                  PeggleSim.trace_json(PeggleSim.event_dict(only(legacy.raw)))
            @test PeggleSim.trace_json(ev.fields) == PeggleSim.trace_json(expected)
            if peg !== nothing && peg.line !== nothing
                retained = (j, ev, peg, expected)
            end
        end
    end

    j, ev, peg, expected = retained
    before = PeggleSim.trace_json(PeggleSim.event_dict(ev))
    peg.id = 99
    peg.peg_type = :red
    peg.x = 999.0
    peg.line = nothing
    ball.id = 77
    @test PeggleSim.trace_json(PeggleSim.event_dict(ev)) == before
    @test ev.fields["line"] isa PeggleSim.ContactLine
    @test !ismutabletype(typeof(ev.fields))
    @test !ismutabletype(typeof(ev.fields["line"]))
    snap = PeggleSim.journal_snapshot(j)
    @test snap.raw[1]["line"] isa Dict{String,Any}
    snap.raw[1]["line"]["id"] = "changed"
    snap.raw[1]["ball_id"] = -1
    @test PeggleSim.trace_json(PeggleSim.event_dict(ev)) == before

    # Sharing an immutable payload across journals is safe, including staging
    # and retaining an event across resets. Exports remain independently mutable.
    staged = PeggleSim.GameplayJournal()
    PeggleSim.stage!(staged, ev.type, ev.fields)
    PeggleSim.reset!(j)
    PeggleSim.begin_step!(staged, ev.step, ev.shot_id)
    @test only(staged.raw).fields === ev.fields
    @test PeggleSim.trace_json(PeggleSim.event_dict(only(staged.raw))) == before
    PeggleSim.reset!(staged)
    @test PeggleSim.trace_json(PeggleSim.event_dict(ev)) == before

    # Typed payloads also export ordinary nested dictionaries through commands.
    commands = PeggleSim.GameplayCommands()
    PeggleSim.push_command!(commands, "contact", ev.fields)
    @test commands.commands[1]["line"] isa Dict{String,Any}
    commands.commands[1]["line"]["id"] = "command mutation"
    @test ev.fields["line"]["id"] == line.id
end

function _contact_journal_batch!(journal, fields)
    PeggleSim.begin_step!(journal, 1, 1)
    for _ in 1:128
        PeggleSim.emit_raw!(journal, "ball_contacted_peg", fields)
    end
    return length(journal.raw)
end

@testset "graze payload and journal allocation reduction" begin
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    config = PeggleSim.load_config(joinpath(root, "interchange", "config.v1.json"))
    ball = PeggleSim.BallState(1, 100.0, 100.0, 6.0)
    ball.launched = true
    ball.vx = 400.0
    x = ball.x + ball.vx * config.fixed_dt * 0.5
    y = ball.y + ball.radius + 9.0 + config.graze_tolerance * 0.5
    line = PeggleSim.LineMetadata("graze rail", 2, 4, true, 0.0)
    peg = PeggleSim.Peg(7, x, y, x, y, PeggleSim.CircleShape(9.0),
                        :blue, false, 0, 0, line)
    journal = PeggleSim.GameplayJournal()
    PeggleSim.begin_step!(journal, 1, 1)
    PeggleSim.physics_update!([ball], [peg], PeggleSim.Peg[], PeggleSim.Peg[],
        config.fixed_dt, nothing, config, 1200.0, journal)
    ev = only(filter(e -> e.type == "ball_contacted_peg", journal.raw))
    @test ev.fields isa PeggleSim.ContactPayload
    @test ev.fields["contact_kind"] == "graze"
    @test ev.fields["did_bounce"] === false
    @test Set(keys(ev.fields)) == Set([
        "ball_id", "contact_kind", "did_bounce", "impact_x", "impact_y",
        "frame_t", "toi", "iteration", "normal_x", "normal_y", "incoming_vx",
        "incoming_vy", "outgoing_vx", "outgoing_vy", "peg_id", "peg_type",
        "peg_shape", "line",
    ])
    @test ev.fields["line"]["closed"] === true
    @test get(ev.fields, "peg_x", :absent) === :absent
    @test get(ev.fields, "peg_theta", :absent) === :absent

    # Compare warmed, equally sized journals. This measures payload ownership
    # costs rather than compilation or vector growth, without a platform-specific
    # byte threshold. Dictionary construction is excluded, making it conservative.
    typed_journal = PeggleSim.GameplayJournal()
    dict_journal = PeggleSim.GameplayJournal()
    dict_fields = PeggleSim._copy_payload(ev.fields)
    for _ in 1:2
        _contact_journal_batch!(typed_journal, ev.fields)
        _contact_journal_batch!(dict_journal, dict_fields)
    end
    typed_bytes = @allocated _contact_journal_batch!(typed_journal, ev.fields)
    dict_bytes = @allocated _contact_journal_batch!(dict_journal, dict_fields)
    @test typed_bytes < dict_bytes
    @test PeggleSim.trace_json(PeggleSim.journal_snapshot(typed_journal).raw) ==
          PeggleSim.trace_json(PeggleSim.journal_snapshot(dict_journal).raw)
end

@testset "public dictionary and named tuple event behavior" begin
    j = PeggleSim.GameplayJournal()
    data = Dict{String,Any}("line" => Dict("id" => "original"),
        "items" => Any[Dict("value" => 1)], "type" => "payload wins", "null" => nothing)
    PeggleSim.stage!(j, "envelope", data)
    data["line"]["id"] = "producer mutation"
    data["items"][1]["value"] = 9
    PeggleSim.begin_step!(j, 1, 1)
    @test only(j.raw).fields isa Dict{String,Any}
    exported = PeggleSim.event_dict(only(j.raw))
    @test exported["line"]["id"] == "original"
    @test exported["items"][1]["value"] == 1
    @test exported["type"] == "payload wins"
    @test haskey(exported, "null") && exported["null"] === nothing
    values = [1, 2]
    PeggleSim.emit_raw!(j, "named", (nested = (values = values,),))
    values[1] = 99
    @test j.raw[2].fields["nested"]["values"] == [1, 2]
end
