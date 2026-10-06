-- SPDX-License-Identifier: GPL-3.0-or-later

if vim.g.loaded_prompt_relay then
  return
end
vim.g.loaded_prompt_relay = true

require("prompt-relay").setup(vim.g.prompt_relay or {})
