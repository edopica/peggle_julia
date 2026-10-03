-- ===========================================================================
-- SlideInversion: valley (pendulum) detection and lowest-peg removal.
--
-- A ball can settle into a concave valley formed by a zero-gap generated
-- line (for example the inner face of the slide level's annular arc) and
-- oscillate like a pendulum, scoring peg after peg on every pass. This
-- processor detects the apex of each oscillation — the moment the ball stops
-- rolling along the slide and goes back — and asks the Engine to remove the
-- lowest already-hit peg(s) of that line, opening the valley floor so the
-- ball falls out instead of racking up extra points.
--
-- Detection (per launched ball, per slide line):
--   * The ball is "on a slide" while it keeps contacting a zero-gap line
--     (line.gap == 0) within slide_invert_contact_timeout. Contacting a
--     different line restarts the tracking.
--   * Each peg contact reports the surface normal (from peg to ball). The
--     signed tangential speed is  tang = n.x * v.y - n.y * v.x  — the
--     component of the ball's velocity along the slide surface. Its sign
--     says which way the ball is rolling; it flips exactly when the ball
--     reverses at an apex. No absolute speed threshold is involved: even a
--     low-energy swing that never exceeds walking pace is caught.
--   * |tang| below slide_invert_tangent_epsilon is ignored (the ball is
--     momentarily stopped and the sign is undetermined), so the previous
--     direction is held across the apex and the opposite sign after it is
--     read as a reversal.
--   * A genuine bounce (did_bounce) is not a pendulum inversion: it resyncs
--     the direction to the post-bounce motion instead of triggering.
--
-- Removal:
--   * On inversion the processor selects, among the already-hit pegs of the
--     sliding line, those whose recorded impact point y is the greatest
--     (lowest on screen). Ties within slide_invert_lowest_tie are all
--     selected. It pushes a `remove_slide_pegs` command with their stable
--     original_index ids. Pegs removed by an earlier inversion are skipped.
--   * Scoring is untouched: a removed peg stays in turnPegsHit, so its
--     points are still awarded. Only the board obstacle is removed.
--
-- Per-ball state is tracked across steps within a shot and reset on shot
-- start/completion.
-- ===========================================================================

local Config = require("src.config")

local SlideInversion = {}
local SlideInversion_mt = { __index = SlideInversion }

function SlideInversion.new()
	local self = setmetatable({}, SlideInversion_mt)
	self:reset_shot()
	return self
end

function SlideInversion:reset_shot()
	self.line_hits = {} -- line_id -> array of { peg_id, impact_y } in score order
	self.hit_seen = {}  -- peg_id -> true (first-hit guard)
	self.removed = {}   -- peg_id -> true (removed by this mechanic)
	self.track = {}     -- ball_id -> { line_id, no_contact_time, tangent_sign }
end

function SlideInversion:on_ball_removed(ball_id)
	self.track[ball_id] = nil
end

local function speed_of(b)
	return math.sqrt(b.vx * b.vx + b.vy * b.vy)
end

-- Sign of the ball's velocity along the contact surface (the tangential
-- component perpendicular to the contact normal). nil when the ball is too
-- slow for the sign to be trusted.
local function tangent_sign(nx, ny, b, epsilon)
	local speed = speed_of(b)
	if speed <= 0 then return nil end
	local tang = nx * b.vy - ny * b.vx
	if math.abs(tang) < epsilon then return nil end
	if tang > 0 then return 1 end
	return -1
end

-- Record first-hit impact positions for zero-gap lines. First-hit only, so
-- one entry per peg; impact_y is the y of the ball at the scoring contact.
function SlideInversion:_note_scores(events)
	for _, ev in ipairs(events:derived()) do
		if ev.type == "peg_scored"
			and type(ev.line) == "table" and ev.line.gap == 0
			and not self.hit_seen[ev.peg_id] then
			self.hit_seen[ev.peg_id] = true
			local line_id = ev.line.id
			local arr = self.line_hits[line_id]
			if not arr then
				arr = {}
				self.line_hits[line_id] = arr
			end
			table.insert(arr, { peg_id = ev.peg_id, impact_y = ev.impact_y or 0 })
		end
	end
end

-- Lowest already-hit, not-yet-removed pegs of a line, in deterministic
-- score order. Empty when the line has no eligible hit pegs.
function SlideInversion:_lowest_hit_pegs(line_id)
	local arr = self.line_hits[line_id]
	if not arr then return {} end
	local tie = Config.slide_invert_lowest_tie or 1.0
	local max_y = nil
	for _, rec in ipairs(arr) do
		if not self.removed[rec.peg_id] then
			if max_y == nil or rec.impact_y > max_y then
				max_y = rec.impact_y
			end
		end
	end
	if max_y == nil then return {} end
	local out = {}
	for _, rec in ipairs(arr) do
		if not self.removed[rec.peg_id] and rec.impact_y >= max_y - tie then
			table.insert(out, rec.peg_id)
		end
	end
	return out
end

-- Run the inversion check for one completed fixed step.
--   events       = GameplayEvents instance (raw + derived available, sealed)
--   commands     = GameplayCommands instance (push remove_slide_pegs)
--   active_balls = engine.active_balls (launched balls only are considered)
--   dt           = fixed dt
--   opts         = optional overrides (contact_timeout, tangent_epsilon).
function SlideInversion:process_step(events, commands, active_balls, dt, opts)
	opts = opts or {}
	local timeout = opts.contact_timeout or Config.slide_invert_contact_timeout or 0.3
	local epsilon = opts.tangent_epsilon or Config.slide_invert_tangent_epsilon or 2.0

	self:_note_scores(events)

	-- This step's zero-gap contact line + surface normal and any genuine
	-- bounce, per ball.
	local contact_line = {}
	local contact_normal = {}
	local bounced = {}
	for _, ev in ipairs(events:raw()) do
		local bid = ev.ball_id
		if bid ~= nil then
			if ev.type == "ball_contacted_peg"
				and type(ev.line) == "table" and ev.line.gap == 0 then
				contact_line[bid] = ev.line.id
				contact_normal[bid] = { ev.normal_x or 0, ev.normal_y or 0 }
			end
			if ev.did_bounce then
				bounced[bid] = true
			end
		end
	end

	for _, b in ipairs(active_balls) do
		if not b.launched then goto continue end
		local bid = b.id
		local line_id = contact_line[bid]
		local track = self.track[bid]

		if line_id then
			if track and track.line_id ~= line_id then
				-- A different line ends the previous slide.
				track = nil
				self.track[bid] = nil
			end
			if not track then
				track = { line_id = line_id, no_contact_time = 0, tangent_sign = nil }
				self.track[bid] = track
			end
			track.no_contact_time = 0
		elseif track then
			track.no_contact_time = track.no_contact_time + dt
			if track.no_contact_time > timeout then
				track = nil
				self.track[bid] = nil
			end
		end

		if track then
			local normal = contact_normal[bid]
			local sign = normal and tangent_sign(normal[1], normal[2], b, epsilon) or nil
			if bounced[bid] then
				-- A real bounce is not a pendulum inversion: resync the
				-- direction to the post-bounce motion.
				track.tangent_sign = sign
			elseif sign then
				if track.tangent_sign and sign ~= track.tangent_sign then
					-- The ball stopped rolling and went back: drop the lowest
					-- already-hit peg(s) of the line to open the valley.
					local peg_ids = self:_lowest_hit_pegs(track.line_id)
					if #peg_ids > 0 then
						for _, pid in ipairs(peg_ids) do
							self.removed[pid] = true
						end
						commands:push("remove_slide_pegs", {
							ball_id = bid,
							line_id = track.line_id,
							reason = "slide_direction_inversion",
							peg_ids = peg_ids,
						})
					end
				end
				track.tangent_sign = sign
			end
		end

		::continue::
	end
end

return SlideInversion
