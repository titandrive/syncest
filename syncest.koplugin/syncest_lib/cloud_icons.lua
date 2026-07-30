-- cloud_icons.lua
-- Per-row cloud-up/cloud-down overlay icons painted on top of the
-- standard ListMenuItem widget tree. Loaded once from bundled SVGs
-- and cached as IconWidget instances for reuse across all rows.

local M = {}

-- Resolve apps/readest.koplugin root via debug.getinfo on this file's
-- own source path (same trick as zen_ui's plugin_root.lua). Needed
-- because our bundled icons aren't in any of KOReader's ICONS_DIRS,
-- so we load them by absolute path through ImageWidget instead of
-- IconWidget's name-based lookup.
local _plugin_root = (function()
    local src = debug.getinfo(1, "S").source or ""
    local path = (src:sub(1, 1) == "@")
        and src:sub(2):match("^(.*)/syncest_lib/[^/]+$") or nil
    if path and path:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs and lfs.currentdir()
        if cwd then path = cwd .. "/" .. path end
    end
    return path
end)()

local ICON_FILES = {
    dl = _plugin_root and (_plugin_root .. "/icons/cloud_download.svg"),
    up = _plugin_root and (_plugin_root .. "/icons/cloud_upload.svg"),
}

-- Per-icon cache: {key → {widget, size_loaded}}. IconWidget loads +
-- caches its bb on first render so we only pay the SVG decode once
-- per icon size.
local _cache = {}

function M.has_icon(kind)
    return ICON_FILES[kind] ~= nil
end

local function get_widget(kind, target_size)
    local entry = _cache[kind]
    if entry and entry.size_loaded == target_size then
        return entry.widget
    end
    if entry and entry.widget then
        local prev = entry.widget
        entry.widget = nil
        pcall(function() prev:free() end)
    end
    local file = ICON_FILES[kind]
    if not file then return nil end
    local ok, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if not ok then return nil end
    local Screen = require("device").screen
    local widget = ImageWidget:new{
        file = file,
        width = target_size,
        height = target_size,
        scale_factor = 0,  -- aspect-preserving fit
        alpha = true,      -- preserve SVG transparency
        is_icon = true,
        -- The whole UI buffer is inverted afterward in night mode. Invert
        -- this white asset once here too, so the final on-screen icon remains
        -- white in both day and night themes.
        invert = Screen.night_mode,
    }
    _cache[kind] = { widget = widget, size_loaded = target_size }
    return widget
end

-- Paint an icon at an exact position.
function M.paint_at(bb, icon_x, icon_y, target_size, kind)
    local icon = get_widget(kind, target_size)
    if not icon then return end
    icon:_render()
    icon:paintTo(bb, icon_x, icon_y)
end

-- Paint the cloud state over the list thumbnail. ListMenu reserves a square
-- thumbnail slot whose width matches the row height; using half that height
-- makes the state immediately visible without obscuring the whole cover.
function M.paint(item, bb, x, y, kind)
    local icon_size = math.floor(item.height * 0.50)
    local icon = get_widget(kind, icon_size)
    if not icon then return end
    icon:_render()
    local s = icon:getSize()
    local icon_x = x + math.floor((item.height - s.w) / 2)
    local icon_y = y + math.floor((item.height - s.h) / 2)
    M.paint_at(bb, icon_x, icon_y, icon_size, kind)
end

return M
