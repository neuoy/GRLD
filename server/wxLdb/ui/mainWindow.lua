-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one
local socket = require( "socket" )
local mainthread = require( "mainthread" )
local ui =
{
	threads = require( "ui.threads" ),
	callstack = require( "ui.callstack" ),
	sourcePage = require( "ui.sourcePage" ),
	promptMountPath = require( "ui.promptMountPath" ),
	id = require( "ui.id" ),
	luaExplorer = require( "ui.luaExplorer" ),
	notification = require( "ui.notification" ),
	about = require( "ui.about" ),
}

local setmetatable = setmetatable
local table = table
local debug = debug
local xpcall = xpcall
local pairs = pairs
local assert = assert
local string = string
local type = type
local os = os
local io = io

module( "ui.mainWindow" )

ID_BREAK = ui.id.new()
ID_CONTINUE = ui.id.new()
ID_STEP_OVER = ui.id.new()
ID_STEP_INTO = ui.id.new()
ID_STEP_OUT = ui.id.new()
ID_TOGGLE_BREAKPOINT = ui.id.new()

ID_FILE_OPEN = ui.id.new()
ID_FILE_CLOSE = ui.id.new()

ID_HELP_MANUAL = ui.id.new()
ID_HELP_ABOUT = ui.id.new()

ID_EXIT = wx.wxID_EXIT

local meta = { __index = {} }

function new()
	local res = {}
	setmetatable( res, meta )
	res:init()
	return res
end

function meta.__index:init()
	self.frame = wx.wxFrame( wx.NULL, wx.wxID_ANY, "GRLD server", wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxDEFAULT_FRAME_STYLE + wx.wxMAXIMIZE)
	mainthread.init( self.frame )
	
	self:initLayout_()
	
	self.mountPathPopup = ui.promptMountPath.new()
	self.notificationPopup = ui.notification.new()
	
	self.idleUpdates = {}
	self.frame:Connect( wx.wxEVT_IDLE, function( event ) self:onIdleUpdate_( event ) end )
	
	self.events = { onBreakPointChanged = {}, onFileOpen = {}, onFileClosed = {}, onApplicationExiting = {} }
end

function meta.__index:show( show )
	self.frame:Show( show )
end

function meta.__index:close()
	self.frame:Close()
end

function meta.__index:initLayout_()
	self.root = wx.wxSplitterWindow( self.frame, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, 0 ) -- root widget
	self.sourceBook = wx.wxNotebook( self.root, wx.wxID_ANY ) -- book of source code pages
	self.debugRoot = wx.wxSplitterWindow( self.root, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, 0 )
	
	-- threads window
	self.threads = ui.threads.new( self.debugRoot, self.frame )
	
	self.debugBooks = wx.wxSplitterWindow( self.debugRoot, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, 0 )
	self.debugBookL = wx.wxNotebook( self.debugBooks, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxNB_BOTTOM )
	self.debugBookR = wx.wxNotebook( self.debugBooks, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxNB_BOTTOM )
	
	-- callstack window
	self.callstack = ui.callstack.new( self.debugBookL )
	self.debugBookL:AddPage( self.callstack:getRoot(), "Call stack" )
	
	-- automatic variables window
	self.auto = ui.luaExplorer.new( self.debugBookR, false )
	self.debugBookR:AddPage( self.auto:getRoot(), "Automatic variables" )
	
	-- watch window
	self.watch = ui.luaExplorer.new( self.debugBookR, true )
	self.debugBookR:AddPage( self.watch:getRoot(), "Watch" )
	
	self.root:SplitHorizontally( self.sourceBook, self.debugRoot, -200 )
	self.debugRoot:SplitVertically( self.threads:getRoot(), self.debugBooks, 250 )
	self.debugBooks:SplitVertically( self.debugBookL, self.debugBookR )
	
	self.sourcePages = {}
	
	local fileMenu = wx.wxMenu()
	fileMenu:Append( ID_FILE_OPEN, "&Open\tCtrl-O", "Open a source file" )
	fileMenu:Append( ID_FILE_CLOSE, "&Close\tCtrl-F4", "Close the current source file" )
	fileMenu:Append( ID_EXIT, "E&xit\tAlt-F4", "Exit the GRLD server" )
	
	local debugMenu = wx.wxMenu()
	debugMenu:Append( ID_BREAK, "&Break\tF12", "Stop execution of the program at the next executed line of code" )
	debugMenu:Append( ID_CONTINUE, "&Continue\tF5", "Run the program at full speed" )
	debugMenu:Append( ID_STEP_OVER, "&Step over\tF10", "Step over a line" )
	debugMenu:Append( ID_STEP_INTO, "Step &into\tF11", "Step into a line" )
    debugMenu:Append( ID_STEP_OUT, "Step &out\tShift-F11", "Step out of the current function" )
	debugMenu:Append( ID_TOGGLE_BREAKPOINT, "&Toggle breakpoint\tF9", "Toggle the breakpoint on the current line" )
	
	local helpMenu = wx.wxMenu()
	helpMenu:Append( ID_HELP_MANUAL, "&Manual", "Send the GRLD manual to your web browser" )
	helpMenu:Append( ID_HELP_ABOUT, "&About", "Open a window with various information about GRLD" )
	
	local menuBar = wx.wxMenuBar()
	menuBar:Append( fileMenu, "&File" )
	menuBar:Append( debugMenu, "&Debug" )
	menuBar:Append( helpMenu, "&Help" )
	self.frame:SetMenuBar( menuBar )
	
	self.frame:Connect( ID_FILE_OPEN, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... ) self:onFileOpen_( ... ) end )
	self.frame:Connect( ID_FILE_CLOSE, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... ) self:onFileClose_( ... ) end )
	self.frame:Connect( ID_HELP_MANUAL, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... ) self:onHelpManual_( ... ) end )
	self.frame:Connect( ID_HELP_ABOUT, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... ) self:onHelpAbout_( ... ) end )
	self.frame:Connect( ID_EXIT, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... ) self:onExitCommand_( ... ) end )
	self.frame:Connect( wx.wxEVT_CLOSE_WINDOW, function( ... ) self:onWindowClosed_( ... ) end )
end

function meta.__index:registerEvent( ID, callback )
	if type( ID ) == "string" then
		assert( self.events[ID] ~= nil, "Unknown event name "..ID )
		table.insert( self.events[ID], callback )
	else
		if self.events[ID] == nil then
			self.events[ID] = {}
			mainthread.execute( function()
				self.frame:Connect( ID, wx.wxEVT_COMMAND_MENU_SELECTED, function( ... )
					for _, callback in ipairs( self.events[ID] ) do
						callback( ... )
					end
				end )
			end )
		end
		table.insert( self.events[ID], callback )
	end
end

function meta.__index:runEvents_( eventName, ... )
	for _, callback in pairs( self.events[eventName] ) do
		callback( ... )
	end
end

function meta.__index:onFileOpen_( event )
	local fullPath = nil
	local fileDialog = wx.wxFileDialog( self.frame, "Open file", "", "", "Lua files (*.lua)|*.lua|Text files (*.txt)|*.txt|All files (*)|*", wx.wxOPEN + wx.wxFILE_MUST_EXIST )
	if fileDialog:ShowModal() == wx.wxID_OK then
		fullPath = fileDialog:GetPath()
	end
	fileDialog:Destroy()
	
	if fullPath ~= nil then
		self:runEvents_( "onFileOpen", fullPath )
	end
end

function meta.__index:onFileClose_( event )
	local idx = self.sourceBook:GetSelection()
	if idx >= 0 and idx < self.sourceBook:GetPageCount() then
		local page = nil
		local source = nil
		for s, p in pairs( self.sourcePages ) do
			if p.pageIdx == idx then
				page = p
				source = s
			elseif p.pageIdx > idx then
				p.pageIdx = p.pageIdx - 1
			end
		end
		assert( page ~= nil )
        self.sourceBook:DeletePage( page.pageIdx )
		page:destroy()
		self.sourcePages[source] = nil
		self:runEvents_( "onFileClosed", source )
    end
end

function meta.__index:onHelpManual_()
	local docPath = "../doc/index.html"
	
	-- get the command to start the default web browser from the registry (MS Windows only)
	local pipe = io.popen( "reg query HKEY_CLASSES_ROOT\\HTTP\\shell\\open\\command" )
	local data = pipe:read( "*a" )
	pipe:close()
	
	-- example of returned data (Windows XP):
	--! REG.EXE VERSION 3.0
	--
	--HKEY_CLASSES_ROOT\HTTP\shell\open\command
	--	<SANS NOM>  REG_SZ  "E:\Outils\Firefox\firefox.exe" -requestPending -osint -url "%1"
	
	-- other example (on Vista)
	--HKEY_CLASSES_ROOT\HTTP\shell\open\command
	--    (par défaut)    REG_SZ    "C:\Program Files\Mozilla Firefox\firefox.exe" -requestPending -osint -url "%1"
	
	-- parse returned data
	local _, _, cmd = string.find( data, "REG_SZ%s+(.+)" )
	local result = -1
	if cmd ~= nil then
		if string.find( cmd, "%%1" ) ~= nil then
			cmd = string.gsub( cmd, "%%1", docPath )
		else
			if string.sub( cmd, -1 ) ~= " " then
				cmd = cmd.." "
			end
			cmd = cmd.."\""..docPath.."\""
		end
		print( cmd )
		
		-- start the default browser with the GRLD documentation as parameter
		result = os.execute( "start \"GRLD documentation\" "..cmd )
	end
	if result ~= 0 then
		wx.wxMessageBox( "Unable to start your default web browser to display the GRLD manual. You can instead open the following file with any HTML or text viewer: "..string.sub(docPath,4), "Error" )
	end
end

function meta.__index:onHelpAbout_()
	ui.about.popup()
end

function meta.__index:onExitCommand_( event )
	self.frame:Close()
end

function meta.__index:onWindowClosed_( event )
	print( "Main window closed" )
	self:runEvents_( "onApplicationExiting" )
	event:Skip( true ) -- allow it to really exit
	self.mountPathPopup:destroy()
	self.notificationPopup:destroy()
	self.frame:Destroy()
end

function meta.__index:getSourcePages()
	return self.sourcePages
end

function meta.__index:getSourcePage( source )
	local page = self.sourcePages[source]
	if page == nil then
		page = mainthread.execute( function() return ui.sourcePage.new( self.sourceBook, source ) end )
		self.sourcePages[source] = page
		local _, _, name = string.find( source, ".*[/\\](.*)" )
		if name == nil then name = source end
		local maxLen = 16
		if #name > 16 then
			name = string.sub( name, 1, 7 ).."..."..string.sub( name, -7 )
		end
		page.pageIdx = self.sourceBook:GetPageCount()
		self.sourceBook:AddPage( page:getRoot(), name )
		page:registerEvent( "onBreakPointChanged", function( ... ) self:runEvents_( "onBreakPointChanged", source, ... ) end )
	end
	return page
end

function meta.__index:findSourcePage( source )
	return self.sourcePages[source]
end

function meta.__index:setSourcePageFocus( source )
	local page = self:getSourcePage( source )
	self.sourceBook:ChangeSelection( page.pageIdx )
end

function meta.__index:findSourcePageFocus()
	local idx = self.sourceBook:GetSelection()
	if idx >= 0 and idx < self.sourceBook:GetPageCount() then
		local page = nil
		local source = nil
		for s, p in pairs( self.sourcePages ) do
			if p.pageIdx == idx then
				return s, p:getFocus()
			end
		end
    end
	return nil
end

function meta.__index:clearMarkers()
	for _, page in pairs( self.sourcePages ) do
		page:clearMarkers()
	end
end

function meta.__index:clearOtherLines()
	for _, page in pairs( self.sourcePages ) do
		page:clearOtherLines()
	end
end

function meta.__index:clearBreakPoints()
	for _, page in pairs( self.sourcePages ) do
		page:clearBreakPoints()
	end
end

function meta.__index:setCurrentLine( source, line )
	for _, page in pairs( self.sourcePages ) do
		page:setCurrentLine( nil )
	end
	local page = self:getSourcePage( source )
	page:setCurrentLine( line )
end

function meta.__index:addIdleUpdate( func )
	table.insert( self.idleUpdates, func )
end

function meta.__index:promptMountPath( ... )
	return self.mountPathPopup:run( ... )
end

function meta.__index:notification( text )
	return self.notificationPopup:run( text )
end

function meta.__index:setActive()
	self.active = true
end

function meta.__index:onIdleUpdate_( event )
	local currentPageIdx = self.sourceBook:GetSelection()
	for _, page in pairs( self.sourcePages ) do
		if currentPageIdx == page.pageIdx then
			if page:update() then
				assert( string.sub( page.source, 1, 1 ) == "@" )
				self:runEvents_( "onFileOpen", string.sub( page.source, 2 ) )
			end
		end
	end
	
	self.active = false
	for _, func in pairs( self.idleUpdates ) do
		local ok, msg = xpcall( func, debug.traceback )
		if not ok then print( "Error in idle update: "..msg ) end
	end
	if not self.active then
		--socket.sleep( 0.05 )
	end
	event:RequestMore( true )
end
