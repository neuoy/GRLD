-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one
local mainthread = require( "mainthread" )
local utilities = require( "grldc.utilities" )

local setmetatable = setmetatable
local assert = assert
local coroutine = coroutine
local debug = debug
local error = error
local string = string

module( "ui.promptMountPath" )

local meta = { __index = {} }

local function checkPath( user, auto )
	if auto == nil then return true end
	if string.sub( auto, 1, #user ) ~= user then
		wx.wxMessageBox( "Bad path: "..user.." not prefix of "..auto, "Error" )
		return false
	end
	local s = string.sub( auto, #user, #user )
	if s ~= "/" and s ~= "\\" then
		--print( user.." does not finish with /" )
		s = string.sub( auto, #user+1, #user+1 )
	end
	if s ~= "/" and s ~= "\\" and s ~= "" then
		wx.wxMessageBox( "Bad path: "..user.." does not finish with / and is not a parent directory of "..auto, "Error" )
		return false
	end
	return true
end

function new()
	local self = {}
	setmetatable( self, meta )
	self:initLayout_()
	return self
end

function meta.__index:destroy()
	self.dialog:Destroy()
end

function meta.__index:run( remotePath, localPath, fileName )
	if remotePath ~= nil and localPath == nil and fileName ~= nil then
		-- we can use the file open dialog to select the local file
		local fullPath = nil
		local fileDialog = wx.wxFileDialog( wx.NULL, "Find source file: "..remotePath..fileName, "", fileName, "Lua files (*.lua)|*.lua|Text files (*.txt)|*.txt|All files (*)|*", wx.wxOPEN + wx.wxFILE_MUST_EXIST )
		if fileDialog:ShowModal() == wx.wxID_OK then
			fullPath = fileDialog:GetPath()
		end
		fileDialog:Destroy()
		
		if fullPath == nil then return nil end
		
		fullPath = utilities.normalizePath( fullPath )
		
		if string.sub( fullPath, -#fileName-1 ) ~= "/"..fileName then
			wx.wxMessageBox( "Remote file and local file must have the same name", "Invalid local source file" )
			return nil
		else
			local lPath = string.sub( fullPath, 1, -#fileName-2 )
			local rPath = utilities.normalizePath( remotePath )
			--[[while true do
				print( lPath, rPath )
				local suffix
				_, _, suffix = string.find( lPath, ".*(/.+)$" )
				if suffix == nil then break end
				if string.sub( rPath, -#suffix ) ~= suffix then break end
				lPath = string.sub( lPath, 1, -#suffix-1 )
				rPath = string.sub( rPath, 1, -#suffix-1 )
			end]]
			--return rPath, lPath
			localPath = lPath
		end
	end
	assert( self.waiting == nil )
	self.waiting = coroutine.running()
	assert( self.waiting ~= nil )
	
	self.mount:SetValue( remotePath or "" )
	self.path:SetValue( localPath or "" )
	self.dialog:Show( true )
	local ok = coroutine.yield()
	assert( self.waiting == coroutine.running() )
	self.waiting = nil
	self.dialog:Show( false )
	if ok then
		local mount = self.mount:GetValue()
		local path = self.path:GetValue()
		if not checkPath( mount, remotePath ) or not checkPath( path, localPath ) then
			return self:run( remotePath, localPath )
		end
		return mount, path
	else
		return nil
	end
end

function meta.__index:initLayout_()
	self.dialog = wx.wxDialog( wx.NULL, wx.wxID_ANY, "Unknown path", wx.wxDefaultPosition, wx.wxDefaultSize )
	local panel = wx.wxPanel( self.dialog, wx.wxID_ANY )
	local vSizer = wx.wxBoxSizer( wx.wxVERTICAL )
	local sizer
	
	sizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
	local label = wx.wxStaticText( panel, wx.wxID_ANY, "Please map the following remote path, or a part of it, to the corresponding local path" )
	sizer:Add( label )
	vSizer:Add( sizer )
	
	sizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
	label = wx.wxStaticText( panel, wx.wxID_ANY, "remote path" )
	sizer:Add( label )
	self.mount = wx.wxTextCtrl( panel, wx.wxID_ANY )
	sizer:Add( self.mount )
	vSizer:Add( sizer )
	
	sizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
	label = wx.wxStaticText( panel, wx.wxID_ANY, "local path" )
	sizer:Add( label )
	self.path = wx.wxTextCtrl( panel, wx.wxID_ANY )
	sizer:Add( self.path )
	vSizer:Add( sizer )
	
	sizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
	local ok = wx.wxButton( panel, wx.wxID_ANY, "OK" )
	mainthread.execute( function()
		self.dialog:Connect( ok:GetId(), wx.wxEVT_COMMAND_BUTTON_CLICKED, function() self:onEnd_( true ) end )
	end )
	sizer:Add( ok )
	local cancel = wx.wxButton( panel, wx.wxID_ANY, "Cancel" )
	mainthread.execute( function()
		self.dialog:Connect( cancel:GetId(), wx.wxEVT_COMMAND_BUTTON_CLICKED, function() self:onEnd_( false ) end )
	end )
	sizer:Add( cancel )
	vSizer:Add( sizer )
	
	panel:SetSizer( vSizer )
	vSizer:SetSizeHints( self.dialog )
	
	mainthread.execute( function()
		self.dialog:Connect( wx.wxEVT_CLOSE_WINDOW, function() self:onEnd_( false ) end )
	end )
end

function meta.__index:onEnd_( ok )
	local status, msg = coroutine.resume( self.waiting, ok )
	assert( status, debug.traceback( self.waiting, msg ) )
end
