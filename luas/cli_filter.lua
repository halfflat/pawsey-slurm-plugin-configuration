-- Utility and helper functions used in filter methods.

-- Regard str as a string of tokens separated by separators that are described by the pattern string and
-- return the tokens as a table.
-- If max_tokens is a positive number, only the first (max_tokens - 1) separators will be considered.
-- If the pattern matches a zero-length subsring, it will only be considered to describe a separator if
-- the preceding token would be non-empty.

function tokenize(str, pattern, max_tokens)
    if #str == 0 then return {} end

    pattern = pattern or '%s'
    max_tokens = max_tokens or 0

    local tokens = {}
    local tok_from = 1
    while tok_from <= #str do
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

        sep_from = sep_from or #str + 1
        sep_to = sep_to or #str + 1

        table.insert(tokens, str:sub(tok_from, sep_from - 1))
        tok_from = sep_to + 1
    end
    return tokens
end

-- Report message to stderr with final newline and return slurm.FAILURE, so that
--     return slurm_failure("error")
-- is equivalent to
--     io.stderr:write("error\n")
--     return slurm.FAILURE
function slurm_failure(error_msg)
    io.stderr:write(error_msg, '\n')
    return slurm.FAILURE
end

-- Execute command; return captured stdout and return code.
function osExecute(cmd)
    local fileHandle     = assert(io.popen(cmd, 'r'))
    local commandOutput  = assert(fileHandle:read('*a'))
    local rc = {fileHandle:close()}
    return commandOutput, rc[3]            -- rc[3] contains return code
end

function parse_partition_info(partition)
    if not partition then return nil end



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
    -- Currently a no-op

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

    -- Set to true to enable debug output
    local enable_debug = false

    if enable_debug then
        -- Potentially write to stderr or log to slurm log instead?
        local function debug(message, ...)
            io.stdout:write(message)
            for _, a in ipairs({...}) do io.stdout:write('\t',a) end
            io.stdout:write('\n')
        end
        local function debugf(fmt, ...)
            io.stdout:write(fmt:format(...), '\n')
        end
        debug('Running cli filter verbosely')
    else
        local function debug(...) end
        local function debugf(...) end
    end

    local function is_gpu_partition(partition)
        return partition == 'gpu' or partition == 'gpu-dev' or partition == 'gpu-highmem'
    end

    -- get the arguments
    local threads = tonumber(options['threads-per-core'])
    local mem = options['mem']
    local mempercore = options['mem-per-cpu']
    local partition = options['partition']
    local exclusive = options['exclusive']

    -- to check if any cpu resource parameters have been passed
    local has_explicit_cpu_request = (
        tonumber(options['cpus-per-task']) > 1 or
        tonumber(options['cpus-per-gpu)']) > 0 or
        tonumber(options['cores-per-socket']) ~=-2 or
    )

    -- to check if any mem resource parameters have been passed
    local has_all_mem_request = options['mem']
    local has_explicit_mem_request = (
        options['mem-per-cpu'] ~= nil or
        options['mem-per-gpu'] ~= nil or
        options['mem'] ~=nil and not has_all_mem_request
    )

    local memforallmem = "0?" -- value that indicates --mem=0 has been passed.

    debug("Before doing any changes values are (mem, mempercore, partition, exclusive?) ", mem, mempercore, partition, exclusive)

    -- First check partition and if nil, then default to work. Ideally it would be good to replace
    if (partition == nil) then
        -- find partition that returns default
        local pcmd = "scontrol show partition --oneliner | grep Default=YES | sed 's:=: :g' | awk '{print $2}' "
        defpart = (osExecute(pcmd)):gsub("[\n\r]","")
        partition = defpart
    end

    -- Early exit if there is an explicit, no

    -- if not the gpu cluster then so long as memory is passed can determine
    -- how to proceed
    if (partition ~= 'gpu' and partition ~= 'gpu-dev' and partition ~= 'gpu-highmem') then
        -- If memory is provided and not 0? (which is the string to store 0 value asking for all the mem on a node) or mempercore provided then continue
        -- otherwise determine default mem request
        if ((mem ~= nil and mem ~= memforallmem) or mempercore ~=nil) then
            return slurm.SUCCESS
        end
    end
    -- if presubmisison has been already run then do nothing ideally we don't need to do these calculations
    -- but it is unclear how to address this

    -- get the partition information
    local pinfocmd = "scontrol show partition " .. partition .. " --oneliner"
    local pinfo = osExecute(pinfocmd):gsub("[\n\r]","")
    part_dict = {}
    if (verbose) then
        print('Extracting parition information')
    end
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

    -- with the partition information get memory info
    local memperhardwarethread = 0
    local mempergpu = 0
    local mempercoredesired = 0
    if (partition ~= 'gpu' and partition ~= 'gpu-dev' and partition ~= 'gpu-highmem') then
        memperhardwarethread = math.floor(tonumber(part_dict["DefMemPerCPU"]))
        -- determine mem per core value
        if (threads == 1) then
            mempercoredesired = memperhardwarethread * 2
        else
            mempercoredesired = memperhardwarethread
        end
        mempercoredesired = math.floor(mempercoredesired)
    end
    if (partition == 'gpu' or partition == 'gpu-dev' or partition == 'gpu-highmem') then
        -- currently there is no robust way of extracting the info in JobDefaults
        -- so we do not calculate mempergpu this way
        -- mempergpu = math.floor(tonumber(part_dict["JobDefaults_DefMemPerGPU"]))
        -- need to think about how to best extract this but for now, since it is just
        -- used in a error message, set it to 1.0/8.0 of total memory
        mempergpu = 1.0/8.0
    end
    local numhardwarethread = math.floor(tonumber(part_dict["TotalCPUs"])/tonumber(part_dict["TotalNodes"]))


    -- first trial of gpu, lets complain if there are some
    if (partition == 'gpu' or partition == 'gpu-dev' or partition == 'gpu-highmem') then
        local totalnumgpus = math.floor(tonumber(part_dict["TRES_cpu"])/tonumber(part_dict["TRESBillingWeights_gres/GPU"]))
        local cpuspergpu = numhardwarethread/totalnumgpus/2
        local igpuset = false
        if (verbose) then
            print("Processing GPU with info of total number of gpus per node and cpus per gpu of", totalnumgpus, cpuspergpu)
            print(options['gres'], options['gpus-per-node'], options['gpus-per-task'])
        end
        -- extract the gpu request
        if (options['gres'] ~= nil) then
            igpuset = true
        end
        if (options['gres'] == nil and options['gpus-per-node'] ~=nil) then
            -- options['gres'] = 'gres:gpu:' .. options['gpus-per-node']
            igpuset = true
        end
                if (options['gres'] == nil and options['gpus'] ~=nil) then
                        -- options['gres'] = 'gres:gpu:' .. options['gpus']
            igpuset = true
                end
        if (options['gres'] == nil) then
            -- before had the code below to calculate gpus per node given gpus per task
            -- and ntasks-per-node but disable this. Only allow gpus per node or gres
            -- and number of nodes as the request.

            if (options['gres'] == nil and options['gpus-per-task'] ~= nil) then
                if (options['ntasks-per-node'] ~= "-2") then
                    local gpuspernodedesired = math.ceil(tonumber(options['gpus-per-task'])*tonumber(options['ntasks-per-node']))
                    -- options['gres'] = 'gres:gpu:' .. gpuspernodedesired
                    if (verbose) then
                        print('Request of gpus per task and tasks-per-node request', options['gres'], options['gpus-per-task'])
                                        end
                    igpuset=true
                end

                if (options['ntasks'] ~= nil) then
                    local numnodes = 0
                    local ntaskspernode = math.floor(totalnumgpus/tonumber(options['gpus-per-task']))
                    local gpuspernodedesired = math.ceil(tonumber(options['gpus-per-task'])*ntaskspernode)
                    if (verbose) then
                        print('Request for gpus per task and total tasks: = (nodes, ntasks, calc_ntaskspernode, calc_gpuspernode', options['nodes'], options['ntasks'], ntaskspernode, gpuspernodesired)
                    end
                    -- options['gres'] = 'gres:gpu:' .. gpuspernodedesired
                    igpuset = true
                    -- print("ERROR: Requested gpus-per-task but did not set ntasks-per-node. \nPlease resubmit with appropriate request")
                    -- return slurm.FAILURE
                end
            end
        end
        -- if (options['gres'] == nil and options['exclusive'] == nil) then
        if (igpuset == false and options['exclusive'] == nil) then
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
