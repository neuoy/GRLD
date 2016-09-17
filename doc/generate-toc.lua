local firstLevel = 2

local function parseTitle( line )
	local level, text
	_, _, level, text = string.find( line, "<h(.)>([^<]+)</h.>" )
	if level ~= nil then
		level = assert( tonumber( level ) )
		assert( text ~= nil )
		if level >= firstLevel then
			--print( level, text )
			return { level = level - firstLevel + 1, text = text }
		end
	end
end

local function getAnchor( number )
	return "section"..string.gsub( number, "%.", "_" )
end

local function createTitle( titleInfo )
	local l = titleInfo.level + firstLevel - 1
	return "<h"..l.." id=\""..getAnchor( titleInfo.number ).."\"> "..titleInfo.number.." "..titleInfo.text.." </h"..l..">"
end

local function createToc( titles )
	local res = ""
	local numeration = {}
	for _, titleInfo in ipairs( titles ) do
		--print( titleInfo.level, titleInfo.text )
		local open = false
		local numClose = 0
		local prevLevel = #numeration
		if titleInfo.level == prevLevel + 1 then
			open = true
			table.insert( numeration, 0 )
		elseif titleInfo.level < prevLevel then
			numClose = prevLevel - titleInfo.level
		else
			assert( titleInfo.level == prevLevel, "Title "..titleInfo.text.." with level "..titleInfo.level.." follows title with level "..prevLevel.." which is not a valid title sequence" )
		end
		
		if open then
			res = res.."<ul>\n"
		end
		for i = 1, numClose do
			res = res.."</ul>\n"
			numeration[#numeration] = nil
		end
		
		if titleInfo.level > 0 then
			numeration[titleInfo.level] = numeration[titleInfo.level] + 1
			res = res.."<li>"
			titleInfo.number = ""
			for _, num in ipairs( numeration ) do
				titleInfo.number = titleInfo.number..num.."."
			end
			res = res.."<a href=\"#"..getAnchor( titleInfo.number ).."\">"
			res = res..titleInfo.number.." "..titleInfo.text.."</a></li>\n"
		end
	end
	
	assert( #numeration == 0, "Missing closing title" )
	return res
end

function generateToc( srcHtml, dstHtml )
	local src = assert( io.open( srcHtml, "r" ) )
	
	local titles = {}
	while true do
		local line = src:read( "*l" )
		if line == nil then break end
		
		local titleInfo = parseTitle( line )
		if titleInfo ~= nil then
			table.insert( titles, titleInfo )
		end
	end
	table.insert( titles, { level = 0 } )
	local nextTitle = 1
	
	src:close()
	local src = assert( io.open( srcHtml, "r" ) )
	
	local dst = assert( io.open( dstHtml, "w" ) )
	
	while true do
		local line = src:read( "*l" )
		if line == nil then break end
		
		line = string.gsub( line, "[\n\r]+", "" )
		
		local titleInfo = parseTitle( line )
		if titleInfo ~= nil then
			titleInfo = titles[nextTitle]
			nextTitle = nextTitle + 1
			dst:write( createTitle( titleInfo ).."\n" )
		else
			dst:write( line.."\n" )
		end
		
		if string.find( line, "@generated_toc@" ) ~= nil then
			dst:write( createToc( titles ).."\n" )
		end
	end
	
	src:close()
	dst:close()
end
