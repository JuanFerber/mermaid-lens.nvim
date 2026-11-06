local T = _G.TestHarness
local terminal = require("mermaid_lens.env.terminal")

T.test("terminal.get_console_metrics returns positive non-zero dimensions", function()
	local metrics = terminal.get_console_metrics()
	T.assert_true(metrics.cell_w > 0, "cell_w must be > 0")
	T.assert_true(metrics.ui_cols > 0, "ui_cols must be > 0")
	T.assert_true(metrics.ui_rows > 0, "ui_rows must be > 0")
	T.assert_true(metrics.screen_px_w > 0, "screen_px_w must be > 0")
	T.assert_true(metrics.screen_px_h > 0, "screen_px_h must be > 0")
end)

local function with_mocked_env(env_vars, fn)
	local saved = {
		KITTY_WINDOW_ID = vim.env.KITTY_WINDOW_ID,
		TERM = vim.env.TERM,
		TERM_PROGRAM = vim.env.TERM_PROGRAM,
	}

	vim.env.KITTY_WINDOW_ID = env_vars.KITTY_WINDOW_ID
	vim.env.TERM = env_vars.TERM
	vim.env.TERM_PROGRAM = env_vars.TERM_PROGRAM

	local ok, err = pcall(fn)

	vim.env.KITTY_WINDOW_ID = saved.KITTY_WINDOW_ID
	vim.env.TERM = saved.TERM
	vim.env.TERM_PROGRAM = saved.TERM_PROGRAM

	if not ok then
		error(err, 0)
	end
end

T.test("terminal.supports_kitty_graphics detects supported terminals accurately", function()
	with_mocked_env({ KITTY_WINDOW_ID = "123", TERM = "xterm-256color", TERM_PROGRAM = "" }, function()
		T.assert_true(terminal.supports_kitty_graphics(), "should detect kitty via KITTY_WINDOW_ID")
	end)

	with_mocked_env({ KITTY_WINDOW_ID = nil, TERM = "xterm-ghostty", TERM_PROGRAM = "" }, function()
		T.assert_true(terminal.supports_kitty_graphics(), "should detect ghostty via TERM")
	end)

	with_mocked_env({ KITTY_WINDOW_ID = nil, TERM = "xterm-256color", TERM_PROGRAM = "WezTerm" }, function()
		T.assert_true(terminal.supports_kitty_graphics(), "should detect wezterm via TERM_PROGRAM")
	end)

	with_mocked_env({ KITTY_WINDOW_ID = nil, TERM = "dumb", TERM_PROGRAM = "Apple_Terminal" }, function()
		T.assert_false(terminal.supports_kitty_graphics(), "should return false for unsupported terminal")
	end)
end)
