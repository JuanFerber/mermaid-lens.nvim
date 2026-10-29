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
	MAX_TEXT_SIZE = 1000000,
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
	touchpad_mode = "zoom",
	picker_scope = "project",
	ignored_dirs = {},
	fallback_to_code = true,
	auto_render_on_save = true,
	save_parent_on_write = true,
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
M.DIAGRAM_TYPES = {
	{ pattern = "^flowchart%s+", name = "flowchart" },
	{ pattern = "^flowchart$", name = "flowchart" },
	{ pattern = "^graph%s+", name = "flowchart" },
	{ pattern = "^graph$", name = "flowchart" },
	{ pattern = "^sequenceDiagram", name = "sequenceDiagram" },
	{ pattern = "^erDiagram", name = "erDiagram" },
	{ pattern = "^classDiagram", name = "classDiagram" },
	{ pattern = "^stateDiagram%-v2", name = "stateDiagram-v2" },
	{ pattern = "^stateDiagram", name = "stateDiagram" },
	{ pattern = "^C4Context", name = "C4Context" },
	{ pattern = "^C4Container", name = "C4Container" },
	{ pattern = "^C4Component", name = "C4Component" },
	{ pattern = "^C4Dynamic", name = "C4Dynamic" },
	{ pattern = "^C4Deployment", name = "C4Deployment" },
	{ pattern = "^gantt", name = "gantt" },
	{ pattern = "^pie", name = "pie" },
	{ pattern = "^gitGraph", name = "gitGraph" },
	{ pattern = "^mindmap", name = "mindmap" },
	{ pattern = "^timeline", name = "timeline" },
	{ pattern = "^journey", name = "journey" },
	{ pattern = "^quadrantChart", name = "quadrantChart" },
	{ pattern = "^requirementDiagram", name = "requirementDiagram" },
	{ pattern = "^sankey", name = "sankey" },
	{ pattern = "^xychart", name = "xychart" },
	{ pattern = "^block%-beta", name = "block" },
	{ pattern = "^packet%-beta", name = "packet" },
	{ pattern = "^architecture%-beta", name = "architecture" },
	{ pattern = "^kanban", name = "kanban" },
}

return M
