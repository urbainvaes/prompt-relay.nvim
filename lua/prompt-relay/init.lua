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

local function notify_error(message)
  vim.notify("prompt-relay: " .. message, vim.log.levels.ERROR)
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

  -- Give Codex's TUI time to consume the bracketed paste before submitting.
  if agent.provider == "codex" then
    vim.defer_fn(submit, 200)
  else
    submit()
  end
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
    local payload = string.format("%s\n\n%s", context, request)
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
