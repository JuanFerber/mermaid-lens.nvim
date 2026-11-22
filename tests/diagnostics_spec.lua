local T = _G.TestHarness
local diagnostics = require("mermaid_lens.renderer.diagnostics")

T.test("diagnostics.parse_stderr strips ANSI escapes, skips stack frames, and extracts line and message", function()
	local raw = table.concat({
		"\27[31mError: Parse error on line 4:\27[0m",
		"    A ---> B",
		"Expecting 'SEMI', 'NEWLINE', got 'MINUS'",
		"    at Parser.parseError (/usr/lib/mermaid/parser.js:12:9)",
		"    at Object.render (/usr/lib/mermaid/index.js:44:3)",
	}, "\n")

	local parsed = diagnostics.parse_stderr(raw)

	T.assert_eq(parsed.line, 4)
	T.assert_true(parsed.message:find("Parse error on line 4", 1, true) ~= nil)
	T.assert_true(parsed.message:find("Expecting 'SEMI'", 1, true) ~= nil)
	T.assert_nil(parsed.message:find("at Parser.parseError", 1, true))
	T.assert_nil(parsed.raw:find("\27", 1, true))
end)

T.test("diagnostics.parse_stderr extracts colon line numbers and UnknownDiagramError", function()
	local raw = "UnknownDiagramError: No diagram type detected matching given configuration for text at input.mmd:7:1"

	local parsed = diagnostics.parse_stderr(raw)

	T.assert_eq(parsed.line, 7)
	T.assert_true(parsed.message:find("UnknownDiagramError", 1, true) ~= nil)
end)

T.test("diagnostics.parse_stderr falls back safely on empty or unstructured stderr", function()
	local empty = diagnostics.parse_stderr("")
	T.assert_eq(empty.line, 1)
	T.assert_eq(empty.message, "Mermaid syntax error")

	local plain = diagnostics.parse_stderr("Unexpected renderer crash")
	T.assert_eq(plain.line, 1)
	T.assert_eq(plain.message, "Unexpected renderer crash")
end)

T.test("diagnostics.publish clamps out-of-range lines and diagnostics.clear removes entries", function()
	T.with_temp_buffer({ "flowchart TD", "  A --> B" }, function(bufnr)
		diagnostics.publish(bufnr, {
			line = 99,
			message = "Syntax issue",
			raw = "Syntax issue",
		}, vim.diagnostic.severity.WARN)

		local items = vim.diagnostic.get(bufnr)
		T.assert_eq(#items, 1)
		T.assert_eq(items[1].lnum, 1) -- clamped to last valid 0-based line (line 2 -> index 1)
		T.assert_eq(items[1].severity, vim.diagnostic.severity.WARN)
		T.assert_eq(items[1].source, "mermaid-lens")

		diagnostics.clear(bufnr)
		T.assert_eq(#vim.diagnostic.get(bufnr), 0)
	end)
end)
