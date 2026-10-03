-- ===========================================================================
-- ReplayLibrary: named, unique replay storage.
--
-- The interactive game always keeps the launch state of the most recent shot
-- in memory (see Engine:saveLastShotReplay). Saving copies it to
-- `replays/<YYYYMMDD_HHMMSS[_name]>.lua`, so every capture is preserved
-- instead of overwriting a single last_shot.lua. Names default to the
-- capture timestamp and accept an optional user label appended after it.
--
-- Files are plain schema-2 captures written by Replay.serialize and read back
-- by Replay.load, so they replay through the same --replay path.
--
-- This module uses plain io/os (not love.filesystem) because replays live in
-- the project working directory, not the LÖVE save directory.
-- ===========================================================================

local Replay = require("src.systems.replay")

local ReplayLibrary = {}

-- Directory (relative to the process working directory) holding saved
-- replays. Created on first save. Tests override this to a temp path.
ReplayLibrary.DIR = "replays"

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function ReplayLibrary.ensureDir()
	-- io.open cannot create directories, so shell out (idempotent).
	os.execute("mkdir -p " .. shell_quote(ReplayLibrary.DIR))
end

function ReplayLibrary.fileExists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- Strip a trailing .lua and reduce anything that is not alphanumeric,
-- dash, or underscore to an underscore. Empty labels collapse to "".
function ReplayLibrary.sanitizeName(name)
	local s = tostring(name)
	s = s:gsub("%.lua$", "")
	s = s:gsub("[^%w%-_]+", "_")
	s = s:gsub("^_+", ""):gsub("_+$", "")
	return s
end

-- Default stem: the capture timestamp, unique to the second.
function ReplayLibrary.defaultName()
	return os.date("%Y%m%d_%H%M%S")
end

-- Resolve an optional label to a never-before-used path inside DIR. Existing
-- files get a numeric suffix so a save can never overwrite another replay.
function ReplayLibrary.uniquePath(name)
	ReplayLibrary.ensureDir()
	local stem = ReplayLibrary.defaultName()
	if name ~= nil and name ~= "" then
		local clean = ReplayLibrary.sanitizeName(name)
		if clean ~= "" then
			stem = stem .. "_" .. clean
		end
	end
	local path = ReplayLibrary.DIR .. "/" .. stem .. ".lua"
	local n = 2
	while ReplayLibrary.fileExists(path) do
		path = ReplayLibrary.DIR .. "/" .. stem .. "_" .. n .. ".lua"
		n = n + 1
	end
	return path
end

-- Save an already-serialized capture. Returns path, or nil plus an error
-- message when the file cannot be written.
function ReplayLibrary.saveSerialized(serialized, name)
	local path = ReplayLibrary.uniquePath(name)
	local ok, err = Replay.write(path, serialized)
	if not ok then
		return nil, err
	end
	return path
end

-- Save a capture data table (serialized immediately, at launch state).
function ReplayLibrary.save(data, name)
	return ReplayLibrary.saveSerialized(Replay.serialize(data), name)
end

-- List saved replays, newest first. Each entry is
-- { name, path, level_name }; level_name is nil for an unreadable capture.
function ReplayLibrary.list()
	local entries = {}
	local p = io.popen("ls -1 " .. shell_quote(ReplayLibrary.DIR) .. " 2>/dev/null")
	if not p then
		return entries
	end
	for line in p:lines() do
		if line:match("%.lua$") then
			local path = ReplayLibrary.DIR .. "/" .. line
			local data = Replay.load(path)
			table.insert(entries, {
				name = line:gsub("%.lua$", ""),
				path = path,
				level_name = data and data.level_name or nil,
			})
		end
	end
	p:close()
	-- Names begin with the capture timestamp, so descending order is newest
	-- first; the tiebreak keeps ordering deterministic for same-second saves.
	table.sort(entries, function(a, b)
		if a.name ~= b.name then
			return a.name > b.name
		end
		return a.path > b.path
	end)
	return entries
end

function ReplayLibrary.latest()
	local entries = ReplayLibrary.list()
	return entries[1]
end

-- Resolve a CLI selector to a replay path. Accepts:
--   "latest" / "last"        -> newest saved replay
--   an existing path         -> used as-is (backward compatible)
--   a stem                   -> replays/<stem>.lua
-- Returns path, or nil plus an error message.
function ReplayLibrary.resolve(selector)
	if selector == nil or selector == "" then
		return nil, "no replay specified"
	end
	if selector == "latest" or selector == "last" then
		local newest = ReplayLibrary.latest()
		if not newest then
			return nil, "no saved replays in " .. ReplayLibrary.DIR .. "/"
		end
		return newest.path
	end
	if ReplayLibrary.fileExists(selector) then
		return selector
	end
	local candidate = ReplayLibrary.DIR .. "/" .. selector
	if ReplayLibrary.fileExists(candidate) then
		return candidate
	end
	candidate = ReplayLibrary.DIR .. "/" .. selector .. ".lua"
	if ReplayLibrary.fileExists(candidate) then
		return candidate
	end
	-- Convenience: match a unique label suffix, so "demo" resolves
	-- "20260913_120000_demo".
	local sanitized = ReplayLibrary.sanitizeName(selector)
	if sanitized ~= "" then
		local suffix = "_" .. sanitized
		local matches = {}
		for _, e in ipairs(ReplayLibrary.list()) do
			if e.name == selector or e.name:sub(-#suffix) == suffix then
				table.insert(matches, e)
			end
		end
		if #matches == 1 then
			return matches[1].path
		end
		if #matches > 1 then
			local names = {}
			for _, e in ipairs(matches) do
				table.insert(names, e.name)
			end
			return nil, "ambiguous replay name '" .. selector .. "': "
				.. table.concat(names, ", ")
		end
	end
	return nil, "replay not found: " .. selector
end

-- Human-readable listing for --list-replays. Newest entry is marked.
function ReplayLibrary.formatList()
	local entries = ReplayLibrary.list()
	if #entries == 0 then
		return "No saved replays in " .. ReplayLibrary.DIR .. "/"
	end
	local lines = { "Saved replays (" .. #entries .. ") in " .. ReplayLibrary.DIR .. "/:" }
	for i, e in ipairs(entries) do
		local marker = i == 1 and "*" or " "
		local level = e.level_name and ("  [" .. e.level_name .. "]") or ""
		table.insert(lines, string.format("  %s %s%s", marker, e.name, level))
	end
	return table.concat(lines, "\n")
end

return ReplayLibrary
