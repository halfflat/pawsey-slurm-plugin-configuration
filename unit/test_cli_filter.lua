lunit = require('lunit')

-- mock slurm interface:

slurm_log_error_tbl = {}
slurm_log_debug_tbl = {}

slurm = {}
function slurm.log_error(fmt, ...)
    table.insert(slurm_log_error_tbl, string.format(fmt, ...))
end
function slurm.log_debug(fmt, ...)
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
end
slurm.SUCCESS = 0
slurm.ERROR = -1

-- schlep in cli_filter; returns table of local functions to test

-- clif_functions = dofile("../luas/cli_filter.lua")

local function tokenize(str, pattern, max_tokens)
    if #str == 0 then return {} end

    pattern = pattern or '%s'
    max_tokens = max_tokens or 0
    local truncate_trailing_empty = max_tokens == 0

    local tokens = {}
    local tok_from = 1
    repeat
        if max_tokens == 1 then
            table.insert(tokens, str:sub(tok_from))
            break
        end
        max_tokens = max_tokens - 1

        local sep_from, sep_to = str:find(pattern, tok_from)

        -- Exclude zero-length tokens when the pattern gives a zero-length match.
        if sep_from == tok_from and sep_to < sep_from then
            sep_from, sep_to = str:find(pattern, tok_from + 1)
        end

        table.insert(tokens, str:sub(tok_from, (sep_from or 1 + #str) - 1))
        tok_from = (sep_to or #str) + 1
    until not sep_from

    if truncate_trailing_empty then
        while #tokens>0 and tokens[#tokens] == '' do tokens[#tokens] = nil end
    end
    return tokens
end

-- test suite:

T = {}
function T.test_tokenize()
    local function join(tokens, sep)
        local joined = ""
            for i, tok in ipairs(tokens) do
            if i==1 then joined = tok
            else joined = joined..sep..tok
            end
        end
        return joined
    end

    local eq = lunit.test_eq_v

    -- simple tokens
    assert(eq({}, tokenize('', ' ')))
    assert(eq({'abc'}, tokenize('abc', ' ')))
    assert(eq({'abc', 'def', '', 'ghi'}, tokenize('abc def  ghi', ' ')))
    assert(eq({'', 'abc', 'def', '', 'ghi'}, tokenize(' abc def  ghi  ', ' ')))

    -- max_tokens -1 will pick up trailing empty tokens
    assert(eq({'', 'abc', 'def', '', 'ghi', '', ''}, tokenize('-abc-def--ghi--', '-', -1)))

    -- zero width separators
    assert(eq({}, tokenize('', '')))
    assert(eq({'a'}, tokenize('a', '')))
    assert(eq({'a', ''}, tokenize('a', '', -1)))
    assert(eq({'a', 'b', 'c'}, tokenize('abc', '')))
    assert(eq({'abc', ',def', ',ghi'}, tokenize('abc,def,ghi', '%f[,]')))

    -- other patterns
    assert(eq({'', 'abc', 'def', 'ghi'}, tokenize(' abc def  ghi  ', ' +')))
    assert(eq({'', 'a', 'b', 'c', 'd', 'e', 'f'}, tokenize(' abc def  ', ' *')))

    -- limit number of tokens
    assert(eq({'a', 'b', 'c=d'}, tokenize('a=b=c=d', '=', 3)))
end

lunit.run_tests(T)
