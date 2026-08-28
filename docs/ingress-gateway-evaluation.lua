local status_markers = {
  ["📝"] = "\\ingressStatusDraft{}",
  ["✅"] = "\\ingressStatusGood{}",
  ["⚠️"] = "\\ingressStatusWarning{}",
  ["⏳"] = "\\ingressStatusPending{}",
  ["🟢"] = "\\ingressStatusPreferred{}",
  ["🟡"] = "\\ingressStatusAlternative{}",
  ["⚪"] = "\\ingressStatusNeutral{}",
  ["🔴"] = "\\ingressStatusExcluded{}",
  ["☐"] = "\\ingressStatusUnchecked{}",
}

local function replace_status_markers(value)
  local inlines = {}
  local index = 1

  while index <= #value do
    local next_position = nil
    local next_marker = nil

    for marker, _ in pairs(status_markers) do
      local position = string.find(value, marker, index, true)
      if position and (not next_position or position < next_position) then
        next_position = position
        next_marker = marker
      end
    end

    if not next_position then
      table.insert(inlines, pandoc.Str(string.sub(value, index)))
      break
    end

    if next_position > index then
      table.insert(inlines, pandoc.Str(string.sub(value, index, next_position - 1)))
    end

    table.insert(inlines, pandoc.RawInline("latex", status_markers[next_marker]))
    index = next_position + #next_marker
  end

  return inlines
end

function Str(element)
  for marker, _ in pairs(status_markers) do
    if string.find(element.text, marker, 1, true) then
      return replace_status_markers(element.text)
    end
  end

  return element
end
