local JSON = {}

local function escape_str(s)
    local in_char  = {'\\', '"', '/', '\b', '\f', '\n', '\r', '\t'}
    local out_char = {'\\', '"', '/',  'b',  'f',  'n',  'r',  't'}
    for i, c in ipairs(in_char) do
        s = s:gsub(c, '\\' .. out_char[i])
    end
    return s
end

function JSON.stringify(val)
    local t = type(val)
    if t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return '"' .. escape_str(val) .. '"'
    elseif t == "table" then
        local is_array = #val > 0
        if next(val) == nil then is_array = true end
        for k, v in pairs(val) do
            if type(k) ~= "number" then
                is_array = false
                break
            end
        end

        local res = {}
        if is_array then
            for i = 1, #val do
                table.insert(res, JSON.stringify(val[i]))
            end
            return "[" .. table.concat(res, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(res, '"' .. escape_str(tostring(k)) .. '":' .. JSON.stringify(v))
            end
            return "{" .. table.concat(res, ",") .. "}"
        end
    elseif val == nil then
        return "null"
    else
        return '"' .. tostring(val) .. '"'
    end
end

return JSON
