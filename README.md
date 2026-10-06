# prompt-relay.nvim

Send a request from Neovim to Claude Code, OpenCode, or Codex in the current tmux session. `<C-a>` prompts for a request and attaches the current file and cursor line/column; in visual mode, it attaches the selection range and columns. Neovim stays focused and shows a green success message after sending. OpenCode is preferred by default; if no supported agent is found, Neovim reports an error.

Install with vim-plug:

```vim
Plug '~/dotfiles/plugins/prompt-relay.nvim'
```

Change the mapping (default `<C-a>`) and, optionally, the provider preference before loading the plugin:

```vim
let g:prompt_relay = {'keymap': '<leader>a', 'preferred_provider': 'codex'}
```

`preferred_provider` may be `opencode`, `claude`, or `codex`; set `keymap` to `v:false` to disable the mapping. Run the CLI interactively in a pane in Neovim's tmux session; OpenCode needs no extra launch flags for tmux input.

Licensed under **GPL-3.0-or-later**; see [LICENSE](LICENSE).

Written by GPT-6 Luna.
