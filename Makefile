.PHONY: all check test-lua-unit clean

targets:=stage/cli_filter.lua

LUA?=lua

all:: $(targets)

# For lua plugins, just perform keyword expansion

stage/cli_filter.lua: lua-plugins/cli_filter.lua.in
	./scripts/keyword-expand $< > $@


# Testing

check: test-lua-unit

test-lua-unit: stage/cli_filter.lua
	cd test/lua-unit; $(LUA) test_lunit.lua && $(LUA) test_cli_filter.lua


# Cleanup

clean:
	rm -f $(targets)

