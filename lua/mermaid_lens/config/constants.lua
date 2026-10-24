--- @module mermaid_lens.config.constants
--- Architectural Layer: Domain Constants
--- Parent: Consumed across `env`, `parser`, `renderer`, `graphics`, and `ui` layers.
--- Children: None (Leaf module).
--- Single Responsibility: Centralize immutable system limits, default user configuration,
--- Mermaid syntax patterns, and workspace filtering rules.

local M = {}

--- @class MermaidLensLimits
M.LIMITS = {
	OPENGL_MAX_TEXTURE_PX = 15500,
	FALLBACK_CELL_WIDTH_PX = 10,
	FALLBACK_CELL_HEIGHT_PX = 20,
	FALLBACK_SCREEN_WIDTH_PX = 1920,
	FALLBACK_SCREEN_HEIGHT_PX = 1080,
	MIN_ZOOM = 1.0,
	MAX_ZOOM = 24.0,
	ZOOM_STEP_IN = 1.20,
	ZOOM_STEP_OUT = 0.83,
	PAN_STEP_RATIO = 0.16,
	MIN_PAN_STEP_PX = 20,
}

--- @class MermaidLensUI
M.UI = {
	MODAL_MARGIN_COL_RATIO = 0.035,
	MODAL_MARGIN_ROW_RATIO = 0.040,
	BACKDROP_ZINDEX = 40,
	MODAL_ZINDEX = 50,
	HELP_ZINDEX = 60,
	LOADER_ZINDEX = 70,
	LOADER_WIDTH = 48,
	LOADER_HEIGHT = 5,
	LOADER_BAR_WIDTH = 28,
	LOADER_TICK_MS = 75,
	SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
}

--- @class MermaidLensDefaults
--- User-facing configuration schema merged during `require("mermaid_lens").setup(opts)`.
M.DEFAULT_CONFIG = {
	theme = "light", -- "light" | "dark"
	backdrop = true, -- Dim the editor background behind the preview modal
	backdrop_blend = 45, -- Backdrop transparency (0 = solid opaque, 100 = fully transparent)
	scale = 3, -- Chromium deviceScaleFactor (1..4) for high-DPI zoom clarity
	touchpad_mode = "zoom", -- Initial 2-finger touchpad behavior: "zoom" | "pan"
	modal = {
		width = 0.92, -- Modal width ratio relative to terminal columns (0.4..1.0)
		height = 0.90, -- Modal height ratio relative to usable terminal rows (0.4..1.0)
		border = "rounded", -- Floating window border style ("rounded" | "single" | "double" | "solid")
	},
	keymaps = { -- Set `keymaps = false` or individual keys to `false` to disable
		preview = "<leader>mp",
		ascii = "<leader>ma",
		search = "<leader>ms",
	},
}

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

M.IGNORED_DIRS = {
	[".git"] = true,
	["node_modules"] = true,
	["target"] = true,
	["dist"] = true,
	["build"] = true,
	[".next"] = true,
	[".nuxt"] = true,
	[".venv"] = true,
	["venv"] = true,
	["__pycache__"] = true,
	[".cache"] = true,
	["vendor"] = true,
}

return M
