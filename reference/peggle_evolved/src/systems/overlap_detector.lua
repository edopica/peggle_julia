local OverlapDetector = {}
local Config = require("src.config")

function OverlapDetector.get_shape_type(peg)
	if not peg.shape then return "circle" end
	return peg.shape
end

function OverlapDetector.get_bounding_radius(peg)
	if peg.bounding_radius then return peg.bounding_radius end
	local shape = OverlapDetector.get_shape_type(peg)
	local br = 0
	if shape == "circle" then
		br = peg.radius or Config.peg_radius or 10
	elseif shape == "rectangle" then
		br = math.sqrt((peg.width/2)^2 + (peg.height/2)^2)
	elseif shape == "annular" then
		br = peg.r_out
	end
	peg.bounding_radius = br
	return br
end

function OverlapDetector.format_peg_desc(peg_id, peg, is_dynamic, dyn_time, dyn_base_x, dyn_base_y)
	local shape = OverlapDetector.get_shape_type(peg)
	if is_dynamic then
		local circuit_id = peg.motion and peg.motion.circuit or "?"
		return string.format("Circuit '%s' peg (base %.1f,%.1f t=%.1f)", circuit_id, dyn_base_x, dyn_base_y, dyn_time)
	else
		return string.format("Peg #%s (%s at %.1f,%.1f)", tostring(peg_id), shape, peg.x, peg.y)
	end
end

-- Poly-poly SAT helper. Returns overlap amount, or < 0 for separation gap.
-- poly is an array of coordinates: {x1,y1, x2,y2, ...}
local function poly_poly_sat(poly1, poly2)
	local overlap = math.huge
	
	local polys = {poly1, poly2}
	for i = 1, 2 do
		local poly = polys[i]
		local n = #poly / 2
		for j = 1, n do
			local x1 = poly[(j-1)*2 + 1]
			local y1 = poly[(j-1)*2 + 2]
			local next_j = (j % n) + 1
			local x2 = poly[(next_j-1)*2 + 1]
			local y2 = poly[(next_j-1)*2 + 2]
			
			local edge_x = x2 - x1
			local edge_y = y2 - y1
			-- Normal (perpendicular to edge)
			local nx = -edge_y
			local ny = edge_x
			local len = math.sqrt(nx*nx + ny*ny)
			if len == 0 then len = 0.001 end
			nx = nx / len
			ny = ny / len
			
			-- Project poly1
			local min1, max1 = math.huge, -math.huge
			for k = 1, #poly1/2 do
				local px = poly1[(k-1)*2 + 1]
				local py = poly1[(k-1)*2 + 2]
				local proj = px * nx + py * ny
				min1 = math.min(min1, proj)
				max1 = math.max(max1, proj)
			end
			
			-- Project poly2
			local min2, max2 = math.huge, -math.huge
			for k = 1, #poly2/2 do
				local px = poly2[(k-1)*2 + 1]
				local py = poly2[(k-1)*2 + 2]
				local proj = px * nx + py * ny
				min2 = math.min(min2, proj)
				max2 = math.max(max2, proj)
			end
			
			local sep1 = min1 - max2
			local sep2 = min2 - max1
			local sep = math.max(sep1, sep2)
			
			if sep > 0 then
				return -sep -- Separated
			end
			
			overlap = math.min(overlap, -sep)
		end
	end
	return overlap
end

local function get_rect_poly(rect)
	local hw = rect.width / 2
	local hh = rect.height / 2
	local angle = rect.angle or 0
	local cos_a = math.cos(angle)
	local sin_a = math.sin(angle)
	local cx, cy = rect.x, rect.y
	
	local corners = {
		{-hw, -hh}, {hw, -hh}, {hw, hh}, {-hw, hh}
	}
	
	local poly = {}
	for _, c in ipairs(corners) do
		local x = c[1] * cos_a - c[2] * sin_a + cx
		local y = c[1] * sin_a + c[2] * cos_a + cy
		table.insert(poly, x)
		table.insert(poly, y)
	end
	return poly
end

-- Circle vs Circle
function OverlapDetector.circle_circle(c1, c2)
	local dx = c2.x - c1.x
	local dy = c2.y - c1.y
	local dist = math.sqrt(dx*dx + dy*dy)
	return (c1.radius + c2.radius) - dist
end

-- Circle vs Rectangle
function OverlapDetector.circle_rect(circ, rect)
	local angle = rect.angle or 0
	local cos_a = math.cos(angle)
	local sin_a = math.sin(angle)
	
	-- Transform circle center into rect local space
	local dx = circ.x - rect.x
	local dy = circ.y - rect.y
	local local_x = dx * cos_a + dy * sin_a
	local local_y = -dx * sin_a + dy * cos_a
	
	local hw = rect.width / 2
	local hh = rect.height / 2
	
	-- Closest point on AABB to circle
	local closest_x = math.max(-hw, math.min(local_x, hw))
	local closest_y = math.max(-hh, math.min(local_y, hh))
	
	local dist_x = local_x - closest_x
	local dist_y = local_y - closest_y
	local dist = math.sqrt(dist_x*dist_x + dist_y*dist_y)
	
	if local_x >= -hw and local_x <= hw and local_y >= -hh and local_y <= hh then
		-- Circle center is inside rectangle
		local dist_left = local_x - (-hw)
		local dist_right = hw - local_x
		local dist_top = local_y - (-hh)
		local dist_bottom = hh - local_y
		local min_dist = math.min(dist_left, dist_right, dist_top, dist_bottom)
		return circ.radius + min_dist
	end
	
	return circ.radius - dist
end

-- Rect vs Rect
function OverlapDetector.rect_rect(r1, r2)
	return poly_poly_sat(get_rect_poly(r1), get_rect_poly(r2))
end

-- Circle vs Annular
function OverlapDetector.circle_annular(circ, ann)
	local dx = circ.x - ann.x
	local dy = circ.y - ann.y
	local dist = math.sqrt(dx*dx + dy*dy)
	
	-- If dist is strictly between r_in-radius and r_out+radius, might overlap
	if dist > ann.r_out + circ.radius or dist < ann.r_in - circ.radius then
		-- Calculate closest gap. It's either outer bound or inner bound.
		local gap1 = dist - (ann.r_out + circ.radius)
		local gap2 = (ann.r_in - circ.radius) - dist
		return -math.max(gap1, gap2)
	end
	
	local atan2 = math.atan2 or math.atan
	local angle = atan2(dy, dx)
	local normalized = (angle - ann.theta_start) % (math.pi * 2)
	local arc_len = ann.theta_end_abs - ann.theta_start
	
	-- Expand arc angle by circle radius (approximate)
	local expand_angle = math.asin(math.min(1, circ.radius / math.max(0.001, dist)))
	
	if normalized <= arc_len + expand_angle or normalized >= (math.pi * 2 - expand_angle) then
		-- Overlaps angularly and radially.
		-- To find true overlap distance, we use SAT between circle and annular polygon for an accurate reading
		-- For simplicity and robustness, circle-poly SAT:
		local overlap = math.huge
		local poly = ann.polygon
		local n = #poly / 2
		for j = 1, n do
			local x1 = poly[(j-1)*2 + 1]
			local y1 = poly[(j-1)*2 + 2]
			local next_j = (j % n) + 1
			local x2 = poly[(next_j-1)*2 + 1]
			local y2 = poly[(next_j-1)*2 + 2]
			
			local edge_x = x2 - x1
			local edge_y = y2 - y1
			local nx = -edge_y
			local ny = edge_x
			local len = math.sqrt(nx*nx + ny*ny)
			if len == 0 then len = 0.001 end
			nx = nx / len
			ny = ny / len
			
			local min_p, max_p = math.huge, -math.huge
			for k = 1, n do
				local px = poly[(k-1)*2 + 1]
				local py = poly[(k-1)*2 + 2]
				local proj = px * nx + py * ny
				min_p = math.min(min_p, proj)
				max_p = math.max(max_p, proj)
			end
			
			local circ_proj = circ.x * nx + circ.y * ny
			local circ_min = circ_proj - circ.radius
			local circ_max = circ_proj + circ.radius
			
			local sep1 = min_p - circ_max
			local sep2 = circ_min - max_p
			local sep = math.max(sep1, sep2)
			if sep > 0 then return -sep end
			overlap = math.min(overlap, -sep)
		end
		
		-- Circle normal to polygon vertices
		for j = 1, n do
			local vx = poly[(j-1)*2 + 1]
			local vy = poly[(j-1)*2 + 2]
			local nx = circ.x - vx
			local ny = circ.y - vy
			local len = math.sqrt(nx*nx + ny*ny)
			if len > 0 then
				nx = nx / len
				ny = ny / len
				local min_p, max_p = math.huge, -math.huge
				for k = 1, n do
					local px = poly[(k-1)*2 + 1]
					local py = poly[(k-1)*2 + 2]
					local proj = px * nx + py * ny
					min_p = math.min(min_p, proj)
					max_p = math.max(max_p, proj)
				end
				local circ_proj = circ.x * nx + circ.y * ny
				local circ_min = circ_proj - circ.radius
				local circ_max = circ_proj + circ.radius
				
				local sep1 = min_p - circ_max
				local sep2 = circ_min - max_p
				local sep = math.max(sep1, sep2)
				if sep > 0 then return -sep end
				overlap = math.min(overlap, -sep)
			end
		end
		
		return overlap
	else
		-- Outside angularly, gap is angular distance
		local gap_angle = 0
		if normalized < math.pi then
			gap_angle = normalized - arc_len
		else
			gap_angle = math.pi * 2 - normalized
		end
		local gap_dist = math.max(0, gap_angle - expand_angle) * dist
		return -gap_dist
	end
end

-- Rect vs Annular
function OverlapDetector.rect_annular(rect, ann)
	return poly_poly_sat(get_rect_poly(rect), ann.polygon)
end

-- Annular vs Annular
function OverlapDetector.annular_annular(a1, a2)
	return poly_poly_sat(a1.polygon, a2.polygon)
end

function OverlapDetector.check_overlap(p1, p2)
	local t1 = OverlapDetector.get_shape_type(p1)
	local t2 = OverlapDetector.get_shape_type(p2)
	
	if t1 == "circle" and t2 == "circle" then
		return OverlapDetector.circle_circle(p1, p2)
	elseif t1 == "circle" and t2 == "rectangle" then
		return OverlapDetector.circle_rect(p1, p2)
	elseif t1 == "rectangle" and t2 == "circle" then
		return OverlapDetector.circle_rect(p2, p1)
	elseif t1 == "rectangle" and t2 == "rectangle" then
		return OverlapDetector.rect_rect(p1, p2)
	elseif t1 == "circle" and t2 == "annular" then
		return OverlapDetector.circle_annular(p1, p2)
	elseif t1 == "annular" and t2 == "circle" then
		return OverlapDetector.circle_annular(p2, p1)
	elseif t1 == "rectangle" and t2 == "annular" then
		return OverlapDetector.rect_annular(p1, p2)
	elseif t1 == "annular" and t2 == "rectangle" then
		return OverlapDetector.rect_annular(p2, p1)
	elseif t1 == "annular" and t2 == "annular" then
		return OverlapDetector.annular_annular(p1, p2)
	end
	return 0
end

return OverlapDetector
