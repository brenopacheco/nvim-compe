local Cache = require'compe.utils.cache'
local Async = require'compe.utils.async'
local Boolean = require'compe.utils.boolean'
local Config = require'compe.config'
local Matcher = require'compe.matcher'
local Context = require'compe.context'

local Source =  {}

Source.base_id = 0

--- new
function Source.new(name, source)
  Source.base_id = Source.base_id + 1

  local self = setmetatable({}, { __index = Source })
  self.id = Source.base_id
  self.name = name
  self.source = source
  self.revision = 0
  self:clear()
  return self
end

-- clear
Source.clear = function(self)
  self.revision = self.revision + 1
  self.status = 'waiting'
  self.metadata = nil
  self.item_id = 0
  self.items = {}
  self.resolved_items = {}
  self.keyword_pattern_offset = 0
  self.trigger_character_offset = 0
  self.is_triggered_by_character = false
  self.context = Context.new({})
  self.request_time = vim.loop.now()
  self.incomplete = false
end

-- trigger
Source.trigger = function(self, context, callback)
  self.context = context

  local metadata = self:get_metadata()

  -- Check filetypes.
  if metadata.filetypes and #metadata.filetypes then
    if not vim.tbl_contains(metadata.filetypes or {}, context.filetype) then
      return self:clear()
    end
  end
  if metadata.ignored_filetypes and #metadata.ignored_filetypes then
    if vim.tbl_contains(metadata.ignored_filetypes or {}, context.filetype) then
      return self:clear()
    end
  end

  -- Normalize trigger offsets
  local state = self.source:determine(context)
  state.trigger_character_offset = state.trigger_character_offset == nil and 0 or state.trigger_character_offset
  state.keyword_pattern_offset = state.keyword_pattern_offset == nil and 0 or state.keyword_pattern_offset
  state.keyword_pattern_offset = state.keyword_pattern_offset == 0 and state.trigger_character_offset or state.keyword_pattern_offset

  -- Check first trigger condition.
  local count = #self:get_filtered_items(context)
  local short = #context:get_input(state.keyword_pattern_offset) < Config.get().min_length
  local empty = (function()
    if context.is_trigger_character_only then
      return state.trigger_character_offset == 0
    end
    return state.keyword_pattern_offset == 0 and state.trigger_character_offset == 0
  end)()

  local manual = context.manual
  local incomplete = self.incomplete and not empty and (vim.loop.now() - self.request_time) > Config.get().incomplete_delay
  local characters = state.trigger_character_offset > 0

  -- if self.status == 'completed' then
  --   if context.col == self.keyword_pattern_offset then
  --     return self:clear()
  --   end
  -- end

  if not (manual or characters or incomplete) then
    -- Does not match.
    if empty then
      return self:clear()
    end

    -- Avoid short input if context is not force.
    if short then
      return self:clear()
    end

    if self.status ~= 'waiting' then
      return
    end
  end

  -- Fix keyword_pattern_offset
  if empty then
    state.keyword_pattern_offset = context.col
  end

  -- Reset current completion
  if empty and count == 0 then
    self:clear()
  end

  -- Update is_triggered_by_character
  if state.trigger_character_offset > 0 then
    self.is_triggered_by_character = state.trigger_character_offset > 0
  end

  self.status = 'processing'
  self.request_time = vim.loop.now()

  -- Completion
  self.source:complete({
    context = self.context;
    input = self.context:get_input(state.keyword_pattern_offset);
    keyword_pattern_offset = state.keyword_pattern_offset;
    trigger_character_offset = state.trigger_character_offset;
    incomplete = self.incomplete;
    callback = Async.fast_schedule_wrap(function(result)
      if self.context ~= context then
        return
      end

      if incomplete and #result.items == 0 then
        self.items = self.items
      else
        self.items = self:_normalize_items(context, result.items)
      end

      self.revision = self.revision + 1
      self.status = 'completed'
      self.incomplete = result.incomplete or false
      self.keyword_pattern_offset = result.keyword_pattern_offset or state.keyword_pattern_offset
      self.trigger_character_offset = state.trigger_character_offset

      callback()
    end);
    abort = Async.fast_schedule_wrap(function()
      self:clear()
      callback()
    end);
  })
  return true
end

--- resolve
Source.resolve = function(self, args)
  if self.resolved_items[args.completed_item.item_id] then
    return args.callback(self.resolved_items[args.completed_item.item_id])
  end

  if not self.source.resolve then
    self.resolved_items[args.completed_item.item_id] = args.completed_item
    return args.callback(self.resolved_items[args.completed_item.item_id])
  end

  self.source:resolve({
    completed_item = args.completed_item,
    callback = function(resolved_completed_item)
      self.resolved_items[args.completed_item.item_id] = resolved_completed_item or args.completed_item
      args.callback(self.resolved_items[args.completed_item.item_id])
    end;
  })
end

--- documentation
Source.documentation = function(self, completed_item)
  if self.source.documentation then
    self:resolve({
      completed_item = completed_item,
      callback = function(resolved_completed_item)
        self.source:documentation({
          completed_item = resolved_completed_item;
          context = Context.new({});
          callback = Async.guard('Source.documentation#callback', Async.fast_schedule_wrap(function(document)
            if document and #document ~= 0 then
              vim.call('compe#documentation#open', document)
            else
              vim.call('compe#documentation#close')
            end
          end));
          abort = Async.guard('Source.documentation#abort', Async.fast_schedule_wrap(function()
            vim.call('compe#documentation#close')
          end));
        })
      end
    })
  else
    Async.fast_schedule(function()
      vim.call('compe#documentation#close')
    end)
  end
end

--- confirm
Source.confirm = function(self, completed_item, callback)
  if self.source.confirm then
    self:resolve({
      completed_item = completed_item,
      callback = function(resolved_completed_item)
        self.source:confirm({
          completed_item = resolved_completed_item,
        })
        callback()
      end
    })
  else
    callback()
  end
end

--- get_metadata
Source.get_metadata = function(self)
  if not self.metadata then
    self.metadata = self.source:get_metadata()
  end

  local metadata = self.metadata
  for key, value in pairs(Config.get_metadata(self.name)) do
    metadata[key] = value
  end
  return metadata
end

--- get_filtered_items
Source.get_filtered_items = function(self, context)
  local start_offset = self:get_start_offset()
  local input = context:get_input(start_offset)

  local cache_group_key = {}
  table.insert(cache_group_key, 'source.get_filtered_items')
  table.insert(cache_group_key, self.id)
  cache_group_key = table.concat(cache_group_key, ':')

  local curr_cache_key = {}
  table.insert(curr_cache_key, self.revision)
  table.insert(curr_cache_key, context.lnum)
  table.insert(curr_cache_key, start_offset)
  table.insert(curr_cache_key, input)
  curr_cache_key = table.concat(curr_cache_key, ':')

  local prev_items = (function()
    if #input == 0 then
      return nil
    end

    local prev_cache_key = {}
    table.insert(prev_cache_key, self.revision)
    table.insert(prev_cache_key, context.lnum)
    table.insert(prev_cache_key, start_offset)
    for i = #input, 1, -1 do
      table.insert(prev_cache_key, input:sub(1, i))
      local prev_items = Cache.get(cache_group_key, table.concat(prev_cache_key, ':'))
      if prev_items then
        return prev_items
      end
      table.remove(prev_cache_key, #prev_cache_key)
    end
    return nil
  end)()

  return Cache.ensure(cache_group_key, curr_cache_key, function()
    if prev_items then
      return Matcher.match(input, prev_items)
    end
    return Matcher.match(input, self.items)
  end)
end

--- get_processing_time
Source.get_processing_time = function(self)
  if self.status == 'processing' then
    return vim.loop.now() - self.request_time
  end
  return Config.get().source_timeout + 1
end

--- get_start_offset
Source.get_start_offset = function(self)
  return self.keyword_pattern_offset or 0
end

--- is_completing
Source.is_completing = function(self, context)
  local is_completing = true
  is_completing = is_completing and self.context.bufnr == context.bufnr
  is_completing = is_completing and self.context.lnum == context.lnum
  is_completing = self.status == 'completed' or (self.incomplete and self.status == 'processing')
  return is_completing
end

--- _normalize_items
Source._normalize_items = function(self, _, items)
  local metadata = self:get_metadata()

  local normalized = {}
  for _, item in ipairs(items) do
    self.item_id = self.item_id + 1

    -- string to completed_item
    if type(item) == 'string' then
      item = {
        word = item;
        abbr = item;
      }
    end

    -- complete-items properties.
    item.word = item.word
    item.abbr = item.abbr or item.word
    item.kind = item.kind or metadata.kind or nil
    item.menu = item.menu or metadata.menu or nil
    item.equal = 1
    item.empty = 1
    item.dup = 1

    -- special properties
    item.filter_text = item.filter_text or nil
    item.sort_text = item.sort_text or nil
    item.preselect = item.preselect or false

    -- internal properties
    item.item_id = self.item_id
    item.source_id = self.id
    item.priority = metadata.priority or 0
    item.sort = Boolean.get(metadata.sort, true)

    -- matcher related properties (will be overwrote)
    item.index = 0
    item.score = 0
    item.fuzzy = false

    -- save original properties
    item.original_word = item.word
    item.original_abbr = item.abbr
    item.original_kind = item.kind
    item.original_menu = item.menu
    item.original_dup = Boolean.get(metadata.dup, true) and 1 or 0

    table.insert(normalized, item)
  end
  return normalized
end

return Source

