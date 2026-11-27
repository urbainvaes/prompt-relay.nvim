# prompt-relay.nvim

## Motivation

This plugin is for users that run Neovim in a `tmux` pane and 
run a harness (Claude Code, OpenCode, or Codex) in another pane or window of the same `tmux` session. 
The main goal is to remove the friction that occurs when frequently switching back and forth between the editor and the harness.
It aims at doing **one thing well**: relaying prompts from Neovim to the harness.

When editing a file, I often want to ask an agent for a focused change.
Switching panes and describing the exact cursor position or selection is cumbersome.
The `opencode.nvim` plugin provided a solution to this problem for OpenCode but it didn't support other agents.
This plugin brings the same workflow to Claude Code, OpenCode, and Codex.

## Description of the plugin 

Send a request from Neovim to a harness (Claude Code, OpenCode, or Codex) in the current tmux session.
`<C-a>` opens a small floating prompt for the request and attaches the current file (as an absolute path) and cursor line/column;
in visual mode, it attaches the selection range and columns.
Neovim stays focused and shows a green success message after sending.
OpenCode is preferred by default;
if no supported agent is found, Neovim reports an error.

After sending, changes to already-open files sync into Neovim as undoable edits (`u` to undo).
Files with unsaved local changes are left untouched and reported.

Requests can also be dictated, as in the harnesses themselves:
hold `<M-v>` (Alt-V) in the prompt to talk, or tap it to start and stop.
Speech is transcribed locally with whisper.cpp, with a level meter and a live preview while recording,
and the transcript lands in the prompt so it can be reviewed and edited before sending.
See [Dictation](#dictation) for setup.

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

## Dictation

The request prompt supports local speech-to-text with [whisper.cpp](https://github.com/ggml-org/whisper.cpp).
**Hold `<M-v>`** (Alt-V) to talk and release it to stop,
or tap it once to start and again to stop.
While recording, the prompt shows a level meter and a live preview of the transcript;
the final transcript is inserted at the cursor, where it can be edited before pressing `<CR>`
(pressing `<CR>` while recording sends the request once the transcript is in).

Requirements: `arecord` (alsa-utils), `whisper-cli` on the `PATH`, and a model, e.g.

```sh
git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j --target whisper-cli
ln -s "$PWD/build/bin/whisper-cli" ~/.local/bin/
mkdir -p ~/.local/share/whisper.cpp/models
curl -L -o ~/.local/share/whisper.cpp/models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Options (shown with their defaults; set `dictation` to `v:false` to disable):

```vim
let g:prompt_relay = {'dictation': {
      \ 'key': '<M-v>',
      \ 'whisper_cmd': 'whisper-cli',
      \ 'model': '~/.local/share/whisper.cpp/models/ggml-small.bin',
      \ 'language': 'auto',
      \ }}
```

Setting `language` (e.g. `'en'` or `'fr'`) instead of `'auto'` saves about a second per transcription.

## License

Licensed under **GPL-3.0-or-later**; see [LICENSE](LICENSE).

## Credits

Written by GPT-6 Luna.
