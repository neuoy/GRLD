-- see copyright notice in wxLdb.lua

local grldc =
{
	net = require( "grldc.net" ),
	utilities = require( "grldc.utilities" )
}
local ui =
{
	mainWindow = require( "ui.mainWindow" )
}
local lfs = require( "lfs" )

local wx = require( "wx" )

require( "coxpcall" )
local coxpcall = coxpcall
local copcall = copcall

local setmetatable = setmetatable
local ipairs = ipairs
local type = type
local assert = assert
local pairs = pairs
local next = next
local print = print
local tostring = tostring
local string = string
local coroutine = coroutine
local io = io
local debug = debug
local xpcall = xpcall
local table = table
local os = os

module( "wxLdbController" )

local meta = { __index = {} }

local complexValueManagerMeta = { __index = {} }

local function createClientConfig(name)
	return {
		name = name,
		mappings = {},
		breakpoints = {},
		scrollPositions = {},
	}
end

function new( engine, window )
	local res =
	{
		engine = engine,
		window = window,
		clients = {},
		configs = {},
		activeClient = nil,
		threadsDirty = true,
		exiting = false,
		requests_ = {},
		toListen = {},
	}
	setmetatable( res, meta )
	res.runCoroutine = coroutine.create( function() res:run_() end )
	local ok, msg = coroutine.resume( res.runCoroutine )
	assert( ok, debug.traceback( res.runCoroutine, msg ) )
	return res
end

function meta.__index:ready_()
	return self.sleeping and #self.requests_ == 0
end

function meta.__index:addListener( ip, port )
	if self.engine.initialized() then
		self.engine.listen( ip, port )
	else
		table.insert( self.toListen, { ip = ip, port = port } )
	end
end

function meta.__index:update()
	if self:ready_() then
		self.sleeping = false
		local ok, msg = coroutine.resume( self.runCoroutine )
		assert( ok, debug.traceback( self.runCoroutine, msg ) )
	elseif self.currentRequest_ ~= nil then
		if coroutine.status( self.currentRequest_ ) ~= "suspended" then
			print( "Asynchronous request has terminated" )
			table.remove( self.requests_, 1 )
			self.currentRequest_ = nil
		end
	elseif self.requests_[1] ~= nil then
		print( "Starting asynchronous request..." )
		local req = self.requests_[1]
		local co = coroutine.create( req )
		self.currentRequest_ = co
		local ok, msg = coroutine.resume( co )
		assert( ok, debug.traceback( co, msg ) )
	end
end

function meta.__index:sleep_()
	self.sleeping = true
	coroutine.yield()
end

function meta.__index:queueRequest_( req )
	table.insert( self.requests_, req )
end

function meta.__index:run_()
	self:sleep_()

--@GRLD_PROTECTION@

	self.engine.init()
	for _, listener in ipairs( self.toListen ) do
		self.engine.listen( listener.ip, listener.port )
	end
	self.toListen = {}
	self.window:show( true )

	for _, cbName in ipairs( { "onNewClient", "onClientBreak", "onClientLost" } ) do
		self.engine.registerEvent( cbName, function( ... ) return self[cbName.."_"]( self, ... ) end )
	end

	local wrapCb = function( cb )
		return function( ... )
			if self:ready_() then
				return cb( ... )
			end
		end
	end

	self.window:registerEvent( ui.mainWindow.ID_BREAK, wrapCb( function() self:onDebugCommand_( "breaknow", "running" ) end ) )
	self.window:registerEvent( ui.mainWindow.ID_CONTINUE, wrapCb( function() self:onDebugCommand_( "run", "break" ) end ) )
	self.window:registerEvent( ui.mainWindow.ID_STEP_OVER, wrapCb( function() self:onDebugCommand_( "stepover", "break" ) end ) )
	self.window:registerEvent( ui.mainWindow.ID_STEP_INTO, wrapCb( function() self:onDebugCommand_( "stepin", "break" ) end ) )
	self.window:registerEvent( ui.mainWindow.ID_STEP_OUT, wrapCb( function() self:onDebugCommand_( "stepout", "break" ) end ) )
	self.window:registerEvent( ui.mainWindow.ID_TOGGLE_BREAKPOINT, wrapCb( function() self:onToggleBreakpoint_() end ) )

	self.window:registerEvent( "onBreakPointChanged", wrapCb( function( ... ) self:onBreakPointChanged_( ... ) end ) )
	self.window:registerEvent( "onFileOpen", wrapCb( function( ... ) self:onFileOpen_( ... ) end ) )
	self.window:registerEvent( "onFileClosed", wrapCb( function( ... ) self:onFileClosed_( ... ) end ) )
	self.window:registerEvent( "onScrollChanged", wrapCb(function( ... ) self:onScrollChanged_( ...) end ) )

	self.window:registerEvent( "onApplicationExiting", wrapCb( function( ... ) self:onApplicationExiting_( ... ) end ) )

	self.window.threads:registerEvent( "onThreadClicked", wrapCb( function( ... ) self:onThreadClicked_( ... ) end ) )
	self.window.threads:registerEvent( "onBreakOnConnectionChanged", wrapCb( function( ... ) self:onBreakOnConnectionChanged_( ... ) end ) )

	self.window.callstack:registerEvent( "onCallstackClicked", wrapCb( function( ... ) self:onCallstackClicked_( ... ) end ) )

	self.window.watch.evaluateCallback = wrapCb( function( expr ) return self:evaluateExpression_( expr ) end )

	self.configs.global = createClientConfig('global')
	self:loadConfig_( "global" )

	self:sleep_()
	while not self.exiting do
		for clientId, clientData in pairs( self.clients ) do
			coxpcall( function()
			if clientData.invalidateTimer ~= nil then
				if os.time() >= clientData.invalidateTimer then
					clientData.invalidateTimer = nil
					assert( clientId == self.activeClient )
					self:invalidateState_( true )
				end
			end
			if clientData.config.dirty and os.time() >= (clientData.config.lastConfigSave or 0) + 10 then
				self:saveConfig_( clientData.config.name )
			end
			if clientData.dirty then
				self.window:setActive()
				clientData.dirty = false
				local client = self.engine.getClient( clientId )
				if client == nil then
					self.threadsDirty = true
				elseif clientId == self.activeClient then
					if client:status() == "break" then
						client:setactivethread( clientData.activeThread )
						self.threadsDirty = true
						local callstack = client:callstack()
						if type( callstack ) ~= "table" then
							-- if we can not get the callstack, we try to switch to the current thread
							clientData.activeThread = "current"
							client:setactivethread( clientData.activeThread )
							callstack = client:callstack()
						end
						self:refreshCallstack_( callstack )
						self:refreshSourceFocus_( callstack, clientData.activeLevel )
					end
					self:refreshBreakPoints_()
				end
			elseif clientData.lastUpdate == nil or os.time() > clientData.lastUpdate + 2 then
				clientData.lastUpdate = os.time()
				self.engine.getClient( clientId ):checkConnection()
			end
			end, function( msg ) print( "Error refreshing client "..clientId ) print( msg ) print( debug.traceback() ) end )
		end

		if self.threadsDirty then
			coxpcall( function()
			self.threadsDirty = false
			self:refreshThreads_()
			end, function( msg ) print( "Error refreshing threads" ) print( msg ) print( debug.traceback() ) end )
		end

		self:sleep_()
	end
end

function meta.__index:getActiveClientConfig_()
	local activeClientId = self.activeClient

	if activeClientId == nil then
		return self.configs.global
	end

	local clientData = self.clients[activeClientId]

	if clientData == nil then
		return self.configs.global
	end

	return clientData.config
end

function meta.__index:evaluateExpression_( expr )
	local clientId = self.activeClient
	local client = self.engine.getClient( clientId )
	if client == nil then return { { name = "<no such client>" } } end
	if client:status() == "running" then return { { name = "<can't evaluate expression while client is running>" } } end
	local clientData = assert( self.clients[clientId] )
	local results = client:evaluate( expr, clientData.activeLevel )
	complexValueManagerMeta.init( results, self.engine, clientId )
	return results
end

function meta.__index:onCallstackClicked_( level )
	local clientId = self.activeClient
	local clientData = self.clients[clientId]
	if clientData == nil then return end
	clientData.activeLevel = level
	clientData.dirty = true
end

function meta.__index:refreshSourcePageFocus_( remoteSource, line )
	local clientId = self.activeClient
	local clientData = assert( self.clients[clientId] )
	local sourceType = string.sub( remoteSource, 1, 1 )
	if sourceType == "@" then
		self.window:raise()
		print( "Setting focus to "..remoteSource.."("..line..")" )
		remoteSource = grldc.utilities.normalizePath( string.sub( remoteSource, 2 ) )
		local source, remotePath, remoteFile = self:getLocalSource_( clientId, remoteSource )
		if source == nil then
			print( "Prompting mount path..." )
			local mount, path = self.window:promptMountPath( remotePath, nil, remoteFile )
			print( mount, path )
			if mount ~= nil then
				mount = grldc.utilities.normalizePath( mount )
				path = grldc.utilities.normalizePath( path, lfs.currentdir() )
				print( mount, path )
				local mountEnd = string.sub( mount, -1 )
				if mountEnd ~= "/" and mountEnd ~= "\\" then
					mount = mount.."/"
				end
				print( mount, path )
				clientData.config.mappings[mount] = path
				clientData.config.dirty = true
				source = self:getLocalSource_( clientId, remoteSource )
				assert( source ~= nil )
			end
		end

		if source ~= nil then
			print( source )
			source = grldc.utilities.normalizePath( source )
			self:setSourceFocus_( "@"..source, line )
		end

		--print( source )
		return source
	end
end

function meta.__index:refreshSourceFocus_( callstack, level )
	local clientId = self.activeClient
	local clientData = assert( self.clients[clientId] )
	if type( callstack ) == "table" and callstack[level] ~= nil then
		local remoteSource = callstack[level].source
		local line = callstack[level].line

		local source = self:refreshSourcePageFocus_( remoteSource, line )

		self:setPointers_( level, source, line )
		self:refreshPointers_()

		self:refreshWatches_( level )
	end
end

function meta.__index:setPointers_( level, source, line )
	self.pointer = { level = level, source = source, line = line }
end

function meta.__index:refreshPointers_()
	self.window:clearMarkers()
	if self.pointer ~= nil then
		local source = self.pointer.source
		local level = self.pointer.level
		local line = self.pointer.line
		if source ~= nil then
			if level == 1 then
				self.window:setCurrentLine( "@"..source, line )
			else
				self.window:getSourcePage( "@"..source ):addOtherLine( line )
			end
		end
	end
end

function meta.__index:refreshWatches_( level )
	local clientId = self.activeClient
	local client = self.engine.getClient( clientId )
	if client == nil then return end
	local autoVariables = {}
	local locals = client:locals( level )
	if type( locals ) == "string" then
		self.window.auto:setData( { { name = "<error evaluating local variables>", value = locals } } )
	else
		for _, entry in ipairs( locals ) do
			table.insert( autoVariables, { name = "[local] "..entry.name, value = entry.value } )
		end
	end
	local upvalues = client:upvalues( level )
	if type( upvalues ) == "string" then
		self.window.auto:setData( { { name = "<error evaluating upvalues>", value = locals } } )
	else
		for _, entry in ipairs( upvalues ) do
			table.insert( autoVariables, { name = "[upvalue] "..entry.name, value = entry.value } )
		end
	end
	complexValueManagerMeta.init( autoVariables, self.engine, clientId )
	self.window.auto:setData( autoVariables )
	self.window.watch:refresh()
end

function meta.__index:onToggleBreakpoint_()
	local source, line = self.window:findSourcePageFocus()
	self:onBreakPointChanged_( source, line )
end

function meta.__index:onBreakPointChanged_( source, line )
	local clientId = self.activeClient
	local config = nil
	if clientId == nil or self.clients[clientId] == nil then
		config = self.configs.global
	else
		local clientData = self.clients[clientId]
		if clientData == nil then return end

		config = clientData.config
	end

	if config.breakpoints[source] == nil then
		config.breakpoints[source] = {}
	end
	config.breakpoints[source][line] = not config.breakpoints[source][line]
	newValue = config.breakpoints[source][line]
	if not newValue then
		config.breakpoints[source][line] = nil
	end

	print( "Setting breakpoint at "..source.."("..line..") to "..tostring(newValue) )

	assert( string.sub( source, 1, 1 ) == "@" )
	source = string.sub( source, 2 )
	for clientId, clientData in pairs( self.clients ) do
		if clientData.config == config then
			local client = self.engine.getClient( clientId )
			if client == nil then return end
			local remoteSource, dir = self:getRemoteSource_( clientId, source )
			self:queueRequest_( function()
				if remoteSource == nil then
					print( "Can't find remote source corresponding to "..source )
					print( "Prompting mount path..." )
					local mount, path = self.window:promptMountPath( nil, dir )
					print( mount, path )
					if mount ~= nil then
						mount = grldc.utilities.normalizePath( mount )
						path = grldc.utilities.normalizePath( path, lfs.currentdir() )
						print( mount, path )
						local mountEnd = string.sub( mount, -1 )
						if mountEnd ~= "/" and mountEnd ~= "\\" then
							mount = mount.."/"
						end
						print( mount, path )
						clientData.config.mappings[mount] = path
						remoteSource, dir = self:getRemoteSource_( clientId, source )
						assert( remoteSource ~= nil )
					end
				end

				if remoteSource ~= nil then
					client:setbreakpoint( "@"..remoteSource, line, newValue )
					clientData.config.dirty = true
				end
				self:refreshBreakPoints_()
			end )
		end
	end
	self:refreshBreakPoints_()
end

function meta.__index:onApplicationExiting_()
	for id, clientData in pairs( self.clients ) do
		if clientData.config.dirty then
			self:saveConfig_( clientData.config.name )
		end
	end
	self.window.threads:setData( nil )
end

function meta.__index:refreshScrollPosition_()
	local config = self:getActiveClientConfig_()

	for source, sp in pairs( config.scrollPositions ) do
		local page = self.window:getSourcePage( source )
		if page ~= nil then
			page:SetScrollPos(sp)
		end
	end	
end

function meta.__index:refreshBreakPoints_()
	local clientId = self.activeClient
	local config = nil
	local client = nil
	if self.activeClient == nil or self.clients[clientId] == nil then
		config = self.configs.global
	else
		config = self.clients[clientId].config
		client = self.engine.getClient( clientId )
	end

	local remoteBreakPoints = {}
	if client ~= nil then
		remoteBreakPoints = client:breakpoints()
	end
	self.window:clearBreakPoints()
	local goodBreakpoints = {}

	for remoteSource, lines in pairs( remoteBreakPoints ) do
		if next( lines ) ~= nil then
			local source = self:getLocalSource_( clientId, string.sub( remoteSource, 2 ) )
			if source ~= nil then
				local page = self.window:findSourcePage( "@"..source )
				if page ~= nil then
					if goodBreakpoints["@"..source] == nil then
						goodBreakpoints["@"..source] = {}
					end
					for line, value in pairs( lines ) do
						if value then
							page:addBreakPoint( line )
							goodBreakpoints["@"..source][line] = true
						end
					end
				else
					print( "Can't find source page for breakpoint in file "..source )
				end
			else
				print( "Can't find source corresponding to remote source "..remoteSource )
			end
		end
	end

	for source, lines in pairs( config.breakpoints ) do
		local page = self.window:findSourcePage( source )
		if page ~= nil then
			for line, value in pairs( lines ) do
				if value then
					if goodBreakpoints[source] == nil or not goodBreakpoints[source][line] then
						page:addBreakPoint( line, true )
					end
				end
			end
		end
	end
end

function meta.__index:onFileOpen_( path )
	print( "onFileOpen: "..path )
	source = "@"..grldc.utilities.normalizePath( path )
	print( "normalized path: "..source )
	self:setSourceFocus_( source, 1 )
	self:refreshPointers_()
	self:refreshBreakPoints_()
	self:refreshScrollPosition_()
end

function meta.__index:onFileClosed_( source )
	for id, clientData in pairs( self.clients ) do
		clientData.config.dirty = true
	end
end

function meta.__index:onScrollChanged_( source, position )
	local clientConfig = self:getActiveClientConfig_()
	clientConfig.scrollPositions[source] = position
	clientConfig.dirty = true
end

function meta.__index:onThreadClicked_( clientId, threadId )
	print( "Thread clicked: client="..clientId..", thread="..threadId )
	local clientData = self.clients[clientId]
	if clientData == nil then return end
	clientData.activeThread = threadId
	clientData.activeLevel = 1
	self:setActiveClient_( clientId )
end

function meta.__index:onBreakOnConnectionChanged_( clientId, newValue )
	local clientData = self.clients[clientId]
	if clientData == nil then return end
	clientData.config.breakOnConnection = newValue
	clientData.config.dirty = true
end

function meta.__index:onDebugCommand_( command, neededState, targetClientId )
	if targetClientId == nil then targetClientId = self.activeClient end
	if targetClientId == nil then return end
	local client = self.engine.getClient( targetClientId )
	if client == nil then
		print( "No client "..targetClientId )
		return
	end
	if neededState ~= nil and client:status() ~= neededState then return end

	self:invalidateState_( false )

	local clientData = assert( self.clients[targetClientId] )
	local ok, msg = xpcall( function() client[command]( client ) end, debug.traceback )
	if not ok then
		print( msg )
	end
	clientData.dirty = true
end

function meta.__index:invalidateState_( immediate )
	local clientData = self.clients[self.activeClient]
	if not clientData or immediate then
		if clientData ~= nil then
			clientData.invalidateTimer = nil
		end
		self.threadsDirty = true
		self.pointer = nil
		self.window:clearMarkers()
		self.window.callstack:setData( nil )
		self:refreshBreakPoints_()

		local client = self.engine.getClient( self.activeClient )
		if client == nil then
			self.window.auto:clear()
			self.window.watch:refresh()
		else
			self.window.auto:setData( nil )
			self.window.watch:refresh()
		end
	else
		clientData.invalidateTimer = os.time() + 1
	end
end

function meta.__index:getLocalSource_( clientId, source )
	--print( source )
	local _, _, dir, file = string.find( source, "(.*[/\\])(.*)" )
	assert( dir ~= nil and file ~= nil )
	local clientData = assert( self.clients[clientId] )
	for mount, path in pairs( clientData.config.mappings ) do
		if string.sub( dir, 1, #mount ) == mount then
			local s = string.sub( dir, #mount, #mount )
			assert( s == "/" or s == "\\" )
			local r = string.sub( dir, #mount + 1 )
			if r ~= "" then r = r.."/" end
			local localPath = grldc.utilities.normalizePath( path.."/"..r..file, lfs.currentdir() )
			--print( localPath )
			if lfs.attributes( localPath, "mode" ) == "file" then
				return localPath, dir, file
			end
		end
	end
	return nil, dir, file
end

function meta.__index:getRemoteSource_( clientId, localSource )
	print( "Searching remote source corresponding to local source "..localSource )
	local _, _, dir, file = string.find( localSource, "(.*[/\\])(.*)" )
	assert( dir ~= nil and file ~= nil )
	local clientData = assert( self.clients[clientId] )
	local bestScore = -1
	local bestPath = nil
	for mount, path in pairs( clientData.config.mappings ) do
		if string.sub( dir, 1, #path ) == path then
			local s = string.sub( dir, #path+1, #path+1 )
			if s == "/" or s == "\\" then
				local r = string.sub( dir, #path + 2 )
				if r ~= "" then r = r.."/" end
				local remotePath = grldc.utilities.normalizePath( mount..r..file )
				local score = 0
				string.gsub( mount, "[/\\]", function() score = score + 1 end )
				print( "Candidate (score="..score..") : "..remotePath )
				if score > bestScore then
					bestScore = score
					bestPath = remotePath
				end
			end
		end
	end
	return bestPath, dir
end

function meta.__index:setSourceFocus_( source, line )
	local exist = (self.window:findSourcePage( source ) ~= nil)
	local page = self.window:getSourcePage( source )
	page:setFocus( line )
	self.window:setSourcePageFocus( source )
	if not exist then
		for id, clientData in pairs( self.clients ) do
			clientData.config.dirty = true
		end
	end
end

function meta.__index:refreshCallstack_( callstack )
	if type( callstack ) == "string" then
		self.window.callstack:setData( { { name = callstack, type = "", source = "", line = "" } } )
	elseif callstack[1] == nil then
		self.window.callstack:setData( { { name = "empty callstack", type = "", source = "", line = "" } } )
	else
		local callstackData = {}
		for level, data in ipairs( callstack ) do
			local entry = {}
			if data.namewhat ~= "" then
				assert( data.name ~= nil )
				entry.name = "["..data.namewhat.."] "..data.name
			else
				entry.name = "???"
			end
			entry.type = data.what
			entry.source = data.source
			if data.line < 0 then
				entry.line = ""
			else
				entry.line = tostring( data.line )
			end
			callstackData[level] = entry
		end
		self.window.callstack:setData( callstackData )
	end
end

function meta.__index:refreshThreads_()
	local data = {}
	for clientId, clientData in pairs( self.clients ) do
		local client = self.engine.getClient( clientId )
		if client == nil then
			print( "Client does not exist anymore: "..clientId )
			if self.activeClient == clientId then
				self.activeClient = nil
				self:invalidateState_( true )
			end
			self.clients[clientId] = nil
		else
			local cdata = {}
			cdata.name = client:name()
			cdata.ip = client:ip()
			cdata.clientId = client.clientId
			cdata.coroutines = {}
			cdata.status = client:status()
			cdata.active = (clientId == self.activeClient)
			cdata.breakOnConnection = clientData.config.breakOnConnection

			if cdata.status == "break" then
				local current = client:getcurrentthread()
				local active = client:getactivethread()
				if active == "current" then
					active = current
				end
				table.insert( cdata.coroutines, { id = "main", current = (current == "main"), active = (active=="main" and cdata.clientId == self.activeClient and client:getactivethread() ~= "current") } )

				local coroutines = client:coroutines()
				--print( coroutines )
				for _, data in ipairs( coroutines ) do
					local codata = {}
					codata.id = data.id
					codata.current = (current == codata.id)
					codata.active = (active == codata.id and cdata.clientId == self.activeClient and client:getactivethread() ~= "current")
					table.insert( cdata.coroutines, codata )
				end
			end

			table.insert( data, cdata )
		end
	end
	self.window.threads:setData( data )
end

function meta.__index:setActiveClient_( clientId )
	self:invalidateState_( true )
	self.activeClient = clientId
	self.clients[clientId].dirty = true
	self.threadsDirty = true
	local clientConfig = self.clients[clientId].config
	for source, lines in pairs( self.configs.global.breakpoints ) do
		for line, _ in pairs( lines ) do
			if clientConfig.breakpoints[source] == nil or not clientConfig.breakpoints[source][line] then
				self:onBreakPointChanged_( source, line )
			end
			lines[line] = nil
		end
	end
	self:refreshBreakPoints_()
end

function meta.__index:onNewClient_( clientId )
	local client = self.engine.getClient( clientId )
	local name = client:name()
	if self.configs[name] == nil then
		self.configs[name] = createClientConfig(name)
		self:loadConfig_( name )
	end
	self.clients[clientId] = { dirty = true, activeThread = "current", activeLevel = 1, config = self.configs[name] }

	for source, lines in pairs( self.configs[name].breakpoints ) do
		assert( string.sub( source, 1, 1 ) == "@" )
		source = string.sub( source, 2 )
		local remoteSource, dir = self:getRemoteSource_( clientId, source )
		if remoteSource ~= nil then
			for line, value in pairs( lines ) do
				if value then
					client:setbreakpoint( "@"..remoteSource, line, true )
				end
			end
		end
	end

	self.threadsDirty = true
	if self.activeClient == nil then
		self:setActiveClient_( clientId )
	end

	if not self.configs[name].breakOnConnection then
		self.clients[clientId].ignoreNextBreak = true
	end
end

function meta.__index:onClientBreak_( clientId )
	local clientData = assert( self.clients[clientId] )
	clientData.invalidateTimer = nil
	clientData.dirty = true
	clientData.activeLevel = 1
	self.threadsDirty = true

	if clientData.ignoreNextBreak then
		clientData.ignoreNextBreak = false
		self:onDebugCommand_( "run", "break", clientId )
	end
end

function meta.__index:onClientLost_( clientId )
	local clientData = assert( self.clients[clientId] )
	if clientData.config.dirty then
		self:saveConfig_( clientData.config.name )
	end
	self.threadsDirty = true
end

function meta.__index:saveConfig_( name )
	local clientConfig = assert( self.configs[name] )
	clientConfig.dirty = false
	local name = clientConfig.name
	local openFiles = {}
	for source, page in pairs( self.window:getSourcePages() ) do
		openFiles[page.pageIdx+1] = source
	end
	local breakpoints = clientConfig.breakpoints
	local scrollPositions = clientConfig.scrollPositions

	local path = "clients/"..name.."/config.lua"
	lfs.mkdir( "clients" )
	lfs.mkdir( "clients/"..name )
	local file = assert( io.open( path, "w" ) )
	file:write( grldc.net.serialize( { 
		mappings = clientConfig.mappings, 
		openFiles = openFiles, 
		breakpoints = breakpoints,
		scrollPositions = scrollPositions,
		breakOnConnection = clientConfig.breakOnConnection
	} ) )
	file:close()
	print( "Saved config \""..name.."\"" )
	clientConfig.lastConfigSave = os.time()
end

function meta.__index:loadConfig_( name )
	local clientConfig = self.configs[name]
	local path = "clients/"..name.."/config.lua"
	local file = io.open( path, "r" )
	if file ~= nil then
		local config = grldc.net.deserialize( file:read( "*a" ) )
		file:close()
		clientConfig.mappings = config.mappings
		clientConfig.breakOnConnection = config.breakOnConnection
		for _, file in ipairs( config.openFiles ) do
			self.window:getSourcePage( file )
		end
		if config.breakpoints ~= nil then
			for source, bp in pairs( config.breakpoints ) do
				if clientConfig.breakpoints[source] == nil then
					clientConfig.breakpoints[source] = {}
				end
				for line, _ in pairs( bp ) do
					clientConfig.breakpoints[source][line] = true
				end
			end
		end

		if config.scrollPositions ~= nil then
			for source, sp in pairs( config.scrollPositions ) do
				clientConfig.scrollPositions[source] = sp
			end
		end
	end
	if clientConfig.breakOnConnection == nil then
		clientConfig.breakOnConnection = true
	end
	clientConfig.dirty = false
end

function complexValueManagerMeta.init( variables, engine, clientId )
	local manager = nil
	for _, entry in pairs( variables ) do
		if type( entry.value ) == "table" and entry.value.id ~= nil then
			if manager == nil then
				manager = { engine = engine, clientId = clientId }
			end
			assert( entry.value.manager == nil )
			entry.value.manager = manager
			setmetatable( entry.value, complexValueManagerMeta )
		end
	end
end

function complexValueManagerMeta.__index:release()
	local client = self.manager.engine.getClient( self.manager.clientId )
	if client == nil then return end
	client:releaseValue( self.id )
end

function complexValueManagerMeta.__index:get()
	local client = self.manager.engine.getClient( self.manager.clientId )
	if client == nil then return { ERROR = "connection with client lost" } end
	local value = client:getValue( self.id )
	complexValueManagerMeta.init( value, self.manager.engine, self.manager.clientId )
	return value
end
