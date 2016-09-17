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

module( "ui.notification" )

local meta = { __index = {} }

function new()
	local self = {}
	setmetatable( self, meta )
	self:initLayout_()
	return self
end

function meta.__index:destroy()
	self.dialog:Destroy()
end

function meta.__index:run( message )
	assert( self.waiting == nil )
	self.waiting = coroutine.running()
	assert( self.waiting ~= nil )
	
	self.message:SetLabel( message )
	self.mainSizer:SetSizeHints( self.dialog )
	self.dialog:Show( true )
	local ok = coroutine.yield()
	
	assert( self.waiting == coroutine.running() )
	self.waiting = nil
	self.dialog:Show( false )
	
	return ok
end

function meta.__index:initLayout_()
	self.dialog = wx.wxDialog( wx.NULL, wx.wxID_ANY, "Notification", wx.wxDefaultPosition, wx.wxDefaultSize )
	local panel = wx.wxPanel( self.dialog, wx.wxID_ANY )
	local vSizer = wx.wxBoxSizer( wx.wxVERTICAL )
	self.mainSizer = vSizer
	local sizer
	
	sizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
	self.message = wx.wxStaticText( panel, wx.wxID_ANY, "test message" )
	sizer:Add( self.message )
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
