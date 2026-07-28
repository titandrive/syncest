-- Small self-contained diagonal corner banner used by the cloud library.

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local M = {}
local cache = {}

function M.paint(bb, cover_left, cover_right, cover_top, cover_h,
        span, band_thick, label, font_size, fill_color, text_color)
    local diagonal = 0.70711
    local width = math.ceil((span + band_thick * 2) * 1.41422)
    local height = band_thick
    if width <= 0 or height <= 0 then return end

    local key = table.concat({
        width, height, bb:getType(), label, font_size,
        fill_color:getColor8().a, text_color:getColor8().a,
    }, "|")
    local banner = cache[key]
    if not banner then
        banner = Blitbuffer.new(width, height, bb:getType())
        if not banner then return end
        banner:paintRectRGB32(0, 0, width, height, text_color)
        if height > 2 then
            banner:paintRectRGB32(0, 1, width, height - 2, fill_color)
        end

        local max_width = math.floor(width * 0.82)
        local max_height = math.max(1, height - 2)
        local text
        local text_size
        local size = font_size
        repeat
            if text and text.free then text:free() end
            text = TextWidget:new{
                text = label,
                face = Font:getFace("cfont", size),
                bold = true,
                fgcolor = text_color,
                padding = 0,
            }
            text_size = text:getSize()
            if text_size.w <= max_width and text_size.h <= max_height then break end
            size = size - 1
        until size < 6
        text:paintTo(
            banner,
            math.max(0, math.floor((width - text_size.w) / 2)),
            math.max(0, math.floor((height - text_size.h) / 2)))
        if text.free then text:free() end
        cache[key] = banner
    end

    local center_x = cover_right - math.floor(span / 2)
    local center_y = cover_top + math.floor(span / 2)
    local half_box = math.ceil((width + height) * diagonal / 2) + 1
    local bb_width, bb_height = bb:getWidth(), bb:getHeight()
    local half_width, half_height = width / 2, height / 2
    for dy = center_y - half_box, center_y + half_box do
        if dy >= cover_top and dy < cover_top + cover_h
                and dy >= 0 and dy < bb_height then
            local relative_y = dy - center_y
            for dx = center_x - half_box, center_x + half_box do
                if dx >= cover_left and dx < cover_right
                        and dx >= 0 and dx < bb_width then
                    local relative_x = dx - center_x
                    local source_x = math.floor(
                        half_width + (relative_x + relative_y) * diagonal)
                    local source_y = math.floor(
                        half_height + (relative_y - relative_x) * diagonal)
                    if source_x >= 0 and source_x < width
                            and source_y >= 0 and source_y < height then
                        bb:setPixel(dx, dy, banner:getPixel(source_x, source_y))
                    end
                end
            end
        end
    end
end

return M
