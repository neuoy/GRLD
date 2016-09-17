-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one
local mainthread = require( "mainthread" )

local assert = assert
local setmetatable = setmetatable
local getmetatable = getmetatable
local string = string
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local table = table
local type = type
local next = next

module( "ui.luaExplorer" )

local meta = { __index = {} }
local evaluableItemMeta = { __index = {} }

local promptString = "<type new expression here>"

local function escapeString( str )
	for i = 1, #str do
		if string.sub( str, i, i ) == "\000" then
			str = string.sub( str, 1, i-1 ).."(NULL)"..string.sub( str, i+1 )
		end
	end
	return str
end

function new( parent, interactive )
	local self = { interactive = interactive }
	setmetatable( self, meta )
	local flags = wx.wxTR_HIDE_ROOT + wx.wxTR_LINES_AT_ROOT + wx.wxTR_HAS_BUTTONS
	if interactive then flags = flags + wx.wxTR_EDIT_LABELS end
	self.tree = wx.wxTreeCtrl( parent, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, flags )
	self.root = self.tree:AddRoot( "root" )
	self.complexValues = {}
	
	self.tree:Connect( wx.wxEVT_COMMAND_TREE_ITEM_EXPANDING, function( event ) self:onExpanding_( event ) end )
	self.tree:Connect( wx.wxEVT_COMMAND_TREE_ITEM_COLLAPSED, function( event ) self:onCollapsed_( event ) end )
	
	if interactive then
		self.tree:Connect( wx.wxEVT_COMMAND_TREE_BEGIN_LABEL_EDIT, function( event ) self:onBeginEdit_( event ) end )
		self.tree:Connect( wx.wxEVT_COMMAND_TREE_END_LABEL_EDIT, function( event ) self:onEdited_( event ) end )
		self.tree:Connect( wx.wxEVT_COMMAND_TREE_KEY_DOWN, function( event ) self:onKeyDown_( event ) end )
		self.tree:AppendItem( self.root, promptString )
	end
	
	return self
end

function meta.__index:getRoot()
	return self.tree
end

function meta.__index:setData( data )
	self:releaseHierarchy_( self.root )
	assert( next( self.complexValues ) == nil )
	
	--for _, cval in pairs( self.complexValues ) do
	--	cval:release()
	--end
	--self.complexValues = {}
	
	self.tree:DeleteChildren( self.root )
	if data ~= nil then
		for _, entry in ipairs( data ) do
			self:append_( self.root, entry )
		end
	end
end

function meta.__index:append_( parent, entry )
	local value
	local t = type( entry.value )
	local isComplex = false
	if t == "table" then
		value = entry.value.short
		if value ~= nil and (entry.value.type == "string" or entry.value.type == "proxy") then
			value = escapeString( value )
		end
		if entry.value.id ~= nil then
			isComplex = true
		end
	elseif t == "string" then
		value = "\""..escapeString( entry.value ).."\""
	elseif t == "nil" then
		value = nil
	else
		value = tostring( entry.value )
	end
	local node
	if value == nil then
		node = self.tree:AppendItem( parent, entry.name )
	else
		node = self.tree:AppendItem( parent, entry.name.." = "..value )
	end
	if isComplex then
		self.tree:SetItemHasChildren( node, true )
		self.complexValues[node:GetValue()] = entry.value
	end
end

function meta.__index:onExpanding_( event )
	local item = event:GetItem()
	local cval = assert( self.complexValues[item:GetValue()] )
	local value = cval:get()
	for _, entry in ipairs( value ) do
		self:append_( item, entry )
	end
end

function meta.__index:onCollapsed_( event )
	local item = event:GetItem()
	self:releaseHierarchy_( item )
	self.tree:DeleteChildren( item )
	self.tree:SetItemHasChildren( item, true )
end

function meta.__index:releaseHierarchy_( item )
	local child = self.tree:GetFirstChild( item )
	while child:IsOk() do
		local cval = self.complexValues[child:GetValue()]
		if cval ~= nil then
			cval:release()
			self.complexValues[child:GetValue()] = nil
		end
		self:releaseHierarchy_( child )
		child = self.tree:GetNextSibling( child )
	end
end

function meta.__index:refresh()
	assert( self.interactive )
	
	local exprItem = self.tree:GetFirstChild( self.root )
	while exprItem:IsOk() do
		self:releaseHierarchy_( exprItem )
		self.tree:Collapse( exprItem )
		self.tree:DeleteChildren( exprItem )
		if self.complexValues[exprItem:GetValue()] ~= nil then
			self.tree:SetItemHasChildren( exprItem, true )
		end
		exprItem = self.tree:GetNextSibling( exprItem )
	end
	
	for _, cval in pairs( self.complexValues ) do
		assert( getmetatable( cval ) == evaluableItemMeta ) -- all other values should have been released
	end
end

function meta.__index:clear()
	local item = self.root
	self:releaseHierarchy_( item )
	self.tree:DeleteChildren( item )
end

function meta.__index:onBeginEdit_( event )
	local item = event:GetItem()
	local parent = self.tree:GetItemParent( item )
	if parent:GetValue() ~= self.root:GetValue() then
		event:Veto() -- only direct children of root can be edited
	end
end

function meta.__index:onEdited_( event )
	local item = event:GetItem()
	assert( self.tree:GetItemParent( item ):GetValue() == self.root:GetValue() )
	
	self:releaseHierarchy_( item )
	self.tree:Collapse( item )
	self.tree:DeleteChildren( item )
	
	local expr = event:GetLabel()
	local cval = { evaluate = function() return self.evaluateCallback( expr ) end }
	setmetatable( cval, evaluableItemMeta )
	self.complexValues[item:GetValue()] = cval
	self.tree:SetItemHasChildren( item, true )
	
	if self.tree:GetLastChild( self.root ):GetValue() == item:GetValue() then
		self.tree:AppendItem( self.root, promptString )
	end
	
	self.tree:Expand( item )
end

function meta.__index:onKeyDown_( event )
	if event:GetKeyCode() == wx.WXK_DELETE then
		local item = self.tree:GetSelection()
		if item:IsOk() then
			local parent = self.tree:GetItemParent( item )
			if parent:GetValue() == self.root:GetValue() and item:GetValue() ~= self.tree:GetLastChild( self.root ):GetValue() then
				self:releaseHierarchy_( item )
				self.tree:Delete( item )
			end
		end
	end
end

function evaluableItemMeta.__index:get()
	return self.evaluate()
end

function evaluableItemMeta.__index:release()
	-- nothing to do
end
