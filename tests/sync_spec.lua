local T = _G.TestHarness
local sync = require("mermaid_lens.editor.sync")

local test_id = 0
local function next_temp_path(prefix)
	test_id = test_id + 1
	return string.format("%s/%s_%d.md", vim.fn.getcwd(), prefix or "test_sync", test_id)
end

T.test("editor.sync.apply_changes updates in-memory buffer without corrupting host lines", function()
	local host_lines = {
		"# Document Header",
		"Paragraph before diagram.",
		"",
		"```mermaid my_chart",
		"flowchart TD",
		"  A --> B",
		"```",
		"",
		"Paragraph after diagram.",
		"Final line of document.",
	}

	T.with_temp_buffer(host_lines, function(bufnr)
		local fake_path = next_temp_path("host")
		vim.api.nvim_buf_set_name(bufnr, fake_path)

		local diagram = {
			kind = "block",
			filepath = fake_path,
			name = "my_chart",
			has_custom_name = true,
			diagram_type = "flowchart",
			code = "flowchart TD\n  A --> B",
			lnum = 4,
			end_lnum = 7,
		}

		local new_code_lines = {
			"flowchart TD",
			"  A --> B",
			"  B --> C",
			"  C --> D",
		}

		local ok, err = sync.apply_changes(diagram, new_code_lines, { write_to_disk = false })
		T.assert_true(ok, "apply_changes failed: " .. tostring(err))

		-- Verify diagram object metadata mutation
		T.assert_eq(diagram.lnum, 4)
		T.assert_eq(diagram.end_lnum, 9)
		T.assert_eq(diagram.code, table.concat(new_code_lines, "\n"))

		local result_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

		-- Verify lines above fence remain identical
		T.assert_eq(result_lines[1], "# Document Header")
		T.assert_eq(result_lines[2], "Paragraph before diagram.")
		T.assert_eq(result_lines[3], "")

		-- Verify opening fence
		T.assert_eq(result_lines[4], "```mermaid my_chart")

		-- Verify updated body
		T.assert_eq(result_lines[5], "flowchart TD")
		T.assert_eq(result_lines[6], "  A --> B")
		T.assert_eq(result_lines[7], "  B --> C")
		T.assert_eq(result_lines[8], "  C --> D")

		-- Verify closing fence
		T.assert_eq(result_lines[9], "```")

		-- Verify lines below fence remain identical
		T.assert_eq(result_lines[10], "")
		T.assert_eq(result_lines[11], "Paragraph after diagram.")
		T.assert_eq(result_lines[12], "Final line of document.")
	end)
end)

T.test("editor.sync.apply_changes relocates fence when lines above were shifted", function()
	local host_lines = {
		"# New inserted line 1",
		"# New inserted line 2",
		"# Document Header",
		"",
		"```mermaid my_relocated",
		"flowchart TD",
		"  X --> Y",
		"```",
		"Trailing text.",
	}

	T.with_temp_buffer(host_lines, function(bufnr)
		local fake_path = next_temp_path("reloc")
		vim.api.nvim_buf_set_name(bufnr, fake_path)

		local diagram = {
			kind = "block",
			filepath = fake_path,
			name = "my_relocated",
			has_custom_name = true,
			diagram_type = "flowchart",
			code = "flowchart TD\n  X --> Y",
			lnum = 3, -- stale
			end_lnum = 6, -- stale
		}

		local new_code_lines = {
			"flowchart TD",
			"  X --> Z",
		}

		local ok, err = sync.apply_changes(diagram, new_code_lines, { write_to_disk = false })
		T.assert_true(ok, "apply_changes relocation failed: " .. tostring(err))

		T.assert_eq(diagram.lnum, 5)
		T.assert_eq(diagram.end_lnum, 8)

		local result_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		T.assert_eq(result_lines[5], "```mermaid my_relocated")
		T.assert_eq(result_lines[6], "flowchart TD")
		T.assert_eq(result_lines[7], "  X --> Z")
		T.assert_eq(result_lines[8], "```")
		T.assert_eq(result_lines[9], "Trailing text.")
	end)
end)

T.test("editor.sync.apply_changes safely handles tilde fences", function()
	local host_lines = {
		"Intro text.",
		"~~~mermaid tilde_chart",
		"flowchart TD",
		"  Start --> End",
		"~~~",
		"Outro text.",
	}

	T.with_temp_buffer(host_lines, function(bufnr)
		local fake_path = next_temp_path("tilde")
		vim.api.nvim_buf_set_name(bufnr, fake_path)

		local diagram = {
			kind = "block",
			filepath = fake_path,
			name = "tilde_chart",
			has_custom_name = true,
			diagram_type = "flowchart",
			code = "flowchart TD\n  Start --> End",
			lnum = 2,
			end_lnum = 5,
		}

		local new_code = { "flowchart TD", "  Start --> Step1", "  Step1 --> End" }
		local ok, err = sync.apply_changes(diagram, new_code, { write_to_disk = false })
		T.assert_true(ok, "tilde sync failed: " .. tostring(err))

		local res = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		T.assert_eq(res[1], "Intro text.")
		T.assert_eq(res[2], "~~~mermaid tilde_chart")
		T.assert_eq(res[3], "flowchart TD")
		T.assert_eq(res[4], "  Start --> Step1")
		T.assert_eq(res[5], "  Step1 --> End")
		T.assert_eq(res[6], "~~~")
		T.assert_eq(res[7], "Outro text.")
	end)
end)

T.test("editor.sync.apply_changes handles standalone diagram file kind", function()
	local initial_lines = {
		"sequenceDiagram",
		"  Alice->>Bob: Hello",
	}

	T.with_temp_buffer(initial_lines, function(bufnr)
		local fake_path = string.format("%s/diagram_%d.mmd", vim.fn.getcwd(), test_id)
		vim.api.nvim_buf_set_name(bufnr, fake_path)

		local diagram = {
			kind = "file",
			filepath = fake_path,
			name = "diagram",
			diagram_type = "sequenceDiagram",
			code = table.concat(initial_lines, "\n"),
			lnum = 1,
			end_lnum = 2,
		}

		local new_code = {
			"sequenceDiagram",
			"  Alice->>Bob: Hello",
			"  Bob-->>Alice: Hi",
		}

		local ok, err = sync.apply_changes(diagram, new_code, { write_to_disk = false })
		T.assert_true(ok, "file kind sync failed: " .. tostring(err))

		T.assert_eq(diagram.lnum, 1)
		T.assert_eq(diagram.end_lnum, 3)
		T.assert_eq(diagram.code, table.concat(new_code, "\n"))

		local res = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		T.assert_eq(#res, 3)
		T.assert_eq(res[3], "  Bob-->>Alice: Hi")
	end)
end)

T.test("editor.sync.apply_changes rejects unlocatable fences without altering buffer", function()
	local host_lines = {
		"Line 1",
		"Line 2",
	}

	T.with_temp_buffer(host_lines, function(bufnr)
		local fake_path = next_temp_path("unloc")
		vim.api.nvim_buf_set_name(bufnr, fake_path)

		local diagram = {
			kind = "block",
			filepath = fake_path,
			name = "ghost",
			has_custom_name = true,
			diagram_type = "flowchart",
			code = "flowchart TD\n  A --> B",
			lnum = 99,
			end_lnum = 105,
		}

		local ok, err = sync.apply_changes(diagram, { "new code" }, { write_to_disk = false })
		T.assert_false(ok)
		T.assert_true(err ~= nil)

		local res = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		T.assert_eq(#res, 2)
		T.assert_eq(res[1], "Line 1")
		T.assert_eq(res[2], "Line 2")
	end)
end)
