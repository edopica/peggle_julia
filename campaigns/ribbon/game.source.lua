local Config = require("src.config")
local Screen = require("src.systems.screen")
local LevelManager = require("src.systems.level_manager")
local Perf = require("src.systems.perf")
local States = require("src.states")
local Engine = require("src.engine.core")
local CliOptions = require("src.cli_options")
local GameplayTraceExporter = require("src.systems.gameplay_trace_exporter")
local ReplayLibrary = require("src.systems.replay_library")

-- ===========================================================================
-- Game State
-- ===========================================================================
local GameState = {}

function GameState:enter(mode, level_name)
	self.mode = mode
	self.level_name = level_name
	self.is_bench = false

	-- Player state
	self.players = {
		{ score = 0, balls = Config.starting_balls, bucket_hits = 0 },
		{ score = 0, balls = Config.starting_balls, bucket_hits = 0 },
	}
	self.current_player_index = 1
	self.shared_bucket_hits = 0
	self.game_over = false
	self.winner = nil
	self.penalty_text = nil
	self.penalty_timer = 0
	self.turn_overlay = ""
	self.turn_overlay_timer = 0
	self.cachedScoreText = ""
	self.style_popups = {}

	-- Replay saving: F8 opens a naming prompt for the most recent shot.
	self.replay_prompt_active = false
	self.replay_prompt_text = ""
	self.replay_message = nil
	self.replay_message_timer = 0

	self.show_debug_overlay = false
	self.is_profiling = false
	self.profile_file = nil
	self.profile_module = nil

	pcall(function()
		self.profile_module = require("jit.profile")
	end)

	self.engine = Engine.new({
		onHUDRefresh = function(eng) self:_refreshHUD(eng) end,
		onLaunch = function(eng) return self:_onLaunch(eng) end,
		onBucketCatch = function(eng, ball) self:_onBucketCatch(eng, ball) end,
		onFeverCatch = function(eng, ball, value) self:_onFeverCatch(eng, ball, value) end,
		onTurnEnd = function(eng) self:_endTurn(eng) end,
		onStyleShot = function(eng, info) self:_onStyleShot(eng, info) end,
	})

	-- Wire session-wide CLI options into the engine.
	self.engine.retain_shot_timeline = CliOptions.retain_shot_timeline
	self.engine.headless = CliOptions.headless
	if CliOptions.gameplay_trace_file then
		GameplayTraceExporter.init(CliOptions.gameplay_trace_file)
		self.engine.trace_exporter = GameplayTraceExporter
	end
	if CliOptions.headless then
		require("src.systems.contact_events").presentation_enabled = false
	end

	self.engine:setupLevel(self.level_name)
	self.engine:resetTurn()
end

function GameState:leave()
	if self.engine and self.engine.trace_exporter then
		self.engine.trace_exporter.close()
		self.engine.trace_exporter = nil
	end
end

function GameState:_player()
	return self.players[self.current_player_index]
end

function GameState:_refreshHUD(eng)
	local player = self:_player()
	local score = player.score + eng:getTurnScore()
	local label = "P1"
	if self.mode == "1v1" then
		label = "P" .. self.current_player_index
	end
	self.cachedScoreText = label .. " Score: " .. score .. " (x" .. eng.currentMultiplier .. ")  Balls: " .. player.balls
end

function GameState:_onLaunch(eng)
	local player = self:_player()
	if player.balls <= 0 then return false end
	player.balls = player.balls - 1
	return true
end

function GameState:_onBucketCatch(eng, ball)
	local player = self:_player()
	local x = ball and ball.x or LevelManager.virtual_width / 2
	local y = ball and ball.y or LevelManager.virtual_height / 3

	if self.mode == "solo" then
		player.balls = player.balls + 1
		table.insert(self.style_popups, {
			text = "FREE BALL!",
			points = nil,
			x = x,
			y = y,
			color = {0, 1, 0},
			scale = 1.4,
			duration = 2.0,
			time = 0
		})
	else
		self.shared_bucket_hits = self.shared_bucket_hits + 1
		local bonus = self.shared_bucket_hits * Config.bucket_incremental_base
		eng.bonusScore = eng.bonusScore + bonus
		table.insert(self.style_popups, {
			text = "BUCKET BONUS!",
			points = bonus,
			x = x,
			y = y,
			color = {0, 1, 0},
			scale = 1.4,
			duration = 2.0,
			time = 0
		})
	end
end

function GameState:_onFeverCatch(eng, ball, value)
	-- Fever points are awarded internally by core; we let the ball drop.
end

function GameState:_onStyleShot(eng, info)
	local ball = eng.balls and eng.balls[info.ball_id]
	local x = ball and ball.x or LevelManager.virtual_width / 2
	local y = ball and ball.y or LevelManager.virtual_height / 3

	local config = {
		long_shot = { text = "LONG SHOT!", color = {1, 1, 0}, scale = 1.2, duration = 2.0 },
		super_long_shot = { text = "SUPER LONG SHOT!", color = {1, 0.5, 0}, scale = 1.6, duration = 2.5 },
		double_long_shot = { text = "DOUBLE LONG SHOT!", color = {0.8, 0.2, 1}, scale = 1.6, duration = 3.0 },
		lucky_bounce = { text = "LUCKY BOUNCE!", color = {0, 1, 0}, scale = 1.3, duration = 2.0 },
		off_the_wall = { text = "OFF THE WALL!", color = {0, 1, 1}, scale = 1.3, duration = 2.0 },
		slide = { text = "SLIDE!", color = {0.6, 1, 1}, scale = 1.4, duration = 2.2 }
	}

	local preset = config[info.style]
	if preset then
		table.insert(self.style_popups, {
			text = preset.text,
			points = info.points,
			x = x,
			y = y,
			color = preset.color,
			scale = preset.scale,
			duration = preset.duration,
			time = 0
		})
	end
end

function GameState:_endTurn(eng)
	local player = self:_player()

	player.score = player.score + eng:getTurnScore()

	if self.mode == "1v1" then
		local hitRed = false
		for _, peg in ipairs(eng.turnPegsHit) do
			if peg.type == "red" then
				hitRed = true
				break
			end
		end
		if not hitRed then
			local turnScore = eng:getTurnScore()
			player.score = player.score - turnScore
			local penalty = math.floor(player.score * 0.25)
			player.score = player.score - penalty
			self.penalty_text = "-25% NO RED HIT"
			self.penalty_timer = 2.0
		end
	end

	local allRedCleared = true
	for _, peg in ipairs(eng.pegs) do
		if peg.type == "red" and not peg.hit then
			allRedCleared = false
			break
		end
	end

	if allRedCleared then
		self.game_over = true
		self.engine.is_halted = true
		self:_determineWinner()
		return
	end

	if self.mode == "solo" then
		if player.balls <= 0 then
			self.game_over = true
			self.engine.is_halted = true
			self.winner = 1
			return
		end
		self.engine:resetTurn()
	else
		local found = false
		for _ = 1, 2 do
			self.current_player_index = self.current_player_index == 1 and 2 or 1
			if self.players[self.current_player_index].balls > 0 then
				found = true
				break
			end
		end
		if not found then
			self.game_over = true
			self.engine.is_halted = true
			self:_determineWinner()
			return
		end

		self.turn_overlay = "PLAYER " .. self.current_player_index .. "'S TURN"
		self.turn_overlay_timer = 1.5
		self.engine:resetTurn()
	end
end

function GameState:_determineWinner()
	if self.mode == "solo" then
		self.winner = 1
	else
		local p1 = self.players[1]
		local p2 = self.players[2]
		if p1.score > p2.score then
			self.winner = 1
		elseif p2.score > p1.score then
			self.winner = 2
		else
			self.winner = 0
		end
	end
end

function GameState:update(dt)
	if not self.replay_prompt_active then
		self.engine:update(dt)
	end

	if self.turn_overlay_timer > 0 then
		self.turn_overlay_timer = self.turn_overlay_timer - dt
	end
	if self.penalty_timer > 0 then
		self.penalty_timer = self.penalty_timer - dt
	end
	if self.replay_message_timer > 0 then
		self.replay_message_timer = self.replay_message_timer - dt
	end

	for i = #self.style_popups, 1, -1 do
		local p = self.style_popups[i]
		p.time = p.time + dt
		p.y = p.y - (40 * dt)
		if p.time >= p.duration then
			table.remove(self.style_popups, i)
		end
	end
	
	Perf.report(dt)
end

function GameState:draw()
	Perf.beginDraw()
	love.graphics.clear(0, 0, 0, 1)
	Screen.apply()

	self.engine:draw()

	love.graphics.setColor(1, 1, 1, 0.7)
	love.graphics.print("Click/Enter: Launch | Arrows/Wheel: Aim | F8: Save Replay | 'R': Reload", 10, 10)

	love.graphics.setColor(1, 1, 1, 1)
	local font = love.graphics.getFont()
	local score_label = love.graphics.newText(font, self.cachedScoreText)
	love.graphics.draw(score_label, 10, 30)

	if self.penalty_timer > 0 then
		love.graphics.setColor(1, 0.3, 0.3, math.min(1, self.penalty_timer * 2))
		local ptext = love.graphics.newText(font, self.penalty_text)
		love.graphics.draw(ptext, LevelManager.virtual_width / 2 - ptext:getWidth() / 2, LevelManager.virtual_height / 2 - 40)
	end

	if self.turn_overlay_timer > 0 then
		local alpha = math.min(1, self.turn_overlay_timer * 2)
		love.graphics.setColor(0, 0, 0, 0.6 * alpha)
		love.graphics.rectangle("fill", 0, 0, LevelManager.virtual_width, LevelManager.virtual_height)
		love.graphics.setColor(1, 1, 1, alpha)
		local otext = love.graphics.newText(font, self.turn_overlay)
		love.graphics.draw(otext, LevelManager.virtual_width / 2 - otext:getWidth() / 2, LevelManager.virtual_height / 2 - otext:getHeight() / 2)
	end

	for _, p in ipairs(self.style_popups) do
		local alpha = 1.0
		if p.time > p.duration - 0.5 then
			alpha = math.max(0, (p.duration - p.time) / 0.5)
		end
		
		local text_str = p.text
		if p.points then
			text_str = text_str .. "\n+" .. p.points
		end
		local ptext = love.graphics.newText(font, text_str)
		local px = p.x - (ptext:getWidth() * p.scale) / 2
		local py = p.y - (ptext:getHeight() * p.scale) / 2
		
		-- Shadow
		love.graphics.setColor(0, 0, 0, 0.5 * alpha)
		love.graphics.draw(ptext, px + 2, py + 2, 0, p.scale, p.scale)
		
		-- Main text
		love.graphics.setColor(p.color[1], p.color[2], p.color[3], alpha)
		love.graphics.draw(ptext, px, py, 0, p.scale, p.scale)
	end

	if self.show_debug_overlay then
		local vw = LevelManager.virtual_width
		love.graphics.setColor(0, 0, 0, 0.7)
		love.graphics.rectangle("fill", vw - 260, 10, 250, self.is_profiling and 90 or 70)
		love.graphics.setColor(0, 1, 0, 1)
		local fps = love.timer.getFPS()
		local mem = collectgarbage("count")
		local ms = love.timer.getAverageDelta() * 1000
		love.graphics.print("FPS: " .. fps, vw - 250, 20)
		love.graphics.print(string.format("Mem: %.2f KB", mem), vw - 250, 40)
		love.graphics.print(string.format("Avg Frame: %.2f ms", ms), vw - 250, 60)
		if self.is_profiling then
			love.graphics.setColor(1, 0, 0, 1)
			love.graphics.print("PROFILING (jit.profile) ACTIVE", vw - 250, 80)
		end
	end

	Screen.clear()

	if self.game_over then
		local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
		love.graphics.setColor(0, 0, 0, 0.7)
		love.graphics.rectangle("fill", 0, 0, ww, wh)

		love.graphics.setColor(1, 1, 1, 1)
		local win_text
		if self.mode == "solo" then
			local player = self.players[1]
			win_text = "GAME OVER\nScore: " .. player.score
		elseif self.winner == 0 then
			win_text = "DRAW!\nP1: " .. self.players[1].score .. "  P2: " .. self.players[2].score
		else
			win_text = "PLAYER " .. self.winner .. " WINS!\nP1: " .. self.players[1].score .. "  P2: " .. self.players[2].score
		end

		local lines = {}
		for line in win_text:gmatch("[^\n]+") do
			table.insert(lines, line)
		end
		for i, line in ipairs(lines) do
			local t = love.graphics.newText(font, line)
			love.graphics.draw(t, ww / 2 - t:getWidth() / 2, wh * 0.3 + (i - 1) * 36)
		end

		local bw, bh = 220, 48
		local bx, by = ww / 2 - bw / 2, wh * 0.55
		local mx, my = love.mouse.getPosition()
		local hover = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
		love.graphics.setColor(hover and { 0.2, 0.5, 0.8 } or { 0.15, 0.35, 0.6 })
		love.graphics.rectangle("fill", bx, by, bw, bh, 8)
		love.graphics.setColor(1, 1, 1)
		local btn_text = love.graphics.newText(font, "RETURN TO MENU")
		love.graphics.draw(btn_text, bx + bw / 2 - btn_text:getWidth() / 2, by + bh / 2 - btn_text:getHeight() / 2)
	end

	if self.replay_message_timer > 0 and self.replay_message then
		local ww = love.graphics.getWidth()
		local alpha = math.min(1, self.replay_message_timer)
		local mtext = love.graphics.newText(font, self.replay_message)
		local mw, mh = mtext:getWidth(), mtext:getHeight()
		love.graphics.setColor(0, 0, 0, 0.75 * alpha)
		love.graphics.rectangle("fill", ww / 2 - mw / 2 - 14, 18, mw + 28, mh + 16, 6)
		love.graphics.setColor(0.6, 1, 0.6, alpha)
		love.graphics.draw(mtext, ww / 2 - mw / 2, 26)
	end

	if self.replay_prompt_active then
		local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
		love.graphics.setColor(0, 0, 0, 0.8)
		love.graphics.rectangle("fill", 0, 0, ww, wh)

		local box_w, box_h = 520, 150
		local bx, by = ww / 2 - box_w / 2, wh / 2 - box_h / 2
		love.graphics.setColor(0.1, 0.1, 0.18)
		love.graphics.rectangle("fill", bx, by, box_w, box_h, 8)

		love.graphics.setColor(1, 1, 1)
		local title = love.graphics.newText(font, "Save replay")
		love.graphics.draw(title, bx + 20, by + 16)

		local shown = self.replay_prompt_text
		if shown == "" then
			shown = "[" .. ReplayLibrary.defaultName() .. "]"
			love.graphics.setColor(0.6, 0.6, 0.7)
		else
			love.graphics.setColor(1, 1, 1)
		end
		local field = love.graphics.newText(font, shown .. "_")
		love.graphics.draw(field, bx + 20, by + 56)

		love.graphics.setColor(0.7, 0.7, 0.7)
		local hint = love.graphics.newText(font, "Enter: save    Esc: cancel    blank = timestamp name")
		love.graphics.draw(hint, bx + 20, by + box_h - 34)
	end

	Perf.endDraw()
end

function GameState:mousepressed(x, y, button)
	if self.game_over then
		if button == 1 then
			local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
			local bw, bh = 220, 48
			local bx, by = ww / 2 - bw / 2, wh * 0.55
			if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
				States.switch("menu")
			end
		end
		return
	end

	self.engine:mousepressed(x, y, button)
end

function GameState:mousemoved(x, y, dx, dy)
	if self.game_over then return end
	self.engine:mousemoved(x, y, dx, dy)
end

function GameState:wheelmoved(x, y)
	if self.game_over then return end
	self.engine:wheelmoved(x, y)
end

function GameState:_openReplayPrompt()
	if not self.engine.last_shot_replay_lua then
		self.replay_message = "No shot to save yet - launch a ball first"
		self.replay_message_timer = 2.5
		return
	end
	self.replay_prompt_active = true
	self.replay_prompt_text = ""
end

function GameState:_saveReplay()
	local path, err = self.engine:saveLastShotReplay(self.replay_prompt_text)
	self.replay_prompt_active = false
	if path then
		self.replay_message = "Replay saved: " .. path
	else
		self.replay_message = "Replay save failed: " .. tostring(err)
	end
	self.replay_message_timer = 3.0
end

function GameState:_handleReplayPromptKey(key)
	if key == "return" or key == "kpenter" then
		self:_saveReplay()
	elseif key == "escape" then
		self.replay_prompt_active = false
		self.replay_message = "Replay save cancelled"
		self.replay_message_timer = 2.0
	elseif key == "backspace" then
		self.replay_prompt_text = self.replay_prompt_text:sub(1, -2)
	end
end

function GameState:textinput(text)
	if self.replay_prompt_active and #self.replay_prompt_text < 64 then
		self.replay_prompt_text = self.replay_prompt_text .. text
	end
end

function GameState:keypressed(key)
	if self.replay_prompt_active then
		self:_handleReplayPromptKey(key)
		return
	end

	if self.game_over then
		if key == "escape" or key == "return" or key == "kpenter" then
			States.switch("menu")
		end
		return
	end

	self.engine:keypressed(key)

	if key == "f8" then
		self:_openReplayPrompt()
	elseif key == "r" then
		self.engine:setupLevel(self.level_name)
		self.engine:resetTurn()
	elseif key == "f5" then
		love.event.quit("restart")
	elseif key == "f3" then
		self.show_debug_overlay = not self.show_debug_overlay
	elseif key == "f4" then
		if self.profile_module then
			self.is_profiling = not self.is_profiling
			if self.is_profiling then
				self.profile_file = io.open("profile_dump.txt", "w")
				self.profile_module.start("li1", function(th, samples, vmst)
					if self.profile_file and self.profile_module then
						local dump = self.profile_module.dumpstack(th, "pf", 1)
						self.profile_file:write(dump .. "\n")
					end
				end)
			else
				self.profile_module.stop()
				if self.profile_file then
					self.profile_file:close()
					self.profile_file = nil
				end
			end
		end
	elseif key == "f6" then
		self.level_name = "benchmark_lasagna"
		self.engine:setupLevel(self.level_name)
		self.engine:resetTurn()
	elseif key == "escape" then
		States.switch("menu")
	end
end

States.game = GameState
return GameState
