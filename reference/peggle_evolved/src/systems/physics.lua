local Config = require("src.config")
local Perf = require("src.systems.perf")
local LevelManager = require("src.systems.level_manager")
local ImpactDebug = require("src.systems.impact_debug")
local ContactEvents = require("src.systems.contact_events")
local ImpactGeometry = require("src.systems.impact_geometry")
local Physics = {}

local PRIORITY = {
	wall          = 1,
	circle_peg    = 2,
	ball          = 2,
	rect_peg      = 3,
	annular_peg   = 4,
	extra_circle  = 5,
}

-- Copy the authoring line metadata of a peg onto an event payload (plain
-- scalars only; the metadata contract is enumerable by design).
local function contact_line(peg)
	if not peg.line then return nil end
	return {
		id = peg.line.id,
		index = peg.line.index,
		count = peg.line.count,
		closed = peg.line.closed,
		gap = peg.line.gap,
	}
end

-- Build and emit a raw contact event to the gameplay event sink. Physics is
-- purely observational here: it reports objective collision facts and never
-- mutates peg.hit or any authoritative gameplay state. The sink (owned by the
-- Engine) records the event for later authoritative reduction.
local function emit_contact(event_sink, event_type, ball, rec, did_bounce, peg, contact_kind)
	if not event_sink then return end
	local ix = rec.isx + rec.move_x * rec.toi
	local iy = rec.isy + rec.move_y * rec.toi
	local frame_t = ((rec.total_dt - rec.window) + rec.toi * rec.window) / rec.total_dt
	local fields = {
		ball_id = ball.id,
		contact_kind = contact_kind,
		did_bounce = did_bounce and true or false,
		impact_x = ix,
		impact_y = iy,
		frame_t = frame_t,
		toi = rec.toi,
		iteration = rec.iter,
		normal_x = rec.nx,
		normal_y = rec.ny,
		incoming_vx = rec.vin_x,
		incoming_vy = rec.vin_y,
		outgoing_vx = rec.vout_x,
		outgoing_vy = rec.vout_y,
	}
	if rec.other_ball then
		fields.other_ball_id = rec.other_ball.id
		fields.other_outgoing_vx = rec.other_vout_x
		fields.other_outgoing_vy = rec.other_vout_y
	end
	if peg then
		fields.peg_id = peg.original_index
		fields.peg_type = peg.type
		fields.peg_shape = peg.shape or "circle"
		fields.line = contact_line(peg)
		local px, py, pa, ptheta = ImpactGeometry.peg_transform_at_toi(peg, rec.window, rec.toi)
		fields.peg_x = px
		fields.peg_y = py
		fields.peg_angle = pa
		if ptheta then
			fields.peg_theta = ptheta
		end
	elseif event_type == "ball_contact_wall" then
		-- Derive wall identity deterministically from the contact normal.
		-- left wall  -> normal (+1, 0)
		-- right wall -> normal (-1, 0)
		-- ceiling    -> normal (0, +1)
		local wall
		if rec.nx > 0 then
			wall = "left"
		elseif rec.nx < 0 then
			wall = "right"
		else
			wall = "top"
		end
		fields.wall = wall
	end
	event_sink:emit_raw(event_type, fields)
end

-- Persistent graze buffer: entries are appended by index and consumed in the
-- same order as the previous table.insert-based list, allocation-free after
-- warmup. The count is reset before each sweep window so entries from a
-- previous window are never read.
local grazed_pool = {}
local grazed_n = 0

local function grazed_add(peg, t)
	grazed_n = grazed_n + 1
	local g = grazed_pool[grazed_n]
	if not g then
		g = {}
		grazed_pool[grazed_n] = g
	end
	g.peg = peg
	g.t = t
end

-- Annular sweep slice helpers, hoisted to file level so the per-slice path
-- allocates no closures. Parameters carry the exact slice-local values the
-- closures used to capture; expression order is unchanged.
local function annular_is_inside_arc(cx_rel, cy_rel, t_start, t_end)
	local hit_angle = math.atan2(cy_rel, cx_rel)
	local normalized = (hit_angle - t_start) % (math.pi * 2)
	-- Small epsilon to account for floating point errors at boundaries
	return normalized <= (t_end - t_start + 0.001)
		or normalized >= (math.pi * 2 - 0.001)
end

local function annular_check_cap(register_hit, peg, ball, peg_index, t_offset, t_scale,
		px, py, bx, by, dx, dy, slice_move_x, slice_move_y,
		normal_x, normal_y, angle)
	local denom = slice_move_x * normal_x + slice_move_y * normal_y
	if denom < -0.0001 then
		local cap_px = px + peg.r_in * math.cos(angle)
		local cap_py = py + peg.r_in * math.sin(angle)
		local d0 = (bx - cap_px) * normal_x + (by - cap_py) * normal_y
		local t = (ball.radius - d0) / denom
		local hit_physically = false

		if t >= -0.001 and t <= 1.0 then
			local t_hit = math.max(0, t)
			local cx_rel = dx + slice_move_x * t_hit
			local cy_rel = dy + slice_move_y * t_hit
			local px_rel = cx_rel - normal_x * ball.radius
			local py_rel = cy_rel - normal_y * ball.radius

			local cap_dir_x = math.cos(angle)
			local cap_dir_y = math.sin(angle)
			local dot = px_rel * cap_dir_x + py_rel * cap_dir_y

			local dist2 = px_rel * px_rel + py_rel * py_rel
			if
				dot >= 0
				and dist2 >= (peg.r_in * peg.r_in - Config.annular_cap_epsilon)
				and dist2 <= (peg.r_out * peg.r_out + Config.annular_cap_epsilon)
			then
				register_hit(t_offset + t_hit * t_scale, normal_x, normal_y, "peg", peg, PRIORITY.annular_peg, peg_index, 0)
				hit_physically = true
			end
		end

		if not hit_physically then
			local p = Config.graze_tolerance or 0.2
			local t_graze = (ball.radius + p - d0) / denom
			if t_graze >= -0.001 and t_graze <= 1.0 then
				local t_hit = math.max(0, t_graze)
				local cx_rel = dx + slice_move_x * t_hit
				local cy_rel = dy + slice_move_y * t_hit
				local px_rel = cx_rel - normal_x * (ball.radius + p)
				local py_rel = cy_rel - normal_y * (ball.radius + p)

				local cap_dir_x = math.cos(angle)
				local cap_dir_y = math.sin(angle)
				local dot = px_rel * cap_dir_x + py_rel * cap_dir_y

				local dist2 = px_rel * px_rel + py_rel * py_rel
				if
					dot >= 0
					and dist2 >= (peg.r_in * peg.r_in - Config.annular_cap_epsilon)
					and dist2 <= (peg.r_out * peg.r_out + Config.annular_cap_epsilon)
				then
					if peg.hit ~= nil then
						grazed_add(peg, t_offset + t_graze * t_scale)
					end
				end
			end
		end
	end
end

local function annular_check_corner(register_hit, peg, ball, peg_index, t_offset, t_scale,
		px, py, bx, by, dx, dy, slice_move_x, slice_move_y, a, corner_r, corner_theta)
	local iter_corner_x = px + corner_r * math.cos(corner_theta)
	local iter_corner_y = py + corner_r * math.sin(corner_theta)

	local cdx = bx - iter_corner_x
	local cdy = by - iter_corner_y
	local cb = 2 * (cdx * slice_move_x + cdy * slice_move_y)
	local cc = (cdx * cdx + cdy * cdy) - (ball.radius * ball.radius)

	if a > 0.0001 then
		local disc = cb * cb - 4 * a * cc

		local p = Config.graze_tolerance or 0.2
		local allowed_disc = -(p * 2 * ball.radius + p * p) * 4 * a

		if disc >= allowed_disc then
			local root = math.sqrt(math.max(0, disc))
			local t1 = (-cb - root) / (2 * a)
			if t1 >= -0.001 and t1 <= 1.0 then
				if disc < 0 then
					if peg.hit ~= nil then
						grazed_add(peg, t_offset + t1 * t_scale)
					end
				else
					local cx_rel = cdx + slice_move_x * t1
					local cy_rel = cdy + slice_move_y * t1
					local dist = math.sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
					if dist == 0 then dist = 0.01 end

					t1 = math.max(0, t1)
					local n_x, n_y = 0, -1
					if dist > 1e-8 then
						n_x = cx_rel / dist
						n_y = cy_rel / dist
					end
					register_hit(t_offset + t1 * t_scale, n_x, n_y, "peg", peg, PRIORITY.annular_peg, peg_index, 0)
				end
			end
		end
	end
end

-- event_sink: an object with method emit_raw(event_type, fields). Physics only
-- reports objective collision facts to it; it never mutates authoritative
-- gameplay state (peg.hit, scoring, ...). If event_sink is nil, no events are
-- emitted and no peg.hit mutation occurs. ContactEvents recording (render-only)
-- is always performed regardless of the sink.
function Physics.update(balls, circle_pegs, rect_pegs, annular_pegs, dt, extra_circles, event_sink)
	ImpactDebug.begin_frame()
	grazed_n = 0

	-- Per-frame ball bookkeeping for ball-ball collision reconstruction. A
	-- launched ball not yet processed this frame is treated as starting at its
	-- stored position and moving with its current velocity over the window. A
	-- ball already processed is treated like a peg: its stored position is the
	-- frame-end and the window start is back-derived as position - vend *
	-- window, where vend is the velocity it actually finished its sub-step
	-- with (post-bounce), so the reconstructed segment stays consistent with
	-- its real motion instead of phantoming its pre-bounce direction.
	local ball_frame = {}
	for _, b in ipairs(balls) do
		if b.launched then
			ball_frame[b] = { done = false }
		end
	end

	for _, ball in ipairs(balls) do
		if not ball.launched then
			goto continue
		end

		ImpactDebug.begin_ball(ball)

		local ball_frame_state = ball_frame[ball]
		if not ball_frame_state then
			ball_frame_state = { done = false }
			ball_frame[ball] = ball_frame_state
		end

		ball.draw_path = {}
		table.insert(ball.draw_path, {x = ball.x, y = ball.y, t = 0})

		local time_remaining = dt
		local total_dt = dt
		local max_iterations = 5
		local iterations = 0

		while time_remaining > 0.00001 and iterations < max_iterations do
			iterations = iterations + 1

			-- Instrumentation capture (read-only): iteration-window start state.
			local iter_sx, iter_sy = ball.x, ball.y
			local iter_time = time_remaining

			local move_x = ball.vx * time_remaining
			local move_y = ball.vy * time_remaining

			local move_len_sq = move_x * move_x + move_y * move_y
			local move_len = math.sqrt(move_len_sq)

			local function broadPhasePass(peg)
				local br = peg.bounding_radius
				if not br then
					if not peg.shape or peg.shape == "circle" then
						br = peg.radius
					elseif peg.shape == "rectangle" then
						br = math.sqrt(peg.width * peg.width + peg.height * peg.height) / 2
					elseif peg.shape == "annular" then
						br = peg.r_out
					else
						return true
					end
					peg.bounding_radius = br
				end

				local peg_vx = peg.vx or 0
				local peg_vy = peg.vy or 0
				local peg_iter_x = peg.x - peg_vx * time_remaining
				local peg_iter_y = peg.y - peg_vy * time_remaining

				local rel_move_x = move_x - peg_vx * time_remaining
				local rel_move_y = move_y - peg_vy * time_remaining

				local dx = ball.x - peg_iter_x
				local dy = ball.y - peg_iter_y

				local rel_move_len = math.sqrt(rel_move_x * rel_move_x + rel_move_y * rel_move_y)
				local reach = ball.radius + br + rel_move_len

				Perf.incPegChecks()

				if dx * dx + dy * dy > reach * reach then
					return false
				end

				return true, dx, dy, rel_move_x, rel_move_y, peg_iter_x, peg_iter_y
			end

			local min_t = 1.0
			local hit_nx, hit_ny = 0, 0
			local hit_type = nil
			local hit_peg = nil
			local hit_other_ball = nil
			local hit_priority = nil
			local hit_peg_index = nil
			local hit_overlap = 0
			grazed_n = 0

			local function register_hit(t, nx, ny, htype, peg, priority, peg_index, overlap, other_ball)
				if t < min_t - Config.toi_epsilon then
					min_t = t
					hit_nx, hit_ny = nx, ny
					hit_type = htype
					hit_peg = peg
					hit_other_ball = other_ball
					hit_priority = priority
					hit_peg_index = peg_index
					hit_overlap = overlap or 0
					return true
				elseif math.abs(t - min_t) <= Config.toi_epsilon then
					if not hit_priority or priority < hit_priority
					   or (priority == hit_priority
						   and (peg_index or 0) < (hit_peg_index or 0)) then
						min_t = t
						hit_nx, hit_ny = nx, ny
						hit_type = htype
						hit_peg = peg
						hit_other_ball = other_ball
						hit_priority = priority
						hit_peg_index = peg_index
						hit_overlap = overlap or 0
						return true
					end
				end
				return false
			end

			-- 1. Check Walls (Swept)
			if move_x < 0 then
				local t = (ball.radius - ball.x) / move_x
				if ball.x <= ball.radius then
					register_hit(0, 1, 0, "wall", nil, PRIORITY.wall, nil, ball.radius - ball.x)
				elseif t >= 0 then
					register_hit(t, 1, 0, "wall", nil, PRIORITY.wall, nil, 0)
				end
			elseif move_x > 0 then
				local right_wall = LevelManager.virtual_width
				local t = (right_wall - ball.radius - ball.x) / move_x
				if ball.x >= right_wall - ball.radius then
					register_hit(0, -1, 0, "wall", nil, PRIORITY.wall, nil, ball.x - (right_wall - ball.radius))
				elseif t >= 0 then
					register_hit(t, -1, 0, "wall", nil, PRIORITY.wall, nil, 0)
				end
			end

			-- Only the ceiling bounces; the floor is open so the ball falls out the bottom
			-- (and may be caught by the bucket).
			if move_y < 0 then
				local t = (ball.radius - ball.y) / move_y
				if ball.y <= ball.radius then
					register_hit(0, 0, 1, "wall", nil, PRIORITY.wall, nil, ball.radius - ball.y)
				elseif t >= 0 then
					register_hit(t, 0, 1, "wall", nil, PRIORITY.wall, nil, 0)
				end
			end

			-- 2. Check Pegs and Extra Circles (Swept Circle-Circle)
			local function checkCircles(circles, is_extra)
				if not circles then
					return
				end
				for _i, circ in ipairs(circles) do
					if true then -- is_extra or not circ.shape or circ.shape == "circle"
						local ok, dx, dy, rel_move_x, rel_move_y, peg_iter_x, peg_iter_y = broadPhasePass(circ)
						if ok then
							local a = rel_move_x * rel_move_x + rel_move_y * rel_move_y
							local b = 2 * (dx * rel_move_x + dy * rel_move_y)
							local radius_sum = ball.radius + circ.radius
							local c = (dx * dx + dy * dy) - (radius_sum * radius_sum)

							if c < 0 then
								-- Already intersecting (Discrete pop-out to prevent getting stuck)
								local dist = math.sqrt(dx * dx + dy * dy)
								if dist == 0 then
									dist = 0.01
								end
								register_hit(0, dx / dist, dy / dist, is_extra and "extra" or "peg", is_extra and nil or circ, is_extra and PRIORITY.extra_circle or PRIORITY.circle_peg, _i, radius_sum - dist)
							elseif a > 0.0001 then
								-- Calculate Time of Impact (TOI) using quadratic formula
								local disc = b * b - 4 * a * c

								-- Allow a tiny miss distance to count as a hit (for grazes where pixels visually touch)
								local p = Config.graze_tolerance or 0.2
								local allowed_disc = -(p * 2 * radius_sum + p * p) * 4 * a

								if disc >= allowed_disc then
									local root = math.sqrt(math.max(0, disc))
									local t1 = (-b - root) / (2 * a)

									if t1 >= -0.001 and t1 <= 1.0 then
										local cx_rel = dx + rel_move_x * t1
										local cy_rel = dy + rel_move_y * t1
										local dist = math.sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
										if dist == 0 then dist = 0.01 end

										if disc < 0 then
											-- This collision was only detected because graze_tolerance expanded
											-- the discriminant window. Light up the peg but do NOT deflect.
											if not is_extra and circ.hit ~= nil then
												grazed_add(circ, t1)
											end
										else
											t1 = math.max(0, t1)
											register_hit(t1, cx_rel / dist, cy_rel / dist, is_extra and "extra" or "peg", is_extra and nil or circ, is_extra and PRIORITY.extra_circle or PRIORITY.circle_peg, _i, 0)
										end
									end
								end
							end
						end
					end
				end
			end

			-- Rotating pegs (rectangles and annulars): the renderer interpolates the peg
			-- angle across the frame, but a swept check can only freeze the angle at one
			-- instant. To keep the swept geometry within a pixel of the drawn geometry,
			-- the frame window is split into time slices such that the surface arc
			-- travelled per slice (|va| * slice_time * bounding_radius) stays below
			-- Config.rotation_sweep_arc_px. Each slice runs the frozen-angle sweep and
			-- reports times in the iteration-wide [0, 1] window. Deterministic: the
			-- slice count derives only from peg velocities and config constants.
			local function rotationSlices(peg, peg_va)
				if peg_va == 0 then
					return 1
				end
				local arc = math.abs(peg_va) * time_remaining * peg.bounding_radius
				local slices = math.ceil(arc / (Config.rotation_sweep_arc_px or 1.0))
				local max_slices = Config.rotation_sweep_max_slices or 32
				if slices > max_slices then
					slices = max_slices
				elseif slices < 1 then
					slices = 1
				end
				return slices
			end

			-- Swept Circle-OBB (Oriented Bounding Box / Angled Rectangle) collision detection and resolution
			local function checkRectangles(rects)
				if not rects then
					return
				end
				for _i, peg in ipairs(rects) do
					if true then -- peg.shape == "rectangle"
						local ok, _dx0, _dy0, rel_move_x, rel_move_y, peg_iter_x, peg_iter_y = broadPhasePass(peg)
						if ok then
							local peg_vx = peg.vx or 0
							local peg_vy = peg.vy or 0
							local peg_va = peg.va or 0

							local slices = rotationSlices(peg, peg_va)
							local angle_iter = (peg.angle or 0) - peg_va * time_remaining

							-- In local space, the peg is an AABB centered at (0, 0)
							local rx = peg.half_w and -peg.half_w or -peg.width / 2
							local ry = peg.half_h and -peg.half_h or -peg.height / 2
							local rw = peg.width
							local rh = peg.height
							local r = ball.radius
							local p = Config.graze_tolerance or 0.2

							local function sweep_slice(s)
								local t_offset = s / slices
								if t_offset > min_t + Config.toi_epsilon then
									return false
								end
								local t_scale = 1 / slices

								-- Positions at slice start (rotation frozen for the slice duration)
								local bx = ball.x + move_x * t_offset
								local by = ball.y + move_y * t_offset
								local px = peg_iter_x + peg_vx * time_remaining * t_offset
								local py = peg_iter_y + peg_vy * time_remaining * t_offset
								local dx = bx - px
								local dy = by - py
								local slice_move_x = rel_move_x * t_scale
								local slice_move_y = rel_move_y * t_scale

								local angle = angle_iter + peg_va * time_remaining * t_offset
								local cos_a = math.cos(angle)
								local sin_a = math.sin(angle)

								-- Transform ball's position relative to peg center into local space
								local local_ball_x = dx * cos_a + dy * sin_a
								local local_ball_y = -dx * sin_a + dy * cos_a

								-- Transform relative movement vector into local space
								local local_move_x = slice_move_x * cos_a + slice_move_y * sin_a
								local local_move_y = -slice_move_x * sin_a + slice_move_y * cos_a

								-- 1. Check if already overlapping (discrete check)
								local cx = math.max(rx, math.min(local_ball_x, rx + rw))
								local cy = math.max(ry, math.min(local_ball_y, ry + rh))
								local l_dx = local_ball_x - cx
								local l_dy = local_ball_y - cy
								local d2 = l_dx * l_dx + l_dy * l_dy

								if d2 < r * r then
									local local_nx, local_ny
									local overlap
									if d2 > 1e-8 then
										local dist = math.sqrt(d2)
										local_nx = l_dx / dist
										local_ny = l_dy / dist
										overlap = r - dist
									else
										-- Ball center inside rectangle, eject along shallowest axis
										local toLeft = local_ball_x - rx
										local toRight = (rx + rw) - local_ball_x
										local toTop = local_ball_y - ry
										local toBottom = (ry + rh) - local_ball_y
										local m = math.min(toLeft, toRight, toTop, toBottom)
										if m == toLeft then
											local_nx, local_ny = -1, 0
											overlap = r - toLeft
										elseif m == toRight then
											local_nx, local_ny = 1, 0
											overlap = r - toRight
										elseif m == toTop then
											local_nx, local_ny = 0, -1
											overlap = r - toTop
										else
											local_nx, local_ny = 0, 1
											overlap = r - toBottom
										end
									end
									-- Rotate normal back to world space
									local wrld_nx = local_nx * cos_a - local_ny * sin_a
									local wrld_ny = local_nx * sin_a + local_ny * cos_a
									register_hit(t_offset, wrld_nx, wrld_ny, "peg", peg, PRIORITY.rect_peg, _i, overlap)
								else
									if d2 < (r + p) * (r + p) then
										if peg.hit ~= nil then
											grazed_add(peg, t_offset)
										end
									end

									-- 2. Swept check: check the 4 sides of the expanded box in local space
									-- Left segment: x = rx - r, y in [ry, ry + rh]
									if local_move_x > 0 then
										local hit_physically = false
										local t = (rx - r - local_ball_x) / local_move_x
										if t >= 0 and t <= 1.0 then
											local iy = local_ball_y + local_move_y * t
											if iy >= ry and iy <= ry + rh then
												local local_nx, local_ny = -1, 0
												register_hit(t_offset + t * t_scale, local_nx * cos_a - local_ny * sin_a, local_nx * sin_a + local_ny * cos_a, "peg", peg, PRIORITY.rect_peg, _i, 0)
												hit_physically = true
											end
										end
										if not hit_physically then
											local t_graze = (rx - r - p - local_ball_x) / local_move_x
											if t_graze >= 0 and t_graze <= 1.0 then
												local iy_graze = local_ball_y + local_move_y * t_graze
												if iy_graze >= ry and iy_graze <= ry + rh then
													if peg.hit ~= nil then
														grazed_add(peg, t_offset + t_graze * t_scale)
													end
												end
											end
										end
									end

									-- Right segment: x = rx + rw + r, y in [ry, ry + rh]
									if local_move_x < 0 then
										local hit_physically = false
										local t = (rx + rw + r - local_ball_x) / local_move_x
										if t >= 0 and t <= 1.0 then
											local iy = local_ball_y + local_move_y * t
											if iy >= ry and iy <= ry + rh then
												local local_nx, local_ny = 1, 0
												register_hit(t_offset + t * t_scale, local_nx * cos_a - local_ny * sin_a, local_nx * sin_a + local_ny * cos_a, "peg", peg, PRIORITY.rect_peg, _i, 0)
												hit_physically = true
											end
										end
										if not hit_physically then
											local t_graze = (rx + rw + r + p - local_ball_x) / local_move_x
											if t_graze >= 0 and t_graze <= 1.0 then
												local iy_graze = local_ball_y + local_move_y * t_graze
												if iy_graze >= ry and iy_graze <= ry + rh then
													if peg.hit ~= nil then
														grazed_add(peg, t_offset + t_graze * t_scale)
													end
												end
											end
										end
									end

									-- Top segment: y = ry - r, x in [rx, rx + rw]
									if local_move_y > 0 then
										local hit_physically = false
										local t = (ry - r - local_ball_y) / local_move_y
										if t >= 0 and t <= 1.0 then
											local ix = local_ball_x + local_move_x * t
											if ix >= rx and ix <= rx + rw then
												local local_nx, local_ny = 0, -1
												register_hit(t_offset + t * t_scale, local_nx * cos_a - local_ny * sin_a, local_nx * sin_a + local_ny * cos_a, "peg", peg, PRIORITY.rect_peg, _i, 0)
												hit_physically = true
											end
										end
										if not hit_physically then
											local t_graze = (ry - r - p - local_ball_y) / local_move_y
											if t_graze >= 0 and t_graze <= 1.0 then
												local ix_graze = local_ball_x + local_move_x * t_graze
												if ix_graze >= rx and ix_graze <= rx + rw then
													if peg.hit ~= nil then
														grazed_add(peg, t_offset + t_graze * t_scale)
													end
												end
											end
										end
									end

									-- Bottom segment: y = ry + rh + r, x in [rx, rx + rw]
									if local_move_y < 0 then
										local hit_physically = false
										local t = (ry + rh + r - local_ball_y) / local_move_y
										if t >= 0 and t <= 1.0 then
											local ix = local_ball_x + local_move_x * t
											if ix >= rx and ix <= rx + rw then
												local local_nx, local_ny = 0, 1
												register_hit(t_offset + t * t_scale, local_nx * cos_a - local_ny * sin_a, local_nx * sin_a + local_ny * cos_a, "peg", peg, PRIORITY.rect_peg, _i, 0)
												hit_physically = true
											end
										end
										if not hit_physically then
											local t_graze = (ry + rh + r + p - local_ball_y) / local_move_y
											if t_graze >= 0 and t_graze <= 1.0 then
												local ix_graze = local_ball_x + local_move_x * t_graze
												if ix_graze >= rx and ix_graze <= rx + rw then
													if peg.hit ~= nil then
														grazed_add(peg, t_offset + t_graze * t_scale)
													end
												end
											end
										end
									end

									-- Check the 4 corner circles of radius r in local space
									local function checkCorner(corner_x, corner_y)
										local cdx = local_ball_x - corner_x
										local cdy = local_ball_y - corner_y
										local a = local_move_x * local_move_x + local_move_y * local_move_y
										local b = 2 * (cdx * local_move_x + cdy * local_move_y)
										local c = (cdx * cdx + cdy * cdy) - (r * r)

										if a > 0.0001 then
											local disc = b * b - 4 * a * c

											local allowed_disc = -(p * 2 * r + p * p) * 4 * a

											if disc >= allowed_disc then
												local root = math.sqrt(math.max(0, disc))
												local t1 = (-b - root) / (2 * a)
												if t1 >= -0.001 and t1 <= 1.0 then
													if disc < 0 then
														if peg.hit ~= nil then
															grazed_add(peg, t_offset + t1 * t_scale)
														end
													else
														local cx_pos = local_ball_x + local_move_x * t1
														local cy_pos = local_ball_y + local_move_y * t1
														local dist = math.sqrt((cx_pos - corner_x) ^ 2 + (cy_pos - corner_y) ^ 2)
														if dist == 0 then dist = 0.01 end

														t1 = math.max(0, t1)
														local local_nx, local_ny
														if dist > 1e-8 then
															local_nx = (cx_pos - corner_x) / dist
															local_ny = (cy_pos - corner_y) / dist
														else
															local_nx, local_ny = 0, -1
														end
														register_hit(t_offset + t1 * t_scale, local_nx * cos_a - local_ny * sin_a, local_nx * sin_a + local_ny * cos_a, "peg", peg, PRIORITY.rect_peg, _i, 0)
													end
												end
											end
										end
									end

									checkCorner(rx, ry)
									checkCorner(rx + rw, ry)
									checkCorner(rx, ry + rh)
									checkCorner(rx + rw, ry + rh)
								end

								return true
							end

							for s = 0, slices - 1 do
								if not sweep_slice(s) then
									break
								end
							end
						end
					end
				end
			end

			local function checkAnnulars(pegs_list)
				if not pegs_list then
					return
				end
				for _i, peg in ipairs(pegs_list) do
					if true then -- peg.shape == "annular"
						local ok, _dx0, _dy0, rel_move_x, rel_move_y, peg_iter_x, peg_iter_y = broadPhasePass(peg)
						if ok then
							local peg_vx = peg.vx or 0
							local peg_vy = peg.vy or 0
							local peg_va = peg.va or 0

							local slices = rotationSlices(peg, peg_va)
							local t_start_iter = peg.theta_start - peg_va * time_remaining
							local t_end_iter = peg.theta_end_abs - peg_va * time_remaining

							for s = 0, slices - 1 do
								local t_offset = s / slices
								if t_offset > min_t + Config.toi_epsilon then
									break
								end
								local t_scale = 1 / slices

								-- Positions and arc angles at slice start (rotation frozen for the slice)
								local bx = ball.x + move_x * t_offset
								local by = ball.y + move_y * t_offset
								local px = peg_iter_x + peg_vx * time_remaining * t_offset
								local py = peg_iter_y + peg_vy * time_remaining * t_offset
								local dx = bx - px
								local dy = by - py
								local slice_move_x = rel_move_x * t_scale
								local slice_move_y = rel_move_y * t_scale

								local da_slice = peg_va * time_remaining * t_offset
								local t_start = t_start_iter + da_slice
								local t_end = t_end_iter + da_slice

								local a = slice_move_x * slice_move_x + slice_move_y * slice_move_y
								local b = 2 * (dx * slice_move_x + dy * slice_move_y)

								-- Discrete overlap check for moving annulars. The catch zone spans
								-- both sides of the wall, so classify the ball center and resolve
								-- through the surface it is actually overlapping: only the outer
								-- side may use the outward normal/outer penetration.
								local dist_center = math.sqrt(dx * dx + dy * dy)
								if dist_center < ball.radius + peg.r_out and annular_is_inside_arc(dx, dy, t_start, t_end) then
									if dist_center == 0 then dist_center = 0.01 end
									local inner_diff = peg.r_in - ball.radius
									if dist_center < peg.r_in then
										-- Center in the hole: push back inward once the ball's
										-- surface has crossed the inner wall. A ball with full
										-- clearance sits deeper and is untouched.
										local inner_clear = dist_center - inner_diff
										if inner_diff > 0 and inner_clear > 0 then
											register_hit(t_offset, -dx / dist_center, -dy / dist_center, "peg", peg, PRIORITY.annular_peg, _i, inner_clear)
										end
									else
										-- Center in the solid band or outside it: exit through
										-- the nearer surface (the hole only counts when the ball
										-- fits through it).
										local outer_clear = (ball.radius + peg.r_out) - dist_center
										local inner_clear = inner_diff > 0 and (dist_center - inner_diff) or nil
										if inner_clear and inner_clear < outer_clear then
											register_hit(t_offset, -dx / dist_center, -dy / dist_center, "peg", peg, PRIORITY.annular_peg, _i, inner_clear)
										elseif outer_clear > 0 then
											register_hit(t_offset, dx / dist_center, dy / dist_center, "peg", peg, PRIORITY.annular_peg, _i, outer_clear)
										end
									end
								end

								-- 1. Outer Arc
								do
									local radius_sum = ball.radius + peg.r_out
									local c = (dx * dx + dy * dy) - (radius_sum * radius_sum)
									if a > 0.0001 then
										local disc = b * b - 4 * a * c

										local p = Config.graze_tolerance or 0.2
										local allowed_disc = -(p * 2 * radius_sum + p * p) * 4 * a

										if disc >= allowed_disc then
											local root = math.sqrt(math.max(0, disc))
											local t1 = (-b - root) / (2 * a)
											if t1 >= -0.001 and t1 <= 1.0 then
												local cx_rel = dx + slice_move_x * t1
												local cy_rel = dy + slice_move_y * t1
												if annular_is_inside_arc(cx_rel, cy_rel, t_start, t_end) then
													if disc < 0 then
														if peg.hit ~= nil then
															grazed_add(peg, t_offset + t1 * t_scale)
														end
													else
														local dist = math.sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
														if dist == 0 then dist = 0.01 end

														t1 = math.max(0, t1)
														register_hit(t_offset + t1 * t_scale, cx_rel / dist, cy_rel / dist, "peg", peg, PRIORITY.annular_peg, _i, 0)
													end
												end
											end
										end
									end
								end

								-- 2. Inner Arc
								if peg.r_in > 0 then
									local radius_diff = peg.r_in - ball.radius
									if radius_diff > 0 then
										local c = (dx * dx + dy * dy) - (radius_diff * radius_diff)
										if a > 0.0001 then
											local disc = b * b - 4 * a * c
											if disc >= 0 then
												local root = math.sqrt(disc)
												-- Correct root for hitting inner boundary from the inside
												local t1 = (-b + root) / (2 * a)
												if t1 >= -0.001 and t1 <= 1.0 then
													t1 = math.max(0, t1)
													local cx_rel = dx + slice_move_x * t1
													local cy_rel = dy + slice_move_y * t1
													if annular_is_inside_arc(cx_rel, cy_rel, t_start, t_end) then
														local dist = math.sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
														-- Normal points INWARD
														register_hit(t_offset + t1 * t_scale, -cx_rel / dist, -cy_rel / dist, "peg", peg, PRIORITY.annular_peg, _i, 0)
													end
												end
											end
										end
									end
								end

								-- 3. Caps (normals derived from the slice-start arc angles)
								local cos_ts = math.cos(t_start)
								local sin_ts = math.sin(t_start)
								local cos_te = math.cos(t_end)
								local sin_te = math.sin(t_end)

								annular_check_cap(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, sin_ts, -cos_ts, t_start)
								annular_check_cap(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, -sin_te, cos_te, t_end)

								-- 4. Corners (recomputed at the slice-start transform)
								annular_check_corner(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, a, peg.r_in, t_start)
								annular_check_corner(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, a, peg.r_out, t_start)
								annular_check_corner(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, a, peg.r_in, t_end)
								annular_check_corner(register_hit, peg, ball, _i, t_offset, t_scale, px, py, bx, by, dx, dy, slice_move_x, slice_move_y, a, peg.r_out, t_end)
							end
						end
					end
				end
			end

			-- Swept circle-circle between launched balls. Other balls are
			-- modelled over the current iteration window from their effective
			-- frame-time state (pending = frame-start, done = frame-end).
			-- Collisions share the circle-peg priority; exact ties are broken
			-- by the peg/ball index (first registered wins when equal).
			local function checkBalls()
				if Config.ball_ball_collisions == false then
					return
				end
				for _i, other in ipairs(balls) do
					if other ~= ball and other.launched then
						local bf = ball_frame[other]
						local ox, oy, other_move_x, other_move_y
						if bf and bf.done then
							local vx = bf.vend_x or other.vx
							local vy = bf.vend_y or other.vy
							ox = other.x - vx * time_remaining
							oy = other.y - vy * time_remaining
							other_move_x = vx * time_remaining
							other_move_y = vy * time_remaining
						else
							ox = other.x
							oy = other.y
							other_move_x = other.vx * time_remaining
							other_move_y = other.vy * time_remaining
						end

						local dx = ball.x - ox
						local dy = ball.y - oy
						local rel_move_x = move_x - other_move_x
						local rel_move_y = move_y - other_move_y
						local radius_sum = ball.radius + other.radius

						local rel_move_len = math.sqrt(rel_move_x * rel_move_x + rel_move_y * rel_move_y)
						local reach = radius_sum + rel_move_len
						if dx * dx + dy * dy <= reach * reach then
							local a = rel_move_x * rel_move_x + rel_move_y * rel_move_y
							local b = 2 * (dx * rel_move_x + dy * rel_move_y)
							local c = (dx * dx + dy * dy) - (radius_sum * radius_sum)

							if c < 0 then
								-- Already intersecting: pop out along the
								-- center line, or along the relative motion
								-- when the centers coincide (multiball spawn).
								local dist = math.sqrt(dx * dx + dy * dy)
								local nx, ny
								if dist > 1e-8 then
									nx, ny = dx / dist, dy / dist
								elseif rel_move_len > 1e-8 then
									nx, ny = rel_move_x / rel_move_len, rel_move_y / rel_move_len
								else
									nx, ny = 1, 0
								end
								register_hit(0, nx, ny, "ball", nil, PRIORITY.ball, _i, radius_sum - dist, other)
							elseif a > 0.0001 then
								local disc = b * b - 4 * a * c
								if disc >= 0 then
									local root = math.sqrt(disc)
									local t1 = (-b - root) / (2 * a)
									if t1 >= -0.001 and t1 <= 1.0 then
										local cx_rel = dx + rel_move_x * t1
										local cy_rel = dy + rel_move_y * t1
										local dist = math.sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
										if dist == 0 then dist = 0.01 end
										t1 = math.max(0, t1)
										register_hit(t1, cx_rel / dist, cy_rel / dist, "ball", nil, PRIORITY.ball, _i, 0, other)
									end
								end
							end
						end
					end
				end
			end

			checkCircles(circle_pegs, false)
			checkRectangles(rect_pegs)
			checkAnnulars(annular_pegs)

			checkCircles(extra_circles, true)

			checkBalls()

		for gi = 1, grazed_n do
			local g = grazed_pool[gi]
			if g.t <= min_t + Config.toi_epsilon then
				-- Graze: report an objective raw contact fact. Authoritative
				-- scoring (peg.hit) is decided later by the Engine reducer.
				if event_sink then
					local ix = iter_sx + move_x * g.t
					local iy = iter_sy + move_y * g.t
					local frame_t = ((total_dt - iter_time) + g.t * iter_time) / total_dt
					event_sink:emit_raw("ball_contacted_peg", {
						ball_id = ball.id,
						peg_id = g.peg.original_index,
						peg_type = g.peg.type,
						peg_shape = g.peg.shape or "circle",
						line = contact_line(g.peg),
						contact_kind = "graze",
						did_bounce = false,
						impact_x = ix,
						impact_y = iy,
						frame_t = frame_t,
						toi = g.t,
						iteration = iterations,
						normal_x = 0,
						normal_y = 0,
						incoming_vx = ball.vx,
						incoming_vy = ball.vy,
						outgoing_vx = ball.vx,
						outgoing_vy = ball.vy,
					})
				end
			end
		end


			-- Apply movement up to impact (use safe_t to avoid floating point sticking to bounds)
			local safe_t = math.max(0, min_t - (Config.safe_t_margin or 0.001))

			if min_t > 0 then
				ball.x = ball.x + move_x * safe_t
				ball.y = ball.y + move_y * safe_t

				local current_t = 1.0 - (time_remaining / total_dt)
				local fraction = min_t * (time_remaining / total_dt)
				table.insert(ball.draw_path, {x = ball.x, y = ball.y, t = current_t + fraction})
			end

			-- Apply gravity for the time spent before the collision
						-- Gravity is applied to the ball's velocity BEFORE collision resolution.
			-- This is correct for swept CCD: gravity acts during the time the ball
			-- traveled to the impact point (time_remaining * min_t), so the velocity
			-- at impact reflects accumulated gravitational acceleration.
			-- The collision normal then acts on this impact-time velocity, not the
			-- frame-start velocity.
			--
			-- Order matters for trajectory reproduction:
			--   1. Apply accumulated gravity
			--   2. Resolve bounce (reflect velocity along normal)
			--   3. Push out if overlapping
			ball.vy = ball.vy + Config.gravity * (time_remaining * min_t)

	if min_t < 1.0 and hit_type then
		Perf.incCollisions()
		-- Instrumentation capture (read-only): impact velocity after the
		-- pre-collision gravity segment, before the impulse.
		local idb_vin_x, idb_vin_y = ball.vx, ball.vy

		local pvx, pvy = 0, 0
		if hit_type == "ball" and hit_other_ball then
			pvx = hit_other_ball.vx
			pvy = hit_other_ball.vy
		elseif hit_peg then
			pvx = hit_peg.vx or 0
			pvy = hit_peg.vy or 0
		end

		local rel_vx = ball.vx - pvx
		local rel_vy = ball.vy - pvy

		-- Collision occurred! Resolve velocity
		local dot = rel_vx * hit_nx + rel_vy * hit_ny
		local did_bounce = false
		local other_vin_x, other_vin_y, other_vout_x, other_vout_y
		if hit_type == "ball" and hit_other_ball then
			other_vin_x, other_vin_y = hit_other_ball.vx, hit_other_ball.vy
		end

		if dot < 0 then
			local bounce_factor
			if hit_type == "wall" then
				bounce_factor = Config.wall_damping
			elseif hit_type == "ball" then
				bounce_factor = Config.ball_ball_restitution or Config.restitution
			else
				bounce_factor = Config.restitution
			end
			-- Settling threshold: a contact whose normal approach speed is
			-- below bounce_min_normal_speed is a resting/creeping contact, not
			-- a bounce. Use a reduced restitution so it loses most energy while
			-- still ejecting from wedges/corners, and report did_bounce=false so
			-- style-shot slide runs are not reset by micro-contacts.
			if (-dot) < (Config.bounce_min_normal_speed or 0) then
				bounce_factor = math.min(bounce_factor, Config.settle_restitution or 0)
			else
				did_bounce = true
			end
			local impulse_x = -(1 + bounce_factor) * dot * hit_nx
			local impulse_y = -(1 + bounce_factor) * dot * hit_ny

			if hit_type == "ball" and hit_other_ball then
				-- Equal-mass impulse: the pair shares the normal impulse in
				-- opposite directions (momentum is conserved exactly).
				ball.vx = ball.vx + impulse_x * 0.5
				ball.vy = ball.vy + impulse_y * 0.5
				hit_other_ball.vx = hit_other_ball.vx - impulse_x * 0.5
				hit_other_ball.vy = hit_other_ball.vy - impulse_y * 0.5
			else
				ball.vx = ball.vx + impulse_x
				ball.vy = ball.vy + impulse_y
			end
		end
		if hit_type == "ball" and hit_other_ball then
			other_vout_x, other_vout_y = hit_other_ball.vx, hit_other_ball.vy
		end

			-- Push out slightly if overlapping
			if min_t == 0 then
				ball.x = ball.x + hit_nx * (hit_overlap + (Config.overlap_push_margin or 0.1))
				ball.y = ball.y + hit_ny * (hit_overlap + (Config.overlap_push_margin or 0.1))

				local current_t = 1.0 - (time_remaining / total_dt)
				table.insert(ball.draw_path, {x = ball.x, y = ball.y, t = current_t})
			end

		local collision_rec = {
			iter = iterations,
			toi = min_t,
			type = hit_type,
			peg = hit_peg,
			other_ball = hit_other_ball,
			other_vin_x = other_vin_x,
			other_vin_y = other_vin_y,
			other_vout_x = other_vout_x,
			other_vout_y = other_vout_y,
			overlap = hit_overlap,
			isx = iter_sx,
			isy = iter_sy,
			move_x = move_x,
			move_y = move_y,
			window = iter_time,
			total_dt = total_dt,
			vin_x = idb_vin_x,
			vin_y = idb_vin_y,
			vout_x = ball.vx,
			vout_y = ball.vy,
			nx = hit_nx,
			ny = hit_ny,
			kind = (min_t == 0) and "overlap" or "sweep",
			did_bounce = did_bounce,
		}
		ImpactDebug.record_collision(collision_rec)
		ContactEvents.record_collision(ball, collision_rec)

		-- Emit the authoritative raw contact event. Physics reports the fact;
		-- the Engine reducer later decides scoring / peg.hit.
		local ev_type
		if hit_type == "wall" then
			ev_type = "ball_contact_wall"
		elseif hit_type == "extra" then
			ev_type = "ball_contact_fever_divider"
		elseif hit_type == "ball" then
			ev_type = "ball_contact_ball"
		else
			ev_type = "ball_contacted_peg"
		end
		emit_contact(event_sink, ev_type, ball, collision_rec, did_bounce, hit_peg, collision_rec.kind)
	end

			time_remaining = time_remaining * (1 - min_t)
		end

		-- In case iterations max out but time remains, finish the frame the same
		-- way the loop does: advance by the leftover time, then apply gravity.
		-- Applying gravity without the matching displacement pumps kinetic
		-- energy into a ball that is still resting on a surface (the arc bowl
		-- was observed accelerating past 3500 px/s with no height to pay for
		-- it). Advancing first keeps the work/energy balance consistent.
		if time_remaining > 0.00001 and iterations >= max_iterations then
			ball.x = ball.x + ball.vx * time_remaining
			ball.y = ball.y + ball.vy * time_remaining
			ball.vy = ball.vy + Config.gravity * time_remaining
		end

		-- End-of-frame de-penetration: when iterations max out, the ball freezes
		-- mid-frame while pegs keep moving to their final transform, and rotating
		-- pegs leave up to one sweep slice of frozen-angle lag. Either way the frame
		-- can end with the ball visibly inside a peg; push it out along the contact
		-- normal (position only) so physics and rendering never show interpenetration.
		local function depenetrate(pegs_list, shape)
			if not pegs_list then
				return
			end
			for _, peg in ipairs(pegs_list) do
				local dx = ball.x - peg.x
				local dy = ball.y - peg.y
				local br
				if shape == "circle" then
					br = peg.radius
				elseif shape == "rectangle" then
					br = math.sqrt(peg.width * peg.width + peg.height * peg.height) / 2
				else
					br = peg.r_out
				end
				local reach = ball.radius + br
				if dx * dx + dy * dy <= reach * reach then
					local nx, ny, overlap
					if shape == "circle" then
						local radius_sum = ball.radius + peg.radius
						local dist = math.sqrt(dx * dx + dy * dy)
						if dist < radius_sum then
							if dist == 0 then dist = 0.01 end
							nx, ny = dx / dist, dy / dist
							overlap = radius_sum - dist
						end
					elseif shape == "rectangle" then
						local angle = peg.angle or 0
						local cos_a = math.cos(angle)
						local sin_a = math.sin(angle)
						local lx = dx * cos_a + dy * sin_a
						local ly = -dx * sin_a + dy * cos_a
						local hw = peg.half_w or peg.width / 2
						local hh = peg.half_h or peg.height / 2
						local cx = math.max(-hw, math.min(lx, hw))
						local cy = math.max(-hh, math.min(ly, hh))
						local l_dx = lx - cx
						local l_dy = ly - cy
						local d2 = l_dx * l_dx + l_dy * l_dy
						if d2 < ball.radius * ball.radius then
							local local_nx, local_ny
							if d2 > 1e-8 then
								local dist = math.sqrt(d2)
								local_nx = l_dx / dist
								local_ny = l_dy / dist
								overlap = ball.radius - dist
							else
								-- Ball center inside rectangle, eject along shallowest axis
								local toLeft = lx + hw
								local toRight = hw - lx
								local toTop = ly + hh
								local toBottom = hh - ly
								local m = math.min(toLeft, toRight, toTop, toBottom)
								if m == toLeft then
									local_nx, local_ny = -1, 0
									overlap = ball.radius + toLeft
								elseif m == toRight then
									local_nx, local_ny = 1, 0
									overlap = ball.radius + toRight
								elseif m == toTop then
									local_nx, local_ny = 0, -1
									overlap = ball.radius + toTop
								else
									local_nx, local_ny = 0, 1
									overlap = ball.radius + toBottom
								end
							end
							nx = local_nx * cos_a - local_ny * sin_a
							ny = local_nx * sin_a + local_ny * cos_a
						end
					else -- annular
						local dist = math.sqrt(dx * dx + dy * dy)
						if dist == 0 then dist = 0.01 end
						local hit_angle = math.atan2(dy, dx)
						local normalized = (hit_angle - peg.theta_start) % (math.pi * 2)
						local in_arc = normalized <= (peg.theta_end_abs - peg.theta_start + 0.001)
							or normalized >= (math.pi * 2 - 0.001)
						local inner_diff = peg.r_in - ball.radius
						if in_arc then
							if dist < peg.r_in then
								-- Inside the hole: the void is the hole, so only push
								-- back inward once the ball's surface has crossed the
								-- inner wall (dist > r_in - ball.radius). A ball with
								-- full clearance sits deeper than that and is untouched.
								local inner_clear = dist - inner_diff
								if inner_diff > 0 and inner_clear > 0 then
									nx, ny = -dx / dist, -dy / dist
									overlap = inner_clear
								end
							elseif dist < ball.radius + peg.r_out then
								-- Inside the solid band: exit through the nearer
								-- surface so the ball is never pushed across the wall.
								local outer_clear = (ball.radius + peg.r_out) - dist
								local inner_clear = inner_diff > 0 and (dist - inner_diff) or nil
								if inner_clear and inner_clear < outer_clear then
									nx, ny = -dx / dist, -dy / dist
									overlap = inner_clear
								else
									nx, ny = dx / dist, dy / dist
									overlap = outer_clear
								end
							end
						end
					end
			if nx then
				local depen_rec = {
					iter = 0,
					toi = 0,
					type = "peg",
					peg = peg,
					overlap = overlap,
					isx = ball.x,
					isy = ball.y,
					move_x = 0,
					move_y = 0,
					window = 0,
					total_dt = total_dt,
					vin_x = ball.vx,
					vin_y = ball.vy,
					vout_x = ball.vx,
					vout_y = ball.vy,
					nx = nx,
					ny = ny,
					kind = "depenetrate",
					did_bounce = false,
				}
				ImpactDebug.record_collision(depen_rec)
				ContactEvents.record_collision(ball, depen_rec)
				ball.x = ball.x + nx * (overlap + (Config.overlap_push_margin or 0.1))
				ball.y = ball.y + ny * (overlap + (Config.overlap_push_margin or 0.1))
				-- Report objective depenetration contact; reducer decides scoring.
				emit_contact(event_sink, "ball_contacted_peg", ball, depen_rec, false, peg, "depenetrate")
			end
				end
			end
		end

		depenetrate(circle_pegs, "circle")
		depenetrate(rect_pegs, "rectangle")
		depenetrate(annular_pegs, "annular")

		-- Ball-ball de-penetration fallback: unlike pegs, other balls also
		-- move, so sequential resolution can leave a residual overlap. Push
		-- only the current ball (position only) to keep its own draw_path
		-- consistent; the other ball's sub-step integrates its own motion.
		local function depenetrate_balls()
			if Config.ball_ball_collisions == false then
				return
			end
			for _i, other in ipairs(balls) do
				if other ~= ball and other.launched then
					local dx = ball.x - other.x
					local dy = ball.y - other.y
					local radius_sum = ball.radius + other.radius
					local d2 = dx * dx + dy * dy
					if d2 < radius_sum * radius_sum then
						local dist = math.sqrt(d2)
						local nx, ny
						if dist > 1e-8 then
							nx, ny = dx / dist, dy / dist
						else
							nx, ny = 1, 0
						end
						local overlap = radius_sum - dist
						local depen_rec = {
							iter = 0,
							toi = 0,
							type = "ball",
							other_ball = other,
							overlap = overlap,
							isx = ball.x,
							isy = ball.y,
							move_x = 0,
							move_y = 0,
							window = 0,
							total_dt = total_dt,
							vin_x = ball.vx,
							vin_y = ball.vy,
							vout_x = ball.vx,
							vout_y = ball.vy,
							nx = nx,
							ny = ny,
							kind = "depenetrate",
							did_bounce = false,
						}
						ImpactDebug.record_collision(depen_rec)
						ContactEvents.record_collision(ball, depen_rec)
						ball.x = ball.x + nx * (overlap + (Config.overlap_push_margin or 0.1))
						ball.y = ball.y + ny * (overlap + (Config.overlap_push_margin or 0.1))
						emit_contact(event_sink, "ball_contact_ball", ball, depen_rec, false, nil, "depenetrate")
					end
				end
			end
		end

		depenetrate_balls()

		table.insert(ball.draw_path, {x = ball.x, y = ball.y, t = 1.0})

		ImpactDebug.end_ball(ball)

		ball_frame_state.vend_x, ball_frame_state.vend_y = ball.vx, ball.vy
		ball_frame_state.done = true

		::continue::
	end
end

function Physics.getLaunchVelocity(x0, y0, xt, yt, v)
	local g = Config.gravity
	local dx = xt - x0
	local dy = yt - y0

	-- Handle near-vertical shots or zero gravity to avoid division by zero
	if math.abs(dx) < 0.1 or math.abs(g) < 0.1 then
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist == 0 then
			return 0, 0
		end
		return (dx / dist) * v, (dy / dist) * v
	end

	local x2 = dx * dx
	local v2 = v * v
	local v4 = v2 * v2

	-- Ballistic discriminant: v^4 - g(g*x^2 + 2*y*v^2)
	-- Note: dy is positive downwards in LÖVE, so we use -2*dy*v2 for standard formula
	local disc = v4 - g * (g * x2 - 2 * dy * v2)

	if disc < 0 then
		-- Target out of range, fallback to direct aim
		local dist = math.sqrt(dx * dx + dy * dy)
		return (dx / dist) * v, (dy / dist) * v
	end

	local root = math.sqrt(disc)

	-- Two solutions for tan(theta) = (-v^2 +- root) / (g * dx)
	local t1 = (-v2 + root) / (g * dx)
	local t2 = (-v2 - root) / (g * dx)

	-- We want the solution that is "flatter" (closer to the direct angle)
	local direct_tan = dy / dx
	local u = math.abs(t1 - direct_tan) < math.abs(t2 - direct_tan) and t1 or t2

	-- Calculate vx, vy from tan(theta) = u and vx^2 + vy^2 = v^2
	local vx = v / math.sqrt(1 + u * u)
	if dx < 0 then
		vx = -vx
	end
	local vy = u * vx

	return vx, vy
end

function Physics.getSnappedAimAngle(angle)
	local steps = Config.aim_discretization_steps
	if not steps then
		return angle
	end

	local limit = Config.aim_angle_limit
	local mid = math.pi / 2

	-- Clamp the input angle just in case
	angle = math.max(mid - limit, math.min(mid + limit, angle))

	-- Scale the angle into [0, 1] range relative to the aiming arc
	local normalized = (angle - (mid - limit)) / (2 * limit)

	-- Snap to the nearest step
	normalized = math.floor(normalized * steps + 0.5) / steps

	-- Scale back to world radians
	return (mid - limit) + normalized * (2 * limit)
end

return Physics
