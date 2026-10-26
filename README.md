# mermaid-lens.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
![LuaJIT](https://img.shields.io/badge/LuaJIT-FFI-2C2D72?logo=lua&logoColor=white)
![Protocol](https://img.shields.io/badge/Graphics-Kitty%20Protocol-7aa2f7)
![License](https://img.shields.io/badge/License-MIT-blue)

Interactive Mermaid diagram viewer, live modal editor, and workspace finder for Neovim powered by the **Kitty Graphics Protocol**, featuring hardware-accelerated pan & zoom, mouse drag, automatic multi-palette coloring, inline syntax diagnostics, and Telescope integration.

<p align="center">
  <img src="assets/demo-hero.gif" alt="Mermaid Lens Demo" width="100%" />
</p>

---

## Why `mermaid-lens.nvim`?

### The Problem

Existing Neovim image plugins render Mermaid diagrams inline inside the text buffer grid. On real-world software architecture diagrams (`erDiagram`, `sequenceDiagram`, large `flowchart`s), inline buffer rendering suffers from four limitations:

1. **Unreadable scaling:** Tall or wide diagrams are crushed into a few terminal rows, making labels illegible.
2. **No interactive camera:** Static inline placements cannot be panned in 2D, dragged with the mouse, or zoomed focally at 60 FPS.
3. **Opaque syntax errors:** When a diagram fails to compile, inline plugins fail silently or print raw stack traces without pointing to the broken line.
4. **No workspace discovery:** Finding a specific diagram across dozens of Markdown docs and `.mmd` files requires manual grepping.

### The Solution

`mermaid-lens.nvim` opens diagrams in a dedicated, aspect-ratio-accurate floating modal backed directly by the terminal's GPU texture memory:

- **Zero-latency hardware pan & zoom:** Uploads the high-DPI texture once and updates source crop rectangles (`x, y, w, h`) via atomic escape sequences without re-transmitting files or moving Neovim's physical cursor (`C=1`).
- **True pixel aspect-ratio adaptation:** Queries exact physical cell dimensions (`ws_xpixel / ws_col`, `ws_ypixel / ws_row`) from the host TTY via LuaJIT FFI `ioctl(TIOCGWINSZ)`—even through `tmux`—so diagrams never stretch or distort when resizing splits.
- **Dual-Mode Live Editing (`<Tab>`) & Isolated Undo:** Toggle seamlessly between the rendered diagram and an editable Mermaid code buffer inside the modal. Saving (`:w`) updates the exact block in your parent `.md` or `.mmd` file, re-renders on change, and maintains a per-diagram isolated undo tree (`u` / `<C-r>`) that never interferes with edits outside the diagram.
- **Exact Syntax Diagnostics (`vim.diagnostic`):** If `mmdc` encounters a syntax error, the modal automatically switches to Code Mode, highlights the exact offending line, and displays the parser error inline.
- **Multi-palette auto-coloring:** Automatically styles entities, actors, states, and nodes with a 10-color palette in both **Light** (Mermaid Live style, default) and **Dark** (TokyoNight style) themes.
- **Workspace & Buffer Telescope Picker:** Scans fenced Markdown blocks and standalone `.mmd` / `.mermaid` files across your project or current file, with customizable ignore rules.

---

## Visual Features

### 1. Light & Dark Auto-Colored Themes (`t` to toggle)

|         Light Theme (Default)          |           Dark Theme (`t`)           |
| :------------------------------------: | :----------------------------------: |
| ![Light Theme](assets/theme-light.png) | ![Dark Theme](assets/theme-dark.png) |

### 2. Live Code Mode (`<Tab>`) & Syntax Error Diagnostics

![Code Mode & Diagnostics](assets/live-edit-diagnostics.gif)

### 3. Project & Buffer Telescope Finder (`<leader>ms` / `<leader>mb`)

![Telescope Picker](assets/telescope-picker.gif)

---

## Architecture & Execution Flow

```mermaid
flowchart TD
    User(["User Action<br/>(:MermaidLensPreview / :MermaidLensTelescope)"]) --> Facade["Facade Controller<br/>(lua/mermaid_lens/init.lua)"]

    Facade --> Scanner["Workspace & Buffer Scanner<br/>(parser/scanner.lua & detector.lua)"]
    Scanner --> Compiler["Async Compiler & Cache Manager<br/>(renderer/compiler.lua & cache.lua)"]

    Compiler -->|Cache Miss| Loader["Centered Progress Loader (0% -> 100%)<br/>(ui/loader.lua)"]
    Compiler -->|Syntax Error / Missing CLI| Diag["Diagnostic Parser<br/>(renderer/diagnostics.lua)"]
    Compiler -->|Cache Hit 0ms / Compiled| Modal["Dual-Mode Preview Modal<br/>(ui/modal.lua & ui/help.lua)"]
    Diag --> Modal

    Modal <-->|"<Tab> Toggle"| CodeView["Isolated Code Buffer & Sync<br/>(ui/code_view.lua & editor/sync.lua)"]
    Modal --> Viewport["2D Camera & ioctl Pixel Math<br/>(graphics/viewport.lua & env/terminal.lua)"]
    Modal --> Input["Sandboxed Keymaps & Mouse/Touchpad Gestures<br/>(ui/input.lua)"]

    Viewport --> Kitty["Atomic Kitty APC + TMUX Passthrough<br/>(graphics/kitty.lua & env/multiplexer.lua)"]
```

---

## Supported Mermaid Diagrams

| Category                    | Supported Diagram Keywords                                                                                               | Auto-Coloring Support                 |
| :-------------------------- | :----------------------------------------------------------------------------------------------------------------------- | :------------------------------------ |
| **Database & Architecture** | `erDiagram`, `classDiagram`, `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`, `C4Deployment`, `architecture-beta` | Yes (10-color cyclic palette)         |
| **Flows & State**           | `flowchart`, `graph`, `stateDiagram`, `stateDiagram-v2`, `block-beta`                                                    | Yes (Nodes, clusters & states)        |
| **Interactions & Time**     | `sequenceDiagram`, `gantt`, `timeline`, `journey`, `gitGraph`                                                            | Yes (Actors, notes, tasks & branches) |
| **Data & Hierarchy**        | `mindmap`, `pie`, `quadrantChart`, `sankey`, `xychart`, `packet-beta`, `requirementDiagram`, `kanban`                    | Yes (`themeVariables` scales)         |

---

## Installation & Configuration

### Using [`lazy.nvim`](https://github.com/folke/lazy.nvim)

#### Minimal Setup (Uses Defaults)

```lua
{
  "JuanFerber/mermaid-lens.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  opts = {},
}
```

#### Full Configuration Reference (`opts`)

All settings and keybindings are optional. Below are the default values:

```lua
{
  "JuanFerber/mermaid-lens.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  opts = {
    -- Default rendering theme: "light" (Mermaid Live style) | "dark" (TokyoNight style)
    theme = "light",

    -- Dim the background behind the floating preview modal
    backdrop = true,
    backdrop_blend = 45, -- 0 (opaque) to 100 (fully transparent)

    -- Headless Chromium deviceScaleFactor (1..4) for crisp deep zoom
    scale = 3,

    -- Initial 2-finger touchpad behavior inside the modal: "zoom" | "pan"
    touchpad_mode = "zoom",

    -- Default Telescope search scope: "project" (all workspace files) | "buffer" (current file only)
    picker_scope = "project",

    -- Additional directories or glob patterns to ignore in Telescope workspace scans
    -- (Appended to built-in defaults: .git, node_modules, target, dist, build, .venv, etc.)
    ignored_dirs = {
      -- ".local",
      -- "docs/archive",
      -- "*.bak.md",
    },

    -- Code Mode & Live Editing options
    fallback_to_code = true,     -- Open modal in Code Mode if dependencies are missing or syntax fails
    auto_render_on_save = true,  -- Re-compile & preview on `:w` in Code Mode (only when code changed)
    save_parent_on_write = true, -- Sync edits back to the parent .md/.mmd file on `:w`

    -- Modal window geometry relative to the current terminal size
    modal = {
      width = 0.92,       -- 92% of terminal columns
      height = 0.90,      -- 90% of usable terminal rows
      border = "rounded", -- "rounded" | "single" | "double" | "solid"
    },

    -- Customizable keymaps (accepts a string, a table of strings, or `false` to disable)
    keymaps = {
      -- Global editor keymaps
      preview = "<leader>mp",
      ascii = "<leader>ma",
      search = "<leader>ms",
      search_buffer = "<leader>mb",

      -- Interactive modal keymaps
      modal = {
        toggle_code = "<Tab>",
        pan_left = { "h", "<Left>" },
        pan_right = { "l", "<Right>" },
        pan_up = { "k", "<Up>" },
        pan_down = { "j", "<Down>" },
        zoom_in = { "+", "=" },
        zoom_out = "-",
        reset = "0",
        toggle_fit = "f",
        toggle_theme = "t",
        toggle_touchpad = "m",
        rerender = "r",
        help = "?",
        quit = { "q", "<Esc>" },
      },

      -- Telescope picker keymaps
      picker = {
        jump_to_source = "<C-g>",
        toggle_scope = "<C-f>",
      },
    },
  },
}
```

### Verifying Your Setup (`:checkhealth`)

```vim
:checkhealth mermaid_lens
```

![Checkhealth Output](assets/checkhealth.png)

---

## Commands & Interactive Controls

### User Commands

| Command                                   | Default Keymap | Description                                                              |
| :---------------------------------------- | :------------- | :----------------------------------------------------------------------- |
| `:MermaidLensPreview`                     | `<leader>mp`   | Render the Mermaid block under the cursor (or the current `.mmd` file).  |
| `:MermaidLensTelescope [project\|buffer]` | `<leader>ms`   | Open the Telescope diagram finder (workspace-wide by default).           |
| `:MermaidLensBuffer`                      | `<leader>mb`   | Open the Telescope diagram finder filtered to the **current file only**. |
| `:MermaidLensASCII`                       | `<leader>ma`   | ASCII rendering mode (_Coming soon_).                                    |

### Interactive Modal Controls

Diagrams open in **Full Overview (`1.0x`)** centered inside the modal. Press `<Tab>` at any time to toggle between **Preview Mode** (sandboxed canvas) and **Code / Edit Mode** (live Mermaid editor with an isolated per-diagram undo tree synced to your source `.md` or `.mmd` file and inline `vim.diagnostic` syntax checking).

#### Preview Mode

| Key / Gesture                  | Action                                                            |
| :----------------------------- | :---------------------------------------------------------------- |
| `<Tab>`                        | Switch to **Code / Edit Mode**                                    |
| `h` `j` `k` `l` / `Arrow Keys` | Pan camera across the diagram                                     |
| `Left Click + Drag`            | Freehand canvas pan (1:1 pixel tracking)                          |
| `+` / `=` / `-`                | Zoom in / Zoom out (anchored to viewport center)                  |
| `Mouse Wheel` / `Ctrl + Wheel` | Focal zoom in / out                                               |
| `f` / `Double Left Click`      | Toggle between **Full Overview (`1.0x`)** and **Smart Width Fit** |
| `0` / `Right Click`            | Reset camera to centered Full Overview (`1.0x`)                   |
| `t`                            | Toggle between **Light** and **Dark** theme in real time          |
| `m`                            | Toggle 2-finger Touchpad mode between **Zoom** and **2D Pan**     |
| `r`                            | Force manual re-render                                            |
| `?`                            | Open / close the keyboard options overlay                         |
| `q` / `<Esc>`                  | Close the modal and free GPU texture memory                       |

#### Code / Edit Mode

| Key / Command | Action                                                                                     |
| :------------ | :----------------------------------------------------------------------------------------- |
| `<Tab>`       | Return to **Preview Mode** (compiles only if the code was modified)                        |
| `:w`          | Save changes back to the parent `.md` block or `.mmd` file (and re-render if modified)     |
| `u` / `<C-r>` | Undo / Redo changes exclusively within this diagram's history                              |
| `?`           | Open / close the keyboard options overlay                                                  |
| `q` / `<Esc>` | Close the modal (`q` warns if there are unsaved modifications; `<Esc>` discards and quits) |

### Telescope Picker Controls

| Key            | Action                                                                                             |
| :------------- | :------------------------------------------------------------------------------------------------- |
| `<CR>` (Enter) | Compile and open the selected diagram in the interactive preview modal                             |
| `<C-g>`        | Open the source file and jump to the exact line where the diagram is defined                       |
| `<C-f>`        | Toggle live between **Workspace (`[Workspace]`)** and **Current File (`[Current File]`)** diagrams |

---

## Repository Structure

```text
lua/
├── mermaid_lens/
│   ├── init.lua              # Public facade, setup(), commands, and keymaps
│   ├── health.lua            # :checkhealth mermaid_lens diagnostics
│   ├── config/
│   │   ├── constants.lua     # System limits, defaults, keymap schemas, and ignore rules
│   │   └── themes.lua        # 10-color Light/Dark palettes and CSS generator
│   ├── editor/
│   │   └── sync.lua          # Safe fence relocation and live .md/.mmd write synchronization
│   ├── env/
│   │   ├── multiplexer.lua   # TMUX detection, pane offsets, and DCS passthrough
│   │   └── terminal.lua      # Kitty protocol detection and LuaJIT FFI ioctl metrics
│   ├── parser/
│   │   ├── detector.lua      # Diagram type classifier and name resolver
│   │   └── scanner.lua       # Buffer extractor and workspace scanner with ignore filters
│   ├── renderer/
│   │   ├── cache.lua         # Content-addressed cache paths and PNG IHDR reader
│   │   ├── compiler.lua      # Async mmdc pipeline and progress loader coordinator
│   │   ├── diagnostics.lua   # mmdc stderr parser and vim.diagnostic publisher
│   │   └── ascii.lua         # Stub for upcoming ASCII mode
│   ├── graphics/
│   │   ├── kitty.lua         # Atomic Kitty APC escape sequences (DECSC/DECRC + C=1)
│   │   └── viewport.lua      # 2D camera projection and corner-to-center clamping
│   └── ui/
│       ├── code_view.lua     # Isolated per-diagram editable buffer and BufWriteCmd hook
│       ├── input.lua         # Buffer key sandboxing and mouse/touchpad gestures
│       ├── loader.lua        # Centered percentage progress bar modal
│       ├── help.lua          # Dynamic keyboard options overlay (?)
│       ├── modal.lua         # Dual-mode interactive preview window and backdrop
│       └── picker.lua        # Telescope workspace and buffer finder
└── telescope/
    └── _extensions/
        └── mermaid_lens.lua  # Native Telescope extension bridge
```

---

## Contributing

Contributions follow the [Conventional Commits](https://www.conventionalcommits.org/) specification and [Semantic Versioning 2.0.0](https://semver.org/).

## License

MIT
