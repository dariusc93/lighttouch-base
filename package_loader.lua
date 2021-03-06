---- PACKAGES STEP BY STEP

-- list directories in packages path
-- foreach dir create specific path to events.txt, disabled_actions.txt, rules and actions
-- 'trigger' the loaders

local log = require "log"
local ansicolors = require 'third-party.ansicolors'

_G.rules = {} -- rules table to store them from all packages
_G.rules_priorities = {} -- table to store priorities of rules, so we can sort _G.rules table later by these priorities
_G.events = { } -- events table
local packages_path = "packages" -- directory where packages are stored
-- Splitting packages path to easier determine the name of current package later
local packages_path_modules = packages_path:split( "/" )
local packages_path_length = #packages_path_modules
-- Adds the packages into the lua search path, so that a package's content
-- can be required using it's name as if it was a lua module, ej:
-- require "lighttouch-libs.actions.create_key"
package.path = package.path..";./packages/?.lua"

local request_process_event = luvent.newEvent()
events["incoming_request_received"] = request_process_event
events["outgoing_response_about_to_be_sent"] = luvent.newEvent()
function request_process_action ()
    log.trace("\tNew request received") -- temporary it can be here
    local request = ctx.msg
    request.path_segments = request.path:split("/")
end
request_process_event:addAction(request_process_action)
request_process_event:setActionPriority(request_process_action, 100)


-- rule interpretter
for k, v in pairs(fs.directory_list(packages_path)) do
    local package_name = v:split( "/" )[packages_path_length+1] -- split package path in "/" places and get the last word 
    os.execute("mkdir -p tmp-lua/" .. package_name .. "/rules")
    local rule_files = fs.get_all_files_in(v .. "rules/") -- get all rules from this package
    
    for _, file_name in ipairs(rule_files) do
        if file_name ~= "lua_files/" then
            local rule_lua_path = "tmp-lua/" .. package_name .. "/" .. "rules/" .. file_name
            local rule_path = packages_path .. "/" .. package_name .. "/rules/" .. file_name
            log.trace("[Rule] Patching " .. ansicolors('%{underline}' .. file_name))

            local rule_yaml = ""
            local rule_yaml_table
            local line_num = 0
            for line in io.lines(rule_path) do
                line_num = line_num + 1        
                rule_yaml = rule_yaml .. line .. "\n" -- get only yaml lines
                if line_num == 1 then break end
            end

            rule_yaml_table = yaml.to_table(rule_yaml)

            -- rule priority cannot be higher than 100

            local priority = rule_yaml_table.priority or 1
            if priority > 100 then priority = 100 end

            --fs.copy(rule_path, rule_lua_path)
            local lua_rule = assert(io.open(rule_lua_path, "w+"))
            
            lua_rule:write("local log = require \"log\"\n")
            lua_rule:write("local priority = " .. priority)
            lua_rule:write("\nlocal function rule(request, events)\n\tlog.debug('[Rule] " .. ansicolors('%{underline}' .. file_name) .. " with priority " .. priority .. " starting to evaluate')")
            
            line_num = 0
            for line in io.lines(rule_path) do
                line_num = line_num + 1
                if line_num >= 2 then
                    lua_rule:write("\n\t" .. line)
                end
            end

            lua_rule:write("\n\tlog.debug('[Rule] " .. ansicolors('%{underline}' .. file_name) .. " evaluated succesfully')")
            lua_rule:write("\nend\nreturn{\n\trule = rule,\npriority = priority}") -- bottom rule function wrapper
            lua_rule:close()

            --fs.append_to_start(rule_lua_path, "local function rule(req, events)\n\tlog.trace('rule " .. file_name .. " starting to evaluate')") -- upper rule function wrapper

        end
    end
end
---

for k, v in pairs (fs.directory_list(packages_path)) do

    local package_name = v:split( "/" )[packages_path_length+1] -- split package path in "/" places and get the last word 

    log.trace("[Package] Patching actions for " .. ansicolors('%{underline}' .. package_name))

    local events_strings = { } -- events names table
    local event_count = 0
    -- read events file
    local events_file = fs.read_file(v .. "events.txt")

    -- put each line into a strings array
    for line in fs.read_lines(v .. "events.txt") do
        table.insert( events_strings, line )
    end
    
    -- count the lines
    
    for _ in pairs(events_strings) do
        event_count = event_count + 1
    end
    
    -- create events
    
    for i=1, event_count do
        local name = events_strings[i]
        local event = _G.events[name]
        if not event then
            event = luvent.newEvent()
            _G.events[name] = event
        end
        event:addAction(function ()
            log.debug("[Event] " .. ansicolors('%{underline}' .. name) .. " triggered")
        end)
    end
    
    -- read disabled actions
    local disabled_actions = { }
    for line in fs.read_lines(v .. "disabled_actions.txt") do
        table.insert( disabled_actions, line )
    end
    ---
    function isDisabled(action_file_name)
        for k, v in pairs(disabled_actions) do
            if action_file_name == v then 
                return true 
            end
        end
    
        return false
    end
    -- actions loader
    
    local action_files = fs.get_all_files_in(v .. "actions/")
    os.execute("mkdir -p tmp-lua/" .. package_name .. "/actions")
    for _, file_name in ipairs(action_files) do
        log.trace("[Action] Patching " .. ansicolors('%{underline}' .. file_name))
        local action_file = assert(io.open(packages_path .. "/" .. package_name .. "/actions/" .. file_name, "r")) -- open yaml / pseudo lua action ifle
        local action_yaml = ""
        local line_num = 0

        for line in io.lines(packages_path .. "/" .. package_name .. "/actions/" .. file_name) do
            line_num = line_num + 1        
            action_yaml = action_yaml .. line .. "\n" -- get only yaml lines
            if line_num == 2 then break end
        end
        action_yaml_table = yaml.to_table(action_yaml) -- decode yaml to lua table
        local action_lua_file = assert(io.open("tmp-lua/" .. package_name .. "/actions/" .. file_name, "w+")) -- w+ to override old files
        action_lua_file:write("local event = { \"" .. action_yaml_table.event[1] .. "\"") -- put values from yaml in lua form

        for _, yaml_event in ipairs(action_yaml_table.event) do
            if yaml_event ~= action_yaml_table.event[1] then 
                action_lua_file:write(', "' .. yaml_event .. '"') -- put all events to 'local event = { }'
            end
        end

        action_lua_file:write(" }")
        action_lua_file:write("\nlocal priority = " .. action_yaml_table.priority .. " \n\n")
        action_lua_file:write("local log = require \"log\"\n")
        action_lua_file:write("local function action(request)\n") -- function wrapper

        line_num = 0

        for line in io.lines(packages_path .. "/" .. package_name .. "/actions/" .. file_name) do
            line_num = line_num + 1
            if line_num > 2 then
                action_lua_file:write(line .. "\n\t")
            end
        end

        action_lua_file:write("\nend\n\nreturn{\n\tevent = event,\n\taction = action,\n\tpriority = priority\n}") -- ending return
        action_lua_file:close()

        local action_require_name = "tmp-lua." .. package_name .. ".actions." .. string.sub( file_name, 0, string.len( file_name ) - 4 )
        local action_require = require(action_require_name)
        
        for k, v in pairs(action_require.event) do
            local event = _G.events[v]
            if event then
                local action = event:addAction(
                    function(req)
                        log.debug("[Action] " .. ansicolors('%{underline}' .. file_name) .. " with priority " .. action_yaml_table.priority .. " is about to run")
                        -- TODO: figure out what to do if more than one responses are returned
                        possibleResponse = action_require.action(req)
                        if possibleResponse ~= nil then
                            if possibleResponse.body ~= nil then
                                _G.response = possibleResponse
                                if events["outgoing_response_about_to_be_sent"] then
                                    events["outgoing_response_about_to_be_sent"]:trigger()
                                end
                            end
                        end
                        log.debug("[Action] " .. ansicolors('%{underline}' .. file_name) .. " ran succesfully")
                    end
                )
                event:setActionPriority(action, action_require.priority)
                if isDisabled(file_name) then
                    event:disableAction(action)
                end
            else
                log.error("event " .. v .. " doesn't exist")
            end
        end 
    end

    log.trace("[Package] Finished patching actions for " .. ansicolors('%{underline}' .. package_name))
end

-- interpreted rules loading
for k, v in pairs(fs.directory_list(packages_path)) do
    local package_name = v:split( "/" )[packages_path_length+1] -- split package path in "/" places and get the last word 

    local rule_files = fs.get_all_files_in(v .. "rules/") -- get all rules from this package

    for _, file_name in ipairs(rule_files) do
        if file_name ~= "lua_files/" then

            local rule_require_name = "tmp-lua." .. package_name .. ".rules." .. string.sub(file_name, 0, string.len( file_name ) - 4)
            local rule_require = require(rule_require_name)
            log.debug("[Rule] Loading " .. ansicolors('%{underline}' .. rule_require_name))

            --table.insert(_G.rules, rule_require)
            _G.rules_priorities[rule_require_name] = rule_require.priority
        end
    end

end

for k,v in sorted_pairs(_G.rules_priorities, function(t,a,b) return t[b] < t[a] end) do
    table.insert(_G.rules, require(k))
end
--

