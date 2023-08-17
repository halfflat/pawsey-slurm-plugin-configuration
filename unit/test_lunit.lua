lunit = require('lunit')

local T = {}
local test_eq = lunit.test_eq
local test_eq_v = lunit.test_eq_v
local run_tests_through = lunit.run_tests_through
local run_tests = lunit.run_tests

function T.test_run_tests_filters()
    local test_set = {}
    local function log_test(name)
        if name == nil then return end
        test_set[name] = true
    end
    local function value_set(tbl)
        set = {}
        for _, v in pairs(tbl) do set[v] = true end
        return set
    end

    local nop = function () end
    local suite = { a1 = nop, a2 = nop, b1 = nop, b2 = nop, x1 = 3, x2 = false, x3 = 'str' }

    -- only function values in the suite should be considered
    test_set = {}
    run_tests_through(log_test, suite)
    assert(test_eq(value_set({'a1','a2','b1','b2'}), test_set))

    -- test matching filter
    test_set = {}
    run_tests_through(log_test, suite, '^b')
    assert(test_eq(value_set({'b1','b2'}), test_set))

    -- test excluding filter
    test_set = {}
    run_tests_through(log_test, suite, '2$')
    assert(test_eq(value_set({'a2','b2'}), test_set))
end

function T.test_test_eq()
    -- non-table equality

    assert(test_eq(0, 0))
    assert(not test_eq(1, 0))
    assert(test_eq('', ''))

    assert(test_eq('fish', 'fish'))
    assert(not test_eq('fish', 'fowl'))
    assert(test_eq(true, true))
    assert(not test_eq(false, true))

    local nop = function () end
    local nop2 = lunit.clone_function(nop)

    assert(test_eq(nop, nop))
    assert(not test_eq(nop2, nop))

    -- non-recursive table comparison

    assert(test_eq({}, {}))
    assert(test_eq({ a = 1, b = { c = 2, d = 3 }}, { a = 1, b = { c = 2, d = 3 }}))
    assert(not test_eq({ b = { c = 2, d = 3 }}, { a = 1, b = { c = 2, d = 3 }}))
    assert(not test_eq({ a = 1, b = { c = 2, d = 3 }}, { a = 1, b = { d = 3 }}))

    -- rescursive table comparison

    local x = { a = 1, b = { top = {}, c = 3 }}
    x.b.top = x
    local y = {}
    y = { a = 1, b = { top = {}, c = 3 }}
    y.b.top = y

    assert(test_eq(x, y))
    y.b.top = x -- still equivalent
    assert(test_eq(x, y))
    y.b.top = {} -- not equivalent
    assert(not test_eq(x, y))

    x = { 1, {} }
    x[2] = x
    y = { 1, {} }
    y[2] = y
    assert(test_eq(x, y))

    y = { 1, {1, {} } }
    y[2][2] = y
    assert(test_eq(x, y))

    y = { 1, {1, {1, {} } } }
    y[2][2][2] = y
    assert(test_eq(x, y))

    y[2][2][2] = {}
    assert(not test_eq(x, y))

    -- mutually recursive table comparison
    x = { 1, {} }
    y = { 1, {} }
    x[2] = y
    y[2] = x
    assert(test_eq(x, y))

    y[2] = { 1, x }
    assert(test_eq(x, y))

    y[2] = { 1, x, 3 }
    assert(not test_eq(x, y))
end

function T.test_clone_function()
    local function make_fns()
        local a = 'A'
        local b = 'B'
        local function concat_ab() return a..b end
        local function set_a(x) a = x end
        local function set_b(x) b = x end
        return concat_ab, set_a, set_b
    end

    local concat_ab, set_a, set_b = make_fns()
    local concat_ab_bis = lunit.clone_function(concat_ab)

    -- check concat_ab_bis has same upvalues, viz. a and b.

    assert(test_eq('AB', concat_ab()))
    assert(test_eq('AB', concat_ab_bis()))

    set_a('X')
    assert(test_eq('XB', concat_ab()))
    assert(test_eq('XB', concat_ab_bis()))

    set_b('Y')
    assert(test_eq('XY', concat_ab()))
    assert(test_eq('XY', concat_ab_bis()))
end

function T.test_mock_env()
    local function load_with_new_env(src)
        local env = {}
        setmetatable(env, { __index = _ENV })
        return load(src, 'chunk', 't', env)
    end

    local test_src =
[[
    global_a = 'a'
    function p(x) end
    local function q(x) end

    -- mutually recursive local functions calling global function p
    -- and local (upvalue) function q.
    local rec1 = 0
    local rec2 = 0
    rec1 = function (n) if n>0 then p(n) q(n) rec2(n-1) end end
    rec2 = function (n) if n>0 then p(n) q(n) rec1(n-1) end end

    -- local function uses other local function to access global
    local function get_a() return global_a end
    local function test_set_a(x)
        local old_a = get_a()
        global_a = x
        return old_a..','.. get_a()
    end

    return { rec1 = rec1, test_set_a = test_set_a }
]]

    F = load_with_new_env(test_src)() -- get rec1, test_set_a from chunk

    -- recursive modification for mutually recursive functions:

    capture_pq = ''
    m_rec1 = lunit.mock_function_env(F.rec1, { p = function (n) capture_pq = capture_pq..(n)..';' end }, true)
    m_rec1(5)
    assert(test_eq_v('5;4;3;2;1;', capture_pq))

    capture_pq = ''
    m_rec1 = lunit.mock_function_upvalues(F.rec1, { q = function (n) capture_pq = capture_pq..(-n)..';'  end }, true)
    m_rec1(5)
    assert(test_eq_v('-5;-4;-3;-2;-1;', capture_pq))

    -- non-recursive modification for these functions should affect only first invocation of p, q from rec1

    capture_pq = ''
    m_rec1 = lunit.mock_function_env(F.rec1, { p = function (n) capture_pq = capture_pq..(n)..';' end }, false)
    m_rec1(5)
    assert(test_eq_v('5;', capture_pq))

    capture_pq = ''
    m_rec1 = lunit.mock_function_upvalues(F.rec1, { q = function (n) capture_pq = capture_pq..(-n)..';'  end }, false)
    m_rec1(5)
    assert(test_eq_v('-5;', capture_pq))

    -- confirm upvalues in recursively mocked function share same modified environment

    assert(test_eq_v('a,b', F.test_set_a('b')))

    m_test_set_a = lunit.mock_function_env(F.test_set_a, { global_a ='A' }, true)
    assert(test_eq_v('A,B', m_test_set_a('B')))
end

if not lunit.run_tests(T) then os.exit(1) end
