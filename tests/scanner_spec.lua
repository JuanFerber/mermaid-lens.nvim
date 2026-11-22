local T = _G.TestHarness
local scanner = require("mermaid_lens.parser.scanner")
local constants = require("mermaid_lens.config.constants")

T.test("scanner.get_buffer_diagrams parses tilde fences and never treats markdown as standalone file", function()
	local lines = {
		"pie is delicious in markdown prose.",
		"",
		"~~~mermaid tilde_flow",
		"flowchart LR",
		"  A --> B",
		"~~~",
	}

	T.with_temp_buffer(lines, function(bufnr)
		vim.api.nvim_buf_set_name(bufnr, "/tmp/scanner_tilde_test.md")
		vim.bo[bufnr].filetype = "markdown"

		local diagrams = scanner.get_buffer_diagrams(bufnr)

		T.assert_eq(#diagrams, 1)
		T.assert_eq(diagrams[1].kind, "block")
		T.assert_eq(diagrams[1].name, "tilde_flow")
		T.assert_eq(diagrams[1].diagram_type, "flowchart")
	end)
end)

T.test("scanner.get_buffer_diagrams numbers multiple unnamed diagrams of identical type", function()
	local lines = {
		"```mermaid",
		"flowchart TD",
		"  A --> B",
		"```",
		"```mermaid",
		"flowchart LR",
		"  C --> D",
		"```",
	}

	T.with_temp_buffer(lines, function(bufnr)
		vim.api.nvim_buf_set_name(bufnr, "/tmp/scanner_unnamed_test.md")

		local diagrams = scanner.get_buffer_diagrams(bufnr)

		T.assert_eq(#diagrams, 2)
		T.assert_eq(diagrams[1].name, "flowchart #1")
		T.assert_eq(diagrams[2].name, "flowchart #2")
	end)
end)

T.test("scanner.get_project_diagrams honors globs, hidden dir gitignore rules, and file size cap in fs_scandir fallback", function()
	local root = string.format("/tmp/mlens_scanner_spec_%d", vim.fn.getpid())
	vim.fn.delete(root, "rf")
	vim.fn.mkdir(root .. "/docs", "p")
	vim.fn.mkdir(root .. "/ignored_dir", "p")
	vim.fn.mkdir(root .. "/.hidden_dir", "p")

	local valid_doc = { "```mermaid ok_chart", "flowchart TD", "  A --> B", "```" }
	vim.fn.writefile(valid_doc, root .. "/docs/valid.md")
	vim.fn.writefile(valid_doc, root .. "/docs/old.bak.md")
	vim.fn.writefile(valid_doc, root .. "/ignored_dir/skip.md")
	vim.fn.writefile(valid_doc, root .. "/.hidden_dir/secret.md")

	-- Create an oversized Markdown file (> MAX_SCAN_FILE_BYTES) that must be skipped
	local huge_path = root .. "/docs/huge.md"
	local f = assert(io.open(huge_path, "wb"))
	f:write("```mermaid huge_chart\nflowchart TD\n  A --> B\n```\n")
	f:write(string.rep("x", constants.LIMITS.MAX_SCAN_FILE_BYTES + 1024))
	f:close()

	local orig_exec = vim.fn.executable
	local orig_cwd = vim.fn.getcwd()
	local ok, err = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(root))
		-- Force pure Lua fs_scandir fallback deterministically
		vim.fn.executable = function(bin)
			if bin == "rg" then
				return 0
			end
			return orig_exec(bin)
		end

		local found = scanner.get_project_diagrams({
			root = root,
			respect_gitignore = true,
			ignored_dirs = { "*.bak.md", "ignored_dir" },
		})

		T.assert_eq(#found, 1)
		T.assert_eq(found[1].name, "ok_chart")
		T.assert_eq(found[1].filename, "valid.md")
	end)

	vim.fn.executable = orig_exec
	vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end)

T.test("scanner.get_project_diagrams respects .gitignore with rg when enabled and includes ignored files when disabled", function()
	if vim.fn.executable("rg") ~= 1 then
		return
	end

	local root = string.format("/tmp/mlens_scanner_rg_%d", vim.fn.getpid())
	vim.fn.delete(root, "rf")
	vim.fn.mkdir(root .. "/.git", "p")
	vim.fn.writefile({ "ignored.md" }, root .. "/.gitignore")

	local valid_doc = { "```mermaid kept_chart", "flowchart TD", "  A --> B", "```" }
	local ignored_doc = { "```mermaid gitignored_chart", "flowchart TD", "  X --> Y", "```" }
	vim.fn.writefile(valid_doc, root .. "/kept.md")
	vim.fn.writefile(ignored_doc, root .. "/ignored.md")

	local orig_cwd = vim.fn.getcwd()
	local ok, err = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(root))

		local respected = scanner.get_project_diagrams({
			root = root,
			respect_gitignore = true,
		})
		T.assert_eq(#respected, 1)
		T.assert_eq(respected[1].name, "kept_chart")

		local included = scanner.get_project_diagrams({
			root = root,
			respect_gitignore = false,
		})
		T.assert_eq(#included, 2)
	end)

	vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end)
