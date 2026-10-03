-- Advanced Circuits level tests: loop geometry, hidden-return clearance,
-- deterministic setup, bounds exemption, preview agreement, and finite
-- physics through the entrance and exit crossings.
-- Plain LuaJIT lacks the "?/init.lua" package pattern that LÖVE provides;
-- add it so the level-select preview module can be required here.
local script_dir = debug.getinfo(1, "S").source:match("@(.*)/.*$") or "."
package.path = package.path .. ";" .. script_dir .. "/../?/init.lua"

local H = require("tests.helpers.engine_helpers")
local Level = require("src.levels.advanced_circuits")
local Path = require("src.systems.path")
local MotionSchema = require("src.systems.motion_schema")
local LevelManager = require("src.systems.level_manager")
local LevelSelectState = require("src.states.level_select")
local Circuits = require("src.systems.circuits")
local Config = require("src.config")
local Peg = require("src.entities.peg")
local Ball = require("src.entities.ball")
local Physics = require("src.systems.physics")

local VISIBLE_SEGMENTS = 8
local PEG_SPACING = 48
local CONVEYOR_SPEED = 170
local RETURN_CLEARANCE = Config.peg_radius + Config.ball_radius
	+ CONVEYOR_SPEED * Config.fixed_dt + 2 * Path.CUBIC_DISTANCE_TOLERANCE

local function with_level_dimensions(fn)
	local width, height = LevelManager.virtual_width, LevelManager.virtual_height
	local ok, err = pcall(fn)
	LevelManager.virtual_width, LevelManager.virtual_height = width, height
	if not ok then error(err, 0) end
end

local function loop_path()
	return Level.level_circuits.conveyor.path
end

local function visible_length(path)
	local total = 0
	for i = 1, VISIBLE_SEGMENTS do
		total = total + path.segments[i].length
	end
	return total
end

return {
	test_level_schema_and_closed_smooth_loop = function()
		local path = loop_path()
		assert_true(Path.is_path(path), "the conveyor uses a compiled Path")
		assert_true(path.closed, "the conveyor loop is closed")
		local ok, issue = path:validate_joins()
		assert_true(ok, "every join and the seam pass the shared contract"
			.. (issue and (" (" .. issue.kind .. " at " .. issue.from_segment .. "->" .. issue.to_segment .. ")") or ""))
		MotionSchema.validate(Level.pegs, Level.level_circuits)
		assert_eq(Level.level_circuits.conveyor.kind, "path")
		assert_true(Level.level_circuits.conveyor.speed > 0)

		local expected_count = math.floor(path:length() / PEG_SPACING)
		assert_eq(#Level.pegs, expected_count, "peg count follows loop length and spacing")
		assert_true(#Level.pegs >= 40, "the loop carries a full conveyor of pegs")
	end,

	test_peg_bases_and_phases_follow_the_loop = function()
		local path = loop_path()
		local length = path:length()
		local count = #Level.pegs
		for i, peg in ipairs(Level.pegs) do
			assert_eq(peg.motion.circuit, "conveyor")
			local expected_phase = (i - 1) / count * length
			assert_true(math.abs(peg.motion.phase - expected_phase) < 1e-9,
				"phase is the even arc-length position")
			local x, y = path:at_distance(expected_phase)
			assert_true(math.abs(peg.base_x - x) < 1e-9, "base follows the loop")
			assert_true(math.abs(peg.base_y - y) < 1e-9, "base follows the loop")
		end
	end,

	test_hidden_return_stays_clear_of_the_playfield = function()
		with_level_dimensions(function()
			local path = loop_path()
			local length = path:length()
			local start = visible_length(path)
			assert_eq(path.segments[VISIBLE_SEGMENTS + 1].p0.x, 1260,
				"coverage starts at the first hidden-return cubic")
			local width = Level.virtual_width
			-- Sample the return leg densely; the allowed region is outside the
			-- wall clearance band. This covers the whole return including the
			-- Hermite bulges between waypoints.
			-- Distance to the playfield is 1-Lipschitz. A half-sample margin
			-- covers between samples, in addition to one full physics sweep.
			local clearance = RETURN_CLEARANCE + (length - start) / 8000
			for i = 0, 4000 do
				local s = start + (length - start) * (i / 4000)
				local x, y = path:at_distance(s)
				local clear = x < -clearance
					or x > width + clearance
					or y < -clearance
				assert_true(clear, string.format(
					"return leg stays outside the playfield (s=%.1f -> %.1f, %.1f)", s, x, y))
			end
		end)
	end,

	test_visible_leg_crosses_both_side_walls = function()
		local path = loop_path()
		local finish = visible_length(path)
		local min_x, max_x = math.huge, -math.huge
		for i = 0, 2000 do
			local x, y = path:at_distance(finish * (i / 2000))
			if x < min_x then min_x = x end
			if x > max_x then max_x = x end
		end
		assert_true(min_x < 0, "the visible entrance starts outside the left wall")
		assert_true(max_x > Level.virtual_width, "the visible exit leaves past the right wall")
	end,

	test_every_peg_becomes_hittable_once_per_cycle = function()
		local path = loop_path()
		local length = path:length()
		local width, height = Level.virtual_width, Level.virtual_height
		local radius = Config.peg_radius
		for _, peg in ipairs(Level.pegs) do
			local hittable = false
			local steps = math.ceil(length / 8)
			for i = 0, steps - 1 do
				local x, y = path:at_distance((peg.motion.phase + i * (length / steps)) % length)
				if x > radius and x < width - radius and y > radius and y < height - radius then
					hittable = true
					break
				end
			end
			assert_true(hittable, "every peg reaches the hittable playfield interior")
		end
	end,

	test_engine_setup_keeps_offscreen_pegs_and_matches_preview = function()
		with_level_dimensions(function()
			local path = loop_path()
			local source_snapshot = {}
			for i, peg in ipairs(Level.pegs) do
				source_snapshot[i] = {
					x = peg.x, y = peg.y,
					time = peg.motion and peg.motion.time,
				}
			end

			local eng = H.new_engine()
			eng:setupLevel("advanced_circuits")
			assert_eq(#eng.pegs, #Level.pegs,
				"off-screen path pegs survive setup without placeholder bases")

			local state = setmetatable({}, { __index = LevelSelectState })
			state:_build_preview_pegs(Level)
			assert_eq(#state.preview_pegs, #eng.pegs, "preview covers every peg")

			-- Initialized engine and preview positions agree (same phase,
			-- same recorded time); the source module is not mutated.
			for i, peg in ipairs(eng.pegs) do
				local preview = state.preview_pegs[i]
				assert_true(math.abs(preview.x - peg.x) < 1e-9 && math.abs(preview.y - peg.y) < 1e-9,
					"preview matches initialized engine position")
				assert_true(math.abs(preview.motion.time - peg.motion.time) < 1e-9,
					"preview matches initialized motion time")
				assert_true(math.abs(Level.pegs[i].x - source_snapshot[i].x) < 1e-12
					&& Level.pegs[i].motion.time == source_snapshot[i].time,
					"preview does not mutate the source level data")
			end
		end)
	end,

	test_repeated_loads_are_identical = function()
		with_level_dimensions(function()
			local first = H.new_engine()
			first:setupLevel("advanced_circuits")
			local first_state = {}
			for i, peg in ipairs(first.pegs) do
				first_state[i] = { peg.x, peg.y, peg.type, peg.motion.phase }
			end

			local second = H.new_engine()
			second:setupLevel("advanced_circuits")
			assert_eq(#second.pegs, #first.pegs)
			for i, peg in ipairs(second.pegs) do
				local expected = first_state[i]
				assert_true(math.abs(peg.x - expected[1]) < 1e-12
					&& math.abs(peg.y - expected[2]) < 1e-12, "geometry is deterministic")
				assert_eq(peg.type, expected[3], "color assignment is deterministic")
				assert_eq(peg.motion.phase, expected[4], "peg order and phases are deterministic")
			end
		end)
	end,

	test_contacts_stay_in_bounds_and_velocities_stay_finite = function()
		with_level_dimensions(function()
			local vw, vh = Level.virtual_width, Level.virtual_height
			local total_contacts = 0
			local max_speed = 0
			local shots = {
				{ x = 600, y = 0, vx = 0, vy = 0 },
				{ x = 300, y = 0, vx = 400, vy = 200 },
				{ x = 900, y = 0, vx = -400, vy = 200 },
			}
			for _, shot in ipairs(shots) do
				local eng = H.new_engine()
				eng:setupLevel("advanced_circuits")
				assert_eq(#eng.pegs, #Level.pegs, "every shot sees the full conveyor")

				eng.callbacks.onStepFinalized = function(e, rec)
					for _, ball in ipairs(e.active_balls) do
						assert_true(ball.x == ball.x and ball.y == ball.y,
							"ball position stays finite")
						assert_true(ball.vx == ball.vx and ball.vy == ball.vy,
							"ball velocity stays finite")
						local speed = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
						if speed > max_speed then max_speed = speed end
					end
					for _, ev in ipairs(rec.raw_events) do
						if ev.type == "ball_contacted_peg" then
							total_contacts = total_contacts + 1
							local peg = e.peg_by_id[ev.peg_id]
							assert_true(peg ~= nil, "contact references a live peg")
							local margin = 40
							assert_true(peg.x > -margin and peg.x < vw + margin
								and peg.y > -margin and peg.y < vh + margin,
								"contacts only happen near the playfield, never on the return leg")
						end
					end
				end

				H.run_shot(eng, shot.x, shot.y, shot.vx, shot.vy, 60 * 20)
			end

			assert_true(total_contacts > 0, "the shots exercise peg contacts")
			assert_true(max_speed <= 4 * Config.launch_speed,
				"no teleport-scale ball impulses (max " .. max_speed .. ")")
		end)
	end,

	test_targeted_entrance_exit_and_seam_contacts = function()
		with_level_dimensions(function()
			LevelManager.virtual_width, LevelManager.virtual_height = Level.virtual_width, Level.virtual_height
			local path = loop_path()
			for _, side in ipairs({ "entrance", "exit", "seam" }) do
				local phase, ball_x, ball_y, vx
				local contact_path = path
				if side == "seam" then
					-- The authored seam is intentionally unreachable. Use an in-bounds
					-- smooth seam to exercise an actual CCD impact during a wrap step.
					contact_path = Path.new({ closed = true, segments = {
						{ kind = "arc", center = {500, 400}, radius = 100,
							theta_start = 0, sweep = 2 * math.pi },
					} })
					phase = contact_path:length() - 0.5
					local x, y = contact_path:at_distance(phase)
					ball_x, ball_y, vx = x + Config.peg_radius + Config.ball_radius + 1, y, -400
				else
					local wall_x = side == "entrance" and 0 or Level.virtual_width
					local lo, hi = 0, visible_length(path)
					for _ = 1, 50 do
						local mid = (lo + hi) / 2
						if path:at_distance(mid) < wall_x then lo = mid else hi = mid end
					end
					phase = (lo + hi) / 2
					local x, y = path:at_distance(phase)
					local direction = side == "entrance" and 1 or -1
					ball_x = x + direction * (Config.peg_radius + Config.ball_radius + 1)
					ball_y, vx = y, -direction * 300
				end
				local peg = Peg.new(0, 0, "red")
				peg.motion = { circuit = "conveyor", phase = phase }
				local eng = H.new_engine()
				H.setup_engine(eng, { peg }, { red = 1, green = 0 }, 1)
				eng.level_circuits = { conveyor = { kind = "path", path = contact_path, speed = CONVEYOR_SPEED } }
				Circuits.initialize(eng.pegs, eng.level_circuits)
				local records = H.make_recorder(eng)
				H.run_shot(eng, ball_x, ball_y, vx, 0, 1)
				local contacts = H.flatten_events(records, "ball_contacted_peg")
				assert_true(#contacts > 0, side .. " has an actual contact")
				local bounced = false
				for _, contact in ipairs(contacts) do
					if contact.did_bounce then bounced = true end
				end
				assert_true(bounced, side .. " contact deflects the ball")
				for _, ball in ipairs(eng.active_balls) do
					assert_true(math.sqrt(ball.vx^2 + ball.vy^2) < 4 * Config.launch_speed,
						side .. " has finite, bounded impulse")
				end
				if side == "seam" then
					assert_true(peg.motion.time > contact_path:length(), "contact step crosses seam")
				end
			end
		end)
	end,

	test_full_cycle_wraps_have_no_cross_playfield_contacts = function()
		with_level_dimensions(function()
			local eng = H.new_engine()
			eng:setupLevel("advanced_circuits")
			local path = loop_path()
			local length, dt = path:length(), Config.fixed_dt
			local wrapped = {}
			local contacts = 0
			local sink = { emit_raw = function(_, kind)
				if kind == "ball_contacted_peg" then contacts = contacts + 1 end
			end }
			for _ = 1, math.ceil(length / (CONVEYOR_SPEED * dt)) + 1 do
				local previous = {}
				for i, peg in ipairs(eng.pegs) do previous[i] = math.floor(peg.motion.time / length) end
				Circuits.update(eng.pegs, eng.level_circuits, dt)
				for i, peg in ipairs(eng.pegs) do
					assert_true(math.sqrt(peg.vx^2 + peg.vy^2)
						<= CONVEYOR_SPEED + 2 * Path.CUBIC_DISTANCE_TOLERANCE / dt)
					if math.floor(peg.motion.time / length) > previous[i] then
						wrapped[i] = true
						local ball = Ball.new(Level.virtual_width / 2, 900)
						ball.launched, ball.id = true, 1
						Physics.update({ ball }, { peg }, {}, {}, dt, nil, sink)
					end
				end
			end
			for i = 1, #eng.pegs do assert_true(wrapped[i], "every peg crosses the seam") end
			assert_eq(contacts, 0, "hidden seam sweeps never contact the central probe ball")
		end)
	end,
}
