local T = _G.TestHarness
local modal = require("mermaid_lens.ui.modal")

T.test("ui.modal closes backdrop cleanly when :quit is executed", function()
	local base_wins = #vim.api.nvim_list_wins()

	local artifact = {
		mode = "code",
		code = "flowchart TD\n  A --> B",
		filepath = vim.fn.getcwd() .. "/test_modal.md",
		name = "test_modal",
		lnum = 1,
	}

	modal.open(artifact)
	local open_wins = #vim.api.nvim_list_wins()
	-- Should have opened backdrop_win and modal_win on top of base_wins
	T.assert_eq(open_wins, base_wins + 2)

	-- Execute native :quit
	vim.cmd("quit")

	-- After :quit, modal and backdrop should be completely closed
	local after_wins = #vim.api.nvim_list_wins()
	T.assert_eq(after_wins, base_wins)
end)

T.test("ui.modal closes backdrop cleanly when :quit! is executed", function()
	local base_wins = #vim.api.nvim_list_wins()

	local artifact = {
		mode = "code",
		code = "sequenceDiagram\n  Alice->>Bob: Hi",
		filepath = vim.fn.getcwd() .. "/test_modal_force.md",
		name = "test_modal_force",
		lnum = 1,
	}

	modal.open(artifact)
	local open_wins = #vim.api.nvim_list_wins()
	T.assert_eq(open_wins, base_wins + 2)

	-- Execute native force quit :quit!
	vim.cmd("quit!")

	local after_wins = #vim.api.nvim_list_wins()
	T.assert_eq(after_wins, base_wins)
end)

T.test("ui.input.lock_buffer_keys does not block colon character", function()
	local input = require("mermaid_lens.ui.input")
	local buf = vim.api.nvim_create_buf(false, true)
	input.lock_buffer_keys(buf)

	local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
	local colon_mapped = false
	for _, km in ipairs(keymaps) do
		if km.lhs == ":" then
			colon_mapped = true
		end
	end
	T.assert_false(colon_mapped, "colon must not be mapped in buffer so Ex command-line mode works")
	vim.api.nvim_buf_delete(buf, { force = true })
end)
