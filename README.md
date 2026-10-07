# prompt-relay.nvim

## Motivation

This plugin is for workflows that use Neovim and run a harness (Claude Code, OpenCode, or Codex) 
in another pane of the same tmux session. 
The main goal is to remove the friction that occurs when frequently switching back and forth between the editor and the harness.
It aims at doing **one thing well**: relaying prompts from Neovim to the harness.

When editing a file, I often want to ask an agent for a focused change.
Switching panes and describing the exact cursor position or selection is cumbersome.
The `opencode.nvim` plugin made this workflow convenient for OpenCode but it didn't support other agents.
This plugin brings the same workflow to Claude Code, OpenCode, and Codex.

## Description of the plugin 

Send a request from Neovim to a harness (Claude Code, OpenCode, or Codex) in the current tmux session.
`<C-a>` prompts for a request and attaches the current file (as an absolute path) and cursor line/column;
in visual mode, it attaches the selection range and columns.
Neovim stays focused and shows a green success message after sending.
OpenCode is preferred by default;
if no supported agent is found, Neovim reports an error.

After sending, changes to already-open files sync into Neovim as undoable edits (`u` to undo).
Files with unsaved local changes are left untouched and reported.

## Installation

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
