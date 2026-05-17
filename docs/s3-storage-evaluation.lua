local status_markers = {
  ["🟢"] = "\\sThreeStatusGood{}",
  ["🟡"] = "\\sThreeStatusMixed{}",
  ["🔴"] = "\\sThreeStatusPoor{}",
}

local function replace_status_markers(text)
  local inlines = {}
  local index = 1

  while index <= #text do
    local next_pos = nil
    local next_marker = nil

    for marker, _ in pairs(status_markers) do
      local pos = string.find(text, marker, index, true)
      if pos and (not next_pos or pos < next_pos) then
        next_pos = pos
        next_marker = marker
      end
    end

    if not next_pos then
      table.insert(inlines, pandoc.Str(string.sub(text, index)))
      break
    end

    if next_pos > index then
      table.insert(inlines, pandoc.Str(string.sub(text, index, next_pos - 1)))
    end

    table.insert(inlines, pandoc.RawInline("latex", status_markers[next_marker]))
    index = next_pos + #next_marker
  end

  return inlines
end

function Str(element)
  if string.find(element.text, "🟢", 1, true)
      or string.find(element.text, "🟡", 1, true)
      or string.find(element.text, "🔴", 1, true) then
    return replace_status_markers(element.text)
  end
  return element
end
