--- @module mermaid_lens.config.constants
--- Architectural Layer: Domain Constants
--- Parent: Consumed across `config`, `env`, `parser`, `renderer`, `graphics`, and `ui` layers.
--- Children: None (Leaf module).
--- Single Responsibility: Centralize immutable system limits, compiler thresholds, UI dimensions,
--- default user configuration, customizable keymap schemas, and Mermaid syntax patterns.

local M = {}

--- @class MermaidLensLimits
M.LIMITS = {
	FALLBACK_CELL_WIDTH_PX = 10,
	FALLBACK_CELL_HEIGHT_PX = 20,
	MIN_ZOOM = 1.0,
	MAX_ZOOM = 24.0,
	SMART_ZOOM_MAX = 12.0,
	SMART_ZOOM_TRIGGER_RATIO = 0.55,
	SMART_ZOOM_TARGET_RATIO = 0.82,
	DEFAULT_FIT_ZOOM = 2.0,
	ZOOM_STEP_IN = 1.20,
	ZOOM_STEP_OUT = 0.83,
	PAN_STEP_RATIO = 0.16,
	MIN_PAN_STEP_PX = 20,
	MODAL_MIN_W_RATIO = 0.40,
	MODAL_MAX_W_RATIO = 0.98,
	MODAL_MIN_H_RATIO = 0.40,
	MODAL_MAX_H_RATIO = 0.96,
}

--- @class MermaidLensCompilerConstants
M.COMPILER = {
	MIN_VIEWPORT_WIDTH_PX = 1280,
	MIN_VIEWPORT_HEIGHT_PX = 720,
	MIN_SCALE = 1,
	MAX_SCALE = 4,
	DEFAULT_SCALE = 3,
	MAX_TEXT_SIZE = 200000,
	MMDC_TIMEOUT_MS = 20000,
}

--- @class MermaidLensUI
M.UI = {
	BACKDROP_ZINDEX = 40,
	MODAL_ZINDEX = 50,
	HELP_ZINDEX = 60,
	LOADER_ZINDEX = 70,
	HELP_WIDTH = 54,
	LOADER_WIDTH = 48,
	LOADER_HEIGHT = 5,
	LOADER_BAR_WIDTH = 28,
	LOADER_TICK_MS = 75,
	LOADER_CLOSE_DELAY_MS = 60,
	PICKER_WIDTH_RATIO = 0.94,
	PICKER_HEIGHT_RATIO = 0.88,
	PICKER_PREVIEW_RATIO = 0.40,
	SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
}

--- Supported file extensions for workspace scanning and buffer detection.
M.SUPPORTED_EXTENSIONS = {
	md = true,
	markdown = true,
	mdx = true,
	mmd = true,
	mermaid = true,
}

--- Ordered list of file globs passed to `rg --files`.
M.RG_FILE_GLOBS = {
	"*.md",
	"*.markdown",
	"*.mdx",
	"*.mmd",
	"*.mermaid",
}

--- Default directories always excluded during workspace scanning.
M.IGNORED_DIRS = {
	".git",
	"node_modules",
	"target",
	"dist",
	"build",
	".next",
	".nuxt",
	".venv",
	"venv",
	"__pycache__",
	".cache",
	"vendor",
}

--- @class MermaidLensDefaults
M.DEFAULT_CONFIG = {
	theme = "light",
	backdrop = true,
	backdrop_blend = 45,
	scale = 3,
	max_text_size = 200000,
	touchpad_mode = "zoom",
	picker_scope = "project",
	ignored_dirs = {},
	fallback_to_code = true,
	auto_render_on_save = true,
	save_parent_on_write = true,
	tmux_auto_configure = true,
	modal = {
		width = 0.92,
		height = 0.90,
		border = "rounded",
	},
	keymaps = {
		preview = "<leader>mp",
		ascii = "<leader>ma",
		search = "<leader>ms",
		search_buffer = "<leader>mb",

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
			ascii = "a",
			help = "?",
			quit = { "q", "<Esc>" },
		},

		picker = {
			jump_to_source = "<C-g>",
			toggle_scope = "<C-f>",
		},
	},
}

--- Ordered table of Mermaid diagram header patterns and their canonical type names.
--- Each keyword requires a word boundary (`%f[%s;:%z]`) to prevent false positives on identifiers like `piece`.
M.DIAGRAM_TYPES = {
	{ pattern = "^flowchart%f[%s;:%z]", name = "flowchart" },
	{ pattern = "^graph%f[%s;:%z]", name = "flowchart" },
	{ pattern = "^sequenceDiagram%f[%s;:%z]", name = "sequenceDiagram" },
	{ pattern = "^erDiagram%f[%s;:%z]", name = "erDiagram" },
	{ pattern = "^classDiagram%f[%s;:%z]", name = "classDiagram" },
	{ pattern = "^stateDiagram%-v2%f[%s;:%z]", name = "stateDiagram-v2" },
	{ pattern = "^stateDiagram%f[%s;:%z]", name = "stateDiagram" },
	{ pattern = "^C4Context%f[%s;:%z]", name = "C4Context" },
	{ pattern = "^C4Container%f[%s;:%z]", name = "C4Container" },
	{ pattern = "^C4Component%f[%s;:%z]", name = "C4Component" },
	{ pattern = "^C4Dynamic%f[%s;:%z]", name = "C4Dynamic" },
	{ pattern = "^C4Deployment%f[%s;:%z]", name = "C4Deployment" },
	{ pattern = "^gantt%f[%s;:%z]", name = "gantt" },
	{ pattern = "^pie%f[%s;:%z]", name = "pie" },
	{ pattern = "^gitGraph%f[%s;:%z]", name = "gitGraph" },
	{ pattern = "^mindmap%f[%s;:%z]", name = "mindmap" },
	{ pattern = "^timeline%f[%s;:%z]", name = "timeline" },
	{ pattern = "^journey%f[%s;:%z]", name = "journey" },
	{ pattern = "^quadrantChart%f[%s;:%z]", name = "quadrantChart" },
	{ pattern = "^requirementDiagram%f[%s;:%z]", name = "requirementDiagram" },
	{ pattern = "^sankey%-beta%f[%s;:%z]", name = "sankey" },
	{ pattern = "^sankey%f[%s;:%z]", name = "sankey" },
	{ pattern = "^xychart%-beta%f[%s;:%z]", name = "xychart" },
	{ pattern = "^xychart%f[%s;:%z]", name = "xychart" },
	{ pattern = "^block%-beta%f[%s;:%z]", name = "block" },
	{ pattern = "^packet%-beta%f[%s;:%z]", name = "packet" },
	{ pattern = "^architecture%-beta%f[%s;:%z]", name = "architecture" },
	{ pattern = "^kanban%f[%s;:%z]", name = "kanban" },
}

return M
