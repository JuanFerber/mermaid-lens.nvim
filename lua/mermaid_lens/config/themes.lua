--- @module mermaid_lens.config.themes
--- Architectural Layer: Domain Service
--- Parent: `mermaid_lens.renderer.compiler`
--- Children: None (Leaf module).
--- Single Responsibility: Define Light and Dark color palettes and synthesize
--- Mermaid configuration variables and CSS rules for multi-diagram auto-coloring.

local M = {}

--- @class MermaidColorSwatch
--- @field border string Hex color for strokes and borders
--- @field header string Hex color for primary node/entity headers
--- @field odd string Hex color for odd table rows or secondary fills
--- @field even string Hex color for even table rows

--- @class MermaidThemePalette
--- @field bg string Canvas background hex color
--- @field text string Primary text hex color
--- @field line string Connector and relationship line hex color
--- @field label_bg string Edge label background hex color
--- @field cluster_bg string Subgraph/cluster background hex color
--- @field cluster_border string Subgraph/cluster border hex color
--- @field colors MermaidColorSwatch[] 10-color cyclic palette

--- Returns the color palette specification for the requested theme mode.
--- Relation to parent (`compiler`): Supplies background colors and cyclic node swatches
--- to build the headless Chromium render configuration.
--- @param theme "light"|"dark"
--- @return MermaidThemePalette
function M.get_palette(theme)
	if theme == "dark" then
		return {
			bg = "#1a1b26",
			text = "#e2e8f0",
			line = "#7aa2f7",
			label_bg = "#16161e",
			cluster_bg = "#1f2335",
			cluster_border = "#565f89",
			colors = {
				{ border = "#f7768e", header = "#3b1f2b", odd = "#2a1821", even = "#21131a" },
				{ border = "#7aa2f7", header = "#1e2b4a", odd = "#172138", even = "#131b2e" },
				{ border = "#bb9af7", header = "#2e2147", odd = "#231936", even = "#1c142b" },
				{ border = "#ff9e64", header = "#3d261a", odd = "#2e1d14", even = "#241710" },
				{ border = "#2ac3de", header = "#16333d", odd = "#12272f", even = "#0e1f26" },
				{ border = "#9ece6a", header = "#24361e", odd = "#1c2917", even = "#162112" },
				{ border = "#ff75a0", header = "#3b1d2e", odd = "#2c1623", even = "#23111c" },
				{ border = "#e0af68", header = "#382d1a", odd = "#2b2214", even = "#221b10" },
				{ border = "#7dcfff", header = "#183042", odd = "#132533", even = "#0f1c26" },
				{ border = "#73daca", header = "#173631", odd = "#122925", even = "#0e1f1c" },
			},
		}
	end

	return {
		bg = "#f8fafc",
		text = "#1e293b",
		line = "#475569",
		label_bg = "#f1f5f9",
		cluster_bg = "#f1f5f9",
		cluster_border = "#94a3b8",
		colors = {
			{ border = "#f43f5e", header = "#ffe4e6", odd = "#fff1f2", even = "#ffffff" },
			{ border = "#3b82f6", header = "#dbeafe", odd = "#eff6ff", even = "#ffffff" },
			{ border = "#a855f7", header = "#f3e8ff", odd = "#faf5ff", even = "#ffffff" },
			{ border = "#f97316", header = "#ffedd5", odd = "#fff7ed", even = "#ffffff" },
			{ border = "#06b6d4", header = "#cffafe", odd = "#ecfeff", even = "#ffffff" },
			{ border = "#10b981", header = "#d1fae5", odd = "#ecfdf5", even = "#ffffff" },
			{ border = "#ec4899", header = "#fce7f3", odd = "#fdf2f8", even = "#ffffff" },
			{ border = "#eab308", header = "#fef9c3", odd = "#fefce8", even = "#ffffff" },
			{ border = "#6366f1", header = "#e0e7ff", odd = "#eef2ff", even = "#ffffff" },
			{ border = "#84cc16", header = "#ecfccb", odd = "#f7fee7", even = "#ffffff" },
		},
	}
end

--- Builds Mermaid's `themeVariables` table for diagrams driven by internal scales
--- (Mindmap, Pie, GitGraph, Timeline, and Sequence notes/activations).
--- @param theme "light"|"dark"
--- @return table<string, string>
function M.build_theme_variables(theme)
	local p = M.get_palette(theme)
	local vars = {
		background = p.bg,
		primaryColor = p.colors[2].header,
		primaryBorderColor = p.colors[2].border,
		primaryTextColor = p.text,
		secondaryColor = p.colors[3].header,
		secondaryBorderColor = p.colors[3].border,
		tertiaryColor = p.colors[6].header,
		tertiaryBorderColor = p.colors[6].border,
		lineColor = p.line,
		textColor = p.text,
		mainBkg = p.colors[2].header,
		nodeBorder = p.colors[2].border,
		noteBkgColor = p.colors[8].header,
		noteBorderColor = p.colors[8].border,
		noteTextColor = p.text,
		activationBkgColor = p.colors[5].header,
		activationBorderColor = p.colors[5].border,
	}

	for i, c in ipairs(p.colors) do
		local idx = i - 1
		vars["cScale" .. idx] = c.header
		vars["cScalePeer" .. idx] = c.border
		vars["cScaleLabel" .. idx] = p.text
		vars["pie" .. i] = c.border
		vars["git" .. idx] = c.border
		vars["gitBranchLabel" .. idx] = p.text
	end

	return vars
end

--- Builds the CSS stylesheet injected into `mermaid-config.json` to automatically
--- colorize ER entities, Flowchart nodes, Sequence actors, State nodes, Class boxes, and C4 elements.
--- @param theme "light"|"dark"
--- @return string
function M.build_theme_css(theme)
	local p = M.get_palette(theme)
	local n = #p.colors

	local rules = {
		string.format(
			".edgePaths path, path.relationshipLine, .flowchart-link, .messageLine0, .messageLine1, g.edgePath path.path { stroke: %s !important; stroke-width: 1.8px !important; }",
			p.line
		),
		string.format(
			".edgeLabel, .relationshipLabelBox, .labelBkg { background-color: %s !important; fill: %s !important; color: %s !important; }",
			p.label_bg,
			p.label_bg,
			p.text
		),
		string.format(
			".nodeLabel, text.er, .messageText, .loopText, .noteText, .stateLabel text, .classText, .actor, tspan { color: %s !important; fill: %s !important; }",
			p.text,
			p.text
		),
		string.format(
			".cluster rect, .statediagram-cluster rect { fill: %s !important; stroke: %s !important; stroke-width: 1.5px !important; }",
			p.cluster_bg,
			p.cluster_border
		),
	}

	for i, c in ipairs(p.colors) do
		local nth = string.format("%dn+%d", n, i)
		local sel_node = string.format("g.nodes > g.node:nth-of-type(%s)", nth)
		local sel_er10 = string.format('svg > g > g[id^="entity-"]:nth-of-type(%s)', nth)
		local sel_state = string.format("g.statediagram-state:nth-of-type(%s)", nth)
		local sel_class = string.format("g.classGroup:nth-of-type(%s)", nth)
		local sel_actor_g = string.format("g:nth-of-type(%s) > rect.actor", nth)
		local sel_actor_r = string.format("rect.actor:nth-of-type(%s)", nth)
		local sel_c4 = string.format("g.person-man:nth-of-type(%s)", nth)

		table.insert(
			rules,
			string.format(
				[[
      %s > g.label-container > path:first-of-type,
      %s > rect:not([style*="fill"]),
      %s > polygon:not([style*="fill"]),
      %s > circle:not([style*="fill"]),
      %s > ellipse:not([style*="fill"]),
      %s rect.er.entityBox,
      %s rect.er.entityBox,
      %s rect.basic,
      %s rect,
      %s > rect:not([style*="fill"]) {
        fill: %s !important;
        stroke: %s !important;
        stroke-width: 1.8px !important;
      }

      %s .row-rect-odd path,
      %s .er.attributeBoxOdd,
      %s .er.attributeBoxOdd {
        fill: %s !important;
      }
      %s .row-rect-even path,
      %s .er.attributeBoxEven,
      %s .er.attributeBoxEven {
        fill: %s !important;
      }
      %s .border path,
      %s .divider path,
      %s .er.attributeBoxOdd,
      %s .er.attributeBoxEven,
      %s .er.attributeBoxOdd,
      %s .er.attributeBoxEven {
        stroke: %s !important;
        stroke-width: 1.2px !important;
      }

      %s,
      %s,
      g:nth-of-type(%s) > rect.note,
      rect.note:nth-of-type(%s) {
        fill: %s !important;
        stroke: %s !important;
        stroke-width: 1.8px !important;
      }

      g.clusters > g.cluster:nth-of-type(%s) > rect:not([style*="fill"]),
      .section%d,
      .task%d {
        fill: %s !important;
        stroke: %s !important;
      }
    ]],
				sel_node,
				sel_node,
				sel_node,
				sel_node,
				sel_node,
				sel_node,
				sel_er10,
				sel_state,
				sel_class,
				sel_c4,
				c.header,
				c.border,
				sel_node,
				sel_node,
				sel_er10,
				c.odd,
				sel_node,
				sel_node,
				sel_er10,
				c.even,
				sel_node,
				sel_node,
				sel_node,
				sel_node,
				sel_er10,
				sel_er10,
				c.border,
				sel_actor_g,
				sel_actor_r,
				nth,
				nth,
				c.header,
				c.border,
				nth,
				i - 1,
				i - 1,
				c.odd,
				c.border
			)
		)
	end

	return table.concat(rules, "\n")
end

return M
