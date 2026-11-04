-- Minimal zero-dependency headless test runner for mermaid-lens.nvim
local script_src = debug.getinfo(1, "S").source
local script_file = script_src:sub(1, 1) == "@" and script_src:sub(2) or script_src
local script_dir = vim.fs.dirname(vim.fn.fnamemodify(script_file, ":p"))
local repo_root = vim.fs.dirname(script_dir)
vim.opt.runtimepath:prepend(repo_root)

local passed = 0
local failed = 0
local errors = {}

local M = {}

function M.assert_eq(actual, expected, msg)
	local is_equal = (actual == expected)
	if not is_equal and type(actual) == "table" and type(expected) == "table" then
		is_equal = vim.deep_equal(actual, expected)
	end
	if not is_equal then
		error(string.format("%s\nExpected: %s\nActual:   %s", msg or "Assertion failed", vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

function M.assert_true(val, msg)
	if val ~= true then
		error(msg or ("Expected true, got " .. tostring(val)), 2)
	end
end

function M.assert_false(val, msg)
	if val ~= false then
		error(msg or ("Expected false, got " .. tostring(val)), 2)
	end
end

function M.assert_nil(val, msg)
	if val ~= nil then
		error(msg or ("Expected nil, got " .. tostring(val)), 2)
	end
end

function M.with_temp_buffer(lines, fn)
	local bufnr = vim.api.nvim_create_buf(false, true)
	if lines then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	end
	local ok, err = pcall(fn, bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
	if not ok then
		error(err, 0)
	end
end

function M.test(name, fn)
	local ok, err = pcall(fn, M)
	if ok then
		passed = passed + 1
		io.stdout:write("  [PASS] " .. name .. "\n")
	else
		failed = failed + 1
		table.insert(errors, { name = name, err = err })
		io.stdout:write("  [FAIL] " .. name .. "\n")
	end
end

_G.TestHarness = M

local test_files = {
	"tests/config_state_spec.lua",
	"tests/detector_spec.lua",
	"tests/sync_spec.lua",
	"tests/terminal_spec.lua",
	"tests/ui_spec.lua",
	"tests/modal_spec.lua",
}

print("Running test suite for mermaid-lens.nvim...\n")

for _, file in ipairs(test_files) do
	local fpath = repo_root .. "/" .. file
	if vim.fn.filereadable(fpath) ~= 1 then
		failed = failed + 1
		table.insert(errors, { name = file, err = "Spec file not found: " .. fpath })
		io.stdout:write("  [FAIL] Missing spec file: " .. file .. "\n")
	else
		print("File: " .. file)
		local ok_load, err_load = pcall(dofile, fpath)
		if not ok_load then
			failed = failed + 1
			table.insert(errors, { name = file, err = "Error executing spec file:\n" .. tostring(err_load) })
			io.stdout:write("  [FAIL] " .. file .. " (execution failed)\n")
		end
	end
end

print(string.format("\nResults: %d passed, %d failed", passed, failed))

if (passed + failed) == 0 then
	print("\nERROR: No tests were executed!")
	vim.cmd("cquit 1")
elseif failed > 0 then
	print("\nFailures:")
	for _, f in ipairs(errors) do
		print("\n--- " .. f.name .. " ---")
		print(f.err)
	end
	vim.cmd("cquit 1")
else
	vim.cmd("qall!")
end
