lunit = require('lunit')

function opaque(x)
    print('opaque', x)
end

local function make_mock_print()
    local saved_ = {}
    return saved_, function (...)
        local line = ''
        for i, arg in ipairs({...}) do
            if i==1 then line = arg
            else line = line .. '\t'.. arg
            end
        end
        table.insert(saved_, line)
    end
end

local function test_opaque()
    local lines, mock_print = make_mock_print()
    local mocked_opaque = lunit.mock_function(opaque, { print = mock_print })

    mocked_opaque(10)
    mocked_opaque('foo')

    assert(lines[1] == 'opaque\t10')
    assert(lines[2] == 'opaque\tfoo')
end

opaque('before test')

lunit.run_tests({ test_opaque = test_opaque })

opaque('after test')
