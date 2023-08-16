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

clif_functions = dofile("../luas/cli_filter.lua")

-- test suite:

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

local function mock_run_show_partition(partition)
    local out = ''
    if not partition or partition == '' then
        for _, entry in pairs(mock_show_partition_output_tbl) do
            out  = out  .. entry .. '\n'
        end
    else
        out = mock_show_partition_output_tbl[partition]
--        print('debug partition, out', partition, out)
    end

    if out then return out, 0
    else return nil, 1
    end
end

function T.test_get_default_partition()
    local get_default_partition = lunit.mock_function(clif_functions.get_default_partition, nil, { run_show_partition = mock_run_show_partition })
    local eq = lunit.test_eq_v

    assert(eq('work', get_default_partition()))

    -- temporarily munge mock partition info to remove Default
    local saved = mock_show_partition_output_tbl.work;
    mock_show_partition_output_tbl.work = string.gsub(saved, 'Default=[^%s]*', '')

    local result = get_default_partition()
    mock_show_partition_output_tbl.work = saved

    assert(eq(nil, result))
end

function T.test_get_partition_info()
    local get_partition_info = lunit.mock_function(clif_functions.get_partition_info, nil, { run_show_partition = mock_run_show_partition })
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
    local slurm_debug = clif_functions.slurm_debug
    local slurm_debugf = clif_functions.slurm_debugf
    local eq = lunit.test_eq_v

    slurm_log_debug_tbl = {}

    slurm_debug('not a %s fmt')
    assert(eq('cli_filter: not a %s fmt', slurm_log_debug_tbl[1]))

    slurm_debugf('%s=%02d', 'foo', 3)
    assert(eq('cli_filter: foo=03', slurm_log_debug_tbl[2]))
end

if not lunit.run_tests(T) then os.exit(1) end
