# prompt-relay.nvim

Send a request from Neovim to Claude Code or OpenCode in the current tmux session. `<C-a>` prompts for a request and attaches the current file and cursor line/column; in visual mode, it attaches the selection range and columns. If both agents are running, OpenCode is preferred. If neither is found, Neovim reports an error.

Install with vim-plug:

```vim
Plug '~/dotfiles/plugins/prompt-relay.nvim'
```

Change the mapping (default `<C-a>`) and, optionally, the provider preference before loading the plugin:

```vim
let g:prompt_relay = {'keymap': '<leader>a', 'preferred_provider': 'claude'}
```

Set `keymap` to `v:false` to disable the default mapping. Run either agent interactively in a pane in Neovim's tmux session; OpenCode needs no extra launch flags for tmux input.
