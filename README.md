# prompt-relay.nvim

## Human preface

This plugin is only useful if you like to use `tmux` 
with `nvim` and a harness (Claude Code, OpenCode, or Codex) running in different panes the same session.

**The problem**. I often want to make AI-assisted edits to a file opened with `nvim` opened in a `tmux` pane.
One solution would be to describe to the harness (Claude Code, OpenCode, or Codex), opened in another `tmux` pane,
precisely where I am in the file, and what I want to do.
But this is inefficient; it is much better to interact with the harness directly from the editor,
without having to switch to a different pane and describe the cursor position or selection range precisely.
The `opencode.nvim` plugin solved this problem for OpenCode
(in fact, it was the only feature of the plugin that I used), 
but the functionality was limited to OpenCode.
This plugin provides a unified interface to send requests to a harness.

## Description of the plugin 

Send a request from Neovim to Claude Code, OpenCode, or Codex in the current tmux session. `<C-a>` prompts for a request and attaches the current file and cursor line/column; in visual mode, it attaches the selection range and columns. Neovim stays focused and shows a green success message after sending. OpenCode is preferred by default; if no supported agent is found, Neovim reports an error.

After sending, changes to already-open files sync into Neovim as undoable edits (`u` to undo). Files with unsaved local changes are left untouched and reported.

Install with vim-plug:

```vim
Plug 'urbainvaes/prompt-relay.nvim'
```

Change the mapping (default `<C-a>`) and, optionally, the provider preference before loading the plugin:

```vim
let g:prompt_relay = {'keymap': '<leader>a', 'preferred_provider': 'codex'}
```

`preferred_provider` may be `opencode`, `claude`, or `codex`; set `keymap` to `v:false` to disable the mapping. Run the CLI interactively in a pane in Neovim's tmux session; OpenCode needs no extra launch flags for tmux input.

## License

Licensed under **GPL-3.0-or-later**; see [LICENSE](LICENSE).

## Credits

Written by GPT-6 Luna.
