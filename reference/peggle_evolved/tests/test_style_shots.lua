-- StyleShots unit tests with synthetic event/command fixtures.
local StyleShots = require("src.systems.style_shots")
local Config = require("src.config")

-- Minimal fake GameplayEvents + GameplayCommands for StyleShots.
local function make_fixtures()
	local ev = { _raw = {}, _derived = {} }
	ev.emit_raw = function(self, t, f) table.insert(self._raw, f) end
	ev.emit_derived = function(self, t, f) table.insert(self._derived, f) end
	ev.seal_raw = function() end
	ev.all = function(self)
		local out = {}
		for _, e in ipairs(self._raw) do table.insert(out, e) end
		for _, e in ipairs(self._derived) do table.insert(out, e) end
		return out
	end
	ev.raw = function(self) return self._raw end
	ev.derived = function(self) return self._derived end
	-- Helper to inject a raw/derived event directly.
	ev._add_raw = function(self, e) table.insert(self._raw, e) end
	ev._add_derived = function(self, e) table.insert(self._derived, e) end
	ev._reset = function() self = ev; ev._raw = {}; ev._derived = {} end

	local cmds = { _pushed = {} }
	cmds.push = function(self, t, f) table.insert(self._pushed, { type = t, fields = f or {} }) end
	cmds._reset = function() cmds._pushed = {} end
	return ev, cmds
end

local function make_peg_contact(seq, bid, kind, ix, iy, peg_type, peg_id, line, did_bounce)
	return {
		schema_version = 1, step = 1, shot_id = 1, sequence = seq, phase = "raw",
		type = "ball_contacted_peg", ball_id = bid,
		peg_id = peg_id or 1, peg_type = peg_type or "blue",
		peg_shape = "circle", contact_kind = kind or "sweep",
		did_bounce = did_bounce == nil and true or did_bounce,
		impact_x = ix, impact_y = iy,
		line = line,
	}
end

local function make_peg_scored(seq, bid, peg_type, ix, iy, line)
	return {
		schema_version = 1, step = 1, shot_id = 1, sequence = 1000 + seq,
		phase = "derived", type = "peg_scored",
		source_sequence = seq, ball_id = bid, peg_id = 1,
		peg_type = peg_type, impact_x = ix, impact_y = iy,
		line = line,
	}
end

-- A zero-gap line peg contact that scores (graze: non-bouncing) at the given
-- line index of line `id` (count defaults to 9 so wrap tests stay open).
local function slide_graze(seq, bid, line_id, index, count)
	local line = { id = line_id, index = index, count = count or 9,
		closed = false, gap = 0 }
	return make_peg_contact(seq, bid, "graze", 0, 0, "blue", index, line, false),
		make_peg_scored(seq, bid, "blue", 0, 0, line)
end

-- A scoring line contact that bounces (sweep), used for landing-bounce seeds.
local function slide_bounce(seq, bid, line_id, index, count)
	local line = { id = line_id, index = index, count = count or 9,
		closed = false, gap = 0 }
	return make_peg_contact(seq, bid, "sweep", 0, 0, "blue", index, line, true),
		make_peg_scored(seq, bid, "blue", 0, 0, line)
end

local function make_wall(seq, bid, wall, did_bounce)
	return { type = "ball_contact_wall", ball_id = bid, wall = wall or "left",
		sequence = seq, impact_x = 0, impact_y = 100,
		did_bounce = did_bounce == nil and true or did_bounce }
end

local function make_divider(seq, bid, did_bounce)
	return { type = "ball_contact_fever_divider", ball_id = bid, sequence = seq,
		did_bounce = did_bounce == nil and true or did_bounce }
end

local function make_ball_contact(seq, bid, other_bid, did_bounce)
	return { type = "ball_contact_ball", ball_id = bid, other_ball_id = other_bid,
		sequence = seq, impact_x = 0, impact_y = 0,
		did_bounce = did_bounce == nil and true or did_bounce }
end

local function make_bucket_bounced(seq, bid)
	return { type = "bucket_bounced_ball", ball_id = bid, sequence = seq }
end

local function make_bucket_caught(seq, bid)
	return { type = "bucket_caught_ball", ball_id = bid, sequence = seq }
end

-- Feed one synthetic step of raw/derived events through the recognizer.
local function feed_slide(s, ev, cmds, events)
	ev:_reset(); cmds:_reset()
	for _, e in ipairs(events) do
		if e.phase == "derived" then ev:_add_derived(e)
		else ev:_add_raw(e) end
	end
	s:process_step(ev, cmds, { virtual_width = 1200 })
end

local function count_styles(cmds)
	local counts = {}
	for _, c in ipairs(cmds._pushed) do
		local s = c.fields.style or c.type
		counts[s] = (counts[s] or 0) + 1
	end
	return counts
end

return {
	setup = function() Config.virtual_width = 1200 end,

	test_just_below_long_threshold_no_award = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance - 1
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, nil, "no long shot below threshold")
		assert_eq(c.super_long_shot, nil)
	end,

	test_at_long_threshold_awards = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, 1)
		assert_eq(c.super_long_shot, nil)
	end,

	test_just_below_super_threshold_long_only = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.super_long_shot_distance - 1
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, 1)
		assert_eq(c.super_long_shot, nil)
	end,

	test_at_super_threshold_super_not_long = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.super_long_shot_distance
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.super_long_shot, 1)
		assert_eq(c.long_shot, nil, "super does not also award long")
	end,

	test_impact_positions_used_not_peg_centres = function()
		-- Distances are measured between impact_x/impact_y, which we set
		-- independently of any peg centre. This test confirms the award uses
		-- the impact delta: set impacts far apart while (implicitly) peg centres
		-- would be close. Award should still fire based on impact distance.
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", Config.long_shot_distance + 50, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", Config.long_shot_distance + 50, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).long_shot, 1)
	end,

	test_double_long_shot_on_second_qualifying_segment = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d * 2, 0, "red"))
		ev:_add_derived(make_peg_scored(3, 1, "red", d * 2, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, 1)
		assert_eq(c.double_long_shot, 1, "double on second qualifying segment")
	end,

	test_blue_swept_peg_breaks_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		-- Blue peg in between breaks the chain.
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d / 2, 0, "blue"))
		ev:_add_derived(make_peg_scored(2, 1, "blue", d / 2, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		-- The purple after a blue peg is the first segment of a new chain: no
		-- award (only one impact so far in the new chain).
		local c = count_styles(cmds)
		assert_eq(c.long_shot, nil, "blue breaks chain, purple is first of new chain")
		assert_eq(c.double_long_shot, nil)
	end,

	test_already_hit_swept_peg_breaks_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		-- Already-hit peg: a swept contact with NO peg_scored for it.
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d / 2, 0, "red"))
		-- (no peg_scored derived for this contact => already hit)
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, nil, "already-hit breaks chain")
	end,

	test_graze_breaks_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		-- A graze on a blue peg between two scoring impacts must break the chain.
		ev:_add_raw(make_peg_contact(2, 1, "graze", d / 2, 0, "blue"))
		ev:_add_derived(make_peg_scored(2, 1, "blue", d / 2, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, nil, "graze on blue peg breaks the chain")
	end,

	test_graze_completes_long_shot = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		-- A graze on a valid peg completes the long shot segment.
		ev:_add_raw(make_peg_contact(2, 1, "graze", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, 1, "graze completes the chain")
	end,

	test_overlap_does_not_complete_or_break_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "overlap", d / 2, 0, "blue"))
		ev:_add_derived(make_peg_scored(2, 1, "blue", d / 2, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).long_shot, 1, "overlap ignored")
	end,

	test_depenetrate_does_not_complete_or_break_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "depenetrate", d / 2, 0, "blue"))
		ev:_add_derived(make_peg_scored(2, 1, "blue", d / 2, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).long_shot, 1, "depenetrate ignored")
	end,

	test_interleaved_two_balls_isolated = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		-- Ball 1: 0 -> d (qualifies). Ball 2: 0 -> short (no award).
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red", 1))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 2, "sweep", 0, 0, "red", 2))
		ev:_add_derived(make_peg_scored(2, 2, "red", 0, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple", 1))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		ev:_add_raw(make_peg_contact(4, 2, "sweep", 10, 0, "purple", 2))
		ev:_add_derived(make_peg_scored(4, 2, "purple", 10, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.long_shot, 1, "only ball 1's long shot")
		-- Ball 2's short segment must not affect ball 1's chain.
	end,

	test_bucket_bounce_then_catch_lucky = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 0, 0, "blue"))
		ev:_add_raw(make_bucket_caught(3, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, 1)
	end,

	test_bucket_bounce_then_catch_no_peg_hit = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_bucket_caught(2, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, nil, "no peg hit between bounce and catch")
	end,

	test_bucket_bounce_then_wall_then_catch = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_wall(2, 1, "left"))
		ev:_add_raw(make_bucket_caught(3, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, 1, "wall bounce satisfies lucky bounce")
	end,

	test_bucket_bounce_then_fallout_no_lucky = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		-- No catch; fall-out instead.
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, nil)
	end,

	test_multiple_bounces_award_lucky_once = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_bucket_bounced(2, 1))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", 0, 0, "blue"))
		ev:_add_raw(make_bucket_caught(4, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, 1)
	end,

	test_side_wall_then_distant_special_off_wall = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		-- Side wall hit, then any non-blue peg scored.
		ev:_add_raw(make_wall(1, 1, "left"))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 200, 100, "red"))
		ev:_add_derived(make_peg_scored(2, 1, "red", 200, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, 1)
	end,

	test_ceiling_does_not_qualify_off_wall = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_wall(1, 1, "top"))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 200, 100, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", 200, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, nil, "ceiling is not a side wall")
	end,

	test_bucket_wall_does_not_qualify_off_wall = function()
		-- Bucket bounces are not wall events; a bucket_bounced_ball event must
		-- not set side_wall_hit. So no off-the-wall from a bucket bounce.
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 200, 100, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", 200, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, nil, "bucket bounce is not a wall")
	end,

	test_short_distance_no_off_wall_and_no_long = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		-- Red close to the wall (left): off-the-wall now awarded regardless of distance.
		ev:_add_raw(make_wall(1, 1, "left"))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 10, 100, "red"))
		ev:_add_derived(make_peg_scored(2, 1, "red", 10, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, 1)
	end,

	test_blue_peg_fails_off_wall_attempt = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_wall(1, 1, "left"))
		-- Blue peg scored after wall: consumes & fails the attempt.
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 200, 100, "blue"))
		ev:_add_derived(make_peg_scored(2, 1, "blue", 200, 100))
		-- Later purple should NOT award off-the-wall (attempt was consumed).
		ev:_add_raw(make_peg_contact(3, 1, "sweep", 400, 100, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", 400, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, nil, "blue fails the attempt")
	end,

	test_already_hit_peg_fails_off_wall_attempt = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_wall(1, 1, "left"))
		-- Already-hit peg (no peg_scored for the contact): fails the attempt.
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 200, 100, "red"))
		-- (no peg_scored => already hit)
		ev:_add_raw(make_peg_contact(3, 1, "sweep", 400, 100, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", 400, 100))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).off_the_wall, nil, "already-hit fails attempt")
	end,

	test_wall_bounce_breaks_long_shot_chain = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		-- Side wall, then a purple peg that is distant-from-wall and
		-- physically far enough from the previous impact for a long shot.
		-- However, the wall bounce breaks the distance chain.
		ev:_add_raw(make_wall(2, 1, "left"))
		local d = Config.long_shot_distance + 50
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(3, 1, "purple", d, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		local c = count_styles(cmds)
		assert_eq(c.off_the_wall, nil, "wall bounce after peg contact does not award off the wall")
		assert_eq(c.long_shot, nil, "wall bounce breaks the distance chain")
	end,

	test_award_once_per_shot = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local d = Config.long_shot_distance + 10
		-- Three qualifying segments; long should only award once.
		ev:_add_raw(make_peg_contact(1, 1, "sweep", 0, 0, "red"))
		ev:_add_derived(make_peg_scored(1, 1, "red", 0, 0))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", d, 0, "purple"))
		ev:_add_derived(make_peg_scored(2, 1, "purple", d, 0))
		ev:_add_raw(make_peg_contact(3, 1, "sweep", d * 2, 0, "red"))
		ev:_add_derived(make_peg_scored(3, 1, "red", d * 2, 0))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).long_shot, 1, "long awarded once per shot")
	end,

	test_reset_shot_clears_state = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		ev:_add_raw(make_bucket_bounced(1, 1))
		ev:_add_raw(make_peg_contact(2, 1, "sweep", 0, 0, "blue"))
		ev:_add_raw(make_bucket_caught(3, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, 1)
		-- New shot: a catch with no prior bounce should not award lucky.
		ev:_reset(); cmds:_reset()
		s:reset_shot()
		ev:_add_raw(make_bucket_caught(1, 1))
		s:process_step(ev, cmds, { virtual_width = 1200 })
		assert_eq(count_styles(cmds).lucky_bounce, nil, "reset_shot cleared state")
	end,

	-- ===================================================================
	-- Slide: five adjacent zero-gap line pegs, no bounce inside the run
	-- ===================================================================

	test_slide_awards_on_five_adjacent_graze_scores = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 5 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		local c = count_styles(cmds)
		assert_eq(c.slide, 1, "five adjacent zero-gap scores award slide")
		local award = cmds._pushed[1]
		assert_eq(award.type, "award_style_points")
		assert_eq(award.fields.style, "slide")
		assert_eq(award.fields.points, 5000)
		assert_eq(award.fields.line_id, "rail")
		assert_eq(#award.fields.source_sequences, 5)
		assert_eq(award.fields.source_sequences[1], 1)
		assert_eq(award.fields.source_sequences[5], 5)
	end,

	test_slide_awards_in_descending_direction = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 5, 1, -1 do
			local r, d = slide_graze(6 - i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1, "descending run awards slide")
	end,

	test_slide_awards_across_closed_seam = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		local line = { id = "ring", count = 8, closed = true, gap = 0 }
		local function closed_graze(seq, index)
			local l = { id = "ring", index = index, count = 8, closed = true, gap = 0 }
			table.insert(events, make_peg_contact(seq, 1, "graze", 0, 0,
				"blue", index, l, false))
			table.insert(events, make_peg_scored(seq, 1, "blue", 0, 0, l))
		end
		-- 6,7,8 wrap to 1,2: five contiguous ring pegs across the seam.
		closed_graze(1, 6) closed_graze(2, 7) closed_graze(3, 8)
		closed_graze(4, 1) closed_graze(5, 2)
		feed_slide(s, ev, cmds, events)
		local c = count_styles(cmds)
		assert_eq(c.slide, 1, "closed seam wraparound run awards slide")
	end,

	test_slide_short_run_no_award = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil, "four pegs are not a slide")
	end,

	test_slide_requires_adjacent_indices = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- A skip (index 4 after 3? no: 5 after 3) must not extend the run.
		for _, i in ipairs({ 1, 2, 3, 5, 6 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"non-adjacent scored index does not extend the run")
	end,

	test_slide_out_of_sequence_score_restarts_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Scored indices 1,2 then a non-adjacent 8 must invalidate the 1,2 run
		-- and reseed at 8; 3,4,5 then only make a length-three run. Without the
		-- restart the 8 is ignored and 1,2 + 3,4,5 would falsely award.
		for _, i in ipairs({ 1, 2, 8, 3, 4, 5 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"out-of-sequence scored index must restart the run")
	end,

	test_slide_awarded_once_per_ball_and_line = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 9 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1, "longer run still awards once")
	end,

	test_slide_two_lines_award_independently = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 5 do
			local r, d = slide_graze(i, 1, "alpha", i)
			table.insert(events, r) table.insert(events, d)
		end
		for i = 1, 5 do
			local r, d = slide_graze(10 + i, 1, "beta", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 2,
			"once per line: each line's five-pegs award")
	end,

	test_slide_bounce_reseeds_run_without_awarding = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Two clean grazes, then a bouncing scoring contact (landing) that
		-- reseeds length one at index 3, then three more grazes: the new run
		-- is only 3,4,5,6 = four pegs, so no award.
		for _, i in ipairs({ 1, 2 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		local rb, db = slide_bounce(3, 1, "rail", 3)
		table.insert(events, rb) table.insert(events, db)
		for _, i in ipairs({ 4, 5, 6 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"bounce inside the run prevents an award")
	end,

	test_slide_landing_bounce_can_start_awarded_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Bouncing scoring contact seeds index 3, then grazes 4,5,6,7 make a
		-- five-peg run with no further bounce: award.
		local rb, db = slide_bounce(1, 1, "rail", 3)
		table.insert(events, rb) table.insert(events, db)
		for _, i in ipairs({ 4, 5, 6, 7 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		feed_slide(s, ev, cmds, events)
		local c = count_styles(cmds)
		assert_eq(c.slide, 1, "landing bounce may start the awarded run")
		local seqs = cmds._pushed[1].fields.source_sequences
		assert_eq(#seqs, 5)
		assert_eq(seqs[1], 1, "the seeding bounce is the first contributing sequence")
	end,

	test_slide_wall_bounce_resets_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_wall(5, 1, "left"))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil, "wall bounce resets the run")
	end,

	test_slide_bucket_bounce_resets_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_bucket_bounced(5, 1))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil, "bucket bounce resets the run")
	end,

	test_slide_non_bouncing_wall_does_not_reset_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_wall(5, 1, "left", false))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1,
			"non-bouncing wall contact must not reset the run")
	end,

	test_slide_non_bouncing_divider_does_not_reset_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_divider(5, 1, false))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1,
			"non-bouncing divider contact must not reset the run")
	end,

	test_slide_divider_bounce_resets_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_divider(5, 1, true))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil, "divider bounce resets the run")
	end,

	test_slide_ball_bounce_resets_run_for_both_balls = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Ball 1 has a 4-peg run, ball 2 independently has a 4-peg run.
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
			local r2, d2 = slide_graze(i + 100, 2, "rail2", i)
			table.insert(events, r2) table.insert(events, d2)
		end
		-- Ball 1 bounces off ball 2: the contact resets both runs.
		table.insert(events, make_ball_contact(5, 1, 2, true))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		local r2, d2 = slide_graze(106, 2, "rail2", 5)
		table.insert(events, r2) table.insert(events, d2)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"ball-ball bounce resets both balls' runs")
	end,

	test_slide_non_bouncing_ball_contact_does_not_reset_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		table.insert(events, make_ball_contact(5, 1, 2, false))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1,
			"non-bouncing ball contact must not reset the run")
	end,

	test_slide_off_line_peg_bounce_resets_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 4 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		-- Bouncing contact on a plain peg (no line metadata).
		table.insert(events, make_peg_contact(5, 1, "sweep", 0, 0, "red", 99))
		local r, d = slide_graze(6, 1, "rail", 5)
		table.insert(events, r) table.insert(events, d)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"bounce on a non-line peg resets the slide")
	end,

	test_slide_non_scoring_contacts_do_not_disturb_run = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Scores 1,2; a non-bouncing, non-scoring graze (already-hit line peg)
		-- in between must neither reset nor extend; then 3,4,5 complete five.
		local r, d = slide_graze(1, 1, "rail", 1)
		table.insert(events, r) table.insert(events, d)
		local r2, d2 = slide_graze(2, 1, "rail", 2)
		table.insert(events, r2) table.insert(events, d2)
		local line = { id = "rail", index = 2, count = 9, closed = false, gap = 0 }
		table.insert(events, make_peg_contact(3, 1, "graze", 0, 0,
			"blue", 2, line, false)) -- no peg_scored: already hit
		for _, i in ipairs({ 3, 4, 5 }) do
			local r3, d3 = slide_graze(3 + i, 1, "rail", i)
			table.insert(events, r3) table.insert(events, d3)
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1,
			"non-bouncing non-scoring contact leaves the run intact")
	end,

	test_slide_positive_gap_lines_do_not_qualify = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		local gapped = { id = "loose", count = 9, closed = false, gap = 6 }
		for i = 1, 5 do
			local l = { id = "loose", index = i, count = 9, closed = false, gap = 6 }
			table.insert(events, make_peg_contact(i, 1, "graze", 0, 0,
				"blue", i, l, false))
			table.insert(events, make_peg_scored(i, 1, "blue", 0, 0, l))
		end
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"only zero-gap lines qualify for slide")
	end,

	test_slide_multiple_balls_isolated = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		for i = 1, 5 do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(events, r) table.insert(events, d)
		end
		-- Ball 2 only grazes two pegs.
		local r, d = slide_graze(6, 2, "rail", 1)
		table.insert(events, r) table.insert(events, d)
		local r2, d2 = slide_graze(7, 2, "rail", 2)
		table.insert(events, r2) table.insert(events, d2)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, 1, "only ball 1's run awards")
	end,

	test_slide_run_persists_across_steps = function()
		-- Replay continuation: a run may span several completed steps; the
		-- award fires when the fifth scored contact lands.
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local step_events = {}
		for _, i in ipairs({ 1, 2, 3 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(step_events, r) table.insert(step_events, d)
		end
		feed_slide(s, ev, cmds, step_events)
		assert_eq(count_styles(cmds).slide, nil, "three pegs across step one")
		step_events = {}
		for _, i in ipairs({ 4, 5 }) do
			local r, d = slide_graze(i, 1, "rail", i)
			table.insert(step_events, r) table.insert(step_events, d)
		end
		feed_slide(s, ev, cmds, step_events)
		assert_eq(count_styles(cmds).slide, 1, "run continues into step two")
	end,

	test_slide_direction_change_does_not_extend = function()
		local ev, cmds = make_fixtures()
		local s = StyleShots.new()
		local events = {}
		-- Ascending 2,3 then a scoring contact back at 1 (a re-graze of an
		-- already scored peg is impossible, so craft 4,3: descending from 4
		-- after ascending 2->3 must not extend the ascending run).
		local r, d = slide_graze(1, 1, "rail", 2)
		table.insert(events, r) table.insert(events, d)
		local r2, d2 = slide_graze(2, 1, "rail", 3)
		table.insert(events, r2) table.insert(events, d2)
		local r3, d3 = slide_graze(3, 1, "rail", 4)
		table.insert(events, r3) table.insert(events, d3)
		local r4, d4 = slide_graze(4, 1, "rail", 3)
		table.insert(events, r4) table.insert(events, d4)
		local r5, d5 = slide_graze(5, 1, "rail", 5)
		table.insert(events, r5) table.insert(events, d5)
		feed_slide(s, ev, cmds, events)
		assert_eq(count_styles(cmds).slide, nil,
			"direction flip must not extend the run")
	end,
}
