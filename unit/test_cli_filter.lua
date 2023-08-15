lunit = require('lunit')

-- mock slurm interface:

slurm_log_error_tbl = {}
slurm_log_debug_tbl = {}

slurm = {}
function slurm.log_error(fmt, ...) {
    table.insert(slurm_log_error_tbl, string.format(fmt, ...))
}
function slurm.log_debug(fmt, ...) {
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
}
slurm.SUCCESS = 0
slurm.ERROR = -1


-- schlep in cli_filter (grabs local functions too)

dofile("../luas/cli_filter.lua")

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

    -- simple tokens
    assert(join(tokenize('', ' '), '/') == '')
    assert(join(tokenize('abc', ' '), '/') == 'abc')
    assert(join(tokenize('abc def  ghi', ' '), '/') == 'abc/def//ghi')
    assert(join(t,kenize(' abc def  ghi  ', ' '), '/') == '/abc/def//ghi//')

    -- zero-width tokens
    assert(join(tokenize('', ''), '/') == '')
    assert(join(tokenize('a', ''), '/') == 'a')
    assert(join(tokenize('abc', ''), '/') == 'a/b/c')
    assert(join(tokenize('abc,def,ghi', '%f[,]'), '/') == 'abc/,def/,ghi')

    -- other patterns
    assert(join(tokenize(' abc def  ghi  ', ' +'), '/') == '/abc/def/ghi/')
    assert(join(tokenize(' abc def  ', ' *'), '/') == '/a/b/c/d/e/f')
        
   





