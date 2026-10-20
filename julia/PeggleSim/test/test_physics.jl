# Focused tests for src/physics.jl (workstream C), porting
# ../peggle_evolved/src/systems/physics.lua (dev tree @ da75225).
#
# Every scene is built from the real `Peg`, `BallState`, `FeverDivider`, and
# `SimConfig` types and driven through the frozen `physics_update!` entry
# point (the depenetration fallbacks, which the reference exercises only from
# engine-level states, are also called directly). The pinned interchange
# config supplies every constant; `_phys_config` derives a real SimConfig with
# named overrides for the scenes that need zero gravity or disabled ball-ball
# collisions (mirroring the reference Lua tests' Config mutations).

using Test
using PeggleSim

const PHYS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const PHYS_CONFIG_PATH = joinpath(PHYS_REPO_ROOT, "interchange", "config.v1.json")
const PHYS_VW = 1200.0
const PHYS_DT = 1.0 / 60.0

# Real SimConfig from the pinned artifact with named field overrides.
function _phys_config(; overrides...)
    base = PeggleSim.load_config(PHYS_CONFIG_PATH)
    fields = fieldnames(PeggleSim.SimConfig)
    vals = Any[getfield(base, f) for f in fields]
    for (key, value) in pairs(overrides)
        i = findfirst(==(key), fields)
        i === nothing && error("unknown SimConfig field $(key)")
        vals[i] = value
    end
    return PeggleSim.SimConfig(vals...)
end

function _phys_circle(id::Int, x::Float64, y::Float64;
                      radius::Float64 = 9.0, peg_type::Symbol = :blue,
                      line = nothing)
    return PeggleSim.Peg(id, x, y, x, y, PeggleSim.CircleShape(radius),
                         peg_type, false, 0, 0, line)
end

function _phys_rect(id::Int, x::Float64, y::Float64, w::Float64, h::Float64,
                    angle::Float64; peg_type::Symbol = :blue)
    return PeggleSim.Peg(id, x, y, x, y, PeggleSim.RectangleShape(w, h, angle),
                         peg_type, false, 0, 0, nothing)
end

function _phys_annular(id::Int, x::Float64, y::Float64, r_in::Float64,
                       r_out::Float64, theta_start::Float64,
                       theta_end_abs::Float64; segments::Int = 16)
    return PeggleSim.Peg(id, x, y, x, y,
                         PeggleSim.AnnularShape(r_in, r_out, theta_start,
                                                theta_end_abs, segments),
                         :blue, false, 0, 0, nothing)
end

function _phys_line(id::String = "line_a", index::Int = 1, count::Int = 2,
                    closed::Bool = false, gap::Float64 = 0.0)
    return PeggleSim.LineMetadata(id, index, count, closed, gap)
end

function _phys_ball(id::Int, x::Float64, y::Float64; vx::Float64 = 0.0,
                    vy::Float64 = 0.0, radius::Float64 = 6.0,
                    launched::Bool = true)
    b = PeggleSim.BallState(id, x, y, radius)
    b.vx = vx
    b.vy = vy
    b.launched = launched
    return b
end

# One fixed step through the frozen entry point.
function _phys_step!(balls::Vector{PeggleSim.BallState},
                     circle_pegs::Vector{PeggleSim.Peg} = PeggleSim.Peg[],
                     rect_pegs::Vector{PeggleSim.Peg} = PeggleSim.Peg[],
                     annular_pegs::Vector{PeggleSim.Peg} = PeggleSim.Peg[];
                     c::PeggleSim.SimConfig = _phys_config(),
                     extras = nothing, vw::Float64 = PHYS_VW)
    j = PeggleSim.GameplayJournal()
    PeggleSim.begin_step!(j, 1, 1)
    PeggleSim.physics_update!(balls, circle_pegs, rect_pegs, annular_pegs,
                              c.fixed_dt, extras, c, vw, j)
    return j
end

function _phys_raw(j::PeggleSim.GameplayJournal, event_type::String)
    return [PeggleSim.event_dict(e) for e in j.raw if e.type == event_type]
end

# Payload-only view (no envelope keys) for exact key-set assertions.
function _phys_fields(j::PeggleSim.GameplayJournal, event_type::String)
    return [e.fields for e in j.raw if e.type == event_type]
end

const PHYS_BASE_KEYS = Set([
    "ball_id", "contact_kind", "did_bounce", "impact_x", "impact_y", "frame_t",
    "toi", "iteration", "normal_x", "normal_y", "incoming_vx", "incoming_vy",
    "outgoing_vx", "outgoing_vy",
])
const PHYS_PEG_KEYS = Set([
    "peg_id", "peg_type", "peg_shape", "peg_x", "peg_y", "peg_angle",
])
const PHYS_BALL_KEYS = Set(["other_ball_id", "other_outgoing_vx", "other_outgoing_vy"])

_bitstr(x::Float64) = PeggleSim.float_bits_hex(x)
_bits(t::Tuple) = map(_bitstr, t)

@testset "physics" begin
    @testset "walls, ceiling, and the open floor" begin
        c = _phys_config()

        # Ceiling: moving up fast enough to be a real bounce.
        up = _phys_ball(1, 440.0, 8.0; vy = -500.0)
        j = _phys_step!([up]; c = c)
        ev = only(_phys_raw(j, "ball_contact_wall"))
        @test ev["wall"] == "top"
        @test ev["contact_kind"] == "sweep"
        @test ev["did_bounce"] === true
        @test ev["incoming_vy"] < -200.0
        @test ev["normal_x"] == 0.0 && ev["normal_y"] == 1.0
        @test ev["impact_y"] == 6.0
        @test ev["outgoing_vy"] == ev["incoming_vy"] - (1 + c.wall_damping) * ev["incoming_vy"]
        @test ev["incoming_vx"] == 0.0 && ev["outgoing_vx"] == 0.0

        # Left wall.
        left = _phys_ball(1, 10.0, 100.0; vx = -500.0)
        j = _phys_step!([left]; c = c)
        ev = only(_phys_raw(j, "ball_contact_wall"))
        @test ev["wall"] == "left"
        @test ev["normal_x"] == 1.0 && ev["normal_y"] == 0.0
        @test ev["impact_x"] == 6.0
        @test ev["outgoing_vx"] == ev["incoming_vx"] - (1 + c.wall_damping) * ev["incoming_vx"]

        # Right wall.
        right = _phys_ball(1, PHYS_VW - 10.0, 100.0; vx = 500.0)
        j = _phys_step!([right]; c = c)
        ev = only(_phys_raw(j, "ball_contact_wall"))
        @test ev["wall"] == "right"
        @test ev["normal_x"] == -1.0 && ev["normal_y"] == 0.0
        @test ev["impact_x"] == PHYS_VW - 6.0
        @test ev["outgoing_vx"] == ev["incoming_vx"] - (1 + c.wall_damping) * ev["incoming_vx"]

        # The floor is open: a dropped ball leaves the board with no contact
        # event at all.
        drop = _phys_ball(1, 440.0, 100.0)
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 1, 1)
        for step in 1:90
            PeggleSim.physics_update!(PeggleSim.BallState[drop], PeggleSim.Peg[],
                                      PeggleSim.Peg[], PeggleSim.Peg[], c.fixed_dt,
                                      nothing, c, PHYS_VW, j)
            PeggleSim.finish_step!(j)
            PeggleSim.begin_step!(j, step + 1, 1)
        end
        @test drop.y > 550.0
        @test isempty(_phys_raw(j, "ball_contact_wall"))
    end

    @testset "circle peg sweep bounce" begin
        c = _phys_config()
        peg = _phys_circle(5, 200.0, 300.0; line = _phys_line())
        ball = _phys_ball(1, 200.0, 280.0; vy = 400.0)
        j = _phys_step!([ball], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "sweep"
        @test ev["did_bounce"] === true
        @test ev["peg_id"] == 5
        @test ev["peg_type"] == "blue"
        @test ev["peg_shape"] == "circle"
        @test ev["normal_x"] == 0.0
        @test ev["normal_y"] == -1.0
        @test ev["impact_x"] == 200.0
        @test ev["impact_y"] == 285.0
        @test ev["outgoing_vy"] == -c.restitution * ev["incoming_vy"]
        @test ev["line"] == Dict{String,Any}(
            "id" => "line_a", "index" => 1, "count" => 2, "closed" => false,
            "gap" => 0.0)
    end

    @testset "circle peg graze" begin
        c = _phys_config()
        ball = _phys_ball(1, 100.0, 100.0; vx = 400.0)
        move_x = ball.vx * c.fixed_dt
        # Closest approach at t1 = 0.5, miss distance radius_sum + p/2.
        radius_sum = ball.radius + 9.0
        peg = _phys_circle(7,
                           ball.x + move_x * 0.5,
                           ball.y + radius_sum + c.graze_tolerance * 0.5)
        j = _phys_step!([ball], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "graze"
        @test ev["did_bounce"] === false
        @test ev["peg_id"] == 7
        @test ev["normal_x"] == 0.0 && ev["normal_y"] == 0.0
        @test ev["incoming_vx"] == 400.0 && ev["outgoing_vx"] == 400.0
        @test ev["incoming_vy"] == 0.0 && ev["outgoing_vy"] == 0.0
        # No deflection: the ball keeps its horizontal velocity; only gravity
        # (applied after the sweep) touches vy.
        @test ball.vx == 400.0
        @test ball.vy == c.gravity * c.fixed_dt
        @test ball.y == 100.0
        # Grazes carry no peg transform keys.
        @test !haskey(ev, "peg_x") && !haskey(ev, "peg_theta")
    end

    @testset "overlapping circle pops out at t=0" begin
        c = _phys_config()
        peg = _phys_circle(3, 110.0, 100.0)
        ball = _phys_ball(1, 100.0, 100.0)
        j = _phys_step!([ball], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "overlap"
        @test ev["toi"] == 0.0
        @test ev["did_bounce"] === false
        @test ev["normal_x"] == -1.0 && ev["normal_y"] == 0.0
        @test ev["impact_x"] == 100.0 && ev["impact_y"] == 100.0
        @test ev["incoming_vx"] == 0.0 && ev["outgoing_vx"] == 0.0
        # overlap = radius_sum - dist = 15 - 10 = 5; pushed by overlap + margin.
        @test ball.x == 100.0 - (5.0 + c.overlap_push_margin)
        @test ball.y == 100.0
    end

    @testset "annular outer arc sweep" begin
        c = _phys_config()
        peg = _phys_annular(1, 200.0, 200.0, 20.0, 40.0, 0.0, Float64(pi))
        # Approaching the r_out point at angle pi from outside the catch zone.
        ball = _phys_ball(1, 148.0, 200.0; vx = 400.0)
        j = _phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "sweep"
        @test ev["peg_shape"] == "annular"
        @test ev["normal_x"] == -1.0
        @test ev["normal_y"] == 0.0
        @test ev["impact_x"] == 154.0
        @test ev["peg_theta"] == 0.0
        @test haskey(ev, "peg_angle")
        @test ev["outgoing_vx"] == -c.restitution * ev["incoming_vx"]
    end

    @testset "annular inner arc sweep" begin
        c = _phys_config()
        peg = _phys_annular(1, 200.0, 200.0, 20.0, 40.0, 0.0, Float64(pi))
        # Inside the hole, surface 6 px from the inner wall.
        ball = _phys_ball(1, 200.0, 208.0; vy = 400.0)
        j = _phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "sweep"
        @test ev["normal_x"] == 0.0
        @test ev["normal_y"] == -1.0
        # Impact is the ball center at TOI: r_in - ball_radius = 14 from the
        # annulus center.
        @test ev["impact_y"] == 214.0
        @test ev["toi"] > 0.0
    end

    @testset "annular cap sweep" begin
        c = _phys_config()
        peg = _phys_annular(1, 200.0, 200.0, 20.0, 40.0, 0.0, Float64(pi))
        # Above the start cap (angle 0), moving +y into its face.
        ball = _phys_ball(1, 230.0, 190.0; vy = 400.0)
        j = _phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "sweep"
        @test ev["normal_x"] == 0.0
        @test ev["normal_y"] == -1.0
        @test ev["peg_theta"] == 0.0
        @test ev["impact_x"] == 230.0
        @test ev["impact_y"] == 194.0
    end

    @testset "annular corner sweep" begin
        c = _phys_config()
        # Quarter annulus; the ball approaches the r_out corner at angle 0 from
        # outside the angular span, so the outer arc path declines and the
        # corner circle resolves the contact.
        peg = _phys_annular(1, 200.0, 200.0, 20.0, 40.0, 0.0, pi / 2)
        ball = _phys_ball(1, 250.0, 190.0; vx = -600.0, vy = 600.0)
        j = _phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "sweep"
        @test ev["peg_theta"] == 0.0
        @test isapprox(ev["normal_x"], sqrt(2) / 2; atol = 1e-9)
        @test isapprox(ev["normal_y"], -sqrt(2) / 2; atol = 1e-9)
        @test ev["normal_x"] == -ev["normal_y"]
        @test ev["toi"] > 0.5 && ev["toi"] < 0.7
    end

    @testset "rectangle swept face" begin
        c = _phys_config()
        peg = _phys_rect(2, 300.0, 300.0, 40.0, 20.0, 0.0)
        ball = _phys_ball(1, 300.0, 280.0; vy = 400.0)
        j = _phys_step!([ball], PeggleSim.Peg[], [peg]; c = c)
        ev = only([e for e in _phys_raw(j, "ball_contacted_peg")
                   if e["contact_kind"] == "sweep"])
        @test ev["peg_shape"] == "rectangle"
        @test ev["normal_x"] == 0.0
        @test ev["normal_y"] == -1.0
        @test ev["impact_y"] == 284.0
        @test ev["outgoing_vy"] == -c.restitution * ev["incoming_vy"]
    end

    @testset "rectangle swept corner" begin
        c = _phys_config()
        peg = _phys_rect(2, 300.0, 300.0, 40.0, 20.0, 0.0)
        # Toward the top-right corner (320, 290) from outside the side spans.
        ball = _phys_ball(1, 330.0, 280.0; vx = -600.0, vy = 600.0)
        j = _phys_step!([ball], PeggleSim.Peg[], [peg]; c = c)
        ev = only([e for e in _phys_raw(j, "ball_contacted_peg")
                   if e["contact_kind"] == "sweep"])
        @test isapprox(ev["normal_x"], sqrt(2) / 2; atol = 1e-9)
        @test isapprox(ev["normal_y"], -sqrt(2) / 2; atol = 1e-9)
        @test ev["toi"] > 0.5 && ev["toi"] < 0.7
    end

    @testset "ball-ball swept collision and equal-mass impulse" begin
        c = _phys_config(gravity = 0.0, ball_ball_collisions = true)
        a = _phys_ball(1, 190.0, 900.0; vx = 400.0)
        b = _phys_ball(2, 210.0, 900.0; vx = -400.0)
        j = _phys_step!([a, b]; c = c)
        ev = _phys_raw(j, "ball_contact_ball")[1]
        @test ev["ball_id"] == 1
        @test ev["other_ball_id"] == 2
        @test ev["contact_kind"] == "sweep"
        @test ev["did_bounce"] === true
        @test ev["normal_x"] == -1.0 && ev["normal_y"] == 0.0
        # Equal-mass split impulse: momentum 400 = -320 + 320.
        @test ev["incoming_vx"] == 400.0
        @test ev["outgoing_vx"] == -320.0
        @test ev["other_outgoing_vx"] == 320.0
        @test ev["outgoing_vx"] + ev["other_outgoing_vx"] == 0.0
        @test a.vx < 0.0 && b.vx > 0.0
    end

    @testset "ball-ball path with collisions disabled" begin
        c = _phys_config(gravity = 0.0, ball_ball_collisions = false)
        a = _phys_ball(1, 190.0, 900.0; vx = 400.0)
        b = _phys_ball(2, 210.0, 900.0; vx = -400.0)
        j = _phys_step!([a, b]; c = c)
        @test isempty(_phys_raw(j, "ball_contact_ball"))
        @test a.x > 190.0
        @test b.x < 210.0
    end

    @testset "fever divider extras" begin
        c = _phys_config()
        divider = PeggleSim.FeverDivider(200.0, 100.0, 40.0, true)
        ball = _phys_ball(1, 148.0, 100.0; vx = 400.0)
        j = _phys_step!([ball]; c = c, extras = PeggleSim.FeverDivider[divider])
        ev = only(_phys_raw(j, "ball_contact_fever_divider"))
        @test ev["contact_kind"] == "sweep"
        @test ev["did_bounce"] === true
        @test ev["normal_x"] == -1.0 && ev["normal_y"] == 0.0
        @test ev["outgoing_vx"] == -c.restitution * ev["incoming_vx"]
        # Lua's `is_extra and nil or circ` evaluates to the divider, so
        # emit_contact reports the static divider transform: shape "circle",
        # x/y, angle 0, and no id/type/line (the divider has none).
        @test ev["peg_shape"] == "circle"
        @test ev["peg_x"] == 200.0 && ev["peg_y"] == 100.0
        @test ev["peg_angle"] == 0.0
        @test !haskey(ev, "peg_id") && !haskey(ev, "peg_type")
        @test !haskey(ev, "line") && !haskey(ev, "peg_theta")
        @test !haskey(ev, "wall")

        # A miss inside the graze tolerance never grazes (dividers have no
        # `hit` field; the extra path is excluded from graze collection).
        near = _phys_ball(1, 100.0, 100.0 + 46.0 + c.graze_tolerance * 0.5;
                          vx = 400.0)
        j2 = _phys_step!([near]; c = c, extras = PeggleSim.FeverDivider[divider])
        @test isempty(j2.raw)
    end

    @testset "event payload key sets" begin
        c = _phys_config()

        # Circle sweep without line metadata -> no `line` key.
        ball = _phys_ball(1, 200.0, 280.0; vy = 400.0)
        peg = _phys_circle(5, 200.0, 300.0)
        fields = only(_phys_fields(_phys_step!([ball], [peg]; c = c), "ball_contacted_peg"))
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, PHYS_PEG_KEYS)

        # With line metadata -> `line` key present.
        ball = _phys_ball(1, 200.0, 280.0; vy = 400.0)
        peg = _phys_circle(5, 200.0, 300.0; line = _phys_line())
        fields = only(_phys_fields(_phys_step!([ball], [peg]; c = c), "ball_contacted_peg"))
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, PHYS_PEG_KEYS, Set(["line"]))

        # Annular sweep -> `peg_theta` present.
        ball = _phys_ball(1, 148.0, 200.0; vx = 400.0)
        peg = _phys_annular(1, 200.0, 200.0, 20.0, 40.0, 0.0, Float64(pi))
        fields = only(_phys_fields(_phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[],
                                               [peg]; c = c), "ball_contacted_peg"))
        @test Set(keys(fields)) ==
              union(PHYS_BASE_KEYS, PHYS_PEG_KEYS, Set(["peg_theta"]))

        # Graze -> no peg transform keys.
        ball = _phys_ball(1, 100.0, 100.0; vx = 400.0)
        move_x = ball.vx * c.fixed_dt
        peg = _phys_circle(7, ball.x + move_x * 0.5, ball.y + 15.0 + 0.25)
        fields = only(_phys_fields(_phys_step!([ball], [peg]; c = c), "ball_contacted_peg"))
        @test Set(keys(fields)) ==
              union(PHYS_BASE_KEYS, Set(["peg_id", "peg_type", "peg_shape"]))

        # Wall -> `wall` key.
        ball = _phys_ball(1, 8.0, 8.0; vy = -500.0)
        fields = only(_phys_fields(_phys_step!([ball]; c = c), "ball_contact_wall"))
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, Set(["wall"]))

        # Ball-ball sweep -> other-ball keys plus `other_outgoing_*`.
        c0 = _phys_config(gravity = 0.0)
        a = _phys_ball(1, 190.0, 900.0; vx = 400.0)
        b = _phys_ball(2, 210.0, 900.0; vx = -400.0)
        fields = _phys_fields(_phys_step!([a, b]; c = c0), "ball_contact_ball")[1]
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, PHYS_BALL_KEYS)

        # Fever divider -> the static divider transform (Lua passes the
        # divider table through `is_extra and nil or circ`), but no id/type/
        # line/theta/wall because the divider carries none of those fields.
        divider = PeggleSim.FeverDivider(200.0, 100.0, 40.0, true)
        ball = _phys_ball(1, 148.0, 100.0; vx = 400.0)
        fields = only(_phys_fields(_phys_step!([ball]; c = c,
                                               extras = PeggleSim.FeverDivider[divider]),
                                   "ball_contact_fever_divider"))
        @test Set(keys(fields)) == union(
            PHYS_BASE_KEYS, Set(["peg_shape", "peg_x", "peg_y", "peg_angle"]))
        @test fields["peg_shape"] == "circle"
        @test fields["peg_x"] == 200.0 && fields["peg_y"] == 100.0
        @test fields["peg_angle"] == 0.0
    end

    @testset "peg depenetration fallback" begin
        c = _phys_config(gravity = 0.0)
        peg = _phys_circle(4, 110.0, 100.0)
        ball = _phys_ball(1, 103.0, 100.0; vx = 50.0, vy = -20.0)
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 1, 1)
        ctx = PeggleSim.PhysicsContext(PeggleSim.BallState[ball], c, PHYS_VW, j)
        ctx.ball = ball
        ctx.total_dt = c.fixed_dt
        @test PeggleSim.depenetrate(ctx, [peg], "circle") === nothing
        ev = only(_phys_raw(j, "ball_contacted_peg"))
        @test ev["contact_kind"] == "depenetrate"
        @test ev["toi"] == 0.0 && ev["iteration"] == 0
        @test ev["frame_t"] == 1.0
        @test ev["impact_x"] == 103.0 && ev["impact_y"] == 100.0
        @test ev["incoming_vx"] == 50.0 && ev["incoming_vy"] == -20.0
        @test ev["outgoing_vx"] == 50.0 && ev["outgoing_vy"] == -20.0
        @test ev["did_bounce"] === false
        @test ev["normal_x"] == -1.0 && ev["normal_y"] == 0.0
        fields = only(_phys_fields(j, "ball_contacted_peg"))
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, PHYS_PEG_KEYS)
        # overlap = 15 - 7 = 8; pushed by overlap + margin.
        @test ball.x == 103.0 - (8.0 + c.overlap_push_margin)
        @test ball.y == 100.0
    end

    @testset "ball depenetration fallback" begin
        c = _phys_config(gravity = 0.0)
        a = _phys_ball(1, 100.0, 100.0)
        b = _phys_ball(2, 110.0, 100.0)
        j = PeggleSim.GameplayJournal()
        PeggleSim.begin_step!(j, 1, 1)
        ctx = PeggleSim.PhysicsContext(PeggleSim.BallState[a, b], c, PHYS_VW, j)
        ctx.ball = a
        ctx.total_dt = c.fixed_dt
        @test PeggleSim.depenetrate_balls(ctx) === nothing
        ev = only(_phys_raw(j, "ball_contact_ball"))
        @test ev["contact_kind"] == "depenetrate"
        @test ev["other_ball_id"] == 2
        # No post-impulse other-vout fields on a depenetration report (Lua
        # nil-assignment drops those keys).
        fields = only(_phys_fields(j, "ball_contact_ball"))
        @test Set(keys(fields)) == union(PHYS_BASE_KEYS, Set(["other_ball_id"]))
        @test !haskey(ev, "other_outgoing_vx") && !haskey(ev, "other_outgoing_vy")
        # overlap = 12 - 10 = 2.
        @test a.x == 100.0 - (2.0 + c.overlap_push_margin)
        @test a.y == 100.0
    end

    @testset "annular band depenetration is side-aware" begin
        c = _phys_config(gravity = 0.0)

        # Inner-wall overlap nudges back into the hole, never across the band.
        peg = _phys_annular(1, 600.0, 950.0, 100.0, 120.0, -0.05, 0.05)
        ball = _phys_ball(1, 600.0 + 100.0 - 6.0 + 0.03, 950.0)
        _phys_step!([ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        dist = abs(ball.x - 600.0)
        @test dist <= 100.0
        @test (100.0 - 6.0 + 0.03) - dist < 1.0

        # A band center nearer the hole exits inward; nearer the rim, outward.
        inner_ball = _phys_ball(1, 600.0 + 105.0, 950.0)
        _phys_step!([inner_ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        @test abs(inner_ball.x - 600.0) < 100.0

        outer_ball = _phys_ball(1, 600.0 + 115.0, 950.0)
        _phys_step!([outer_ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        @test abs(outer_ball.x - 600.0) > 120.0

        # A ball with full clearance sits untouched.
        clear_ball = _phys_ball(1, 600.0 + 90.0, 950.0)
        _phys_step!([clear_ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg]; c = c)
        @test clear_ball.x == 600.0 + 90.0
        @test clear_ball.y == 950.0
    end

    @testset "determinism across independent runs" begin
        function run()
            c = _phys_config()
            pegs = PeggleSim.Peg[
                _phys_circle(1, 200.0, 120.0),
                _phys_circle(2, 260.0, 240.0),
                _phys_rect(3, 200.0, 320.0, 40.0, 20.0, 0.25),
                _phys_annular(4, 300.0, 160.0, 20.0, 40.0, 0.0, Float64(pi)),
            ]
            ball = _phys_ball(1, 200.0, 60.0; vx = 0.0, vy = 400.0)
            j = PeggleSim.GameplayJournal()
            events = Dict{String,Any}[]
            for step in 1:120
                PeggleSim.begin_step!(j, step, 1)
                PeggleSim.physics_update!(PeggleSim.BallState[ball],
                                          PeggleSim.Peg[p for p in pegs if p.shape isa PeggleSim.CircleShape],
                                          PeggleSim.Peg[p for p in pegs if p.shape isa PeggleSim.RectangleShape],
                                          PeggleSim.Peg[p for p in pegs if p.shape isa PeggleSim.AnnularShape],
                                          c.fixed_dt, nothing, c, PHYS_VW, j)
                append!(events, (PeggleSim.event_dict(e) for e in j.raw))
            end
            return (_bits((ball.x, ball.y, ball.vx, ball.vy)), events)
        end

        bits1, events1 = run()
        bits2, events2 = run()
        @test bits1 == bits2
        @test events1 == events2
        @test length(events1) > 0
        @test PeggleSim.canonical_json(events1) == PeggleSim.canonical_json(events2)
    end

    @testset "launch velocity and aim snapping" begin
        c = _phys_config()

        # Near-vertical direct aim falls back to the unit direction.
        vx, vy = PeggleSim.get_launch_velocity(0.0, 0.0, 0.0, 100.0, 800.0, c)
        @test vx == 0.0 && vy == 800.0

        # Ballistic aim passes through the target: y(t) = 0 at x = xt.
        vx, vy = PeggleSim.get_launch_velocity(0.0, 0.0, 100.0, 0.0, 800.0, c)
        @test isapprox(vx * vx + vy * vy, 800.0^2; rtol = 1e-12)
        @test vx > 0.0 && vy < 0.0
        t = 100.0 / vx
        @test isapprox(vy * t + 0.5 * c.gravity * t * t, 0.0; atol = 1e-6)

        # Out of range falls back to direct aim.
        vx, vy = PeggleSim.get_launch_velocity(0.0, 0.0, 10000.0, 0.0, 100.0, c)
        @test isapprox(vx, 100.0; atol = 1e-9) == false || vx > 0.0
        @test isapprox(vx * vx + vy * vy, 100.0^2; rtol = 1e-12)

        # Snapping: the arc midpoint is a fixed point; the grid has
        # aim_discretization_steps cells across [mid-limit, mid+limit].
        @test PeggleSim.get_snapped_aim_angle(pi / 2, c) == pi / 2
        step = (2 * c.aim_angle_limit) / c.aim_discretization_steps
        a = pi / 2 - c.aim_angle_limit + 3.4 * step
        @test PeggleSim.get_snapped_aim_angle(a, c) ==
              pi / 2 - c.aim_angle_limit + 3 * step
        # Clamped inputs snap to the endpoints.
        @test PeggleSim.get_snapped_aim_angle(-10.0, c) ==
              pi / 2 - c.aim_angle_limit
        @test PeggleSim.get_snapped_aim_angle(10.0, c) ==
              pi / 2 + c.aim_angle_limit
    end
end
