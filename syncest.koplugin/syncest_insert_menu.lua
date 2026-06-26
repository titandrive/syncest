local reader_order = require("ui/elements/reader_menu_order")

local pos = 1
for index, value in ipairs(reader_order.tools) do
    if value == "highlight_sync" then
        pos = index + 1
        break
    end
end
table.insert(reader_order.tools, pos, "syncest")

local ok, filemanager_order = pcall(require, "ui/elements/filemanager_menu_order")
if ok and filemanager_order then
    pos = 1
    for index, value in ipairs(filemanager_order.tools) do
        if value == "highlight_sync" then
            pos = index + 1
            break
        end
    end
    table.insert(filemanager_order.tools, pos, "syncest")
end
