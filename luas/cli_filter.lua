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

-- Utility and helper functions used in filter methods.

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

local function slurm_error(_msg)
    slurm.log_error("cli_filter: %s", msg)
    return slurm.ERROR
end

local function slurm_errorf(fmt, ...)
    return slurm_error("cli_filter: "..fmt, ...)
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

local function get_default_partition()
    local all_pinfo, rc = os_execute('scontrol show partition --oneliner 2>/dev/null')
    if not rc then
        for _, line in ipairs(tokenize(all_pinfo, '\n')) do
            if line:find("Default=YES") then return line:match('PartitionName=([^%s]+)') end
        end
    return nil
end

function parse_partition_info_str(pinfo_str)
    if not pinfo_str then return nil end

    -- ...
end

function get_partition_info(partition)
    local pinfo, rc = os_execute('scontrol show partition --oneliner '..partition..' 2>/dev/null')
    if rc then return nil else return parse_partition_info_str(pinfo_str)
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

    -- to check if any cpu resource parameters have been passed
    local has_explicit_cpu_request = (
        tonumber(options['cpus-per-task']) > 1 or
        tonumber(options['cpus-per-gpu)']) > 0 or
        not is_unset(options['cores-per-socket'])
    )

    -- to check if any gpu resrouce parameters have been passed
    local has_explicit_gpu_request = (
        not is_unset(options['gres']) or
        not is_unset(options['gpus']) or
        not is_unset(options['gpus-per-node']) or
        not is_unset(options['gpus-per-task'])
    )

    -- to check if any mem resource parameters have been passed, excluding a request for all memorya
    local has_all_mem_request = options['mem'] == "0?"
    local has_explicit_mem_request = (
        options['mem-per-cpu'] ~= nil or
        options['mem-per-gpu'] ~= nil or
        options['mem'] ~=nil and not has_all_mem_request
    )

    local is_node_exclusive = options['exclusive'] == 'exclusive' -- disregard 'user', 'mcs' possibilities.
    local partition = options['partition'] or get_default_partition()

    -- if presubmisison has been already run then do nothing ideally we don't need to do these calculations
    -- but it is unclear how to address this

    -- get the partition information
    local pinfocmd = "scontrol show partition " .. partition .. " --oneliner"
    local pinfo = osExecute(pinfocmd):gsub("[\n\r]","")
    part_dict = {}
    slurm_debug('extracting parition information...')
    for j, keyvalue_string in pairs(splitstr(pinfo, ' ')) do
        if (verbose) then
            print('Current field and values:', keyvalue_string)
        end
        local keyvalue_dict = splitstr(keyvalue_string, '=')
        local key = nil
        local value = nil
        -- some fields contain several entries, process them differently.
        local tresbillingresult = string.match(keyvalue_dict[1],"TRESBillingWeights")
        local tresresult = string.match(keyvalue_dict[1],"TRES")
        local jobdefaultsresult = string.match(keyvalue_dict[1], "JobDefaults")
        if (tresresult == nil and tresbillingresult == nil and jobdefaultsresult == nil) then
            key = keyvalue_dict[1]
            value =  keyvalue_dict[2]
            part_dict[key] = value
        else
            -- clean up the string to get entries
            if (jobdefaultsresult == nil) then
                local tresstring
                if (tresbillingresult ~= nil) then
                    tresstring = "TRESBillingWeights"
                else
                    tresstring = "TRES"
                end
                keyvalue_string = keyvalue_string:gsub(tresstring .. "=", '')
                keyvalue_string = keyvalue_string:gsub('%,', '\n')
                local oldkeyvalue_dict = splitstr(keyvalue_string, '\n')
                for k,v in pairs(oldkeyvalue_dict) do
                    keyvalue_dict = splitstr(v, '=')
                    key = tresstring .. "_" .. keyvalue_dict[1]
                    value  = keyvalue_dict[2]
                    part_dict[key] = value
                end
            else
                -- there are currently problems with trying to robustly extract info in the
                -- JobDefaults portion of the partition, which can contain stuff like DefMemPerGPU
                local key_string = "JobDefaults"
                keyvalue_string = keyvalue_string:gsub(key_string .. "=", '')
                keyvalue_string = keyvalue_string:gsub('%,', '\n')
                local oldkeyvalue_dict = splitstr(key_string, '\n')
                for k,v in pairs(oldkeyvalue_dict) do
                    keyvalue_dict = splitstr(v, '=')
                    key = key_string .. "_" .. keyvalue_dict[1]
                    value  = keyvalue_dict[2]
                    part_dict[key] = value
                end
            end
        end
    end

    if not is_gpu_partition(partition) then
        -- Non-gpu partition path: compute correct mem-per-cpu value from available memory and threads-per-core option
        -- if memory has not been reqested explicitly

        if has_explicit_mem_request then
            return slurm.SUCCESS
        end

        local pinfo = get_partition_info(partition)
        if pinfo == nil then return slurm_error("unable to retrieve partition information") end

        local mem_per_hw_thread = math.floor(tonumber(pinfo.DefMemPerCPU]))

        if is_node_exlcusive or has_all_mem_request then
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
        options['cpus-per-gpu'] = cpus_per_gpu

        -- try to get mem-per-gpu from JobDefaults?
        local def_mem_per_gpu = pinfo.JobDefaults and pinfo.JobDefaults.DefMemPerGPU
        if has_explicit_mem_request then
            return slurm_errorf('cannont explicitly request memory for GPU allocation; each allocated GPU allocates %s MB of memory', def_memper_gpu or "some")
        end

        -- ... TBC


    -- first trial of gpu, lets complain if there are some
    if (partition == 'gpu' or partition == 'gpu-dev' or partition == 'gpu-highmem') then
        local totalnumgpus = math.floor(tonumber(part_dict["TRES_cpu"])/tonumber(part_dict["TRESBillingWeights_gres/GPU"]))
        local cpuspergpu = numhardwarethread/totalnumgpus/2
        local igpuset = false
        debugf('processing gpu request with %d gpus/node, %d cpus/gpu and options gres=%s, gpus-per-node=%s, gpus-per-task=%s, ntasks-per-node=%s',
            totalnumgpus, cpuspergpu, options['gres'], options['gpus-per-node'], options['gpus-per-task'], options['ntasks-per-node'])

        if not has_explicit_gpu_request and options['exclusive'] == nil then
            print("ERROR: No explicit request gpus with gres or gpus-per-node or not exclusive use.\nPlease resubmit with a GPU request.")
            return slurm.FAILURE
        end
        if (options['gres'] == "gres:gpu:0") then
            print("ERROR: Requesting 0 gpus. \nPlease resubmit with a valid GPU request.")
            return slurm.FAILURE
        end
        -- set the number of cpus per gpu to ensure automatic chiplet allocation and gpu-closest binding.
        options['cpus-per-gpu'] = math.floor(cpuspergpu)
        -- check if any mem related requests have been passed and reject
        -- if passed using sbatch or salloc
        if (has_explicit_mem_request) then
            print("ERROR: Explicitly requesting Memory resources. \nPlease resubmit with just GPU request. 1 GPU = ", mempergpu, "of total node memory.")
            return slurm.FAILURE
        end
        -- check if any cpu related requests have been passed and reject
        -- if passed using sbatch or salloc
        local icpuflag = false
        for k,v in pairs(cpulist) do
            if (v) then
                icpuflag = true
            end
        end
        if (icpuflag) then
            print("ERROR: Explicitly requesting CPU resources. \nPlease resubmit with just GPU request. 1 GPU = 8 CPUS (with SMT turned off)")
            return slurm.FAILURE
        end
        -- if exclusive set the memory to all by using 0
        -- and set the gres=gpu:8
        -- otherwise set cpus and memory to the appropriate amount
        if (exclusive == "exclusive") then
            options['gres'] = 'gpu:8'
        end
        --if (verbose) then
        --    print("Now submitting a job for (exclusive flag, gpu, ntasks-per-node, mem, mem-per-cpu,mem-per-gpu)", exclusive, options['gres'], options['ntasks-per-node'], options['mem'], options['mem-per-cpu'], options['mem-per-gpu'])
        --end
        return slurm.SUCCESS
    end

    -- if all the memory has been requested, set the value (in MB)
    -- if exclusive is requested and no memory set, assume all the memory requested
    if ( mem == memforallmem or (exclusive == "exclusive" and mem == nil )) then
        mem = math.floor(memperhardwarethread*numhardwarethread)
        options['mem'] = mem
    end
    -- otherwise set the mem per cpu value to the default
    if (mem == nil and mempercore == nil and exclusive ~= "exclusive") then
        mempercore = mempercoredesired
        options['mem-per-cpu'] = mempercore
    end

    -- lets add some reporting
    if (verbose) then
        print("After doing any changes values are (mem, mempercore, partition, exclusive?) ", mem, mempercore, partition, exclusive)
        print("And cpu requests are (ntasks, ntasks-per-node)", options["ntasks"], options["ntasks-per-node"])
    end

    return slurm.SUCCESS
end


--[[
    Testing

    The clif_test table exports utility functions for unit testing. A test environment will need to mock the slurm interfaces:
        slurm.SUCCESS       Return value on success
        slurm.ERROR         Return value on 

