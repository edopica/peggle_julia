-- ===========================================================================
-- StyleShots: deterministic style-shot recognition from gameplay events.
--
-- Consumes a step's completed event stream (raw then derived) and pushes
-- `award_style_points` commands for qualifying style shots.
--
-- Recognized styles:
--   long_shot          — a segment between two consecutive chain-eligible
--                        scoring peg impacts (same ball) whose impact-position
--                        distance is >= long_shot_distance.
--   super_long_shot   — same, but >= super_long_shot_distance. Super does not
--                        also award Long.
--   double_long_shot   — the second consecutive *qualifying* segment in a row.
--   lucky_bounce       — a bucket bounce followed (later in the shot) by a
--                        bucket catch for the same ball.
--   off_the_wall       — a side-wall contact followed by a non-blue peg
--                        score for the same ball.
--   slide              — at least slide_min_pegs consecutive scoring contacts
--                        on adjacent zero-gap line pegs of ONE line (closed
--                        lines wrap) with no bounce inside the run; awarded
--                        once per ball and line per shot (see below).
--
-- Slide rules (per ball and line, reset each shot):
--   * Only zero-gap generated line pegs qualify; runs are tracked per
--     (ball, line id) with a running direction.
--   * A scoring contact on a qualifying line peg seeds a length-one run.
--     A later scoring contact extends the run only when its line index is
--     adjacent to the last scored index in the same direction (closed lines
--     use wraparound adjacency); the first extension fixes the direction.
--   * A bouncing contact (did_bounce on a peg/wall/divider contact or a
--     bucket bounce) resets the ball's runs. If that same bounced contact
--     scores a qualifying line peg it immediately seeds a new run, so a
--     landing bounce may start a slide but no bounce may occur inside an
--     awarded run.
--   * Non-bouncing contacts neither reset nor extend a run unless they
--     score the required adjacent peg.
--   * Reaching slide_min_pegs awards style="slide" once per ball and line
--     per shot, carrying the five contributing scoring source sequences.
--
-- Chain rules (per ball, across the whole shot):
--   * Only valid impacts ("sweep" or "graze") on peg contacts participate.
--   * A valid contact that scores a NON-blue peg for the first time is
--     "chain-eligible": it forms a segment measured from the last chain
--     impact. A qualifying distance awards Long/Super and advances the
--     consecutive-qualifying streak; a short distance resets the streak.
--   * A valid contact with a blue peg (scores but is blue), or with an
--     already-hit peg (no peg_scored this contact), BREAKS the chain: the
--     streak and last-impact are cleared.
--   * Graze / overlap / depenetration contacts neither complete nor break
--     the chain.
--   * Off the Wall: a side-wall hit is "consumed" (set to nil) when a peg is
--     subsequently scored — non-blue awards it, blue or
--     already-hit fails it.
--
-- Style points are added to engine.styleScore by the Engine command handler.
-- Style points do NOT reset the no-score timer (BallState owns that).
--
-- Per-ball state is tracked across steps within a shot and reset on shot
-- start/completion.
-- ===========================================================================

local Config = require("src.config")

local StyleShots = {}
local StyleShots_mt = { __index = StyleShots }

function StyleShots.new()
	local self = setmetatable({}, StyleShots_mt)
	self:reset_shot()
	return self
end

function StyleShots:reset_shot()
	self.last_impact = {}       -- ball_id -> {x, y, seq}  (chain-eligible impacts)
	self.qualifying_streak = {} -- ball_id -> int
	self.last_qualifying_seq = {} -- ball_id -> raw sequence of contact that completed the previous qualifying segment
	self.bucket_bounced = {}    -- ball_id -> raw sequence of latest bucket bounce
	self.bounced_after_bucket = {} -- ball_id -> bool
	self.side_wall_hit = {}      -- ball_id -> raw sequence of latest side-wall contact
	self.hit_any_peg = {}        -- ball_id -> bool (has this ball hit a peg yet?)
	self.awarded = {}            -- ball_id -> { long, super, double_long_shot, lucky, off_wall }
	self.slide_runs = {}         -- "ball|line" -> { len, last, dir, seqs }
	self.slide_awarded = {}      -- "ball|line" -> bool
end

local function ensure_award_tab(self, ball_id)
	local t = self.awarded[ball_id]
	if not t then
		t = {}
		self.awarded[ball_id] = t
	end
	return t
end

local function dist(x1, y1, x2, y2)
	local dx = x1 - x2
	local dy = y1 - y2
	return math.sqrt(dx * dx + dy * dy)
end

-- Slide helpers (per ball and line): state nests as
--   self.slide_runs[ball_id][line_id] = { len, last, dir, seqs }
-- and awarding is tracked per (ball, line) the same way. A bounce clears
-- only runs: the once-per-(ball, line)-per-shot award markers survive.
local function clear_ball_slide(self, bid)
	self.slide_runs[bid] = nil
end

local function run_tab(self, bid, line_id)
	local by_line = self.slide_runs[bid]
	if not by_line then
		by_line = {}
		self.slide_runs[bid] = by_line
	end
	local run = by_line[line_id]
	if not run then
		run = { len = 0, last = nil, dir = 0, seqs = {} }
		by_line[line_id] = run
	end
	return run
end

-- Extend or seed the slide run for one scored contact on a zero-gap line.
-- Called only for scoring contacts (peg_scored exists for this sequence).
function StyleShots:note_slide_score(ev, scored, commands, min, points)
	local bid = ev.ball_id
	local line = ev.line
	local index = scored.line.index
	local run = run_tab(self, bid, line.id)

	if ev.did_bounce then
		-- A landing bounce may start a slide: any existing run was already
		-- cleared by the bounce handling in process_step; seed length one.
		run.len = 1
		run.last = index
		run.dir = 0
		run.seqs = { ev.sequence }
		return
	end

	if run.len == 0 then
		run.len = 1
		run.last = index
		run.dir = 0
		run.seqs = { ev.sequence }
		return
	end

	-- Extend: adjacent in the run's direction. Closed lines wrap.
	local delta = index - run.last
	if math.abs(delta) ~= 1 then
		if line.closed and delta == 1 - line.count then
			delta = 1
		elseif line.closed and delta == line.count - 1 then
			delta = -1
		end
	end
	-- A qualifying zero-gap contact that cannot extend the current run
	-- invalidates it and seeds a fresh length-one run at this index. This
	-- covers both a non-adjacent delta and a direction mismatch.
	if (delta ~= 1 and delta ~= -1)
		or (run.dir ~= 0 and run.dir ~= delta) then
		run.len = 1
		run.last = index
		run.dir = 0
		run.seqs = { ev.sequence }
		return
	end
	if run.dir == 0 then
		run.dir = delta
	end

	run.len = run.len + 1
	run.last = index
	if #run.seqs < min then
		table.insert(run.seqs, ev.sequence)
	end

	if run.len == min then
		local awarded = self.slide_awarded[bid]
		if awarded and awarded[line.id] then
			return
		end
		if not awarded then
			awarded = {}
			self.slide_awarded[bid] = awarded
		end
		awarded[line.id] = true
		commands:push("award_style_points", {
			ball_id = bid,
			style = "slide",
			points = points,
			line_id = line.id,
			source_sequences = run.seqs,
		})
	end
end

-- Run style-shot recognition for one completed fixed step.
--   events      = GameplayEvents instance (raw + derived available, sealed)
--   commands    = GameplayCommands instance (push award_style_points)
--   opts        = optional overrides; Engine passes virtual_width.
function StyleShots:process_step(events, commands, opts)
	opts = opts or {}
	local long_d = opts.long_distance or Config.long_shot_distance or 400
	local super_d = opts.super_distance or Config.super_long_shot_distance or 700
	local pt_long = opts.long_points or Config.long_shot_points or 1000
	local pt_super = opts.super_points or Config.super_long_shot_points or 5000
	local pt_double = opts.double_points or Config.double_long_shot_points or 2000
	local pt_lucky = opts.lucky_points or Config.lucky_bounce_points or 2500
	local pt_off_wall = opts.off_wall_points or Config.off_the_wall_points or 5000
	local slide_min = opts.slide_min_pegs or Config.slide_min_pegs or 5
	local pt_slide = opts.slide_points or Config.slide_points or 5000
	local vw = opts.virtual_width or Config.virtual_width

	-- Index peg_scored derived events by their source raw sequence.
	local scored_by_source = {}
	for _, ev in ipairs(events:derived()) do
		if ev.type == "peg_scored" and ev.source_sequence ~= nil then
			scored_by_source[ev.source_sequence] = ev
		end
	end

	for _, ev in ipairs(events:all()) do
		local bid = ev.ball_id

		if ev.type == "ball_contact_wall" and bid ~= nil then
			if self.bucket_bounced[bid] then
				self.bounced_after_bucket[bid] = true
			end
			if (ev.wall == "left" or ev.wall == "right") and not self.hit_any_peg[bid] then
				self.side_wall_hit[bid] = ev.sequence
			end
			-- Only a real bounce breaks the Long Shot chain / resets slides;
			-- settling (non-bouncing) wall contacts are observational.
			if ev.did_bounce then
				-- Wall bounce breaks Long Shot chain
				self.qualifying_streak[bid] = 0
				self.last_impact[bid] = nil
				self.last_qualifying_seq[bid] = nil
				-- Wall bounce resets slide runs.
				clear_ball_slide(self, bid)
			end

		elseif ev.type == "bucket_bounced_ball" and bid ~= nil then
			self.bucket_bounced[bid] = ev.sequence
			self.bounced_after_bucket[bid] = false
			-- Bucket bounce breaks Long Shot chain
			self.qualifying_streak[bid] = 0
			self.last_impact[bid] = nil
			self.last_qualifying_seq[bid] = nil
			-- Bucket bounce resets slide runs.
			clear_ball_slide(self, bid)

		elseif ev.type == "ball_contact_fever_divider" and bid ~= nil then
			-- Only a real divider bounce resets slide runs.
			if ev.did_bounce then
				clear_ball_slide(self, bid)
			end

		elseif ev.type == "ball_contact_ball" and bid ~= nil then
			-- A real ball-ball bounce is a trajectory discontinuity for both
			-- balls: reset their slide runs. It does not break the Long Shot
			-- chain (mirrors peg semantics: intermediate bounces between
			-- chain-eligible scoring impacts do not reset the chain).
			if self.bucket_bounced[bid] then
				self.bounced_after_bucket[bid] = true
			end
			local other_bid = ev.other_ball_id
			if other_bid ~= nil and self.bucket_bounced[other_bid] then
				self.bounced_after_bucket[other_bid] = true
			end
			if ev.did_bounce then
				clear_ball_slide(self, bid)
				if other_bid ~= nil then
					clear_ball_slide(self, other_bid)
				end
			end

		elseif ev.type == "bucket_caught_ball" and bid ~= nil then
			local tab = ensure_award_tab(self, bid)
			if self.bucket_bounced[bid] and self.bounced_after_bucket[bid] and not tab.lucky then
				tab.lucky = true
				commands:push("award_style_points", {
					ball_id = bid,
					style = "lucky_bounce",
					points = pt_lucky,
					source_sequences = { self.bucket_bounced[bid], ev.sequence },
				})
			end

		elseif ev.type == "ball_contacted_peg" and bid ~= nil then
			self.hit_any_peg[bid] = true
			if self.bucket_bounced[bid] then
				self.bounced_after_bucket[bid] = true
			end

			-- Slide: zero-gap line contacts track per (ball, line). A bounced
			-- contact clears the ball's runs; a scoring contact may seed a
			-- new run (even from the bounce itself) or extend an adjacent
			-- consistent-direction run.
			if type(ev.line) == "table" and ev.line.gap == 0 then
				local scored = ev.sequence and scored_by_source[ev.sequence]
				if ev.did_bounce then
					clear_ball_slide(self, bid)
					if scored and scored.line then
						self:note_slide_score(ev, scored, commands, slide_min, pt_slide)
					end
				elseif scored and scored.line then
					self:note_slide_score(ev, scored, commands, slide_min, pt_slide)
				end
			elseif ev.did_bounce then
				-- Bounce off a non-line peg ends any slide the ball had.
				clear_ball_slide(self, bid)
			end

			if ev.contact_kind == "sweep" or ev.contact_kind == "graze" then
				local scored = ev.sequence and scored_by_source[ev.sequence]
				local tab = ensure_award_tab(self, bid)
				local ix, iy = ev.impact_x, ev.impact_y

				if scored and scored.peg_type ~= "blue" then
				-- Chain-eligible scoring impact.
				-- Off the Wall: non-blue peg scored after a side wall.
				if self.side_wall_hit[bid] and not tab.off_wall then
					tab.off_wall = true
					commands:push("award_style_points", {
						ball_id = bid,
						style = "off_the_wall",
						points = pt_off_wall,
						peg_id = scored.peg_id,
						source_sequences = { self.side_wall_hit[bid], ev.sequence },
					})
					self.side_wall_hit[bid] = nil -- consumed (awarded)
				end

				local last = self.last_impact[bid]
				if last then
					local d = dist(last.x, last.y, ix, iy)
					local segment_qualified = false
					if d >= super_d then
						if not tab.super then
							tab.super = true
							commands:push("award_style_points", {
								ball_id = bid,
								style = "super_long_shot",
								points = pt_super,
								distance = d,
								source_sequences = { last.seq, ev.sequence },
							})
						end
						segment_qualified = true
					elseif d >= long_d then
						if not tab.long then
							tab.long = true
							commands:push("award_style_points", {
								ball_id = bid,
								style = "long_shot",
								points = pt_long,
								distance = d,
								source_sequences = { last.seq, ev.sequence },
							})
						end
						segment_qualified = true
					end

					if segment_qualified then
						-- Double: second consecutive qualifying segment. The
						-- sources are the contacts completing segment 1 and 2.
						local prev_qual_seq = self.last_qualifying_seq[bid]
						self.qualifying_streak[bid] = (self.qualifying_streak[bid] or 0) + 1
						if self.qualifying_streak[bid] >= 2 and not tab.double_long_shot then
							tab.double_long_shot = true
							commands:push("award_style_points", {
								ball_id = bid,
								style = "double_long_shot",
								points = pt_double,
								source_sequences = { prev_qual_seq, ev.sequence },
							})
						end
						self.last_qualifying_seq[bid] = ev.sequence
					else
						-- Short distance: streak broken (but the current special
						-- peg still becomes the base of the next segment below).
						self.qualifying_streak[bid] = 0
						self.last_qualifying_seq[bid] = nil
					end
				end
				-- First chain impact sets the base; no streak increment yet.
				self.last_impact[bid] = { x = ix, y = iy, seq = ev.sequence }
			else
				-- Breaks the chain: a blue peg (scored but blue) or an
				-- already-hit peg (no peg_scored for this contact).
				self.qualifying_streak[bid] = 0
				self.last_impact[bid] = nil
				self.last_qualifying_seq[bid] = nil
				-- Off the Wall: blue/already-hit consumes and fails the attempt.
				if self.side_wall_hit[bid] then
					self.side_wall_hit[bid] = nil
				end
			end
		end
		end
	end
end

return StyleShots
