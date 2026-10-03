local OverlapDetector = require("src.systems.overlap_detector")
local CircuitAnalyzer = require("src.systems.circuit_analyzer")
local MotionSchema = require("src.systems.motion_schema")
local Lines = require("src.systems.lines")

local LevelChecker = {}

function LevelChecker.check(level_data)
	local pegs = {}
	local raw_pegs = level_data.pegs or {}
	for _, p in ipairs(raw_pegs) do table.insert(pegs, p) end

	local level_circuits = level_data.level_circuits or {}

	-- The peg array is the only peg collection; circuit definitions never
	-- own pegs. Reject any authoring that violates the motion schema.
	MotionSchema.validate(pegs, level_circuits)
	
	-- Pre-process pegs to assign IDs for stable reporting
	for i, peg in ipairs(pegs) do
		peg.id = i
	end
	
	local static_pegs = {}
	local num_circuit_pegs = 0
	
	for _, p in ipairs(pegs) do
		if MotionSchema.is_moving(p) and level_circuits[p.motion.circuit] then
			num_circuit_pegs = num_circuit_pegs + 1
		else
			table.insert(static_pegs, p)
		end
	end
	
	local errors = 0
	local warnings = 0
	local reports = {
		static = {},
		dynamic = {}
	}
	
	local function report_static(tier, p1, p2, overlap)
		local t = (tier == "ERROR") and "ERROR" or "WARN "
		local msg = string.format("  [%s] %s overlaps %s by %.3fpx", 
			t, 
			OverlapDetector.format_peg_desc(p1.id, p1), 
			OverlapDetector.format_peg_desc(p2.id, p2), 
			overlap)
		table.insert(reports.static, msg)
		if tier == "ERROR" then errors = errors + 1 else warnings = warnings + 1 end
	end
	
	local function report_dynamic(tier, p1, p2, overlap, is_dyn, best_t, min_gap)
		local t = (tier == "ERROR") and "ERROR" or "WARN "
		local desc1 = OverlapDetector.format_peg_desc(p1.id, p1, true, best_t, p1.base_x, p1.base_y)
		local desc2 = OverlapDetector.format_peg_desc(p2.id, p2, p2.motion ~= nil, best_t, p2.base_x, p2.base_y)
		
		local msg = string.format("  [%s] %s sweeps through %s\n           Closest approach: %.3fpx at t ~ %.2f (min gap: %.1f > %.1f)", 
			t, desc1, desc2, math.max(0, -overlap), best_t, min_gap or 0, min_gap or 0)
		table.insert(reports.dynamic, msg)
		if tier == "ERROR" then errors = errors + 1 else warnings = warnings + 1 end
	end

	local function report_line_error(message)
		table.insert(reports.static, "  [ERROR] Lines: " .. message)
		errors = errors + 1
	end

	-- Phase-3 line authoring validation (unique ids, contiguous indices,
	-- consistent metadata, recoverable shape/path combinations, same-line
	-- non-neighbor overlaps). Hard-fails atomically on the first structural
	-- violation but reports it as a counted level error rather than crashing
	-- the check run.
	local ok, verr = pcall(Lines.validate, pegs)
	if not ok then
		report_line_error(tostring(verr):gsub("^.-Lines: ", ""))
	end

	-- Layer 1: Pre-compute bounding radii
	for _, peg in ipairs(pegs) do
		OverlapDetector.get_bounding_radius(peg)
	end
	
	-- Layer 2: Spatial grid (for static pegs)
	local CELL_SIZE = 150
	local grid = {}
	
	local OverlapDetector = require("src.systems.overlap_detector")
	for _, p in ipairs(static_pegs) do
		local br = p.bounding_radius or OverlapDetector.get_bounding_radius(p)
		local min_cx = math.floor((p.x - br) / CELL_SIZE)
		local max_cx = math.floor((p.x + br) / CELL_SIZE)
		local min_cy = math.floor((p.y - br) / CELL_SIZE)
		local max_cy = math.floor((p.y + br) / CELL_SIZE)
		
		for cx = min_cx, max_cx do
			for cy = min_cy, max_cy do
				local key = cx .. "," .. cy
				if not grid[key] then grid[key] = {} end
				table.insert(grid[key], p)
			end
		end
	end
	
	local checked_pairs = {}
	local pair_checks = 0
	
	local active_cells = 0
	for _, cell_pegs in pairs(grid) do
		active_cells = active_cells + 1
		for i = 1, #cell_pegs do
			local p1 = cell_pegs[i]
			for j = i+1, #cell_pegs do
				local p2 = cell_pegs[j]
				
				-- Canonical pair key
				local id1, id2 = p1.id, p2.id
				if id1 > id2 then id1, id2 = id2, id1 end
				local pair_key = id1 .. "," .. id2
				
				if not checked_pairs[pair_key] then
					checked_pairs[pair_key] = true
					pair_checks = pair_checks + 1
					
					-- Layer 3: Bounding-radius fast rejection
					local dx = p1.x - p2.x
					local dy = p1.y - p2.y
					local r_sum = p1.bounding_radius + p2.bounding_radius
					
					if dx*dx + dy*dy < r_sum*r_sum then
						-- Layer 4: Detailed checks
						local overlap = OverlapDetector.check_overlap(p1, p2)
						if overlap > 0.01 then
							report_static("ERROR", p1, p2, overlap)
						elseif overlap >= -0.01 and overlap <= 0.01 then
							-- Exact contact between adjacent zero-gap line
							-- pegs is intentional authoring (one shared
							-- boundary), not an ambiguous-overlap warning.
							if not Lines.is_intentional_contact(p1, p2) then
								report_static("WARN", p1, p2, overlap)
							end
						end
					end
				end
			end
		end
	end
	
	local num_circuits = 0
	for _ in pairs(level_circuits) do num_circuits = num_circuits + 1 end
	
	table.insert(reports.static, string.format("  [INFO]  Checked %d static pegs with spatial grid (%d cells, %d pair checks)", #static_pegs, active_cells, pair_checks))
	
	-- Phase 3: Dynamic overlap pass
	local diagnostics = CircuitAnalyzer.analyze(pegs, level_circuits, report_dynamic)
	if num_circuits > 0 then
		table.insert(reports.dynamic, string.format(
			"  [INFO]  Dynamic sweep horizon: %.2fs (finite sampling window; independent circuit periods may extend beyond it)",
			diagnostics.horizon))
	end
	
	return {
		total_pegs = #pegs,
		static_pegs = #static_pegs,
		circuit_pegs = num_circuit_pegs,
		num_circuits = num_circuits,
		errors = errors,
		warnings = warnings,
		reports = reports
	}
end

return LevelChecker
