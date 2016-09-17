-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one

local setmetatable = setmetatable
local table = table
local debug = debug
local xpcall = xpcall
local pairs = pairs
local ipairs = ipairs
local assert = assert
local tostring = tostring

local ui =
{
	id = require( "ui.id" ),
}

module( "ui.threads" )

local meta = { __index = {} }

local ID_CLIENT_BREAK_ON_CONNECT = ui.id.new()

function new( ... )
	local res = {}
	setmetatable( res, meta )
	res:init( ... )
	return res
end

function meta.__index:init( parentWidget, frame )
	self.events = { onThreadClicked = {}, onBreakOnConnectionChanged = {} }
	self.popups = {}
	setmetatable( self.popups, { __mode = "v" } )
	self.frame = frame
	self.tree = wx.wxTreeCtrl( parentWidget, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxTR_HIDE_ROOT + wx.wxTR_LINES_AT_ROOT + wx.wxTR_HAS_BUTTONS )
	
	local imageList = wx.wxImageList(16, 16)
	imageList:Add(wx.wxArtProvider.GetBitmap(wx.wxART_GO_FORWARD, wx.wxART_TOOLBAR, wx.wxSize(16, 16)))
	imageList:Add(wx.wxArtProvider.GetBitmap(wx.wxART_EXECUTABLE_FILE, wx.wxART_TOOLBAR, wx.wxSize(16, 16)))
	self.tree:AssignImageList( imageList )
	
	self.root = self.tree:AddRoot( "clients" )
	
	self.tree:Connect( wx.wxEVT_COMMAND_TREE_SEL_CHANGED, function( event )
		if self.disableInputs then return end
		local item = event:GetItem()
		local data = assert( self.nodeData[item:GetValue()] )
		--print( "thread selected: "..data.clientId..", "..data.threadId )
		self:runEvents_( "onThreadClicked", data.clientId, data.threadId )
	end )
	
	self.tree:Connect( wx.wxEVT_COMMAND_TREE_ITEM_RIGHT_CLICK, function( event )
		local item = event:GetItem()
		local data = assert( self.nodeData[item:GetValue()] )
		if data.threadId == "current" then -- right click on a client
			menu = wx.wxMenu()
			self.popups[menu] = data
			menu:Append( ID_CLIENT_BREAK_ON_CONNECT, "Break on connection", "Specify if the client should break execution each time it connects to the server", wx.wxITEM_CHECK )
			menu:Check( ID_CLIENT_BREAK_ON_CONNECT, data.breakOnConnection )
			self.tree:PopupMenu( menu )
		end
	end )
	
	self.frame:Connect( ID_CLIENT_BREAK_ON_CONNECT, wx.wxEVT_COMMAND_MENU_SELECTED, function( event )
		local data = assert( self.popups[event:GetEventObject():DynamicCast( "wxMenu" )] )
		data.breakOnConnection = event:IsChecked()
		self:runEvents_( "onBreakOnConnectionChanged", data.clientId, data.breakOnConnection )
	end )
end

function meta.__index:getRoot()
	return self.tree
end

function meta.__index:registerEvent( eventName, callback )
	assert( self.events[eventName] ~= nil, "Unknown event name "..eventName )
	table.insert( self.events[eventName], callback )
end

function meta.__index:runEvents_( eventName, ... )
	for _, callback in pairs( self.events[eventName] ) do
		callback( ... )
	end
end

function meta.__index:setData( data )
	self.disableInputs = true
	if self.data ~= nil then
		self.tree:DeleteChildren( self.root )
		self.data = nil
	end
		
	if data ~= nil then
		self.data = {}
		self.nodeData = {}
		for _, client in pairs( data ) do
			local cdata = {}
			cdata.node = self.tree:AppendItem( self.root, client.name.." ["..client.ip.."]", 1 )
			if client.active then
				self.tree:SetItemBold( cdata.node, true )
				self.tree:SelectItem( cdata.node, true )
			end
			--print( "client:", cdata.node, cdata.node:GetValue() )
			self.nodeData[cdata.node:GetValue()] = { clientId = client.clientId, threadId = "current", breakOnConnection = client.breakOnConnection }
			cdata.coroutines = {}
			for _, co in ipairs( client.coroutines ) do
				local codata = {}
				local label = ""
				--if co.current then
				--	label = "-> "
				--end
				label = label..co.id
				local imageIdx = -1
				if co.current then
					imageIdx = 0
				end
				codata.node = self.tree:AppendItem( cdata.node, label, imageIdx )
				self.nodeData[codata.node:GetValue()] = { clientId = client.clientId, threadId = co.id }
				--print( "\tthread:", codata.node, codata.node:GetValue() )
				if co.active then
					self.tree:SetItemBold( codata.node, true )
					self.tree:SelectItem( codata.node, true )
				end
				table.insert( cdata.coroutines, codata )
			end
			self.tree:Expand( cdata.node )
			table.insert( self.data, cdata )
		end
	end
	self.disableInputs = false
end
