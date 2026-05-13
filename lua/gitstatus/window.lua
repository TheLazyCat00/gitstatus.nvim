local M = {}

---@param lines string[]
---@return integer
local function max_line_length(lines)
	local max_length = 0
	for _, line in ipairs(lines) do
		max_length = math.max(max_length, #line)
	end
	return max_length
end

---@param lines string[]
---@param numberwidth integer
---@param parent_win_width number
---@return number
function M.width(lines, numberwidth, parent_win_width)
	local margin = 5
	local width = max_line_length(lines) + numberwidth + margin
	return math.min(width, parent_win_width)
end

---@param lines string[]
---@param parent_win_height number
---@return number
function M.height(lines, parent_win_height)
	return math.min(#lines, parent_win_height)
end

---@param parent_win_height number
---@param win_height number
---@return number
function M.row(parent_win_height, win_height)
	return (parent_win_height - win_height) / 2
end

---@param parent_win_width number
---@param win_width number
---@return number
function M.column(parent_win_width, win_width)
	return (parent_win_width - win_width) / 2
end

return M
