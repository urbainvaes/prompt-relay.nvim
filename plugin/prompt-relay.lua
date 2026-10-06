if vim.g.loaded_prompt_relay then
  return
end
vim.g.loaded_prompt_relay = true

require("prompt-relay").setup(vim.g.prompt_relay or {})
