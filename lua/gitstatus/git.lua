local StringUtils = require('gitstatus.string_utils')

local M = {}

---@param args string[]
---@param cwd string?
---@return vim.SystemCompleted
local function run_git(args, cwd)
	local opts = { text = true }
	if cwd then
		opts.cwd = cwd
	end
	return vim.system(vim.list_extend({ 'git' }, args), opts):wait()
end

---@param obj vim.SystemCompleted
---@param prefix string
---@return string, string?
local function stdout_or_err(obj, prefix)
	if obj.code ~= 0 then
		local err = obj.stderr ~= '' and obj.stderr or obj.stdout
		return '', prefix .. err
	end
	return obj.stdout, nil
end

---@return string, string?
function M.status(cwd)
	local obj = run_git({ 'status', '--porcelain=v1' }, cwd)
	return stdout_or_err(obj, 'Unable to get git status: ')
end

---@return string, string?
function M.branch(cwd)
	local obj = run_git({ 'branch' }, cwd)
	return stdout_or_err(obj, 'Unable to get git branch: ')
end

---@param file string
---@param cwd string
---@return string?
function M.stage_file(file, cwd)
	local obj = run_git({ 'add', file }, cwd)
	if obj.code ~= 0 then
		return 'Unable to stage file: ' .. obj.stderr
	end
end

---@param file string
---@param cwd string
---@return string?
function M.unstage_modified_file(file, cwd)
	local obj = run_git({ 'restore', '--staged', file }, cwd)
	if obj.code ~= 0 then
		return 'Unable to unstage file: ' .. obj.stderr
	end
end

---@param file string
---@param cwd string
---@return string?
function M.unstage_added_file(file, cwd)
	local obj = run_git({ 'rm', '--cached', file }, cwd)
	if obj.code ~= 0 then
		return 'Unable to unstage file: ' .. obj.stderr
	end
end

---@return string?
function M.stage_all(cwd)
	local obj = run_git({ 'add', '-A' }, cwd)
	if obj.code ~= 0 then
		return 'Unable to stage all changes: ' .. obj.stderr
	end
end

---@param filename string
---@return string, string? # success message, error
function M.commit(filename, cwd)
	local obj = run_git({ 'commit', '-F', filename }, cwd)
	if obj.code ~= 0 then
		return '', obj.stderr
	end
	return obj.stdout, nil
end

---@return string, string? # success message, error
function M.push(cwd)
	local obj = run_git({ 'push' }, cwd)
	if obj.code ~= 0 then
		return '', obj.stderr
	end
	return obj.stdout, nil
end

---@return string, string?
function M.repo_root_dir()
	local obj = run_git({ 'rev-parse', '--show-toplevel' }, nil)
	if obj.code ~= 0 then
		return '', 'Unable to get git repo root dir: ' .. obj.stderr
	end
	return StringUtils.strip_trailing_newline(obj.stdout), nil
end

---@param repo_git_dir string
---@return boolean
function M.repo_has_pre_commit_hook(repo_git_dir)
	local obj =
		vim.system({ 'test', '-e', repo_git_dir .. '/hooks/pre-commit' }):wait()
	return obj.code == 0
end

---@return string, string?
function M.repo_git_dir()
	local obj = run_git({ 'rev-parse', '--git-dir' }, nil)
	if obj.code ~= 0 then
		return '', 'Unable to get git dir: ' .. obj.stderr
	end
	return StringUtils.strip_trailing_newline(obj.stdout), nil
end

return M
