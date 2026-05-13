local File = require('gitstatus.file')
local Line = require('gitstatus.line')
local StringUtils = require('gitstatus.string_utils')
local Window = require('gitstatus.window')
local constants = require('gitstatus.constants')
local git = require('gitstatus.git')
local out_formatter = require('gitstatus.out_formatter')
local parse = require('gitstatus.parse')

local M = {}
local config = require('gitstatus.defaults')

---@class State
---@field help_window_id integer?
---@field buf_lines Line[]
---@field window_id integer
---@field buf_id integer
---@field namespace_id integer
---@field parent_win_width integer
---@field parent_win_height integer
---@field repo_root string
---@field repo_git_dir string

local WINDOW_WIDTH = 80

---@return BorderChars
local function get_border_chars()
  local border = config.border
  return constants.BORDER_CHARS[border]
end

---@param win_id integer?
local function safe_close_win(win_id)
  if win_id ~= nil and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_close(win_id, false)
  end
end

---@param buf_id integer?
local function safe_delete_buf(buf_id)
  if buf_id ~= nil and vim.api.nvim_buf_is_valid(buf_id) then
    vim.api.nvim_buf_delete(buf_id, {})
  end
end

---@param state State
local function close_status_window(state)
  safe_close_win(state.help_window_id)
  state.help_window_id = nil

  safe_close_win(state.window_id)
  safe_delete_buf(state.buf_id)
end

---@param buf_id integer
---@param namespace_id integer
---@param lines Line[]
---@param lock_buf boolean?
---@return string[]
local function render_lines(buf_id, namespace_id, lines, lock_buf)
  if lock_buf == nil then
    lock_buf = true
  end

  local line_strings = Line.get_lines_strings(lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf_id })
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, true, line_strings)
  vim.api.nvim_buf_clear_namespace(buf_id, namespace_id, 0, -1)

  for row, line in ipairs(lines) do
    local col = 0
    for _, part in ipairs(line.parts) do
      if part.hl_group ~= nil and part.hl_group ~= '' and #part.str > 0 then
        vim.api.nvim_buf_set_extmark(buf_id, namespace_id, row - 1, col, {
          end_col = col + #part.str,
          hl_group = part.hl_group,
        })
      end
      col = col + #part.str
    end
  end

  if lock_buf then
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf_id })
  end
  return line_strings
end

---@param state State
local function toggle_help_window(state)
  if state.help_window_id ~= nil then
    safe_close_win(state.help_window_id)
    state.help_window_id = nil
    return
  end

  local lines = out_formatter.make_help_window_msg()
  local buf_id = vim.api.nvim_create_buf(false, true)
  local namespace_id = vim.api.nvim_create_namespace('gitstatus_help')
  local lines_strings = render_lines(buf_id, namespace_id, lines)

  local pos = vim.api.nvim_win_get_position(state.window_id)
  local row, col = unpack(pos)
  state.help_window_id = vim.api.nvim_open_win(buf_id, false, {
    relative = 'editor',
    width = WINDOW_WIDTH,
    height = #lines_strings,
    row = row + vim.api.nvim_win_get_height(state.window_id) + 1,
    col = col,
    zindex = 100,
    style = 'minimal',
    border = get_border_chars(),
  })
end

---@param cursor_file File?
---@param buf_lines Line[]
---@return integer
local function get_new_cursor_row(cursor_file, buf_lines)
  local default = Line.next_file_index(buf_lines, 0) or 1
  if cursor_file == nil then
    return default
  end
  return Line.line_index_of_file(buf_lines, cursor_file) or default
end

---@param state State
---@param cursor_file File?
local function refresh_buffer(state, cursor_file)
  if not vim.api.nvim_win_is_valid(state.window_id) then
    return
  end

  local col = vim.api.nvim_win_get_cursor(state.window_id)[2]

  local status_out, err = git.status(state.repo_root)
  if err ~= nil then
    vim.notify(err, vim.log.levels.ERROR)
    close_status_window(state)
    return
  end
  local paths = parse.git_status(status_out)
  local files = File.paths_to_files(paths)

  local branch_out, err2 = git.branch(state.repo_root)
  if err2 ~= nil then
    vim.notify(err2, vim.log.levels.ERROR)
    close_status_window(state)
    return
  end
  local branch, err3 = parse.git_branch(branch_out)
  if err3 ~= nil then
    vim.notify(err3, vim.log.levels.ERROR)
    close_status_window(state)
    return
  end

  state.buf_lines = out_formatter.format_out_lines(branch, files)
  local lines_strings =
    render_lines(state.buf_id, state.namespace_id, state.buf_lines)

  local optimal_height = Window.height(lines_strings, state.parent_win_height)
  local max_height = 15
  local height = optimal_height > max_height and max_height or optimal_height
  vim.api.nvim_win_set_config(state.window_id, {
    relative = 'editor',
    width = WINDOW_WIDTH,
    height = height,
    row = Window.row(state.parent_win_height, height),
    col = Window.column(state.parent_win_width, WINDOW_WIDTH),
  })
  vim.api.nvim_win_set_cursor(state.window_id, {
    get_new_cursor_row(cursor_file, state.buf_lines),
    col,
  })

  if state.help_window_id ~= nil then
    safe_close_win(state.help_window_id)
    state.help_window_id = nil
    toggle_help_window(state)
  end
end

---@param file File
---@return fun(file: string, cwd: string): string?
local function get_toggle_stage_file_func(file)
  if file.state == File.STATE.staged then
    return file.type == File.EDIT_TYPE.added and git.unstage_added_file
      or git.unstage_modified_file
  end
  return git.stage_file
end

---@param state State
---@return File? next_file
local function toggle_stage_file(state)
  local row = vim.api.nvim_win_get_cursor(state.window_id)[1]
  local line = state.buf_lines[row]
  if line == nil or line.file == nil then
    vim.notify(
      'Unable to stage/unstage file: invalid line',
      vim.log.levels.WARN
    )
    return
  end

  local toggle_stage_file_func = get_toggle_stage_file_func(line.file)
  local err = toggle_stage_file_func(line.file.path, state.repo_root)
  if err ~= nil then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  if line.file.orig_path ~= nil then
    err = toggle_stage_file_func(line.file.orig_path, state.repo_root)
    if err ~= nil then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
  end

  local next_file_index = Line.next_file_index(state.buf_lines, row)
    or Line.prev_file_index(state.buf_lines, row)
  return next_file_index ~= nil and state.buf_lines[next_file_index].file or nil
end

---@param state State
local function go_next_file(state)
  local cursor = vim.api.nvim_win_get_cursor(state.window_id)
  local row = cursor[1]
  local col = cursor[2]

  local motion_count = vim.api.nvim_get_vvar('count')
  local new_row = motion_count > 0 and row + motion_count
    or Line.next_file_index(state.buf_lines, row)
    or row < #state.buf_lines and row + 1
    or row
  vim.api.nvim_win_set_cursor(state.window_id, { new_row, col })
end

---@param state State
local function go_prev_file(state)
  local cursor = vim.api.nvim_win_get_cursor(state.window_id)
  local row = cursor[1]
  local col = cursor[2]

  local motion_count = vim.api.nvim_get_vvar('count')
  local new_row = motion_count > 0 and row - motion_count
    or Line.prev_file_index(state.buf_lines, row)
    or row > 1 and row - 1
    or row
  vim.api.nvim_win_set_cursor(state.window_id, { new_row, col })
end

---@param state State
local function open_file(state)
  local row = vim.api.nvim_win_get_cursor(state.window_id)[1]
  local line = state.buf_lines[row]
  if line == nil or line.file == nil then
    vim.notify('Unable to open file: invalid line', vim.log.levels.WARN)
    return
  end

  close_status_window(state)
  local open_file_cmd = vim.fn.bufexists(line.file.path) == 1 and 'buffer'
    or 'e'
  vim.api.nvim_cmd(
    { cmd = open_file_cmd, args = { vim.fn.fnameescape(line.file.path) } },
    {}
  )
end

---@param state State
local function open_commit_prompt(state)
  if Line.staged_files(state.buf_lines) == 0 then
    vim.notify('Unable to commit: no staged files', vim.log.levels.WARN)
    return
  end

  if Line.unmerged_files(state.buf_lines) > 0 then
    vim.notify(
      'Committing is not possible because you have unmerged files.',
      vim.log.levels.WARN
    )
    return
  end

  local buf_id = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf_id, state.repo_git_dir .. '/COMMIT_EDITMSG')
  vim.api.nvim_buf_call(buf_id, vim.cmd.edit)
  local help_msg = out_formatter.make_commit_init_msg()
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, true, help_msg)

  local height = 7
  local pos = vim.api.nvim_win_get_position(state.window_id)
  local row, col = unpack(pos)
  vim.api.nvim_open_win(buf_id, true, {
    relative = 'editor',
    width = WINDOW_WIDTH,
    height = height,
    row = row - height - 2,
    col = col,
    title = 'Git commit',
    border = get_border_chars(),
    noautocmd = true,
  })
  vim.cmd('silent write')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  vim.api.nvim_create_autocmd('QuitPre', {
    buffer = buf_id,
    callback = function(ev)
      local msg = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, true)
      local is_not_comment = function(str)
        return not StringUtils.str_starts_with(str, '#')
      end
      local msg_without_comments = StringUtils.filter(msg, is_not_comment)
      vim.api.nvim_buf_set_lines(ev.buf, 0, -1, true, msg_without_comments)
      vim.cmd('silent write')

      -- TODO: figure out why this notification isn't run until after the commit has finished
      -- TODO: if possible, consider running the hook when opening the commit window instead of when quitting it
      -- if git.repo_has_pre_commit_hook(repo_git_dir) then
      --   vim.notify('Running pre-commit hook...', vim.log.levels.INFO)
      -- end

      local commit_msg_file = vim.api.nvim_buf_get_name(ev.buf)
      local _, err2 = git.commit(commit_msg_file, state.repo_root)

      -- redraw before sending notification to avoid annoying prompt
      vim.cmd('redraw')

      if err2 ~= nil then
        vim.notify(
          StringUtils.strip_trailing_newline(err2),
          vim.log.levels.WARN
        )
      else
        vim.notify('Commit successful!', vim.log.levels.INFO)
      end

      vim.api.nvim_buf_delete(ev.buf, {})
      refresh_buffer(state, nil)
    end,
  })
end

---@param state State
local function register_keybindings(state)
  vim.keymap.set('n', 'q', function()
    close_status_window(state)
  end, {
    buffer = state.buf_id,
    desc = 'Quit',
  })
  vim.keymap.set('n', 's', function()
    local next_file = toggle_stage_file(state)
    refresh_buffer(state, next_file)
  end, {
    buffer = state.buf_id,
    desc = 'Stage/unstage file',
  })
  vim.keymap.set('n', 'a', function()
    local err = git.stage_all(state.repo_root)
    if err ~= nil then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    refresh_buffer(state, nil)
  end, {
    buffer = state.buf_id,
    desc = 'Stage all changes',
  })
  vim.keymap.set('n', 'j', function()
    go_next_file(state)
  end, {
    buffer = state.buf_id,
    desc = 'Go to next file',
  })
  vim.keymap.set('n', 'k', function()
    go_prev_file(state)
  end, {
    buffer = state.buf_id,
    desc = 'Go to previous file',
  })
  vim.keymap.set('n', 'o', function()
    open_file(state)
  end, {
    buffer = state.buf_id,
    desc = 'Open file',
  })
  vim.keymap.set('n', 'c', function()
    open_commit_prompt(state)
  end, {
    buffer = state.buf_id,
    desc = 'Open commit prompt',
  })
  vim.keymap.set('n', 'p', function()
    local out, err = git.push(state.repo_root)
    if err ~= nil then
      vim.notify(StringUtils.strip_trailing_newline(err), vim.log.levels.WARN)
      return
    end
    vim.notify(StringUtils.strip_trailing_newline(out), vim.log.levels.INFO)
  end, {
    buffer = state.buf_id,
    desc = 'Push',
  })
  vim.keymap.set('n', '?', function()
    toggle_help_window(state)
  end, {
    buffer = state.buf_id,
    desc = 'Toggle help window',
  })
end

function M.open_status_win()
  local buf_id = vim.api.nvim_create_buf(false, true)
  local parent_win_width = vim.api.nvim_win_get_width(0)
  local parent_win_height = vim.api.nvim_win_get_height(0)
  local default_height = 10
  local window_id = vim.api.nvim_open_win(buf_id, true, {
    relative = 'editor',
    width = WINDOW_WIDTH,
    height = default_height,
    row = Window.row(parent_win_height, default_height),
    col = Window.column(parent_win_width, WINDOW_WIDTH),
    title = 'Git status',
    border = get_border_chars(),
  })

  local nvim_notify_exists, nvim_notify = pcall(require, 'notify')
  if nvim_notify_exists then
    vim.notify = nvim_notify
  end

  local repo_root, err = git.repo_root_dir()
  if err ~= nil then
    vim.notify(err, vim.log.levels.ERROR)
    safe_close_win(window_id)
    safe_delete_buf(buf_id)
    return
  end

  local repo_git_dir, err2 = git.repo_git_dir()
  if err2 ~= nil then
    vim.notify(err2, vim.log.levels.ERROR)
    safe_close_win(window_id)
    safe_delete_buf(buf_id)
    return
  end

  local namespace_id = vim.api.nvim_create_namespace('gitstatus')
  vim.api.nvim_win_set_hl_ns(window_id, namespace_id)

  ---@type State
  local state = {
    help_window_id = nil,
    buf_lines = {},
    window_id = window_id,
    buf_id = buf_id,
    namespace_id = namespace_id,
    parent_win_width = parent_win_width,
    parent_win_height = parent_win_height,
    repo_root = repo_root,
    repo_git_dir = repo_git_dir,
  }

  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf_id,
    callback = function()
      close_status_window(state)
    end,
  })

  register_keybindings(state)
  refresh_buffer(state, nil)
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

return M
