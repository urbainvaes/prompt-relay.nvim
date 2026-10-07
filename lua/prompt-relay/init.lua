-- SPDX-License-Identifier: GPL-3.0-or-later

local M = {}

local defaults = {
  keymap = "<C-a>",
  preferred_provider = "opencode",
}

local providers = { "opencode", "claude", "codex" }
local provider_names = {
  opencode = "OpenCode",
  claude = "Claude Code",
  codex = "Codex",
}

local current_keymap
local tracked_buffers = {}
local sync_timer
local syncing = false

local function notify_error(message)
  vim.notify("prompt-relay: " .. message, vim.log.levels.ERROR)
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for i = 1, #left do
    if left[i] ~= right[i] then
      return false
    end
  end
  return true
end

local function read_file_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function file_signature(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return table.concat({
    stat.size,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.ctime.sec,
    stat.ctime.nsec,
  }, ":")
end

local function track_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    tracked_buffers[buf] = nil
    return
  end
  if vim.bo[buf].buftype ~= "" or vim.bo[buf].binary then
    return
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local signature = path ~= "" and file_signature(path) or nil
  local lines = signature and read_file_lines(path) or nil
  if signature and lines then
    tracked_buffers[buf] = { path = path, signature = signature, disk_lines = lines }
  end
end

local function buffer_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function checkpoint_buffer(buf)
  return vim.api.nvim_buf_call(buf, function()
    if vim.bo[buf].modified then
      vim.cmd("silent noautocmd write!")
    end
    return true
  end)
end

local function apply_disk_changes(buf, old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"
  local hunks = vim.diff(old_text, new_text, { result_type = "indices" })

  return vim.api.nvim_buf_call(buf, function()
    for i = #hunks, 1, -1 do
      local hunk = hunks[i]
      local start_row = hunk[2] == 0 and hunk[1] or math.max(0, hunk[1] - 1)
      local replacement = {}
      for row = hunk[3], hunk[3] + hunk[4] - 1 do
        table.insert(replacement, new_lines[row])
      end

      if i < #hunks then
        pcall(vim.cmd, "undojoin")
      end
      vim.api.nvim_buf_set_lines(buf, start_row, start_row + hunk[2], false, replacement)
    end

    -- Only checkpoint the new undo state if the disk still matches what we
    -- just applied; don't replace a newer concurrent write.
    local current_disk = read_file_lines(vim.api.nvim_buf_get_name(buf))
    if not current_disk or not same_lines(current_disk, new_lines) then
      return false
    end
    return checkpoint_buffer(buf)
  end)
end

local function sync_buffer(buf, state)
  local signature = file_signature(state.path)
  if not signature or signature == state.signature then
    return
  end

  local disk_lines = read_file_lines(state.path)
  if not disk_lines then
    return
  end
  if same_lines(state.disk_lines, disk_lines) then
    state.signature = signature
    return
  end

  local current_lines = buffer_lines(buf)
  if same_lines(current_lines, disk_lines) then
    local ok, err = pcall(checkpoint_buffer, buf)
    if not ok then
      vim.notify("prompt-relay: could not checkpoint synced buffer: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    state.disk_lines = disk_lines
    state.signature = signature
    return
  end
  if not same_lines(current_lines, state.disk_lines) then
    state.disk_lines = disk_lines
    state.signature = signature
    vim.notify(
      "prompt-relay: external change to " .. vim.fn.fnamemodify(state.path, ":.")
        .. " not synced because the buffer has unsaved edits",
      vim.log.levels.WARN
    )
    return
  end

  local ok, checkpointed = pcall(apply_disk_changes, buf, state.disk_lines, disk_lines)
  if not ok then
    vim.notify("prompt-relay: could not sync external change: " .. tostring(checkpointed), vim.log.levels.ERROR)
    return
  end

  state.disk_lines = disk_lines
  if checkpointed then
    state.signature = file_signature(state.path) or signature
  end
  vim.notify(
    "prompt-relay: synced " .. vim.fn.fnamemodify(state.path, ":.") .. " (undo with u)",
    vim.log.levels.INFO
  )
end

local function poll_buffers()
  if syncing then
    return
  end
  syncing = true

  for buf, state in pairs(tracked_buffers) do
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      tracked_buffers[buf] = nil
    else
      sync_buffer(buf, state)
    end
  end

  syncing = false
end

local function start_sync()
  if sync_timer then
    return
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    track_buffer(buf)
  end
  sync_timer = vim.uv.new_timer()
  sync_timer:start(500, 500, vim.schedule_wrap(poll_buffers))
end

local function setup_sync_autocmds()
  local group = vim.api.nvim_create_augroup("PromptRelaySync", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(args)
      if sync_timer then
        track_buffer(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      tracked_buffers[args.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if sync_timer then
        sync_timer:stop()
        sync_timer:close()
        sync_timer = nil
      end
    end,
  })
end

local function tmux(args, input)
  local output
  if input == nil then
    output = vim.fn.system(args)
  else
    output = vim.fn.system(args, input)
  end
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output)
  end
  return output
end

local function find_agent(preferred_provider)
  if not vim.env.TMUX or not vim.env.TMUX_PANE then
    return nil, "Neovim is not running in a tmux pane"
  end

  local session_id, err = tmux({
    "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE, "#{session_id}",
  })
  if not session_id then
    return nil, "could not determine the current tmux session: " .. err
  end
  session_id = vim.trim(session_id)

  local panes, pane_err = tmux({
    "tmux", "list-panes", "-s", "-t", session_id,
    "-F", "#{pane_id}\t#{pane_current_command}",
  })
  if not panes then
    return nil, "could not list tmux panes: " .. pane_err
  end

  local found = { opencode = {}, claude = {}, codex = {} }
  for line in panes:gmatch("[^\n]+") do
    local pane, command = line:match("^([^\t]+)\t(.+)$")
    if pane and command then
      command = vim.fs.basename(command):lower()
      if command == "opencode" then
        table.insert(found.opencode, pane)
      elseif command == "claude" or command == "claude-code" then
        table.insert(found.claude, pane)
      elseif command == "codex" or command == "codex-cli" then
        table.insert(found.codex, pane)
      end
    end
  end

  local priority = { preferred_provider }
  for _, provider in ipairs(providers) do
    if provider ~= preferred_provider then
      table.insert(priority, provider)
    end
  end

  for _, provider in ipairs(priority) do
    if #found[provider] > 0 then
      return { provider = provider, pane = found[provider][1] }
    end
  end

  return nil, "no Claude Code, OpenCode, or Codex pane found in this tmux session"
end

local function position(line, column)
  return { line = line, column = column }
end

local function capture_context(is_visual)
  local filename = vim.fn.expand("%:p")
  if filename == "" then
    return nil, "the current buffer has no file name"
  end
  filename = vim.fn.fnamemodify(filename, ":.")

  local start_pos, end_pos
  if is_visual then
    local anchor = vim.fn.getpos("v")
    local cursor = vim.fn.getpos(".")
    start_pos = position(anchor[2], vim.fn.virtcol("v"))
    end_pos = position(cursor[2], vim.fn.virtcol("."))

    if start_pos.line > end_pos.line
      or (start_pos.line == end_pos.line and start_pos.column > end_pos.column) then
      start_pos, end_pos = end_pos, start_pos
    end
  else
    local cursor = vim.api.nvim_win_get_cursor(0)
    start_pos = position(cursor[1], vim.fn.virtcol("."))
    end_pos = start_pos
  end

  local location
  if not is_visual then
    location = string.format("Location: %s:%d:%d", filename, start_pos.line, start_pos.column)
  elseif start_pos.line == end_pos.line and start_pos.column == end_pos.column then
    location = string.format("Selection: %s:%d:%d", filename, start_pos.line, start_pos.column)
  elseif start_pos.line == end_pos.line then
    location = string.format(
      "Selection: %s:%d:%d-%d",
      filename, start_pos.line, start_pos.column, end_pos.column
    )
  else
    location = string.format(
      "Selection: %s:%d:%d-%d:%d",
      filename, start_pos.line, start_pos.column, end_pos.line, end_pos.column
    )
  end

  return location
end

local function send(agent, payload, callback)
  local _, err = tmux({ "tmux", "load-buffer", "-" }, payload)
  if err then
    callback(nil, "could not prepare the request for tmux: " .. err)
    return
  end
  _, err = tmux({ "tmux", "paste-buffer", "-d", "-t", agent.pane })
  if err then
    callback(nil, "could not paste the request into the agent pane: " .. err)
    return
  end

  local function submit()
    local _, submit_err = tmux({ "tmux", "send-keys", "-t", agent.pane, "Enter" })
    if submit_err then
      callback(nil, "could not submit the request: " .. submit_err)
    else
      callback(true)
    end
  end

  -- Give the TUI time to consume the bracketed paste before submitting.
  vim.defer_fn(submit, 200)
end

local function relay(is_visual, preferred_provider)
  local context, context_err = capture_context(is_visual)
  if not context then
    notify_error(context_err)
    return
  end

  local agent, agent_err = find_agent(preferred_provider)
  if not agent then
    notify_error(agent_err)
    return
  end

  if is_visual then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  vim.ui.input({ prompt = "Request for " .. provider_names[agent.provider] .. ": " }, function(request)
    if not request or vim.trim(request) == "" then
      return
    end
    local payload = string.format("%s · %s", context, request)
    start_sync()
    send(agent, payload, function(ok, err)
      if not ok then
        notify_error(err)
      else
        vim.api.nvim_echo({ { "prompt-relay: sent to " .. provider_names[agent.provider], "MoreMsg" } }, false, {})
      end
    end)
  end)
end

function M.setup(options)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  setup_sync_autocmds()

  if not vim.tbl_contains(providers, options.preferred_provider) then
    error("prompt-relay: preferred_provider must be 'opencode', 'claude', or 'codex'")
  end

  if current_keymap then
    pcall(vim.keymap.del, { "n", "x" }, current_keymap)
    current_keymap = nil
  end

  if options.keymap ~= false then
    current_keymap = options.keymap
    local map_options = { desc = "Send a request to a tmux coding agent" }
    vim.keymap.set("n", current_keymap, function()
      relay(false, options.preferred_provider)
    end, map_options)
    vim.keymap.set("x", current_keymap, function()
      relay(true, options.preferred_provider)
    end, map_options)
  end
end

return M
