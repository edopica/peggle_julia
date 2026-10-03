local TraceExporter = {
	file = nil,
	frame = 0
}

function TraceExporter.init(filename)
	TraceExporter.file = io.open(filename, "w")
	TraceExporter.frame = 0
	if TraceExporter.file then
		print("Exporting traces to " .. filename)
	else
		print("Failed to open trace file: " .. filename)
	end
end

function TraceExporter.record_frame(balls, pegs, bucket)
	if not TraceExporter.file then return end
	
	local t = {"{"}
	table.insert(t, '"frame":' .. TraceExporter.frame .. ',')
	
	table.insert(t, '"balls":[')
	for i, b in ipairs(balls) do
		table.insert(t, string.format('{"x":%.3f,"y":%.3f,"vx":%.3f,"vy":%.3f}', b.x, b.y, b.vx, b.vy))
		if i < #balls then table.insert(t, ",") end
	end
	table.insert(t, '],')
	
	table.insert(t, '"pegs":[')
	for i, p in ipairs(pegs) do
		table.insert(t, string.format('{"id":%d,"x":%.3f,"y":%.3f,"angle":%.3f}', p.original_index or 0, p.x, p.y, p.angle or 0))
		if i < #pegs then table.insert(t, ",") end
	end
	table.insert(t, '],')
	
	table.insert(t, '"bucket":{')
	if bucket then
		table.insert(t, string.format('"x":%.3f', bucket.x))
	else
		table.insert(t, '"x":0')
	end
	table.insert(t, '}')
	
	table.insert(t, "}\n")
	
	TraceExporter.file:write(table.concat(t))
	TraceExporter.frame = TraceExporter.frame + 1
end

function TraceExporter.close()
	if TraceExporter.file then
		TraceExporter.file:close()
		TraceExporter.file = nil
		print("Traces exported successfully.")
	end
end

return TraceExporter
