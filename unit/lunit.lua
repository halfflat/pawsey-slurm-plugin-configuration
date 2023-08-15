-- Simple unit test runner

-- Simple usage:
--      lunit = require('lunit')
--      a_test_suite = ...
--      pass = lunit.run_tests(a_test_suite)
--      os.exit(pass)

local function is_callable(x)
    local mt = getmetatable(x)
    return mt and type(mt.__call) == 'function'
end

function make_default_reporter()
    local n_test = 0
    local n_pass = 0
    return function (test_name, pass, fail_msg)
	if test_name then
	    print(('%s: %s%s%s'):format(test_name, pass and 'pass' or 'fail', pass and '' or ': ', fail_msg or ''))
	    n_test = n_test + 1
	    if pass then n_pass = n_pass + 1 end
	else
	    -- no more tests in suite
	    print(('passed %d/%d'):format(n_pass, n_test))
	    return n_pass == n_test
	end
    end
end

local function run_tests_through(reporter, suite, matching, excluding)
    -- reporter is a callable which signature
    --     reporter(test_name: string, success: boolean, fail_msg: string)
    -- When reporter is called with no arguments it signifies the end of the
    -- test suite. If all tests passed, it should return true, else false.
    --
    -- suite is a table with test functions. All functions in the table with a
    -- key that matches the string parameter matching (if not nil) and which
    -- don't match the string parameter excluding (if not nil) are invoked.

    local base_env = is_callable(suite) and suite() or _ENV

    for name, fn in pairs(suite) do
	if  type(fn) == 'function' and
            (not matching or string.find(name, matching)) and
	    (not excluding or not string.find(name, excluding))
	then
	    local pass, msg = pcall(fn)
	    if pass then msg = '' end
	    reporter(tostring(name), pass, msg)
	end
    end

    return reporter() -- call with nil arguments to indicate end of suite
end

local function run_tests(suite, matching, excluding)
    return run_tests_through(make_default_reporter(), suite, matching, excluding)
end

return {
    make_default_reporter = make_default_reporter,
    run_tests_through = run_tests_through,
    run_tests = run_tests
}

