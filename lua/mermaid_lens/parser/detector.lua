--- @module mermaid_lens.parser.detector
--- Architectural Layer: Domain Logic
--- Parent: `mermaid_lens.parser.scanner`
--- Children: `mermaid_lens.config.constants`
--- Single Responsibility: Classify Mermaid diagram types from raw source text
--- and resolve explicit or auto-numbered diagram identifiers.

local constants = require("mermaid_lens.config.constants")

local M = {}

--- Inspects Mermaid source code (skipping YAML frontmatter and `%%` comments)
--- and returns the canonical diagram type name if valid.
--- @param code string Raw block or file content
--- @return string|nil diagram_type
function M.detect_diagram_type(code)
	local in_frontmatter = false
	local first_line_checked = false

	for line in (code or ""):gmatch("[^\r\n]+") do
		local trimmed = vim.trim(line)
		if not first_line_checked and trimmed == "---" then
			in_frontmatter = true
			first_line_checked = true
		elseif in_frontmatter then
			if trimmed == "---" then
				in_frontmatter = false
			end
		elseif trimmed ~= "" and not trimmed:match("^%%%%") then
			first_line_checked = true
			for _, dt in ipairs(constants.DIAGRAM_TYPES) do
				if trimmed:match(dt.pattern) then
					return dt.name
				end
			end
			return nil
		end
	end

	return nil
end

--- Extracts an explicit diagram name from a Markdown fence info string (` ```mermaid <name> `)
--- or an internal `%% name: <name>` directive.
--- @param info_str string Text following the opening triple backticks
--- @param code string Inner body of the fenced block
--- @return string|nil explicit_name, boolean is_mermaid_block
function M.extract_explicit_name(info_str, code)
	local clean_info = vim.trim(info_str or "")

	-- Case 1: Standard ` ```mermaid <name> `
	local after_mermaid = clean_info:match("^mermaid%s+(.+)$")
	if after_mermaid then
		local explicit = vim.trim(after_mermaid):match("^([%w_%-%.]+)")
		if explicit and explicit ~= "" then
			return explicit, true
		end
	end

	-- Case 2: Custom ` ```<name> ` where body starts with a valid Mermaid keyword
	if clean_info ~= "" and clean_info ~= "mermaid" then
		if M.detect_diagram_type(code) then
			local explicit = clean_info:match("^([%w_%-%.]+)")
			if explicit and explicit ~= "" then
				return explicit, true
			end
		else
			return nil, false
		end
	end

	-- Case 3: Plain ` ```mermaid ` with optional `%% name: <name>` inside body
	if clean_info == "mermaid" then
		local comment_name = code:match("%%%%%s*name:%s*([%w_%-%.]+)")
		if comment_name and comment_name ~= "" then
			return comment_name, true
		end
		return nil, true
	end

	return nil, false
end

return M
