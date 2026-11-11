CODECOMPANION_PATH ?= ../codecompanion.nvim
NVIM ?= nvim

.PHONY: test format

test:
	cd "$(CODECOMPANION_PATH)" && CODECOMPANION_INTERACTIVE_PATH="$(CURDIR)" LC_ALL=C $(NVIM) --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run_file(vim.fs.joinpath(vim.env.CODECOMPANION_INTERACTIVE_PATH, 'tests/test_interactive_command.lua'))"

format:
	stylua --column-width 120 --indent-type Spaces --indent-width 2 lua tests
