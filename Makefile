.PHONY: test

top:=$(dir $(realpath $(lastword $(MAKEFILE_LIST))))

test:
	cd $(top)/unit; lua test_cli_filter.lua

