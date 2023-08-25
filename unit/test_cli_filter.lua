--[[
    Unit tests for code in the Pawsey slurm lua cli_filter.

    The cli_filter provides three global functions as part of
    the slurm lua cli_filter API. It also uses a number of
    local functions in the implementation of these API functions.

    These unit tests aim to provide some test coverage of
    both the API functions and the local implementation functions,
    though at this point in time only tests for the latter have
    been implemented.
]]--

lunit = require('lunit')

-- Mock slurm interface:
--
-- Slurm itself exports some interfaces to slurm functionality
-- and key constants to the cli_filter lua program; mock these
-- for isolated unit testing directly in the global environment.

slurm_log_error_tbl = {}
slurm_log_debug_tbl = {}

slurm = {}
function slurm.log_error(fmt, ...)
    table.insert(slurm_log_error_tbl, string.format(fmt, ...))
end
function slurm.log_debug(fmt, ...)
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
end
-- For now at least, cli_filter debug output is being sent via slurm.log_info.
function slurm.log_info(fmt, ...)
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
end
-- If we use slurm.json_cli_options(options) in the filter, we'll need something
-- here too.
function slurm.json_cli_options(opts)
    return '{}'
end
slurm.SUCCESS = 0
slurm.ERROR = -1

-- Mock os.getenv with mock os table as required

mock_unset_tbl = {}
mock_setenv_tbl = {}

mock_os = {}
setmetatable(mock_os, { __index = os })
function mock_os.getenv(v)
    if mock_unset_tbl[v] then return nil
    elseif mock_setenv_tbl[v] ~= nil then return mock_setenv_tbl[v]
    else return os.getenv(v)
    end
end

function mock_setenv(v, x)
    mock_unset_tbl[v] = nil
    mock_setenv_tbl[v] = x
end

function mock_unset(v, x)
    mock_unset_tbl[v] = true
    mock_setenv_tbl[v] = nil
end

function mock_clearenv()
    mock_unset_tbl = {}
    mock_setenv_tbl = {}
end


-- Schlep in cli_filter; returns table of local functions to test.

clif_functions = dofile("../luas/cli_filter.lua")

-- Test suite:

T = {}
function T.test_tokenize()
    local tokenize = clif_functions.tokenize
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

local mock_show_partition_output_tbl = {
    work = "PartitionName=work AllowGroups=ALL AllowAccounts=ALL \z
            AllowQos=ALL AllocNodes=ALL Default=YES QoS=N/A \z
            DefaultTime=01:00:00 DisableRootJobs=NO ExclusiveUser=NO \z
            GraceTime=0 Hidden=NO MaxNodes=UNLIMITED MaxTime=1-00:00:00 \z
            MinNodes=0 LLN=NO MaxCPUsPerNode=UNLIMITED \z
            Nodes=nid[001008-001011,001020-001023] \z
            PriorityJobFactor=0 PriorityTier=0 RootOnly=NO ReqResv=NO \z
            OverSubscribe=FORCE:1 OverTimeLimit=NONE PreemptMode=OFF \z
            State=UP TotalCPUs=2048 TotalNodes=8 SelectTypeParameters=NONE \z
            JobDefaults=(null) DefMemPerCPU=920 MaxMemPerCPU=1840 \z
            TRES=cpu=2048,mem=1960000M,node=8,billing=2048 \z
            TRESBillingWeights=CPU=1",

    gpu =  "PartitionName=gpu AllowGroups=ALL AllowAccounts=ALL \z
            AllowQos=ALL AllocNodes=ALL Default=NO QoS=N/A \z
            DefaultTime=01:00:00 DisableRootJobs=NO ExclusiveUser=NO \z
            GraceTime=0 Hidden=NO MaxNodes=UNLIMITED MaxTime=1-00:00:00 \z
            MinNodes=0 LLN=NO MaxCPUsPerNode=UNLIMITED \z
            Nodes=nid[001000,001002,001004,001006] \z
            PriorityJobFactor=0 PriorityTier=0 RootOnly=NO ReqResv=NO \z
            OverSubscribe=NO OverTimeLimit=NONE PreemptMode=OFF \z
            State=UP TotalCPUs=512 TotalNodes=4 \z
            SelectTypeParameters=CR_SOCKET_MEMORY \z
            JobDefaults=DefMemPerGPU=29440 \z
            DefMemPerNode=UNLIMITED MaxMemPerNode=UNLIMITED \z
            TRES=cpu=512,mem=980000M,node=4,billing=2048,gres/gpu=32 \z
            TRESBillingWeights=CPU=1,gres/GPU=64"
}

-- provide a substitute for invoking `scontrol partition info`
local function mock_run_show_partition(partition)
    local out = ''
    if not partition or partition == '' then
        for _, entry in pairs(mock_show_partition_output_tbl) do
            out  = out  .. entry .. '\n'
        end
    else
        out = mock_show_partition_output_tbl[partition]
    end

    if out then return out, 0
    else return nil, 1
    end
end

function T.test_get_default_partition_or_env()
    local tmp = lunit.mock_function_upvalues(clif_functions.get_default_partition_or_env, { run_show_partition = mock_run_show_partition }, true)
    local get_default_partition_or_env = lunit.mock_function_env(tmp, { os = mock_os }, true)
    local eq = lunit.test_eq_v

    mock_unset('SLURM_JOB_PARTITION')
    assert(eq('work', get_default_partition_or_env()))

    mock_setenv('SLURM_JOB_PARTITION', 'caterpillar')
    assert(eq('caterpillar', get_default_partition_or_env()))

    mock_unset('SLURM_JOB_PARTITION')

    -- temporarily munge mock partition info to remove Default
    local saved = mock_show_partition_output_tbl.work;
    mock_show_partition_output_tbl.work = string.gsub(saved, 'Default=[^%s]*', '')

    local result = get_default_partition_or_env()
    mock_show_partition_output_tbl.work = saved

    assert(eq(nil, result))
end

function T.test_get_partition_info()
    local get_partition_info = lunit.mock_function_upvalues(clif_functions.get_partition_info, { run_show_partition = mock_run_show_partition }, true)
    local eq = lunit.test_eq_v

    local pinfo_work = get_partition_info('work')
    local pinfo_gpu = get_partition_info('gpu')

    assert(eq('4', pinfo_gpu.TotalNodes))
    assert(eq('8', pinfo_work.TotalNodes))

    assert(eq({ DefMemPerGPU = '29440' }, pinfo_gpu.JobDefaults))
    assert(eq({}, pinfo_work.JobDefaults))

    assert(eq({ cpu = '512', mem = '980000M', node = '4', billing = '2048', ['gres/gpu'] = '32' }, pinfo_gpu.TRES))
    assert(eq({ cpu = '2048', mem = '1960000M', node = '8', billing = '2048' }, pinfo_work.TRES))

    assert(eq({ CPU = '1', ['gres/GPU'] = '64' }, pinfo_gpu.TRESBillingWeights))
    assert(eq({ CPU = '1' }, pinfo_work.TRESBillingWeights))
end

function T.test_slurm_error()
    local slurm_error = clif_functions.slurm_error
    local slurm_errorf = clif_functions.slurm_errorf
    local eq = lunit.test_eq_v

    slurm_log_error_tbl = {}

    assert(eq(slurm.ERROR, slurm_error('not a %s fmt')))
    assert(eq('cli_filter: not a %s fmt', slurm_log_error_tbl[1]))

    assert(eq(slurm.ERROR, slurm_errorf('%s=%02d', 'foo', 3)))
    assert(eq('cli_filter: foo=03', slurm_log_error_tbl[2]))
end

function T.test_slurm_debug()
    local enable_debug = true
    local function mock_debug_lvl() return enable_debug and 1 or 0 end

    local slurm_debug = lunit.mock_function_upvalues(clif_functions.slurm_debug, { debug_lvl = mock_debug_lvl }, true)
    local slurm_debugf = lunit.mock_function_upvalues(clif_functions.slurm_debugf, { debug_lvl = mock_debug_lvl }, true)
    local eq = lunit.test_eq_v

    slurm_log_debug_tbl = {}

    slurm_debug('not a %s fmt')
    assert(eq('cli_filter: not a %s fmt', slurm_log_debug_tbl[1]))

    slurm_debugf('%s=%02d', 'foo', 3)
    assert(eq('cli_filter: foo=03', slurm_log_debug_tbl[2]))

    slurm_log_debug_tbl = {}
    enable_debug = false

    slurm_debug('not a %s fmt')
    slurm_debugf('%s=%02d', 'foo', 3)
    assert(eq(0, #slurm_log_debug_tbl))
end

function T.test_cli_sets_memory()
    -- matches or is derived from mock partition info above
    local def_mem_per_cpu = 920
    local n_threads_per_node = 256

    local eq = lunit.test_eq_v

    -- expect only mem-per-cpu to be set out of the memory options
    options = { partition = 'work', ['threads-per-core'] = 1 }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem']))
    assert(eq(def_mem_per_cpu*2, tonumber(options['mem-per-cpu'])))

    options = { partition = 'work', ['threads-per-core'] = 2 }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem']))
    assert(eq(def_mem_per_cpu, tonumber(options['mem-per-cpu'])))

    -- expect only mem to be set
    options = { partition = 'work', ['threads-per-core'] = 1, exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 1, mem = '0?' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 2, exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 2, mem = '0?' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    -- expect no other memory options to be set
    options = { partition = 'work', mem = '500M' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq('500M', options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 1, ['mem-per-cpu'] = '500M' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq('500M', options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    -- if partition is gpu, also expect no memory mangling
    options = { partition = 'gpu', gpus = '1'}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    options = { partition = 'gpu', exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    -- if partition is gpu, expect an error if memory request
    options = { partition = 'gpu', gpus = '1', mem = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', gpus = '1', ['mem-per-gpu'] = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', gpus = '1', ['mem-per-cpu'] = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', exclusive = 'exclusive', mem = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))
end

if not lunit.run_tests(T) then os.exit(1) end
