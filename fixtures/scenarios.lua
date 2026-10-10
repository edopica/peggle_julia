-- Targeted boundary scenarios for the M1 fixture matrix.
--
-- Each entry runs against the pinned reference under LÖVE (real RNG, real
-- arithmetic) and returns a compact, JSON-encodable observation record. The
-- runner snapshots scalar Config values and LevelManager dimensions around
-- every scenario, so mutations here cannot leak into other fixtures.
--
-- Scenarios are deliberately at the physics/engine seam where natural aim
-- grid shots cannot reliably target the boundary: exact graze thresholds,
-- near-ties inside toi_epsilon, depenetration exits, and cap geometry.

local Config = require("src.config")
local Physics = require("src.systems.physics")
local Ball = require("src.entities.ball")
local Peg = require("src.entities.peg")
local H = require("tests.helpers.engine_helpers")
local CanonicalJSON = require("canonical_json")

local Scenarios = {}

local GRAZE_PEG_RADIUS = 10

local function contact_sink(events)
	return {
		emit_raw = function(_, event_type, fields)
			events[#events + 1] = {
				type = event_type,
				ball_id = fields.ball_id,
				peg_id = fields.peg_id,
				peg_shape = fields.peg_shape,
				contact_kind = fields.contact_kind,
				did_bounce = fields.did_bounce and true or false,
				toi = fields.toi,
				impact_x = fields.impact_x,
				impact_y = fields.impact_y,
				normal_x = fields.normal_x,
				normal_y = fields.normal_y,
				incoming_vx = fields.incoming_vx,
				incoming_vy = fields.incoming_vy,
				outgoing_vx = fields.outgoing_vx,
				outgoing_vy = fields.outgoing_vy,
			}
		end,
	}
end

local function summarize_events(events)
	local kinds = {}
	for _, event in ipairs(events) do
		kinds[#kinds + 1] = event.contact_kind
	end
	return CanonicalJSON.array(kinds)
end

-- Fail the scenario before its record is accepted when the captured contact
-- does not reach the mechanism the fixture claims to cover. The runner wraps
-- run() in pcall, so the message reaches the capture log verbatim.
local function scenario_assert(condition, message)
	if not condition then
		error("scenario assertion failed: " .. message, 0)
	end
end

-- Require the first captured event to be a genuine bouncing swept contact
-- with the expected peg shape, and (optionally) its impact point on a given
-- world-space corner or its normal aligned with a given surface normal.
local function assert_first_swept_contact(events, expected)
	local first = events[1]
	scenario_assert(first ~= nil, "expected a contact event but none was captured")
	scenario_assert(first.contact_kind == "sweep",
		string.format('first contact kind "%s", expected "sweep" (toi=%s)',
			tostring(first.contact_kind), tostring(first.toi)))
	scenario_assert(first.toi > 0,
		"first sweep toi is " .. tostring(first.toi) .. ", expected > 0")
	scenario_assert(first.did_bounce == true,
		"first sweep did_bounce is " .. tostring(first.did_bounce) .. ", expected true")
	scenario_assert(first.peg_shape == expected.peg_shape,
		string.format('first contact peg_shape "%s", expected "%s"',
			tostring(first.peg_shape), expected.peg_shape))
	if expected.corner then
		local px = first.impact_x - first.normal_x * Config.ball_radius
		local py = first.impact_y - first.normal_y * Config.ball_radius
		local dx = px - expected.corner.x
		local dy = py - expected.corner.y
		local dist = math.sqrt(dx * dx + dy * dy)
		scenario_assert(dist <= expected.tolerance,
			string.format(
				"first sweep impact point (%.9f, %.9f) is %.9f px from the intended corner (%.9f, %.9f)",
				px, py, dist, expected.corner.x, expected.corner.y))
	end
	if expected.normal then
		local dot = first.normal_x * expected.normal.x + first.normal_y * expected.normal.y
		scenario_assert(dot > 0.999,
			string.format(
				"first sweep normal (%.9f, %.9f) dot expected normal (%.9f, %.9f) = %.9f, expected > 0.999",
				first.normal_x, first.normal_y, expected.normal.x, expected.normal.y, dot))
	end
	for i = 2, #events do
		scenario_assert(events[i].contact_kind ~= "overlap",
			"contact " .. i .. " is an overlap correction; expected a clean swept first contact")
	end
	return first
end

-- Ball falls past a circle peg at a fixed center-line gap. The gap is
-- measured beyond the exact tangent distance (peg radius + ball radius).
local function graze_probe(gap)
	local saved = Config.gravity
	Config.gravity = 0
	local peg = Peg.new(600, 300, "blue", GRAZE_PEG_RADIUS)
	peg.original_index = 1
	local ball = Ball.new(600 - (GRAZE_PEG_RADIUS + Config.ball_radius + gap), 150)
	ball.id = 1
	ball.launched = true
	ball.vy = 400
	local events = {}
	local steps = 0
	for i = 1, 120 do
		Physics.update({ ball }, { peg }, {}, {}, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if ball.y > 500 then break end
	end
	Config.gravity = saved
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			gap = gap,
			event_count = #events,
			contact_kinds = summarize_events(events),
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

-- Ball sweeps the bottom-left local corner of a rotated rectangle. The path
-- runs along the rotated local -y axis from local y = half_h + start_offset,
-- at local x = -half_w - delta with 0 < delta < ball_radius. The lateral
-- offset leaves every expanded side segment (whose local x ranges start at
-- -half_w), so the corner circle is the only candidate and the first frame
-- starts clear of the expanded box.
local function rectangle_corner_probe(angle)
	local saved = Config.gravity
	Config.gravity = 0
	local rect = Peg.new_rectangle(600, 300, "blue", 40, 20, angle)
	rect.original_index = 1
	local half_w, half_h = 20, 10
	local delta = 3
	-- Contact lands at t = 0.9997 of the second frame: the residual window
	-- (dt * 3e-4 < 1e-5 s) is below the physics loop's threshold, so no
	-- follow-up iteration samples the ball inside the discrete graze band.
	-- (No-contact frames advance 0.999 of the move via the safe margin.)
	local start_offset = 31.8455
	local corner_local = { x = -half_w, y = half_h }
	local start_local = { x = -half_w - delta, y = half_h + start_offset }
	local corner_x = 600 + math.cos(angle) * corner_local.x - math.sin(angle) * corner_local.y
	local corner_y = 300 + math.sin(angle) * corner_local.x + math.cos(angle) * corner_local.y
	local start_x = 600 + math.cos(angle) * start_local.x - math.sin(angle) * start_local.y
	local start_y = 300 + math.sin(angle) * start_local.x + math.cos(angle) * start_local.y
	local speed = 800
	local vx = speed * math.sin(angle)
	local vy = -speed * math.cos(angle)
	local ball = Ball.new(start_x, start_y)
	ball.id = 1
	ball.launched = true
	ball.vx = vx
	ball.vy = vy
	local events = {}
	local steps = 0
	for i = 1, 90 do
		Physics.update({ ball }, {}, { rect }, {}, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if #events > 0 or ball.y > 460 then break end
	end
	Config.gravity = saved
	assert_first_swept_contact(events, {
		peg_shape = "rectangle",
		corner = { x = corner_x, y = corner_y },
		tolerance = 1e-6,
	})
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			angle = angle,
			corner_local = { x = corner_local.x, y = corner_local.y },
			corner = { x = corner_x, y = corner_y },
			delta = delta,
			start_offset = start_offset,
			start = { x = start_x, y = start_y },
			velocity = { vx = vx, vy = vy },
			event_count = #events,
			contact_kinds = summarize_events(events),
			events = events,
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

local function annular_sector()
	local peg = Peg.new_annular(600, 300, "blue", 40, 50, -0.5, 0.5)
	peg.original_index = 1
	return peg
end

-- Ball approaches the outer surface radially from outside.
local function annular_outer_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local peg = annular_sector()
	local ball = Ball.new(600 + 50 + Config.ball_radius + 1, 300)
	ball.id = 1
	ball.launched = true
	ball.vx = -200
	local events = {}
	local steps = 0
	for i = 1, 90 do
		Physics.update({ ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if ball.x < 590 then break end
	end
	Config.gravity = saved
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			surface = "outer",
			event_count = #events,
			contact_kinds = summarize_events(events),
			events = events,
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

-- Ball inside the hole approaches the inner surface radially from inside.
local function annular_inner_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local peg = annular_sector()
	local ball = Ball.new(600 + 40 - Config.ball_radius - 1, 300)
	ball.id = 1
	ball.launched = true
	ball.vx = 200
	local events = {}
	local steps = 0
	for i = 1, 90 do
		Physics.update({ ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if ball.x > 610 then break end
	end
	Config.gravity = saved
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			surface = "inner",
			event_count = #events,
			contact_kinds = summarize_events(events),
			events = events,
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

-- Ball approaches the sector's start cap (angle -0.5) from outside the
-- angular span, perpendicular to the cap plane, at band radius 45. Starting
-- 0.2 rad (d0 = 45*sin(0.2) = 8.94 px) out leaves the ball clear of the cap
-- graze band (6.5 px), and the crossing point sits at cap radius
-- 45*cos(0.2) = 44.10, clear of the r_in/r_out corner graze bands, so the cap
-- registers the first sweeping bounce.
local function annular_cap_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local peg = annular_sector()
	local cap_angle = -0.5
	local radius = 45
	local angular_offset = 0.2
	local theta = cap_angle - angular_offset
	local start_x = 600 + radius * math.cos(theta)
	local start_y = 300 + radius * math.sin(theta)
	local normal = { x = math.sin(cap_angle), y = -math.cos(cap_angle) }
	local speed = 250
	local vx = -normal.x * speed
	local vy = -normal.y * speed
	local ball = Ball.new(start_x, start_y)
	ball.id = 1
	ball.launched = true
	ball.vx = vx
	ball.vy = vy
	local events = {}
	local steps = 0
	for i = 1, 90 do
		Physics.update({ ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if ball.x < 560 or ball.y < 200 then break end
	end
	Config.gravity = saved
	local first = assert_first_swept_contact(events, {
		peg_shape = "annular",
		normal = normal,
	})
	local qx = first.impact_x - first.normal_x * Config.ball_radius
	local qy = first.impact_y - first.normal_y * Config.ball_radius
	local cap_dx, cap_dy = qx - 600, qy - 300
	local cap_radius = math.sqrt(cap_dx * cap_dx + cap_dy * cap_dy)
	local off_axis = math.abs(cap_dx * math.sin(cap_angle) - cap_dy * math.cos(cap_angle))
	scenario_assert(off_axis <= 1e-6,
		string.format("sweep impact is %.6f px off the cap plane", off_axis))
	scenario_assert(cap_radius >= peg.r_in and cap_radius <= peg.r_out,
		string.format("sweep impact radius %.6f is outside the cap span [%g, %g]",
			cap_radius, peg.r_in, peg.r_out))
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			surface = "cap",
			cap_angle = cap_angle,
			angular_offset = angular_offset,
			start = { x = start_x, y = start_y },
			velocity = { vx = vx, vy = vy },
			cap_normal = normal,
			cap_radius = cap_radius,
			event_count = #events,
			contact_kinds = summarize_events(events),
			events = events,
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

-- Two identical pegs at equal distance from the launch column: the first
-- physics contact frame contains a TOI tie that the reducer must break by
-- candidate order (lower original_index first).
local function near_tie_probe()
	local engine = H.new_engine()
	local pegs = {
		Peg.new(585, 300, "blue", 10),
		Peg.new(615, 300, "blue", 10),
	}
	H.setup_engine(engine, pegs, { red = 0, green = 0 }, 1)
	local start_step = engine.sim_step_id
	H.run_shot(engine, 600, 150, 0, 400, 600)
	local order = {}
	for _, peg in ipairs(engine.turnPegsHit) do
		order[#order + 1] = peg.original_index
	end
	return {
		steps = engine.sim_step_id - start_step,
		completed = true,
		reason = "probe_complete",
		result = {
			scored_order = order,
			pegs_hit = #engine.turnPegsHit,
			score = engine:getTurnScore(),
		},
	}
end

-- Regression case from the annular depenetration test: a ball resting
-- 0.03 px inside the inner wall of a large-radius, tiny-span border must be
-- nudged back into the hole, not pushed through the wall.
local function depenetration_inner_wall_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local cx, cy = 600, 950
	local r_in, r_out = 8724.9, 8744.9
	local span = 0.0014
	local peg = Peg.new_annular(cx, cy, "blue", r_in, r_out, -span / 2, span / 2)
	peg.original_index = 1
	local ball = Ball.new(cx + r_in - Config.ball_radius + 0.03, cy)
	ball.id = 1
	ball.launched = true
	local function radial()
		local dx, dy = ball.x - cx, ball.y - cy
		return math.sqrt(dx * dx + dy * dy)
	end
	local before = radial()
	local events = {}
	Physics.update({ ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(events))
	local after = radial()
	Config.gravity = saved
	return {
		steps = 1,
		completed = true,
		reason = "probe_complete",
		result = {
			before = before,
			after = after,
			moved = before - after,
			inside_hole = after <= r_in,
			contact_kinds = summarize_events(events),
			final = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy },
		},
	}
end

-- Regression case from the annular depenetration test: an overlapped ball in
-- the band exits through whichever surface is nearer.
local function depenetration_band_exit_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local cx, cy = 600, 950
	local r_in, r_out = 100, 120
	local peg = Peg.new_annular(cx, cy, "blue", r_in, r_out, -0.05, 0.05)
	peg.original_index = 1
	local function radial(ball)
		local dx, dy = ball.x - cx, ball.y - cy
		return math.sqrt(dx * dx + dy * dy)
	end
	local inner_ball = Ball.new(cx + 105, cy)
	inner_ball.id = 1
	inner_ball.launched = true
	local inner_events = {}
	Physics.update({ inner_ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(inner_events))

	local outer_ball = Ball.new(cx + 115, cy)
	outer_ball.id = 2
	outer_ball.launched = true
	local outer_events = {}
	Physics.update({ outer_ball }, {}, {}, { peg }, Config.fixed_dt, {}, contact_sink(outer_events))
	Config.gravity = saved
	return {
		steps = 1,
		completed = true,
		reason = "probe_complete",
		result = {
			inner_ball_radius = radial(inner_ball),
			inner_exits_inward = radial(inner_ball) < r_in,
			inner_contact_kinds = summarize_events(inner_events),
			outer_ball_radius = radial(outer_ball),
			outer_exits_outward = radial(outer_ball) > r_out,
			outer_contact_kinds = summarize_events(outer_events),
		},
	}
end

-- Equal-mass head-on ball-ball collision: both balls carry identical
-- identity-independent state, so the exchange is exactly symmetric.
local function ball_ball_impulse_probe()
	local saved = Config.gravity
	Config.gravity = 0
	local a = Ball.new(580, 300)
	a.id = 1
	a.launched = true
	a.vx = 200
	a.vy = 0
	local b = Ball.new(620, 300)
	b.id = 2
	b.launched = true
	b.vx = -200
	b.vy = 0
	local events = {}
	local steps = 0
	for i = 1, 60 do
		Physics.update({ a, b }, {}, {}, {}, Config.fixed_dt, {}, contact_sink(events))
		steps = i
		if a.vx < 0 and b.vx > 0 then break end
	end
	Config.gravity = saved
	return {
		steps = steps,
		completed = true,
		reason = "probe_complete",
		result = {
			event_count = #events,
			contact_kinds = summarize_events(events),
			a = { x = a.x, y = a.y, vx = a.vx, vy = a.vy },
			b = { x = b.x, y = b.y, vx = b.vx, vy = b.vy },
		},
	}
end

Scenarios[#Scenarios + 1] = {
	id = "probe_graze_gap_0_25",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = function() return graze_probe(0.25) end,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_graze_gap_0_50",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = function() return graze_probe(0.5) end,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_graze_gap_0_75",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = function() return graze_probe(0.75) end,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_rectangle_corner_rotated",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = function() return rectangle_corner_probe(0.6) end,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_annular_outer_surface",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = annular_outer_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_annular_inner_surface",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = annular_inner_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_annular_cap_crossing",
	category = "shape_boundary",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = annular_cap_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_near_tie_equal_toi",
	category = "near_tie",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = near_tie_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_depenetration_inner_wall",
	category = "overlap_correction",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = depenetration_inner_wall_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_depenetration_band_exit",
	category = "overlap_correction",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = depenetration_band_exit_probe,
}

Scenarios[#Scenarios + 1] = {
	id = "probe_ball_ball_impulse",
	category = "multiball",
	seed = 1,
	type_counts = { red = 0, green = 0 },
	run = ball_ball_impulse_probe,
}

return Scenarios
