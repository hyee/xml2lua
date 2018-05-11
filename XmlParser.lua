--- @module Class providing the actual XML parser.
--  Available options are:
--      * stripWS   
--        Strip non-significant whitespace (leading/trailing) 
--        and do not generate events for empty text elements
--  
--      * expandEntities 
--        Expand entities (standard entities + single char 
--        numeric entities only currently - could be extended 
--        at runtime if suitable DTD parser added elements
--        to table (see obj._ENTITIES). May also be possible
--        to expand multibyre entities for UTF-8 only
--  
--      * errorHandler
--        Custom error handler function 
--
--  NOTE: Boolean options must be set to 'nil' not '0'
local XmlParser = {
    options     = {},
    handler     = {},
    
    -- Private attribures/functions
    _stack      = {},

    _XML        = '^([^<]*)<(%/?)([^>]-)(%/?)>',
    _ATTR1      = '([%w-:_]+)%s*=%s*"(.-)"',
    _ATTR2      = '([%w-:_]+)%s*=%s*\'(.-)\'',
    _CDATA      = '<%!%[CDATA%[(.-)%]%]>',
    _PI         = '<%?(.-)%?>',
    _COMMENT    = '<!%-%-(.-)%-%->',
    _TAG        = '^(.-)%s.*',
    _LEADINGWS  = '^%s+',
    _TRAILINGWS = '%s+$',
    _WS         = '^%s*$',
    _DTD1       = '<!DOCTYPE%s+(.-)%s+(SYSTEM)%s+["\'](.-)["\']%s*(%b[])%s*>',
    _DTD2       = '<!DOCTYPE%s+(.-)%s+(PUBLIC)%s+["\'](.-)["\']%s+["\'](.-)["\']%s*(%b[])%s*>',
    _DTD3       = '<!DOCTYPE%s+(.-)%s*(%b[])%s*>',
    _DTD4       = '<!DOCTYPE%s+(.-)%s+(SYSTEM)%s+["\'](.-)["\']%s*>',
    _DTD5       = '<!DOCTYPE%s+(.-)%s+(PUBLIC)%s+["\'](.-)["\']%s+["\'](.-)["\']%s*>',

    _ATTRERR1   = '=%s*"[^"]*$',
    _ATTRERR2   = '=%s*\'[^\']*$',
    _TAGEXT     = '(%/?)>',

    _errstr = { 
        xmlErr = "Error Parsing XML",
        declErr = "Error Parsing XMLDecl",
        declStartErr = "XMLDecl not at start of document",
        declAttrErr = "Invalid XMLDecl attributes",
        piErr = "Error Parsing Processing Instruction",
        commentErr = "Error Parsing Comment",
        cdataErr = "Error Parsing CDATA",
        dtdErr = "Error Parsing DTD",
        endTagErr = "End Tag Attributes Invalid",
        unmatchedTagErr = "Unbalanced Tag",
        incompleteXmlErr = "Incomplete XML Document",
    },

    _ENTITIES = { 
        ["&lt;"] = "<",
        ["&gt;"] = ">",
        ["&amp;"] = "&",
        ["&quot;"] = '"',
        ["&apos;"] = "'",
        ["&#(%d+);"] = decimalToHtmlChar,
        ["&#x(%x+);"] = hexadecimalToHtmlChar,
    },
}

--- Instantiates a XmlParser object.
--@param _handler Handler module to be used to convert the XML string
--               to another formats. See the available handlers at the handler directory.
--               Usually you get an instance to a handler module using, for instance:
--               local handler = require("xmlhandler/tree").
--@param _options Options for this XmlParser instance.
--@see XmlParser.options
function XmlParser.new(_handler, _options)
  local obj = {
      handler = _handler,
      options = _options
  }

	setmetatable(obj, XmlParser)
  return obj;
end


local function err(self, err, pos)
    if self.options.errorHandler then
        self.options.errorHandler(err,pos)
    end
end

--- Removes whitespaces
local function stripWS(self, s)
    if self.options.stripWS then
        s = string.gsub(s,'^%s+','')
        s = string.gsub(s,'%s+$','')
    end
    return s
end

local function parseEntities(self, s) 
    if self.options.expandEntities then
        --for k,v in self._ENTITIES do
        for k,v in pairs(self._ENTITIES) do
            --print (k, v) 
            s = string.gsub(s,k,v)
        end
    end

    return s
end

--- Parses a string representing a tag
--@param s String containing tag text
--@return a {name, attrs} table
-- where name is the name of the tag and attrs 
-- is a table containing the atributtes of the tag
local function parseTag(self, s)
    local tag = {
        name = string.gsub(s, self._TAG, '%1'),
        attrs = {}
      }            

    local parseFunction = function (k, v) 
            tag.attrs[string.lower(k)] = parseEntities(self, v)
            tag.attrs._ = 1 
          end
                          
    string.gsub(s, self._ATTR1, parseFunction) 
    string.gsub(s, self._ATTR2, parseFunction)

    if tag.attrs._ then
        tag.attrs._ = nil
    else 
        tag.attrs = nil
    end

    return tag
end

local function parseXmlDeclaration(self, xml, f)
    -- XML Declaration
    f.match, f.endMatch, f.text = string.find(xml, self._PI, f.pos)
    if not f.match then 
        err(self, self._errstr.declErr, f.pos)
    end 

    if f.match ~= 1 then
        -- Must be at start of doc if present
        err(self, self._errstr.declStartErr, f.pos)
    end

    tag = parseTag(self, f.text) 
    -- TODO: Check if attributes are valid
    -- Check for version (mandatory)
    if tag.attrs and tag.attrs.version == nil then
        err(self, self._errstr.declAttrErr, f.pos)
    end

    if self.handler.decl then 
        self.handler:decl(tag, f.match, f.endMatch) 
    end    

    return tag
end

local function parseXmlProcessingInstruction(self, xml, f)
    local tag = {}

    -- XML Processing Instruction (PI)
    f.match, f.endMatch, f.text = string.find(xml, self._PI, f.pos)
    if not f.match then 
        err(self, self._errstr.piErr, f.pos)
    end 
    if self.handler.pi then 
        -- Parse PI attributes & text
        tag = parseTag(self, f.text) 
        local pi = string.sub(f.text, string.len(tag.name)+1)
        if pi ~= "" then
            if tag.attrs then
                tag.attrs._text = pi
            else
                tag.attrs = { _text = pi }
            end
        end
        self.handler:pi(tag, f.match, f.endMatch) 
    end

    return tag
end

local function parseComment(self, xml, f)
    f.match, f.endMatch, f.text = string.find(xml, self._COMMENT, f.pos)
    if not f.match then 
        err(self, self._errstr.commentErr, f.pos)
    end 

    if self.handler.comment then 
        f.text = parseEntities(self, stripWS(self, f.text))
        self.handler:comment(f.text, next, f.match, f.endMatch)
    end
end

local function _parseDtd(self, xml, pos)
    -- match,endMatch,root,type,name,uri,internal
    local m,e,r,t,n,u,i
    
    m,e,r,t,u,i = string.find(xml, self._DTD1,pos)
    if m then
        return m, e, {_root=r,_type=t,_uri=u,_internal=i} 
    end

    m,e,r,t,n,u,i = string.find(xml, self._DTD2,pos)
    if m then
        return m, e, {_root=r,_type=t,_name=n,_uri=u,_internal=i} 
    end

    m,e,r,i = string.find(xml, self._DTD3,pos)
    if m then
        return m, e, {_root=r,_internal=i} 
    end

    m,e,r,t,u = string.find(s,self._DTD4,pos)
    if m then
        return m,e,{_root=r,_type=t,_uri=u} 
    end

    m,e,r,t,n,u = string.find(s,self._DTD5,pos)
    if m then
        return m,e,{_root=r,_type=t,_name=n,_uri=u} 
    end

    return nil
end

local function parseDtd(self, xml, f)
    f.match, f.endMatch, attrs = self:_parseDtd(xml, f.pos)
    if not f.match then 
        err(self, self._errstr.dtdErr, f.pos)
    end 

    if self.handler.dtd then
        self.handler:dtd(attrs._root, attrs, f.match, f.endMatch)
    end
end

local function parseCdata(self, xml, f)
    f.match, f.endMatch, f.text = string.find(xml, self._CDATA, f.pos)
    if not f.match then 
        err(self, self._errstr.cdataErr, f.pos)
    end 

    if self.handler.cdata then
        self.handler:cdata(f.text, nil, f.match, f.endMatch)
    end    
end

--- Parse a Normal tag
-- Need check for embedded '>' in attribute value and extend
-- match recursively if necessary eg. <tag attr="123>456"> 
local function parseNormalTag(self, xml, f)
    while 1 do
        f.errStart, f.errEnd = string.find(f.tagstr,self._ATTRERR1)
        if f.errEnd == nil then
            f.errStart, f.errEnd = string.find(f.tagstr, self._ATTRERR2)
            if f.errEnd == nil then
                break
            end
        end
        f.extStart, f.extEnd, f.endt2 = string.find(xml, self._TAGEXT, f.endMatch+1)
        f.tagstr = f.tagstr .. string.sub(xml, f.endMatch, f.extEnd-1)
        if not f.match then 
            err(self, self._errstr.xmlErr, f.pos)
        end 
        f.endMatch = f.extEnd
    end 

    -- Extract tag name and attrs
    tag = parseTag(self, f.tagstr) 

    if (f.endt1=="/") then
        -- End tag
        if self.handler.endtag then
            if tag.attrs then
                -- Shouldn't have any attributes in endtag
                err(self, string.format("%s (/%s)", self._errstr.endTagErr, tag.name), f.pos)
            end
            if table.remove(self._stack) ~= tag.name then
                err(self, string.format("%s (/%s)", self._errstr.unmatchedTagErr, tag.name), f.pos)
            end
            self.handler:endtag(tag, f.match, f.endMatch)
        end
    else
        -- Start Tag
        table.insert(self._stack, tag.name)
        if self.handler.starttag then
            self.handler:starttag(tag, f.match, f.endMatch)
        end
        --TODO: Tags com fechamento automático estão sendo
        --retornadas como uma tabela, o que complica
        --para a app NCLua tratar isso. É preciso
        --fazer com que seja retornado um campo string vazio.

        -- Self-Closing Tag
        if (f.endt2=="/") then
            table.remove(self._stack)
            if self.handler.endtag then
                self.handler:endtag(tag, f.match, f.endMatch)
            end
        end
    end

    return tag
end

local function parseTagType(self, xml, f)
    -- Test for tag type
    if string.find(string.sub(f.tagstr, 1, 5), "?xml%s") then
        tag = parseXmlDeclaration(self, xml, f)
    elseif string.sub(f.tagstr, 1, 1) == "?" then
        tag = parseXmlProcessingInstructions(self, xml, f)
    elseif string.sub(f.tagstr, 1, 3) == "!--" then
        parseComment(self, xml, f)
    elseif string.sub(f.tagstr, 1, 8) == "!DOCTYPE" then
        parseDtd(self, xml, f)
    elseif string.sub(f.tagstr, 1, 8) == "![CDATA[" then
        parseCdata(self, xml, f)
    else
        parseNormalTag(self, xml, f)
    end
end

--- Get next tag (first pass - fix exceptions below).
--@return true if the next tag could be got, false otherwise
local function getNextTag(self, xml, f)
  f.match, f.endMatch, f.text, f.endt1, f.tagstr, f.endt2 = string.find(xml, self._XML, f.pos)
  if not f.match then 
      if string.find(xml, self._WS, f.pos) then
          -- No more text - check document complete
          if #self._stack ~= 0 then
              err(self, self._errstr.incompleteXmlErr, f.pos)
          else
              return false 
          end
      else
          -- Unparsable text
          err(self, self._errstr.xmlErr, f.pos)
      end
  end 

  f.text = f.text or ''
  f.tagstr = f.tagstr or ''
  f.match = f.match or 0
  
  return f.endMatch ~= nil
end

--Main function which starts the XML parsing process
--@param xml the XML string to parse
--@param parseAttributes indicates if tag attributes should be parsed or not. 
--       If omitted, the default value is true.
function XmlParser:parse(xml, parseAttributes)
    if type(self) ~= "table" or getmetatable(self) ~= XmlParser then
        error("You must call xmlparser:parse(parameters) instead of xmlparser.parse(parameters)")
    end
    
    if parseAttributes == nil then
        parseAttributes = true
    end
    self.handler.parseAttributes = parseAttributes

    --Stores string.find results and parameters
    --and other auxiliar variables
    local f = {
        --string.find return
        match = 0, 
        endMatch = 0,
        text, end1, tagstr, end2,

        --string.find parameters and auxiliar variables
        pos = 1, startText, endText, 
        errStart, errEnd, extStart, extEnd,
    }

    while f.match do
        if not getNextTag(self, xml, f) then
            break
        end
        
        -- Handle leading text
        f.startText = f.match
        f.endText = f.match + string.len(f.text) - 1
        f.match = f.match + string.len(f.text)
        f.text = parseEntities(self, stripWS(self, f.text))
        if f.text ~= "" and self.handler.text then
            self.handler:text(f.text, nil, f.match, f.endText)
        end

        parseTagType(self, xml, f)
        f.pos = f.endMatch + 1
    end
end

XmlParser.__index = XmlParser
return XmlParser