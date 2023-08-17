--[[
# Simple unit test runner

Run a 'suite' of test functions, capturing and counting failures raised by `error`.

Simple demo:
```
    lunit = require('lunit')
    suite = {
        test_three_is_three = function () assert(3==3) end,
        test_four_is_five = function () assert(4==5) end,
    }
    if not lunit.run_tests(suite) then os.exit(1) end
```

## Terminology

* A _suite_ is a table containing zero or more functions, indexed by a test name.
* A _matching pattern_ selects all functions in a suite whose name match the pattern.
* An _excluding pattern_ omits all functions in a suite whose name match the pattern.
* A _reporter_ is a callable that performs two roles:
  * When called with a test name, pass/fail result, and optionally a fail message it
    processes the result, for example to pretty-print the test result and update statistics.
  * When called with no arguments at the end of a series of tests from a test suite,
    it performs any summary actions and returns a summary status, true or false indicating
    an overall pass or fail of the suite.

## Test running Functions

### run_tests_through(reporter, suite, matching, excluding)

The tests comprise all the functions in the table _suite_ with a key that matches the pattern _matching_
and that does not match the pattern _excluding_. If _matching_ is nil, accept every key;
if _excluding_ is nil, exclude no key.

Each test function is called with `pcall`; the test is considered to have passed if it does
not raise an error. For each test function, _reporter_ is called with the corresponding key,
pass result (true or false), and any error message.

When all tests are completed, the function calls _reporter_ with no arguments and returns the result.

### run_tests(suite, matching, exlcuding)

Calls run_tests_through with a reporter constructed by make_simple_reporter().

### make_simple_reporter()

Returns a reporter that:
* Prints a message to stdout with the test name, pass/fail result and any error message for each test.
* Accumulates a tally of tests run and passed.
* When invoked with no arguments, prints the pass tally to stdout and returns true only if all tests passed.

## Extra tests and assertions

### test_eq(a, b)

If a and b are not both tables, return a==b. Otherwise return true iff a and b have the same
key-set and test_eq(a[k], b[k]) is true for each key k.

### test_eq_v(expected, value)

Returns two values: the result of test_eq(expected, value); and a message describing the failure
if test_eq returned false. Can be used directly in an assert().

## Utility functions

### clone_function(f)

Returns a new function with the same definition and up-values as the supplied function f.

### mock_function(f, mocked_globals, mocked_upvalues)

Returns a clone of the function f with modified environment and upvalues.

If mocked_globals is not nil, create a new environment for the clone which is a shallow copy of
mocked_globals and which derives from the environment of f. Any function-value upvalues of f
are recursively replaced with clones whose environments are similarly modified.

If mocked_upvalues is not nil, replace any upvalue in the cloned function with a name that equals
a key in the mocked_upvalue with the corresponding value.

]]--

local function is_callable(x)
    local mt = getmetatable(x)
    return mt and type(mt.__call) == 'function'
end

local function make_simple_reporter()
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

    for name, fn in pairs(suite) do
        if type(fn) == 'function' and
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
    return run_tests_through(make_simple_reporter(), suite, matching, excluding)
end

-- Test functions

local function test_eq(a, b, _visited)
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end

    local check = tostring(a)..tostring(b)

    if not _visited then _visited = { check = true }
    elseif _visited[check] then return true
    else _visited[check] = true
    end

    for k, v in pairs(a) do
        local bv = b[k]
        if bv == nil or not test_eq(v, bv, _visited) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function test_eq_v(expected, value)
    local function repn(x)
        local is_scalar = { number = true, string = true, ['nil'] = true, boolean = true }
        return is_scalar[type(x)] and tostring(x) or type(x)
    end

    local eq = test_eq(expected, value)
    return eq, eq or 'expected '..repn(expected)..' not equal to '..repn(value)
end

-- Mocking utilities

local function clone_function(fn)
    local new_fn = loadstring(string.dump(fn))
    local i = 1
    while debug.getupvalue(fn, i) do
        debug.upvaluejoin(new_fn, i, fn, i)
        i = i + 1
    end
    return new_fn
end

local function new_context(value) local z = value or {} return function () return z end end

-- if recurse is truthy, recursively mock functional upvalues of mocked f with modified global environment
local function mock_function_env(f, mocked_globals, recurse)
    -- return upvalue index and value of _ENV in function h, or nil if not present
    local function find_env(h)
        local i = 1
        while true do
            local up_name, up_value = debug.getupvalue(h, i)
            if not up_name then return nil
            elseif up_name == '_ENV' then return i, up_value
            end
            i = i + 1
        end
    end

    local function make_mocked_env(env)
        local menv = {}
        for k, v in pairs(mocked_globals) do menv[k] = v end
        setmetatable(menv, { __index = env })
        return menv
    end

    if not recurse then
        local g = clone_function(f)
        local i_ENV, g_ENV = find_env(g)
        if i_ENV then
            debug.upvaluejoin(g, i_ENV, new_context(make_mocked_env(g_ENV)), 1)
        end
        return g
    else
        -- maintain map of modified environments: f and its functional upvalue descendants may
        -- not have the same _ENV.

        local function recursive_impl(f, menv_map, visited)
            if visited[f] then return visited[f] end
            local g = clone_function(f)
            visited[f] = g

            i_ENV, g_ENV = find_env(g)
            if i_ENV then
                local menv = menv_map[g_ENV]
                if not menv then
                    menv = make_mocked_env(g_ENV)
                    menv_map[g_ENV] = menv
                end
                debug.upvaluejoin(g, i_ENV, new_context(menv), 1)
            end

            -- update any function-valued upvalues recursively
            local i = 1
            while true do
                local up_name, up_value = debug.getupvalue(g, i)
                if not up_name then break end

                if type(up_value) == 'function' then
                    debug.upvaluejoin(g, i, new_context(recursive_impl(up_value, menv_map, visited)), 1)
                end
                i = i + 1
            end
            return g
        end

        return recursive_impl(f, {}, {})
    end
end

-- if recurse is truthy, recursively mock functional upvalues of mocked f with new upvalues.
local function mock_function_upvalues(f, mocked_upvalues, recurse)
    if not recurse then
        local g = clone_function(f)
        local i = 1
        while true do
            local up_name, _ = debug.getupvalue(g, i)
            if not up_name then break end

            if mocked_upvalues and mocked_upvalues[up_name] ~= nil then
                debug.upvaluejoin(g, i, new_context(mocked_upvalues[up_name]), 1)
            end
            i = i + 1
        end
        return g
    else
        local function recursive_impl(f, visited)
            if visited[f] then return visited[f] end
            local g = clone_function(f)
            visited[f] = g

            -- update any function-valued upvalues recursively
            local i = 1
            while true do
                local up_name, up_value = debug.getupvalue(g, i)
                if not up_name then break end

                if mocked_upvalues and mocked_upvalues[up_name] ~= nil then
                    debug.upvaluejoin(g, i, new_context(mocked_upvalues[up_name]), 1)
                elseif type(up_value) == 'function' then
                    debug.upvaluejoin(g, i, new_context(recursive_impl(up_value, visited)), 1)
                end
                i = i + 1
            end
            return g
        end

        return recursive_impl(f, {})
    end
end

-- Return exports

return {
    make_simple_reporter = make_simple_reporter,
    run_tests_through = run_tests_through,
    run_tests = run_tests,
    test_eq = test_eq,
    test_eq_v = test_eq_v,
    clone_function = clone_function,
    mock_function_env = mock_function_env,
    mock_function_upvalues = mock_function_upvalues
}
