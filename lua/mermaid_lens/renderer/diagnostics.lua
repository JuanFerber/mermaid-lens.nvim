--- @module mermaid_lens.renderer.diagnostics
--- Architectural Layer: Domain Logic / Diagnostics Adapter
--- Parent: `mermaid_lens.renderer.compiler` and `mermaid_lens.ui.code_view`
--- Children: None (Leaf module).
--- Single Responsibility: Parse Mermaid CLI (`mmdc`) syntax error output into
--- structured line/message pairs and publish native Neovim diagnostics.

local M = {}

local ns_id = vim.api.nvim_create_namespace("MermaidLensDiagnostics")

--- @class MermaidSyntaxError
--- @field line integer 1-based line number inside the Mermaid snippet
--- @field message string Clean, human-readable error description
--- @field raw string Full raw stderr output for reference

--- Parses raw `mmdc` stderr/stdout text to extract the offending line number and reason.
--- @param raw_output string
--- @return MermaidSyntaxError
function M.parse_stderr(raw_output)
	local clean = (raw_output or ""):gsub("\27%[[0-9;]*m", "")
	local detected_line = nil
	local summary_parts = {}

	for line in clean:gmatch("[^\r\n]+") do
		local trimmed = vim.trim(line)

		-- Ignore internal Node/Puppeteer stack trace frames
		if not trimmed:match("^at%s+") and trimmed ~= "" then
			if not detected_line then
				local lnum = trimmed:match("[Ll]ine%s+(%d+)") or trimmed:match(":(%d+):%d+")
				if lnum then
					detected_line = tonumber(lnum)
				end
			end

			if
				trimmed:match("[Pp]arse error")
				or trimmed:match("[Ll]exical error")
				or trimmed:match("[Ss]yntax error")
				or trimmed:match("^Expecting%s+")
				or trimmed:match("^Error:")
				or trimmed:match("^UnknownDiagramError")
			then
				local msg = trimmed:gsub("^Error:%s*", "")
				table.insert(summary_parts, msg)
			end
		end
	end

	local final_message = table.concat(summary_parts, " — ")
	if final_message == "" then
		final_message = clean:match("([^\r\n]+)") or "Mermaid syntax error"
	end

	return {
		line = math.max(1, detected_line or 1),
		message = final_message,
		raw = clean,
	}
end

--- Clears all active Mermaid diagnostics from `buf`.
--- @param buf integer
function M.clear(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.diagnostic.reset(ns_id, buf)
	end
end

--- Publishes a syntax error or fallback notice onto `buf` using `vim.diagnostic`.
--- @param buf integer
--- @param err MermaidSyntaxError
--- @param severity integer|nil Defaults to `vim.diagnostic.severity.ERROR`
function M.publish(buf, err, severity)
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not err then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_lnum = math.max(0, math.min(line_count - 1, (err.line or 1) - 1))

	vim.diagnostic.set(ns_id, buf, {
		{
			lnum = target_lnum,
			col = 0,
			severity = severity or vim.diagnostic.severity.ERROR,
			message = err.message,
			source = "mermaid-lens",
		},
	}, {
		virtual_text = {
			prefix = "■ ",
			spacing = 2,
		},
		signs = true,
		underline = true,
	})
end

return M
