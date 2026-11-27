-- SPDX-License-Identifier: GPL-3.0-or-later

-- Floating prompt window with push-to-talk dictation.

local dictation = require("prompt-relay.dictation")

local M = {}

local ns = vim.api.nvim_create_namespace("prompt-relay-prompt")

-- Terminals do not report key releases, so holding the dictation key is
-- detected from the auto-repeated presses the keyboard sends while it is held.
-- Recording starts on the first press; if repeats follow, it stops when they
-- do (push-to-talk), otherwise it was a tap and the next tap stops it.
local FIRST_REPEAT_MS = 900 -- max delay between the press and its first repeat
local RELEASE_MS = 250 -- no repeat for this long means the key was released
local PREVIEW_INTERVAL_MS = 1500

local METER = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function meter_char(value)
  if value <= 0 then
    return METER[1]
  end
  local index = math.floor((math.log(value, 10) + 3) / 2.5 * #METER) + 1
  return METER[math.max(1, math.min(#METER, index))]
end

--- Open the prompt. options:
---   title: window title
---   on_submit(text): called with the request when it is sent
---   dictation: false, or { key = "<M-v>" }
function M.open(options)
  local dictation_options = options.dictation
  local can_dictate = false
  local unavailable_reason
  if dictation_options then
    can_dictate, unavailable_reason = dictation.available()
  end

  local origin_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "prompt-relay"

  local width = math.max(20, math.min(100, vim.o.columns - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor(vim.o.lines * 0.3)),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 3,
    style = "minimal",
    border = "rounded",
    title = " " .. options.title .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local state = {
    closed = false,
    recorder = nil, -- active recording
    mode = nil, -- "pending" (just pressed), "hold", or "toggle"
    levels = {},
    started_at = 0,
    anchor = nil, -- extmark where the transcript goes
    preview = nil, -- latest live transcript
    preview_job = nil,
    final_job = nil,
    submit_when_done = false,
    ui_timer = nil,
    release_timer = nil,
    ignore_until = 0, -- swallow repeats of the key press that stopped recording
  }

  local key = dictation_options and dictation_options.key
  local hints = "<CR> send · <C-c> cancel"
  if can_dictate and key then
    hints = hints .. " · hold or tap " .. key .. " to dictate"
  end

  local function set_footer(chunks)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, { footer = chunks, footer_pos = "center" })
    end
  end

  local function render()
    if state.closed then
      return
    end

    if state.recorder then
      local meter = {}
      for i = math.max(1, #state.levels - 15), #state.levels do
        table.insert(meter, meter_char(state.levels[i]))
      end
      local stop_hint = state.mode == "hold" and ("release " .. key .. " to stop")
        or (key .. " to stop")
      set_footer({
        { " ● ", "DiagnosticError" },
        { string.format("%.1fs ", (now_ms() - state.started_at) / 1000), "Normal" },
        { table.concat(meter) .. " ", "DiagnosticOk" },
        { stop_hint .. " ", "Comment" },
      })
    elseif state.final_job then
      set_footer({ { " … transcribing ", "DiagnosticWarn" } })
    else
      set_footer({ { " " .. hints .. " ", "Comment" } })
    end

    if state.anchor then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, state.anchor, {})
      if pos[1] then
        local text = state.preview and state.preview ~= "" and state.preview
          or (state.recorder and "listening…" or "")
        state.anchor = vim.api.nvim_buf_set_extmark(buf, ns, pos[1], pos[2], {
          id = state.anchor,
          right_gravity = true,
          virt_text = text ~= "" and { { text, "Comment" } } or nil,
          virt_text_pos = "inline",
        })
      end
    end
  end

  local function stop_timer(name)
    if state[name] then
      state[name]:stop()
      state[name]:close()
      state[name] = nil
    end
  end

  local function cancel_jobs()
    if state.recorder then
      state.recorder.stop()
      state.recorder = nil
    end
    if state.preview_job then
      state.preview_job.cancel()
      state.preview_job = nil
    end
    if state.final_job then
      state.final_job.cancel()
      state.final_job = nil
    end
    stop_timer("ui_timer")
    stop_timer("release_timer")
  end

  local function close()
    if state.closed then
      return
    end
    state.closed = true
    cancel_jobs()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    vim.cmd.stopinsert()
  end

  local stop_recording

  local function submit()
    if state.recorder or state.final_job then
      -- Send once the transcript is in.
      state.submit_when_done = true
      if state.recorder then
        stop_recording()
      end
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, " "))
    close()
    if text ~= "" then
      options.on_submit(text)
    end
  end

  local function insert_transcript(text)
    local pos = state.anchor and vim.api.nvim_buf_get_extmark_by_id(buf, ns, state.anchor, {})
    state.anchor = nil
    state.preview = nil
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if not text or text == "" or not pos or not pos[1] then
      return
    end

    local row, col = pos[1], pos[2]
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local before = line:sub(col, col)
    local after = line:sub(col + 1, col + 1)
    if col > 0 and not before:match("%s") then
      text = " " .. text
    end
    if after ~= "" and not after:match("%s") then
      text = text .. " "
    end
    vim.api.nvim_buf_set_text(buf, row, col, row, col, { text })
    if vim.api.nvim_get_current_win() == win then
      vim.api.nvim_win_set_cursor(win, { row + 1, col + #text })
    end
  end

  local function start_recording(mode)
    if state.recorder or state.final_job or state.closed then
      return
    end
    local recorder, err = dictation.record(function(value)
      table.insert(state.levels, value)
    end)
    if not recorder then
      vim.notify("prompt-relay: could not start recording: " .. err, vim.log.levels.ERROR)
      return
    end

    state.recorder = recorder
    state.mode = mode
    state.levels = {}
    state.preview = nil
    state.started_at = now_ms()
    local cursor = vim.api.nvim_win_get_cursor(win)
    state.anchor = vim.api.nvim_buf_set_extmark(buf, ns, cursor[1] - 1, cursor[2], { right_gravity = true })

    local last_preview = now_ms()
    state.ui_timer = vim.uv.new_timer()
    state.ui_timer:start(0, 100, vim.schedule_wrap(function()
      if not state.recorder then
        return
      end
      render()
      -- Live preview: periodically transcribe what has been said so far.
      if not state.preview_job and now_ms() - last_preview >= PREVIEW_INTERVAL_MS
        and recorder.seconds() >= 1 then
        last_preview = now_ms()
        state.preview_job = dictation.transcribe(recorder.audio(), function(text)
          state.preview_job = nil
          if state.recorder == recorder and text then
            state.preview = text
            render()
          end
        end)
      end
    end))
  end

  stop_recording = function()
    if not state.recorder then
      return
    end
    local pcm = state.recorder.stop()
    state.recorder = nil
    stop_timer("ui_timer")
    stop_timer("release_timer")
    if state.preview_job then
      state.preview_job.cancel()
      state.preview_job = nil
    end

    state.final_job = dictation.transcribe(pcm, function(text, err)
      state.final_job = nil
      if state.closed then
        return
      end
      if err then
        vim.notify("prompt-relay: " .. err, vim.log.levels.ERROR)
      end
      insert_transcript(text)
      render()
      if state.submit_when_done then
        state.submit_when_done = false
        submit()
      end
    end)
    render()
  end

  local function arm_release_timer(ms)
    if not state.release_timer then
      state.release_timer = vim.uv.new_timer()
    end
    state.release_timer:start(ms, 0, vim.schedule_wrap(function()
      if state.mode == "hold" then
        stop_recording()
      elseif state.mode == "pending" then
        -- No auto-repeat followed the press: it was a tap, keep listening.
        state.mode = "toggle"
        render()
      end
    end))
  end

  local function on_key()
    local t = now_ms()
    if t < state.ignore_until then
      state.ignore_until = t + RELEASE_MS
      return
    end
    if state.final_job then
      return
    end
    if not can_dictate then
      vim.notify("prompt-relay: dictation unavailable: " .. (unavailable_reason or "disabled"), vim.log.levels.WARN)
      return
    end

    if not state.recorder then
      start_recording("pending")
      arm_release_timer(FIRST_REPEAT_MS)
    elseif state.mode == "pending" or state.mode == "hold" then
      -- Auto-repeat: the key is held down.
      state.mode = "hold"
      arm_release_timer(RELEASE_MS)
    else
      -- Second tap.
      state.ignore_until = t + RELEASE_MS
      stop_recording()
    end
  end

  local map = function(modes, lhs, rhs, extra)
    vim.keymap.set(modes, lhs, rhs, vim.tbl_extend("force", { buffer = buf, nowait = true }, extra or {}))
  end
  map({ "i", "n" }, "<CR>", submit)
  map({ "i", "n" }, "<C-c>", close)
  map("n", "<Esc>", close)
  map("n", "q", close)
  if key then
    map({ "i", "n" }, key, on_key)
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  render()
  vim.cmd.startinsert()
end

return M
