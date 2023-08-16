--[[
    Local implementation of cli_filter.lua interface for Pawsey machies.

    The cli_filer interface is provided by the functions
        slurm_cli_pre_submit(options, offset)
        slurm_cli_post_submit(offset, jobid, stepid)
        slurm_cli_setup_defaults(options, early)

    Debugging output is through the slurm.log_debug lua interface,
    corresponding to slurm's LOG_LEVEL_DEBUG, which should then be directed to
    stderr when e.g. salloc is given the option -vv.

    Error messages are emitted through the slurm.log_error lua interface,
    corresponding to slurm's LOG_LEVEL_ERROR, which writes to stderr by default.
--]]

--[[
   tokenize(str, pattern, max_tokens)

   Regard str as a string of tokens separated by separators that are described by the pattern string and
   return the tokens as a table. Operates similarly to perl's split function.

  If max_tokens is a positive number, only the first (max_tokens - 1) separators will be considered.
  If max_tokens is zero, exclude any trailing empty tokens from the result.
  If max_tokens is a negative number, return all tokens.
  If the pattern matches a zero-length subsring, it will only be considered to describe a separator if
  the preceding token would be non-empty.
]]--

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

-- Wrappers for slurm logging

local function slurm_error(msg)
    slurm.log_error("cli_filter: %s", msg)
    return slurm.ERROR
end

local function slurm_errorf(fmt, ...)
    slurm.log_error("cli_filter: "..fmt, ...)
    return slurm.ERROR
end

local function slurm_debug(msg)
    slurm.log_debug("cli_filter: %s", msg)
end

local function slurm_debugf(fmt, ...)
    slurm.log_debug("cli_filter: "..fmt, ...)
end

-- Execute command; return captured stdout and return code.

local function os_execute(cmd)
    local fileHandle     = assert(io.popen(cmd, 'r'))
    local commandOutput  = assert(fileHandle:read('*a'))
    local rc = {fileHandle:close()}
    return commandOutput, rc[3]            -- rc[3] contains return code
end

-- Run scontrol show partition; this function will be mocked in unit testing.

local function run_show_partition(partition)
    return os_execute('scontrol show partition --oneliner '..(partition or '')..' 2>/dev/null')
end

local function get_default_partition()
    local all_pinfo_str, rc = run_show_partition()
    if rc == 0 then
        for _, line in ipairs(tokenize(all_pinfo_str, '\n')) do
            if line:find("Default=YES") then return line:match('PartitionName=([^%s]+)') end
        end
    end
    return nil
end

local function parse_partition_info_str(pinfo_str)
    if not pinfo_str then return nil end

    local pinfo = {}
    for _, field in ipairs(tokenize(pinfo_str, '%s+')) do
        local k, v = table.unpack(tokenize(field, '=', 2))

        -- some fields themselves are expected to contain tables
        if k == 'JobDefaults' or k == 'TRES' or k == 'TRESBillingWeights' then
            local rhs = {}
            if v ~= '(null)' then
                for _, subfield in ipairs(tokenize(v, ',')) do
                    local k, v = table.unpack(tokenize(subfield, '=', 2))
                    if v == nil then rhs.insert(k)
                    else rhs[k] = v
                    end
                end
            end
            pinfo[k] = rhs
        else
            pinfo[k] = v
        end
    end
    return pinfo
end

local function get_partition_info(partition)
    if not partition or partition == '' then return nil end
    local pinfo_str, rc = run_show_partition(partition)

    if rc == 0 then
        return parse_partition_info_str(pinfo_str)
    end
    return nil
end

-- Slurm CLI filter interface functions:

function slurm_cli_setup_defaults(options, early)
    --[[
        Rather than just have a default SLURM_HINT in the
        module, which is hard to override, this sets the
        same default in a "more elegant" way.
        See SchedMD Bug 10377
    --]]

    options['threads-per-core'] = 1
    return slurm.SUCCESS
end

function slurm_cli_post_submit(offset, jobid, stepid)
    return slurm.SUCCESS
end

function slurm_cli_pre_submit(options, offset)
    --[[
        Sets the memory request if not provided
        Relies on output from scontrol so large formating
        changes will break this pre processing
        It also relies on mem=0 being a way of requesting all
        the memory on a node and that this value is stored internally
        as "0?".
        Finally, the script also relies on DefMemPerCPU being set and
        being a meaningful value such that DefMemPerCPU * Total number of cores on a node
        is all the memory on a node.
    --]]

    slurm_debugf("before doing any changes options are mem=%s, mem-per-cpu=%s, partition=%s, exclusive=%s",
        options['mem'], options['mem-per-cpu'], options['partition'], options['exclusive'])

    local function is_gpu_partition(partition)
        return partition == 'gpu' or partition == 'gpu-dev' or partition == 'gpu-highmem'
    end

    -- An unset option can be repesented by nil, the string "-2", or the string "unset": check all of them.
    local function is_unset(x) return x == nil or x == '-2' or x == 'unset' end

    -- have any cpu resource options been passed?
    local has_explicit_cpu_request =
        tonumber(options['cpus-per-task']) > 1 or tonumber(options['cpus-per-gpu)']) > 0 or
        not is_unset(options['cores-per-socket'])

    -- have any gpu resrouce options been passed?
    local has_explicit_gpu_request =
        not is_unset(options['gres']) or not is_unset(options['gpus']) or
        not is_unset(options['gpus-per-node']) or not is_unset(options['gpus-per-task'])

    -- have any mem resource options been passed, excluding a request for all node memory?
    local has_all_mem_request = options['mem'] == "0?"
    local has_explicit_mem_request =
        options['mem-per-cpu'] ~= nil or options['mem-per-gpu'] ~= nil or options['mem'] ~=nil and not has_all_mem_request

    local is_node_exclusive = options['exclusive'] == 'exclusive' -- disregard 'user', 'mcs' possibilities.
    local partition = options['partition'] or get_default_partition()

    if not is_gpu_partition(partition) then
        -- Non-gpu partition path: compute correct mem-per-cpu value from available memory and threads-per-core option
        -- if memory has not been reqested explicitly

        if has_explicit_mem_request then
            return slurm.SUCCESS
        end

        local pinfo = get_partition_info(partition)
        if pinfo == nil then return slurm_error("unable to retrieve partition information") end

        local mem_per_hw_thread = math.floor(tonumber(pinfo.DefMemPerCPU))

        if is_node_exclusive or has_all_mem_request then
            local hw_threads_per_node = math.floor(tonumber(pinfo.TotalCPUs)/tonumber(pinfo.TotalNodes))
            options['mem'] = math.floor(mem_per_hw_thread * hw_threads_per_node)
        else
            local mem_scale = 1
            if tonumber(options['threads-per-core']) == 1 then mem_scale = 2 end

            options['mem-per-cpu'] = mem_per_hw_thread * mem_scale
        end
        return slurm.SUCCESS
    else
        -- Gpu partition path

        local pinfo = get_partition_info(partition)
        if pinfo == nil then return slurm_error("unable to retrieve partition information") end

        local tres = pinfo.TRES
        if not tres or not tres.cpu or not tres['gres/gpu'] then return slurm_error('unable to determine cpu to gpu ratio') end
        local cpus_per_gpu = math.floor(tres.cpu/tres['gres/gpu'])

        if has_explicit_cpu_request then
            return slurm_errorf('cannot explicitly request CPU resources for GPU allocation; each allocated GPU allocates %d cores', cpus_per_gpu)
        end

        -- Try to get mem-per-gpu from JobDefaults? Only used for informational purposes.
        local def_mem_per_gpu = pinfo.JobDefaults and pinfo.JobDefaults.DefMemPerGPU
        if has_explicit_mem_request then
            return slurm_errorf('cannot explicitly request memory for GPU allocation; each allocated GPU allocates %s MB of memory', def_mem_per_gpu or "some")
        end

        -- Ensure there is some gpu request on a gpu partition
        if not is_node_exclusive and not has_explicit_gpu_request then
            return slurm_error('')
        end

        options['cpus-per-gpu'] = cpus_per_gpu
        if is_node_exclusive then
            options['gres'] = 'gpu:8'
        end
        return slurm.SUCCESS
    end
end

-- return table of local functions for unit testing
return {
    tokenize = tokenize,
    slurm_error = slurm_error,
    slurm_errorf = slurm_errorf,
    slurm_debug = slurm_debug,
    slurm_debugf = slurm_debugf,
    get_default_partition = get_default_partition,
    parse_partition_info_str = parse_partition_info_str,
    get_partition_info = get_partition_info,
}
