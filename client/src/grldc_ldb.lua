-- see copyright notice in grldc.h

local debug = require( "debug" )
local net = require( "grldc.net" )
local socket = require( "grldc.socket" )
local utilities = require( "grldc.utilities" )

local assert = assert
local print = print
local type = type
local debug = debug
local xpcall = xpcall
local pcall = pcall
local tostring = tostring
local string = string
local table = table
local unpack = unpack
local error = error
local setmetatable = setmetatable
local getmetatable = getmetatable
local coroutine = coroutine
local pairs = pairs
local ipairs = ipairs
local loadstring = loadstring
local originalCoroutineCreate = coroutine.create
local globals = _G
local getfenv = getfenv
local setfenv = setfenv
local findfenv = getfenv

-- luabind functions
local class_info = class_info

if getfenv == nil then
	-- lua 5.2: no get/set environment
	findfenv = function( f )
		local idx = 1
		while true do
			local name, value = debug.getupvalue( f, idx )
			if name == nil then break end
			--print( "\""..name.."\"" )
			if name == "_ENV" then return value end
			idx = idx + 1
		end
		return nil
	end
	
	getfenv = function( f )
		local env = findfenv( f )
		if env == nil then
			error( "Can't find function environment" )
		end
		return env
	end
	
	assert( setfenv == nil )
	setfenv = function( f, env )
		local idx = 1
		while true do
			local name, value = debug.getupvalue( f, idx )
			if name == nil then break end
			--print( "\""..name.."\"" )
			if name == "_ENV" then
				debug.setupvalue( f, idx, env )
				return
			end
			idx = idx + 1
		end
		error( "Can't find function environment" )
	end
end

module( "grldc" )

local server = nil
local status = "running"

local hookActiveCount = 0

local callstack
local coroutines = {}
setmetatable( coroutines, { __mode = "k" } )

local commands = {}
local runningCommands = {} -- commands that can be issued even when the debugged code is running

local breakPoints = {}
local breakPointAliases = {}

internal_.init( breakPointAliases )

local values = {}
local proxyMeta = {}

local envMeta = {}

local function releaseValue( id )
	--print( "Releasing value with ID "..id )
	assert( values[id] ~= nil )
	values[id] = nil
end

local function splitValue( value )
	local t = type( value )
	if t == "nil" then
		return { type = t, short = tostring( value ) }
	elseif t == "number" then
		return value
	elseif t == "string" then
		local maxStringLength = 48
		if #value > maxStringLength then
			local id = #values + 1 -- table 'values' can have holes, but this will always give a free id
			--print( "Created string value with ID "..id )
			values[id] = value
			return { type = t, short = "\""..string.sub( value, 1, maxStringLength-3 ).."\"...", id = id }
		else
			return value
		end
	elseif t == "boolean" then
		return value
	elseif t == "table" then
		local id = #values + 1 -- table 'values' can have holes, but this will always give a free id
		--print( "Created table value with ID "..id )
		values[id] = value
		local res = { type = t, short = tostring( value ), id = id }
		if getmetatable( value ) == proxyMeta then
			res.type = "proxy"
			res.short = value.short
		end
		return res
	elseif t == "function" then
		local id = #values + 1 -- table 'values' can have holes, but this will always give a free id
		--print( "Created function value with ID "..id )
		values[id] = value
		return { type = t, short = tostring( value ), id = id }
	elseif t == "thread" then
		return { type = t, short = tostring( value ) }
	elseif t == "userdata" then
		local m = getmetatable(value)
		if m and m.__luabind_class then
			local tostr = m.__tostring
			m.__tostring = nil -- temporarily disable tostring, so that we can get native lua info
			local ok, ptr = pcall(tostring,value)
			m.__tostring = tostr
			_, _, ptr = string.find( ptr, "userdata: (.+)" )
			local info = class_info( value )
			local id = #values + 1 -- table 'values' can have holes, but this will always give a free id
			values[id] = value
			return { type = t, short = "[luabind] "..info.name..": "..ptr, id = id }
		end
		return { type = t, short = tostring(value) }
	end
end

local function getValue( id )
	local value = assert( values[id], "No value associated to ID "..tostring(id) )
	local t = type( value )
	local res
	if t == "table" and getmetatable( value ) == proxyMeta then
		res = {}
		for _, entry in ipairs( value ) do
			table.insert( res, { name = entry.name, value = splitValue( entry.value ) } )
		end
	elseif t == "table" then
		res = {}
		local meta = getmetatable( value )
		if meta ~= nil then
			table.insert( res, { name = "<metatable>", value = splitValue( meta ) } )
		end
		for k, v in pairs( value ) do
			local key = splitValue(k)
			local val = splitValue(v)
			if type( key ) == "table" and key.id ~= nil then -- the key is a complex value
				local proxy = { { name = "<key>", value = k }, { name = "<value>", value = v } }
				if type( val ) == "table" then
					proxy.short = val.short
				else
					if type( val ) == "string" then
						proxy.short = "\""..val.."\""
					else
						proxy.short = tostring( val )
					end
				end
				setmetatable( proxy, proxyMeta )
				proxy = splitValue( proxy )
				table.insert( res, { name = "["..key.short.."]", value = proxy } )
				releaseValue( key.id )
				if type( val ) == "table" and val.id ~= nil then
					releaseValue( val.id )
				end
			else
				local name
				if type( key ) == "table" then
					name = "["..key.short.."]"
				else
					local simpleKey = false
					if type( key ) == "string" then
						simpleKey = (string.find( key, "^[%a_][%a%d_]*$" ) ~= nil)
					end
					if simpleKey then
						name = key
					else
						local keyStr = tostring( key )
						if type( key ) == "string" then
							keyStr = "\""..keyStr.."\""
						end
						name = "["..keyStr.."]"
					end
				end
				table.insert( res, { name = name, value = val } )
			end
		end
	elseif t == "function" then
		res = {}
		local upvaluesProxy = {}
		setmetatable( upvaluesProxy, proxyMeta )
		local upIdx = 1
		while true do
			local upName, upValue = debug.getupvalue( value, upIdx )
			if upName == nil then break end
			table.insert( upvaluesProxy, { name = upIdx..": "..upName, value = upValue } )
			upIdx = upIdx + 1
		end
		local info = debug.getinfo( value, "S" )
		table.insert( res, { name = "<what>", value = splitValue( info.what ) } )
		if string.sub( info.source, 1, 1 ) == "@" then
			table.insert( res, { name = "<source>", value = splitValue( info.source.."("..info.linedefined..")" ) } )
		else
			table.insert( res, { name = "<source>", value = splitValue( info.source ) } )
		end
		table.insert( res, { name = "<environment>", value = splitValue( findfenv( value ) ) } )
		table.insert( res, { name = "<upvalues>", value = splitValue( upvaluesProxy ) } )
	elseif t == "string" then
		res = { { name = "<value>", value = value } }
	elseif t == "userdata" then
		local m = getmetatable( value )
		if m and m.__luabind_class then
			local info = class_info( value )
			local res = {}
			table.insert( res, { name = "<class methods>", value = splitValue( info.methods ) } )
			for _, attrName in pairs( info.attributes ) do
				table.insert( res, { name = attrName, value = splitValue( value[attrName] ) } )
			end
			return res
		else
			error( "Unknown value type: "..t.." (value = "..tostring( value )..")" )
		end
	else
		error( "Unknown value type: "..t.." (value = "..tostring( value )..")" )
	end
	if res[1] == nil then
		res[1] = { name = "<empty>" }
	end
	return res
end

local function checkClosed( f, ... )
	local results = { xpcall( f, function( msg ) if msg == "closed" then return msg end return debug.traceback( msg ) end ) }
	if not results[1] then
		if results[2] == "closed" then
			print( "Connection with debugger lost" )
			server = nil
		else
			error( results[2], 0 )
		end
		return ...
	end
	return unpack( results, 2 )
end

local function synchronize()
	print( "sending synchronization request..." )
	server:send( "synchronize" )
	print( "receiving breakpoints..." )
	local numBreakpoints = server:receive()
	print( tostring(numBreakpoints).." breakpoint(s)" )
	assert( numBreakpoints == 0 ) -- not yet implemented
	local breakOnConnection = server:receive()
	return breakOnConnection
end

function updateRunningRequests_()
	while true do
		if server == nil then break end
		local command = server:tryReceive( "running" )
		if command == nil then break end
		local func = runningCommands[command]
		assert( func ~= nil, "Unknown running command: "..tostring( command ) )
		local ok, msg = xpcall( func, debug.traceback )
		if not ok then
			print( "Error processing running command "..command..": "..tostring( msg ) )
		end
	end
end

function registerSourceFile_( fileName )
	local nsource = "@"..utilities.normalizePath( string.sub( fileName, 2 ) )
	s = breakPoints[nsource]
	if s == nil then
		s = {}
		breakPoints[nsource] = s
	end
	breakPointAliases[fileName] = s
	return s
end

local function getinfo( thread, level, what )
	if type(level) ~= "function" then
		level = level + 1 -- do not count ourself
	end
	if thread == nil then
		thread = getmainthread()
	end
	return debug.getinfo( thread, level, what )
end

local function getlocal( thread, level, idx )
	level = level + 1 -- do not count ourself
	if thread == nil then
		thread = getmainthread()
	end
	return debug.getlocal( thread, level, idx )
end

local function setlocal( thread, level, idx, value )
	level = level + 1 -- do not count ourself
	if thread == nil then
		thread = getmainthread()
	end
	return debug.setlocal( thread, level, idx, value )
end

function getAppLevel_( thread, fromLevel )
	-- find where the application code starts in the callstack (we want to ignore grldc functions)
	local level = (fromLevel or 1) + 1
	local appLevel
	local grldcFunction = { [breakNow] = true, [connect] = true, [globals.coroutine.create] = true, [updateRunningRequests_] = true }
	--[[print( "GRLDC functions:" )
	for f in pairs( grldcFunction ) do
		print( "\t"..tostring(f).." ("..tostring(getinfo(thread,f,"nf").name)..")" )
	end
	print( "Current stack:" )]]
	while true do
		local info = getinfo( thread, level, "f" )
		if info == nil then break end
		--print( "\t"..level.." "..tostring(info.func).." ("..tostring(info.name)..")" )
		if grldcFunction[info.func] then appLevel = level end -- actual appLevel is level + 1, but we don't count ourself
		level = level + 1
	end
	return appLevel
end

local function getCallstack( thread )
	local appLevel = getAppLevel_( thread )
	if appLevel == nil then appLevel = 0 end

	local callstack = {}
	local level = appLevel
	while true do
		local info = getinfo( thread, level, "nSl" )
		if info == nil then break end
		level = level + 1
		local data =
		{
			name = info.name,
			namewhat = info.namewhat,
			what = info.what,
			source = info.source,
			line = info.currentline,
		}
		table.insert( callstack, data )
	end
	return callstack
end

local function setHook()
	hookActiveCount = hookActiveCount + 1
	if hookActiveCount == 1 then
		internal_.setHookActive( true )
	end
end

local function removeHook()
	hookActiveCount = hookActiveCount - 1
	if hookActiveCount == 0 then
		internal_.setHookActive( false )
	end
	--debug.sethook( nil )
end

function suspendHook()
	removeHook()
end

function resumeHook()
	setHook()
end

local function registerCoroutine( co )
	--debug.sethook( co, hook, "crl" )
	internal_.setHook( co )
	coroutines[co] = {}
end

globals.coroutine.create = function( f )
	local co = originalCoroutineCreate( f )
	registerCoroutine( co )
	return co
end

local function setBreakPoint( source, line, value )
	assert( string.sub( source, 1, 1 ) == "@" )
	local nsource = "@"..utilities.normalizePath( string.sub( source, 2 ) )
	assert( nsource == source, "Source must be normalized before setting a breakpoint, but source "..source.." is not normalized to "..nsource )
	print( "Setting breakpoint at "..source.."("..line..") to "..tostring( value ) )
	local s = breakPoints[source]
	if s == nil then s = {} breakPoints[source] = s end
	if value then
		s[line] = true
	else
		s[line] = nil
	end
end

function connect( address, port, name, maxRetry )
	local retryCount = maxRetry
    assert( name ~= nil )
    assert( server == nil, "Already connected" )
    print( "grldc: connecting to GRLD server..." )
    while true do
        local ok, msg = pcall( function()
            server = net.connect( address, port )
        end )
        if ok then break end
        if not ok and msg ~= "connection refused" then
            error( msg )
        end
        if maxRetry ~= nil then
            retryCount = retryCount - 1
            if retryCount < 0 then
				print( "grldc: can't connect to GRLD server after "..(maxRetry+1).." attempt(s) ; debugging disabled" )
                return false
            end
        end
    end
    print( "grldc module connected to the GRLD server" )
    checkClosed( function()
        print( "sending client name..." )
        server:send( name )
        print( "synchronizing with server..." )
		local breakOnConnection = synchronize()
		local co, mainthread = coroutine.running()
		assert( co == nil or mainthread, "Connection to the debugger must be done from the main thread" )
		if mainthread then
			-- lua 5.2: we can access the main thread directly
			getmainthread = function() return co end
		end
        print( "setting debug hook..." )
        internal_.setHook( getmainthread() )
        print( "hook set" )
        setHook()
        if breakOnConnection then
            breakNow()
        end
    end )
    return true
end

local function breakNowImpl()
	assert( status == "running" )
	status = "break"
	internal_.setStepMode( 0, nil )
	server:send( "break" )
	--assert( server:receive() == "ack_break" )
	
	callstack = getCallstack( coroutine.running() )
	
	server:send( callstack[1].source )
	server:send( callstack[1].line )
	while status == "break" do
		--print( "waiting data..." )
		server:waitData()
		--print( "received data" )
		updateRunningRequests_()
		local command = server:tryReceive()
		if command ~= nil then
			assert( commands[command] ~= nil, "Received unknown command: "..tostring(command) )
			commands[command]()
		end
	end
	
	callstack = nil
end

local function getCoroutineId( co )
	if co == nil then
		return "main"
	else
		local _, _, id = string.find( tostring( co ), "thread: (.*)" )
		assert( id ~= nil )
		return id
	end
end

local function getCoroutineFromId( id )
	if id == "current" then
		return coroutine.running()
	else
		local co = nil
		if id ~= "main" then
			for c, info in pairs( coroutines ) do
				if coroutine.status( c ) ~= "dead" and id == getCoroutineId( c ) then
					co = c
					break
				end
			end
			if co == nil then
				return "no such coroutine"
			end
		end
		return co
	end
end

function commands.run()
	--server:send( "ack_run" )
	status = "running"
	--assert( stepMode == nil )
end

function commands.stepover()
	--server:send( "ack_stepover" )
	status = "running"
	internal_.setStepMode( 2, coroutine.running() or getmainthread() )
end

function commands.stepin()
	--server:send( "ack_stepin" )
	status = "running"
	internal_.setStepMode( 1, nil )
end

function commands.stepout()
	--server:send( "ack_stepout" )
	status = "running"
	internal_.setStepMode( 3, coroutine.running() or getmainthread() )
end

function commands.callstack()
	local thread = server:receive()
	if thread == "current" then
		server:send( callstack )
	else
		local co = getCoroutineFromId( thread )
		if type( co ) ~= "string" then
			server:send( getCallstack( co ) )
		else
			server:send( co )
		end
	end
end

function commands.coroutines()
	local res = {}
	for co, info in pairs( coroutines ) do
		if coroutine.status( co ) ~= "dead" then
			local id = getCoroutineId( co )
			table.insert( res, { id = id } )
		end
	end
	server:send( res )
end

function commands.currentthread()
	server:send( getCoroutineId( coroutine.running() ) )
end

function commands.breakpoints()
	server:send( breakPoints )
end

function commands.locals()
	local res = {}
	local thread = server:receive()
	local level = server:receive()
	local co = getCoroutineFromId( thread )
	if type( co ) ~= "string" then
		local idx = 1
		local appLevel = getAppLevel_( co, 1 )
		if appLevel == nil then
			appLevel = 0
		end
		level = level + appLevel - 1
		while true do
			local name, value = getlocal( co, level, idx )
			if name == nil then break end
			if name ~= "(*temporary)" then
				table.insert( res, { name = name, value = splitValue( value ) } )
			end
			idx = idx + 1
		end
		server:send( res )
	else
		server:send( "no such coroutine" )
	end
end

function commands.upvalues()
	local res = {}
	local thread = server:receive()
	local level = server:receive()
	local co = getCoroutineFromId( thread )
	if type( co ) ~= "string" then
		local idx = 1
		local appLevel = getAppLevel_( co, 1 )
		if appLevel == nil then
			appLevel = 0
		end
		level = level + appLevel - 1
		local info = getinfo( co, level, "f" )
		while true do
			local name, value = debug.getupvalue( info.func, idx )
			if name == nil then break end
			table.insert( res, { name = name, value = splitValue( value ) } )
			idx = idx + 1
		end
		server:send( res )
	else
		server:send( "no such coroutine" )
	end
end

function commands.evaluate()
	local expr = server:receive()
	local thread = server:receive()
	local level = server:receive()
	local co = getCoroutineFromId( thread )
	if type( co ) ~= "string" then
		if string.sub( expr, 1, 1 ) == "=" then
			expr = "return "..string.sub( expr, 2 )
		end
		local ok, results = pcall( function()
			local f = assert( loadstring( expr ) )
			
			local appLevel = getAppLevel_( co, 1 )
			if appLevel == nil then
				appLevel = 0
			end
			local orgLevel = level
			level = level + appLevel - 1
			local info = getinfo( co, level, "f" )
			
			local upvalues = {}
			local idx = 1
			while true do
				local name, value = debug.getupvalue( info.func, idx )
				if name == nil then break end
				upvalues[name] = idx
				idx = idx + 1
			end
			
			local locals = {}
			idx = 1
			while true do
				local name, value = getlocal( co, level, idx )
				if name == nil then break end
				locals[name] = idx
				idx = idx + 1
			end
			
			local env = setmetatable( { func = info.func, thread = co, level = orgLevel, locals = locals, upvalues = upvalues, environment = getfenv( info.func ) }, envMeta )
			setfenv( f, env )
			return { f() }
		end )
		if ok then
			local res = {}
			local lastResult = 0 -- TODO : check if there is a way to know the actual number of results, even if the last ones are nil values
			for idx, value in pairs( results ) do
				if idx > lastResult then lastResult = idx end
				res[idx] = { name = "result #"..tostring(idx), value = splitValue( value ) }
			end
			for idx = 1, lastResult - 1 do
				if res[idx] == nil then
					res[idx] = { name = "result #"..tostring(idx), value = splitValue( nil ) }
				end
			end
			if res[1] == nil then
				res[1] = { name = "<no result>" }
			end
			server:send( res )
		else
			server:send( { { name = "<error>", value = splitValue( results ) } } )
		end
	else
		server:send( { { name = "<error>", value = "no such coroutine" } } )
	end
end

envMeta.__index = function( self, key )
	if key == "__globals__" then
		return globals
	elseif key == "_G" then
		return self
	end
	
	local lv = self.locals[key]
	if lv ~= nil then
		local appLevel = getAppLevel_( self.thread, 1 )
		if appLevel == nil then
			appLevel = 0
		end
		level = self.level + appLevel - 1
		local k, v = getlocal( self.thread, level, lv )
		return v
	end
	
	local uv = self.upvalues[key]
	if uv ~= nil then
		local k, v = debug.getupvalue( self.func, uv )
		return v
	end
	
	return self.environment[key]
end

envMeta.__newindex = function( self, key, value )
	if key == "__globals__" then
		globals[key] = value
		return
	elseif key == "_G" then
		error( "Can't override _G when remotely evaluating an expression" )
	end
	
	local lv = self.locals[key]
	if lv ~= nil then
		local appLevel = getAppLevel_( self.thread, 1 )
		if appLevel == nil then
			appLevel = 0
		end
		level = self.level + appLevel - 1
		setlocal( self.thread, level, lv, value )
		return
	end
	
	local uv = self.upvalues[key]
	if uv ~= nil then
		debug.setupvalue( self.func, uv, value )
		return
	end
	
	self.environment[key] = value
end

function commands.getValue()
	local id = server:receive()
	server:send( getValue( id ) )
end

function runningCommands.releaseValue()
	local id = server:receive( "running" )
	releaseValue( id )
end

runningCommands["break"] = function()
	if status == "running" then
		breakNow()
	else
		print( "Break command ignored: already breaked" )
	end
end

runningCommands.setbreakpoint = function()
	local data = server:receive( "running" )
	setBreakPoint( data.source, data.line, data.value )
end

function breakNow()
	removeHook()
	print( "Breaking execution..." )
	while true do
		if server == nil then
			print( "Can't break execution: not connected to a debugger" )
			return
		end
		local ok, msg = xpcall( breakNowImpl,
			function( msg )
				if msg == "closed" then return msg end
				return debug.traceback( msg )
			end
		)
		if ok then
			break
		else
			if msg == "closed" then
				print( "Connection with debugger lost" )
				server = nil
				break
			else
				print( "Error during break: "..msg )
			end
		end
		socket.sleep( 0.1 )
		status = "running"
	end
	print( "Resuming execution..." )
	internal_.setStepDepth( 0 )
	setHook()
end
