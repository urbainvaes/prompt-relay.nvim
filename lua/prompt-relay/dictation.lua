-- SPDX-License-Identifier: GPL-3.0-or-later

-- Microphone recording and local speech-to-text with whisper.cpp.

local M = {}

local SAMPLE_RATE = 16000
local BYTES_PER_SECOND = SAMPLE_RATE * 2 -- mono, signed 16-bit

local config = {
  whisper_cmd = "whisper-cli",
  model = "~/.local/share/whisper.cpp/models/ggml-small.bin",
  -- "auto" detects the language on every request, which costs about a second;
  -- set e.g. "en" or "fr" for faster transcription.
  language = "auto",
  threads = math.max(1, math.min(12, #vim.uv.cpu_info())),
  record_cmd = { "arecord", "-q", "-t", "raw", "-f", "S16_LE", "-r", "16000", "-c", "1" },
}

function M.configure(options)
  config = vim.tbl_extend("force", config, options or {})
end

function M.available()
  if vim.fn.executable(config.record_cmd[1]) ~= 1 then
    return false, "recording command not found: " .. config.record_cmd[1]
  end
  if vim.fn.executable(config.whisper_cmd) ~= 1 then
    return false, "whisper.cpp not found: " .. config.whisper_cmd
  end
  if vim.fn.filereadable(vim.fn.expand(config.model)) ~= 1 then
    return false, "whisper model not found: " .. config.model
  end
  return true
end

local function le(value, bytes)
  local out = {}
  for i = 1, bytes do
    out[i] = string.char(value % 256)
    value = math.floor(value / 256)
  end
  return table.concat(out)
end

local function wav(pcm)
  return "RIFF" .. le(36 + #pcm, 4) .. "WAVE"
    .. "fmt " .. le(16, 4) .. le(1, 2) .. le(1, 2)
    .. le(SAMPLE_RATE, 4) .. le(BYTES_PER_SECOND, 4) .. le(2, 2) .. le(16, 2)
    .. "data" .. le(#pcm, 4) .. pcm
end

-- Root-mean-square amplitude of a chunk of samples, in [0, 1].
local function level(chunk, first)
  local sum, count = 0, 0
  for i = first, #chunk - 1, 8 do
    local lo, hi = chunk:byte(i, i + 1)
    local sample = hi * 256 + lo
    if sample >= 32768 then
      sample = sample - 65536
    end
    sum = sum + sample * sample
    count = count + 1
  end
  if count == 0 then
    return 0
  end
  return math.sqrt(sum / count) / 32768
end

--- Start recording from the microphone.
--- on_level(level) is called on the main loop for each chunk of audio.
function M.record(on_level)
  local chunks, total = {}, 0
  local recorder = {}

  local ok, proc = pcall(vim.system, config.record_cmd, {
    stdout = function(_, data)
      if not data then
        return
      end
      -- Samples are 2 bytes; keep them aligned if a chunk split one.
      local first = total % 2 == 1 and 2 or 1
      table.insert(chunks, data)
      total = total + #data
      if on_level then
        local value = level(data, first)
        vim.schedule(function()
          on_level(value)
        end)
      end
    end,
  })
  if not ok then
    return nil, tostring(proc)
  end

  function recorder.audio()
    local pcm = table.concat(chunks)
    return pcm:sub(1, #pcm - #pcm % 2)
  end

  function recorder.seconds()
    return total / BYTES_PER_SECOND
  end

  function recorder.stop()
    if proc then
      pcall(proc.kill, proc, "sigterm")
      proc = nil
    end
    return recorder.audio()
  end

  return recorder
end

local function clean(text)
  text = text:gsub("%b[]", " "):gsub("%b()", " "):gsub("%s+", " ")
  return vim.trim(text)
end

--- Transcribe raw 16 kHz mono PCM. callback(text, err) runs on the main loop.
--- Returns a handle with a cancel() method.
function M.transcribe(pcm, callback)
  local seconds = #pcm / BYTES_PER_SECOND
  if seconds < 0.3 then
    vim.schedule(function()
      callback("")
    end)
    return { cancel = function() end }
  end
  -- whisper.cpp ignores clips shorter than a second: pad them with silence.
  local min_bytes = math.floor(1.1 * BYTES_PER_SECOND)
  if #pcm < min_bytes then
    pcm = pcm .. string.rep("\0", min_bytes - #pcm)
    seconds = #pcm / BYTES_PER_SECOND
  end

  local path = vim.fn.tempname() .. ".wav"
  local file = io.open(path, "wb")
  if not file then
    vim.schedule(function()
      callback(nil, "could not write " .. path)
    end)
    return { cancel = function() end }
  end
  file:write(wav(pcm))
  file:close()

  -- Whisper always encodes 30 s of audio (1500 frames) unless told otherwise;
  -- shrinking the context to the clip length makes short prompts much faster.
  -- Below ~384 frames decoding becomes unstable and much slower, though.
  local audio_ctx = math.min(1500, math.max(384, math.ceil(seconds * 50) + 128))
  local cancelled = false
  local ok, proc = pcall(vim.system, {
    config.whisper_cmd,
    "-m", vim.fn.expand(config.model),
    "-f", path,
    "-l", config.language,
    "-t", tostring(config.threads),
    "-ac", tostring(audio_ctx),
    "-nt", "-np",
  }, { text = true }, function(result)
    os.remove(path)
    vim.schedule(function()
      if cancelled then
        return
      end
      if result.code ~= 0 then
        callback(nil, "whisper.cpp failed: " .. vim.trim(result.stderr or ""))
      else
        callback(clean(result.stdout or ""))
      end
    end)
  end)
  if not ok then
    os.remove(path)
    vim.schedule(function()
      callback(nil, tostring(proc))
    end)
    return { cancel = function() end }
  end

  return {
    cancel = function()
      cancelled = true
      pcall(proc.kill, proc, "sigterm")
    end,
  }
end

return M
