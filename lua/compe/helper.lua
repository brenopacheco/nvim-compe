local Pattern = require'compe.pattern'
local Character = require'compe.utils.character'

local Helper = {}

--- determine
Helper.determine = function(context, option)
  option = option or {}

  local trigger_character_offset = 0
  if option.trigger_characters and context.before_char ~= ' ' then
    if vim.tbl_contains(option.trigger_characters, context.before_char) then
      trigger_character_offset = context.col
    end
  end

  local keyword_pattern_offset = 0
  if option.keyword_pattern then
    keyword_pattern_offset = Pattern.get_pattern_offset(context.before_line, option.keyword_pattern)
  else
    keyword_pattern_offset = Pattern.get_keyword_offset(context)
  end

  return {
    keyword_pattern_offset = keyword_pattern_offset;
    trigger_character_offset = trigger_character_offset;
  }
end

--- get_keyword_pattern
Helper.get_keyword_pattern = function(filetype)
  return Pattern.get_keyword_pattern(filetype)
end

--- get_default_keyword_pattern
Helper.get_default_pattern = function()
  return Pattern.get_default_pattern()
end

--- convert_lsp
Helper.convert_lsp = function(args)
  local keyword_pattern_offset = args.keyword_pattern_offset
  local context = args.context
  local request = args.request
  local response = args.response

  local complete_items = {}
  for _, completion_item in pairs(vim.tbl_islist(response or {}) and response or response.items or {}) do
    local word = ''
    local abbr = ''
    if completion_item.insertTextFormat == 2 then
      word = completion_item.label
      abbr = completion_item.label

      local text = word
      if completion_item.textEdit ~= nil then
        text = completion_item.textEdit.newText or text
      elseif completion_item.insertText ~= nil then
        text = completion_item.insertText or text
      end
      if word ~= text then
        abbr = abbr .. '~'
      end
      word = text
    else
      word = completion_item.insertText or completion_item.label
      abbr = completion_item.label
    end

    -- Fix for textEdit
    --
    -- 1. sumneko_lua's require completion
    --
    --   local Config = require'compe.| -> local Config = require'compe.config|
    --
    --   ※ `.` is not contained in keyword_pattern so we should fix offset. If item has `textEdit` we should use `textEdit.range.start.character`
    --
    local offset_fixed = false
    if not offset_fixed and completion_item.textEdit then
      -- https://github.com/microsoft/vscode/blob/master/src/vs/editor/contrib/suggest/completionModel.ts#L170
      -- https://github.com/microsoft/vscode/blob/master/src/vs/editor/contrib/suggest/completionModel.ts#L195
      -- TODO: This implementation aligned to following cases.
      -- 1. html-language-server's closing tag's textEdit
      -- 2. clangd's dot-property accessing
      local idx = completion_item.textEdit.range.start.character + 1
      if string.find(word, string.sub(context.before_line, idx, -1), 1, true) == 1 then
        keyword_pattern_offset = idx
        offset_fixed = true
      end
    end

    -- Fix for leading_word
    --
    -- 1. tsserver's scoped module completion
    --
    --   import {} from '@|' -> import {} from '@babel'
    --   ※ `@` is not contained in keyword_pattern so we should fix offset to include '@'.
    --
    if not offset_fixed and not Character.is_alnum(string.byte(word, 1)) then
      -- TODO: We should check this implementation respecting what is VSCode does.
      for idx = #context.before_line, 1, -1 do
        if Character.is_white(string.byte(context.before_line, idx)) then
          break
        end
        if Character.match(string.byte(word, 1), string.byte(context.before_line, idx)) then
          local part = string.sub(context.before_line, idx, -1)
          if string.find(word, part, 1, true) == 1 then
            keyword_pattern_offset = idx
            offset_fixed = true
            break
          end
        end
      end
    end

    table.insert(complete_items, {
      word = word;
      abbr = abbr;
      kind = vim.lsp.protocol.CompletionItemKind[completion_item.kind] or nil;
      user_data = {
        compe = {
          request_position = request.position;
          completion_item = completion_item;
        };
      };
      filter_text = completion_item.filterText or nil;
      sort_text = completion_item.sortText or nil;
      preselect = completion_item.preselect or false;
      offset = keyword_pattern_offset;
      offset_fixed = offset_fixed;
    })
  end

  -- Remove invalid chars from word without already allowed range.
  --   `func`($0)
  --   `class`="$0"
  --   `variable`$0
  --   `"json-props"`: "$0"

  local fixed_offset = args.keyword_pattern_offset
  for _, complete_item in ipairs(complete_items) do
    local leading = (args.keyword_pattern_offset - complete_item.offset)
    complete_item.word = string.match(complete_item.word, ('.'):rep(leading) .. '[^%s=%(%$\'"]+') or ''
    complete_item.abbr = string.gsub(string.gsub(complete_item.abbr, '^%s*', ''), '%s*$', '')
    fixed_offset = math.min(fixed_offset, complete_item.offset)
  end

  return {
    items = complete_items,
    incomplete = response.isIncomplete or false,
    keyword_pattern_offset = fixed_offset,
  }
end

return Helper

