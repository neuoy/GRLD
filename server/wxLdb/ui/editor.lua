-- see copyright notice in wxLdb.lua

local print = print
local wx = require( "wx" )
_G.print = print -- override wx print function with original one
local wxstc = require( "wxstc" )
local mainthread = require( "mainthread" )

local setmetatable = setmetatable

module( "ui.editor" )

local font
local fontItalic

-- Pick some reasonable fixed width fonts to use for the editor
if wx.__WXMSW__ then
    font       = wx.wxFont(10, wx.wxFONTFAMILY_MODERN, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL, false, "Andale Mono")
    fontItalic = wx.wxFont(10, wx.wxFONTFAMILY_MODERN, wx.wxFONTSTYLE_ITALIC, wx.wxFONTWEIGHT_NORMAL, false, "Andale Mono")
else
    font       = wx.wxFont(10, wx.wxFONTFAMILY_MODERN, wx.wxFONTSTYLE_NORMAL, wx.wxFONTWEIGHT_NORMAL, false, "")
    fontItalic = wx.wxFont(10, wx.wxFONTFAMILY_MODERN, wx.wxFONTSTYLE_ITALIC, wx.wxFONTWEIGHT_NORMAL, false, "")
end

-- Markers for editor margin
markers =
{
	breakpoint = 1,
	badBreakpoint = 2,
	currentLine = 3,
	otherLine = 4,
}

local function createEditor( parent, owner )
	local editor = wxstc.wxStyledTextCtrl( parent, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, wx.wxSUNKEN_BORDER )
	
	editor:SetBufferedDraw(true)
    editor:StyleClearAll()

    editor:SetFont(font)
    editor:StyleSetFont(wxstc.wxSTC_STYLE_DEFAULT, font)
    for i = 0, 32 do
        editor:StyleSetFont(i, font)
    end

    editor:StyleSetForeground(0,  wx.wxColour(128, 128, 128)) -- White space
    editor:StyleSetForeground(1,  wx.wxColour(0,   127, 0))   -- Block Comment
    editor:StyleSetFont(1, fontItalic)
    --editor:StyleSetUnderline(1, false)
    editor:StyleSetForeground(2,  wx.wxColour(0,   127, 0))   -- Line Comment
    editor:StyleSetFont(2, fontItalic)                        -- Doc. Comment
    --editor:StyleSetUnderline(2, false)
    editor:StyleSetForeground(3,  wx.wxColour(127, 127, 127)) -- Number
    editor:StyleSetForeground(4,  wx.wxColour(0,   127, 127)) -- Keyword
    editor:StyleSetForeground(5,  wx.wxColour(0,   0,   127)) -- Double quoted string
    editor:StyleSetBold(5,  true)
    --editor:StyleSetUnderline(5, false)
    editor:StyleSetForeground(6,  wx.wxColour(127, 0,   127)) -- Single quoted string
    editor:StyleSetForeground(7,  wx.wxColour(127, 0,   127)) -- not used
    editor:StyleSetForeground(8,  wx.wxColour(0,   127, 127)) -- Literal strings
    editor:StyleSetForeground(9,  wx.wxColour(127, 127, 0))  -- Preprocessor
    editor:StyleSetForeground(10, wx.wxColour(0,   0,   0))   -- Operators
    --editor:StyleSetBold(10, true)
    editor:StyleSetForeground(11, wx.wxColour(0,   0,   0))   -- Identifiers
    editor:StyleSetForeground(12, wx.wxColour(0,   0,   0))   -- Unterminated strings
    editor:StyleSetBackground(12, wx.wxColour(224, 192, 224))
    editor:StyleSetBold(12, true)
    editor:StyleSetEOLFilled(12, true)

    editor:StyleSetForeground(13, wx.wxColour(0,   0,  95))   -- Keyword 2 highlighting styles
    editor:StyleSetForeground(14, wx.wxColour(0,   95, 0))    -- Keyword 3
    editor:StyleSetForeground(15, wx.wxColour(127, 0,  0))    -- Keyword 4
    editor:StyleSetForeground(16, wx.wxColour(127, 0,  95))   -- Keyword 5
    editor:StyleSetForeground(17, wx.wxColour(35,  95, 175))  -- Keyword 6
    editor:StyleSetForeground(18, wx.wxColour(0,   127, 127)) -- Keyword 7
    editor:StyleSetBackground(18, wx.wxColour(240, 255, 255)) -- Keyword 8

    editor:StyleSetForeground(19, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(19, wx.wxColour(224, 255, 255))
    editor:StyleSetForeground(20, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(20, wx.wxColour(192, 255, 255))
    editor:StyleSetForeground(21, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(21, wx.wxColour(176, 255, 255))
    editor:StyleSetForeground(22, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(22, wx.wxColour(160, 255, 255))
    editor:StyleSetForeground(23, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(23, wx.wxColour(144, 255, 255))
    editor:StyleSetForeground(24, wx.wxColour(0,   127, 127))
    editor:StyleSetBackground(24, wx.wxColour(128, 155, 255))

    editor:StyleSetForeground(32, wx.wxColour(224, 192, 224))  -- Line number
    editor:StyleSetBackground(33, wx.wxColour(192, 192, 192))  -- Brace highlight
    editor:StyleSetForeground(34, wx.wxColour(0,   0,   255))
    editor:StyleSetBold(34, true)                              -- Brace incomplete highlight
    editor:StyleSetForeground(35, wx.wxColour(255, 0,   0))
    editor:StyleSetBold(35, true)                              -- Indentation guides
    editor:StyleSetForeground(37, wx.wxColour(192, 192, 192))
    editor:StyleSetBackground(37, wx.wxColour(255, 255, 255))

    editor:SetUseTabs(true)
    editor:SetIndentationGuides(true)

    editor:SetVisiblePolicy(wxstc.wxSTC_VISIBLE_SLOP, 3)
    --editor:SetXCaretPolicy(wxstc.wxSTC_CARET_SLOP, 10)
    --editor:SetYCaretPolicy(wxstc.wxSTC_CARET_SLOP, 3)

    editor:SetMarginWidth(0, editor:TextWidth(32, "9999_")) -- line # margin

    editor:SetMarginWidth(1, 16) -- marker margin
    editor:SetMarginType(1, wxstc.wxSTC_MARGIN_SYMBOL)
    editor:SetMarginSensitive(1, true)

    editor:MarkerDefine(markers.breakpoint, wxstc.wxSTC_MARK_ROUNDRECT, wx.wxWHITE, wx.wxRED)
	editor:MarkerDefine(markers.badBreakpoint, wxstc.wxSTC_MARK_ROUNDRECT, wx.wxRED, wx.wxColour(192,192,192))
    editor:MarkerDefine(markers.currentLine, wxstc.wxSTC_MARK_SHORTARROW, wx.wxBLACK, wx.wxColour(255,255,0))
	editor:MarkerDefine(markers.otherLine, wxstc.wxSTC_MARK_ARROW, wx.wxBLACK, wx.wxGREEN)

    editor:SetMarginWidth(2, 16) -- fold margin
    editor:SetMarginType(2, wxstc.wxSTC_MARGIN_SYMBOL)
    editor:SetMarginMask(2, wxstc.wxSTC_MASK_FOLDERS)
    editor:SetMarginSensitive(2, true)

    editor:SetFoldFlags(wxstc.wxSTC_FOLDFLAG_LINEBEFORE_CONTRACTED +
                        wxstc.wxSTC_FOLDFLAG_LINEAFTER_CONTRACTED)

    editor:SetProperty("fold", "1")
    editor:SetProperty("fold.compact", "1")
    editor:SetProperty("fold.comment", "1")

    local grey = wx.wxColour(128, 128, 128)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDEROPEN,    wxstc.wxSTC_MARK_BOXMINUS, wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDER,        wxstc.wxSTC_MARK_BOXPLUS,  wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDERSUB,     wxstc.wxSTC_MARK_VLINE,    wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDERTAIL,    wxstc.wxSTC_MARK_LCORNER,  wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDEREND,     wxstc.wxSTC_MARK_BOXPLUSCONNECTED,  wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDEROPENMID, wxstc.wxSTC_MARK_BOXMINUSCONNECTED, wx.wxWHITE, grey)
    editor:MarkerDefine(wxstc.wxSTC_MARKNUM_FOLDERMIDTAIL, wxstc.wxSTC_MARK_TCORNER,  wx.wxWHITE, grey)
    grey:delete()
	
	editor:SetLexer(wxstc.wxSTC_LEX_LUA)

	-- Note: these keywords are shamelessly ripped from scite 1.68
	editor:SetKeyWords(0,
		[[and break do else elseif end false for function if
		in local nil not or repeat return then true until while]])
	editor:SetKeyWords(1,
		[[_VERSION assert collectgarbage dofile error gcinfo loadfile loadstring
		print rawget rawset require tonumber tostring type unpack]])
	editor:SetKeyWords(2,
		[[_G getfenv getmetatable ipairs loadlib next pairs pcall
		rawequal setfenv setmetatable xpcall
		string table math coroutine io os debug
		load module select]])
	editor:SetKeyWords(3,
		[[string.byte string.char string.dump string.find string.len
		string.lower string.rep string.sub string.upper string.format string.gfind string.gsub
		table.concat table.foreach table.foreachi table.getn table.sort table.insert table.remove table.setn
		math.abs math.acos math.asin math.atan math.atan2 math.ceil math.cos math.deg math.exp
		math.floor math.frexp math.ldexp math.log math.log10 math.max math.min math.mod
		math.pi math.pow math.rad math.random math.randomseed math.sin math.sqrt math.tan
		string.gmatch string.match string.reverse table.maxn
		math.cosh math.fmod math.modf math.sinh math.tanh math.huge]])
	editor:SetKeyWords(4,
		[[coroutine.create coroutine.resume coroutine.status
		coroutine.wrap coroutine.yield
		io.close io.flush io.input io.lines io.open io.output io.read io.tmpfile io.type io.write
		io.stdin io.stdout io.stderr
		os.clock os.date os.difftime os.execute os.exit os.getenv os.remove os.rename
		os.setlocale os.time os.tmpname
		coroutine.running package.cpath package.loaded package.loadlib package.path
		package.preload package.seeall io.popen
		debug.debug debug.getfenv debug.gethook debug.getinfo debug.getlocal
		debug.getmetatable debug.getregistry debug.getupvalue debug.setfenv
		debug.sethook debug.setlocal debug.setmetatable debug.setupvalue debug.traceback]])
	
	mainthread.execute( function()
		editor:Connect(wxstc.wxEVT_STC_MARGINCLICK, function( event )
			local line = editor:LineFromPosition(event:GetPosition())
			local margin = event:GetMargin()
			if margin == 1 then
				owner:toggleBreakpoint( line )
			elseif margin == 2 then
				--[[if wx.wxGetKeyState(wx.WXK_SHIFT) and wx.wxGetKeyState(wx.WXK_CONTROL) then
					FoldSome()
				else
					local level = editor:GetFoldLevel(line)
					if HasBit(level, wxstc.wxSTC_FOLDLEVELHEADERFLAG) then
						editor:ToggleFold(line)
					end
				end]]
			end
		end )
	end )
	
	return editor
end

local function splitMarkers( m )
	local maxMarker = 31
	local res = {}
	for marker = maxMarker, 0, -1 do
		local value = 2^marker
		res[marker] = m >= value
		if res[marker] then
			m = m - value
		end
	end
	return res
end

local meta = { __index = {} }

function new( parent )
	local res = {}
	setmetatable( res, meta )
	res.editor = createEditor( parent, res )
	return res
end

function meta.__index:toggleBreakpoint( line )
	local editor = self.editor
	
	--[[local m = editor:MarkerGet(line)
	m = splitMarkers( m )
	
	if m[markers.breakpoint] then
		editor:MarkerDelete( line, markers.breakpoint )
	else
		editor:MarkerAdd( line, markers.breakpoint )
	end]]
	self.breakpointCallback( line + 1 )
end

function meta.__index:destroy()
	-- nothing to do (the parent widget will destroy the editor widget)
end
