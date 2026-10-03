local Config = require("src.config")
local States = require("src.states")
local Circuits = require("src.systems.circuits")

-- ===========================================================================
-- Level Select State
-- ===========================================================================
local LevelSelectState = {}

function LevelSelectState:enter(mode)
	self.mode = mode
	self.levels = {}
	self.selected_index = 1
	self.preview_level_name = nil
	self.mouse_x = 0
	self.mouse_y = 0

	local items = love.filesystem.getDirectoryItems("src/levels")
	for _, filename in ipairs(items) do
		if filename:match("%.lua$") and not filename:match("^benchmark_") then
			local name = filename:gsub("%.lua$", "")
			table.insert(self.levels, name)
		end
	end
	table.sort(self.levels)
end
function LevelSelectState:leave() end

-- Copy one peg (and its motion record) for preview initialization. Annular
-- pegs own mutable geometry buffers, so those are copied too. Compiled Path
-- objects referenced by circuit definitions are shared deliberately:
-- Circuits.initialize never mutates them and Path.is_path must keep working.
local function clone_peg(peg)
	local clone = {}
	for k, v in pairs(peg) do clone[k] = v end
	if peg.motion then
		local motion = {}
		for k, v in pairs(peg.motion) do motion[k] = v end
		clone.motion = motion
	end
	if peg.corners then
		local corners = {}
		for i, c in ipairs(peg.corners) do corners[i] = { x = c.x, y = c.y } end
		clone.corners = corners
	end
	if peg.normal_start then
		clone.normal_start = { x = peg.normal_start.x, y = peg.normal_start.y }
	end
	if peg.normal_end then
		clone.normal_end = { x = peg.normal_end.x, y = peg.normal_end.y }
	end
	if peg.polygon then
		local polygon = {}
		for i = 1, #peg.polygon do polygon[i] = peg.polygon[i] end
		clone.polygon = polygon
	end
	return clone
end

-- Build the preview peg set at initialized positions without touching the
-- cached level module. Levels without circuits reuse the raw peg tables (the
-- preview only reads them).
function LevelSelectState:_build_preview_pegs(data)
	local raw = data.pegs or {}
	local circuits = data.level_circuits
	if not circuits or next(circuits) == nil then
		self.preview_pegs = raw
		return
	end
	local clones = {}
	for i, peg in ipairs(raw) do
		local clone = clone_peg(peg)
		if clone.base_x == nil then clone.base_x = clone.x end
		if clone.base_y == nil then clone.base_y = clone.y end
		clones[i] = clone
	end
	Circuits.initialize(clones, circuits)
	self.preview_pegs = clones
end

function LevelSelectState:_load_preview(name)
	if self.preview_level_name == name then return end
	self.preview_level_name = name
	self.preview_data = nil
	self.preview_error = nil
	self.preview_pegs = nil

	package.loaded["src.levels." .. name] = nil
	local ok, data = pcall(require, "src.levels." .. name)
	if not ok or not data then
		self.preview_error = tostring(data)
		return
	end
	self.preview_data = data

	local built, err = pcall(function() self:_build_preview_pegs(data) end)
	if not built then
		self.preview_data = nil
		self.preview_pegs = nil
		self.preview_error = tostring(err)
	end
end

function LevelSelectState:_preview_virtual(name)
	package.loaded["src.levels." .. name] = nil
	local ok, data = pcall(require, "src.levels." .. name)
	if ok and data then
		return data.virtual_width, data.virtual_height
	end
	return nil, nil
end

function LevelSelectState:update(dt) end

function LevelSelectState:draw()
	local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
	local font = love.graphics.getFont()

	love.graphics.setColor(0.05, 0.05, 0.1)
	love.graphics.rectangle("fill", 0, 0, ww, wh)

	-- Header
	love.graphics.setColor(1, 1, 1, 0.8)
	local mode_text = self.mode == "solo" and "Solo" or "1v1"
	local header = love.graphics.newText(font, "Select Level - " .. mode_text .. " Mode")
	love.graphics.draw(header, 20, 15)

	-- Level list area
	local list_x, list_y = 20, 60
	local list_w, list_h = 260, wh - 100
	local entry_h = 36

	love.graphics.setColor(0.1, 0.1, 0.18)
	love.graphics.rectangle("fill", list_x, list_y, list_w, list_h, 4)

	local mx, my = self.mouse_x, self.mouse_y
	local list_hover = -1

	for i, name in ipairs(self.levels) do
		local ey = list_y + 4 + (i - 1) * entry_h
		if ey + entry_h > list_y + list_h then break end
		local hover = mx >= list_x and mx <= list_x + list_w and my >= ey and my <= ey + entry_h
		if hover then list_hover = i end

		love.graphics.setColor(i == self.selected_index and { 0.2, 0.45, 0.7 } or (hover and { 0.15, 0.3, 0.5 } or { 0.1, 0.1, 0.15 }))
		love.graphics.rectangle("fill", list_x + 2, ey, list_w - 4, entry_h - 2, 3)
		love.graphics.setColor(1, 1, 1)
		local label = love.graphics.newText(font, name:gsub("_", " "):gsub("^%l", string.upper))
		love.graphics.draw(label, list_x + 10, ey + entry_h / 2 - label:getHeight() / 2)
	end

	-- Start button
	local btn_w, btn_h = 180, 48
	local btn_x, btn_y = list_x, list_y + list_h + 10
	local btn_hover = mx >= btn_x and mx <= btn_x + btn_w and my >= btn_y and my <= btn_y + btn_h
	love.graphics.setColor(btn_hover and { 0.2, 0.65, 0.35 } or { 0.12, 0.45, 0.22 })
	love.graphics.rectangle("fill", btn_x, btn_y, btn_w, btn_h, 6)
	love.graphics.setColor(1, 1, 1)
	local start_text = love.graphics.newText(font, "START")
	love.graphics.draw(start_text, btn_x + btn_w / 2 - start_text:getWidth() / 2, btn_y + btn_h / 2 - start_text:getHeight() / 2)

	-- Back button
	local back_w, back_h = 100, 36
	local back_x, back_y = ww - back_w - 20, 15
	local back_hover = mx >= back_x and mx <= back_x + back_w and my >= back_y and my <= back_y + back_h
	love.graphics.setColor(back_hover and { 0.5, 0.25, 0.25 } or { 0.35, 0.15, 0.15 })
	love.graphics.rectangle("fill", back_x, back_y, back_w, back_h, 4)
	love.graphics.setColor(1, 1, 1)
	local back_text = love.graphics.newText(font, "BACK")
	love.graphics.draw(back_text, back_x + back_w / 2 - back_text:getWidth() / 2, back_y + back_h / 2 - back_text:getHeight() / 2)

	-- Preview area
	local prev_x, prev_y = list_x + list_w + 30, 60
	local prev_w, prev_h = ww - prev_x - 20, wh - 100

	love.graphics.setColor(0.08, 0.08, 0.15)
	love.graphics.rectangle("fill", prev_x, prev_y, prev_w, prev_h, 4)

	if #self.levels > 0 and self.selected_index <= #self.levels then
		local name = self.levels[self.selected_index]
		self:_load_preview(name)

		love.graphics.setColor(1, 1, 1, 0.6)
		local pname = love.graphics.newText(font, "Preview: " .. name:gsub("_", " "):gsub("^%l", string.upper))
		love.graphics.draw(pname, prev_x + 10, prev_y + 8)

		if self.preview_data then
			local vw = self.preview_data.virtual_width or Config.virtual_width
			local vh = self.preview_data.virtual_height or Config.virtual_height
			local margin = 20
			local avail_w = prev_w - margin * 2
			local avail_h = prev_h - margin * 2 - 30
			local scale = math.min(avail_w / vw, avail_h / vh)
			local off_x = prev_x + (prev_w - vw * scale) / 2
			local off_y = prev_y + (prev_h - vh * scale) / 2 + 10

			love.graphics.setScissor(prev_x, prev_y, prev_w, prev_h)
			love.graphics.rectangle("line", off_x, off_y, vw * scale, vh * scale)

			local pegs = self.preview_pegs or self.preview_data.pegs or {}
			for _, p in ipairs(pegs) do
				if p.radius and p.base_x and not p.motion then
					p = { x = p.base_x or p.x, y = p.base_y or p.y, radius = p.radius or Config.peg_radius, shape = p.shape, width = p.width, height = p.height, polygon = p.polygon }
				end

				love.graphics.setColor(0.3, 0.5, 0.9)
				local sx = off_x + (p.x or 0) * scale
				local sy = off_y + (p.y or 0) * scale

				if p.shape == "rectangle" then
					local rw = (p.width or Config.peg_rect_width) * scale
					local rh = (p.height or Config.peg_rect_height) * scale
					love.graphics.rectangle("fill", sx - rw / 2, sy - rh / 2, rw, rh)
				elseif p.shape == "annular" and p.polygon then
					local poly = {}
					for i = 1, #p.polygon, 2 do
						poly[#poly + 1] = off_x + p.polygon[i] * scale
						poly[#poly + 1] = off_y + p.polygon[i + 1] * scale
					end
					love.graphics.polygon("fill", poly)
				else
					local pr = (p.radius or Config.peg_radius) * scale
					love.graphics.circle("fill", sx, sy, pr)
				end
			end
			love.graphics.setScissor()
		elseif self.preview_error then
			love.graphics.setColor(1, 0.3, 0.3)
			local err = love.graphics.newText(font, "Error loading level")
			love.graphics.draw(err, prev_x + 10, prev_y + 40)
		end
	end
end

function LevelSelectState:mousepressed(x, y, button)
	if button ~= 1 then return end
	local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()

	-- Back button
	local back_w, back_h = 100, 36
	local back_x, back_y = ww - back_w - 20, 15
	if x >= back_x and x <= back_x + back_w and y >= back_y and y <= back_y + back_h then
		States.switch("menu")
		return
	end

	-- Start button
	local list_x, list_y = 20, 60
	local list_w, list_h = 260, wh - 100
	local btn_w, btn_h = 180, 48
	local btn_x, btn_y = list_x, list_y + list_h + 10
	if x >= btn_x and x <= btn_x + btn_w and y >= btn_y and y <= btn_y + btn_h then
		if #self.levels > 0 and self.selected_index <= #self.levels then
			States.switch("game", self.mode, self.levels[self.selected_index])
		end
		return
	end

	-- Level list
	local entry_h = 36
	for i, name in ipairs(self.levels) do
		local ey = list_y + 4 + (i - 1) * entry_h
		if ey + entry_h > list_y + list_h then break end
		if x >= list_x and x <= list_x + list_w and y >= ey and y <= ey + entry_h then
			self.selected_index = i
			return
		end
	end
end

function LevelSelectState:mousemoved(x, y, dx, dy)
	self.mouse_x = x
	self.mouse_y = y
end

function LevelSelectState:keypressed(key)
	if key == "escape" then
		States.switch("menu")
	elseif key == "down" then
		self.selected_index = math.min(self.selected_index + 1, #self.levels)
	elseif key == "up" then
		self.selected_index = math.max(self.selected_index - 1, 1)
	elseif key == "return" or key == "kpenter" then
		if #self.levels > 0 and self.selected_index <= #self.levels then
			States.switch("game", self.mode, self.levels[self.selected_index])
		end
	end
end

States.level_select = LevelSelectState
return LevelSelectState
