--- @module mermaid_lens.parser.detector
--- Architectural Layer: Domain Logic
--- Parent: `mermaid_lens.parser.scanner` and `mermaid_lens.editor.sync`
--- Children: `mermaid_lens.config.constants`
--- Single Responsibility: Classify Mermaid diagram types, resolve explicit names,
--- and parse fenced Mermaid blocks from raw line arrays.

local constants = require("mermaid_lens.config.constants")

local M = {}

--- @class ParsedMermaidFence
--- @field open_lnum integer 1-based line number of opening backtick fence
--- @field close_lnum integer 1-based line number of closing backtick fence
--- @field explicit_name string|nil Explicit name from fence header or `%% name:` comment
--- @field diagram_type string Canonical Mermaid diagram type
--- @field code string Inner Mermaid source code

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

	local after_mermaid = clean_info:match("^mermaid%s+(.+)$")
	if after_mermaid then
		local explicit = vim.trim(after_mermaid):match("^([%w_%-%.]+)")
		if explicit and explicit ~= "" then
			return explicit, true
		end
	end

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

	if clean_info == "mermaid" then
		local comment_name = code:match("%%%%%s*name:%s*([%w_%-%.]+)")
		if comment_name and comment_name ~= "" then
			return comment_name, true
		end
		return nil, true
	end

	return nil, false
end

--- Scans an array of Markdown lines and returns all valid fenced Mermaid blocks in order.
--- Shared by both `scanner.lua` (indexing) and `editor/sync.lua` (fence relocation).
--- @param lines string[]
--- @return ParsedMermaidFence[]
function M.scan_fenced_blocks(lines)
	local blocks = {}
	local in_block = false
	local open_idx = 1
	local fence_char = "`"
	local fence_len = 3
	local info_str = ""
	local body = {}

	for idx, line in ipairs(lines) do
		if not in_block then
			local ticks, info_ticks = line:match("^%s*(```+)(.*)$")
			local tildes, info_tildes = line:match("^%s*(~~~+)(.*)$")
			if ticks then
				in_block = true
				fence_char = "`"
				fence_len = #ticks
				open_idx = idx
				info_str = info_ticks
				body = {}
			elseif tildes then
				in_block = true
				fence_char = "~"
				fence_len = #tildes
				open_idx = idx
				info_str = info_tildes
				body = {}
			end
		else
			local is_closing = false
			if fence_char == "`" then
				local close_ticks = line:match("^%s*(```+)%s*$")
				if close_ticks and #close_ticks >= fence_len then
					is_closing = true
				end
			elseif fence_char == "~" then
				local close_tildes = line:match("^%s*(~~~+)%s*$")
				if close_tildes and #close_tildes >= fence_len then
					is_closing = true
				end
			end

			if is_closing then
				local code = table.concat(body, "\n")
				if vim.trim(code) ~= "" then
					local explicit_name, is_mermaid = M.extract_explicit_name(info_str, code)
					local dtype = M.detect_diagram_type(code)
					if is_mermaid and dtype then
						table.insert(blocks, {
							open_lnum = open_idx,
							close_lnum = idx,
							explicit_name = explicit_name,
							diagram_type = dtype,
							code = code,
							fence_char = fence_char,
							fence_len = fence_len,
						})
					end
				end
				in_block = false
			else
				table.insert(body, line)
			end
		end
	end

	return blocks
end

return M
