local compe = require("compe")

local Source = {
    -- store dictionaries directly in memory instead of reading from file 
    -- on every query
    dicts = {}
}

function Source.new()
    return setmetatable({}, { __index = Source })
end

function Source.get_metadata(_)
    return {
        priority = 90;
        dup = 0;
        menu = '[Dict]';
    }
end

function Source.determine(_, context)
    return compe.helper.determine(context)
end

function Source._load_dicts(self)
    -- get dictionary paths
    local paths = {}
    local opt = vim.bo.dictionary or vim.b.dictionary -- try buf local first
    for path in string.gmatch(opt, "([^,]+)") do
        paths[path] = true
    end

    -- load missing dictionaries into sources
    for path,_ in pairs(paths) do
        if not self.dicts[path] then
            self.dicts[path] = {}
            for line in io.lines(path) do
                if not string.match(line, "^%s*$") then -- skip empty lines
                    table.insert(self.dicts[path], line)
                end
            end
        end
    end

    -- removes unused dictionaries
    for path,_ in pairs(self.dicts) do
        if not paths[path] then
            self.dicts[path] = nil
        end
    end
end

function Source._matches(self, word)
    local matches = {}

    -- set a smartcase pattern for word
    local pattern = "^" .. string.gsub(word, "%a", function (c)
        if string.match(c, "%u") then
            return c
        else
            return string.format("[%s%s]", 
            string.lower(c),
            string.upper(c))
        end
    end)
    for path, dict in pairs(self.dicts) do
        local filename = vim.fn.fnamemodify(path, ":t:r")
        local len = 0
        for _,line in ipairs(dict) do
            if string.match(line, pattern) then
                len = len + 1
                table.insert(matches, {
                    word = line,
                    kind = filename
                })
            end
            -- having too many entries may slow things down if using very 
            -- large dictionaries. store up to 20 entries per dictionary
            if len >= 20 then break end 
        end
    end
    return matches
end

function Source.complete(self, context)
    self:_load_dicts()
    context.callback({
        items = self:_matches(context.input)
    })
end

return Source.new()

