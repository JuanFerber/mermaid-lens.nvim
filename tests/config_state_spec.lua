local T = _G.TestHarness
local config_state = require("mermaid_lens.config.state")
local constants = require("mermaid_lens.config.constants")

T.test("config.state defaults match constants.DEFAULT_CONFIG", function()
	local cfg = config_state.get()
	T.assert_eq(cfg.theme, constants.DEFAULT_CONFIG.theme)
	T.assert_eq(cfg.scale, constants.DEFAULT_CONFIG.scale)
	T.assert_eq(cfg.backdrop, constants.DEFAULT_CONFIG.backdrop)
end)

T.test("config.state deep merge overrides settings and preserves defaults", function()
	config_state.set({ theme = "dark", scale = 2, modal = { border = "single" } })
	local cfg = config_state.get()
	T.assert_eq(cfg.theme, "dark")
	T.assert_eq(cfg.scale, 2)
	T.assert_eq(cfg.modal.border, "single")
	T.assert_eq(cfg.modal.width, constants.DEFAULT_CONFIG.modal.width)

	-- Reset back to defaults for subsequent tests
	config_state.set(nil)
	local reset_cfg = config_state.get()
	T.assert_eq(reset_cfg.theme, constants.DEFAULT_CONFIG.theme)
end)
