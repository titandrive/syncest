local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("syncest_i18n")

local SyncConfig = {}

local function normalizeIdentifier(identifier)
    if identifier:match("urn:") then
        return identifier:match("([^:]+)$")
    elseif identifier:match(":") then
        return identifier:match("^[^:]+:(.+)$")
    end
    return identifier
end

local function normalizeAuthor(author)
    author = author:gsub("^%s*(.-)%s*$", "%1")
    return author
end

function SyncConfig:getMetadataHashInfo(ui)
    local doc_props = ui.doc_settings:readSetting("doc_props") or {}
    local title = doc_props.title or ''
    if title == '' then
        local _doc_path, filename = util.splitFilePathName(ui.doc_settings:readSetting("doc_path") or '')
        local basename, _suffix = util.splitFileNameSuffix(filename)
        title = basename or ''
    end

    local authors_raw = doc_props.authors or ''
    local authors_list = {}
    if authors_raw:find("\n") then
        local list = util.splitToArray(authors_raw, "\n")
        for i, author in ipairs(list) do
            authors_list[i] = normalizeAuthor(author)
        end
    elseif authors_raw ~= '' then
        authors_list = { normalizeAuthor(authors_raw) }
    end

    local identifiers_raw = doc_props.identifiers or ''
    local identifiers_list = {}
    if identifiers_raw:find("\n") then
        local list = util.splitToArray(identifiers_raw, "\n")
        local normalized = {}
        local priorities = { "uuid", "calibre", "isbn" }
        local preferred = nil
        for i, id in ipairs(list) do
            normalized[i] = normalizeIdentifier(id)
            local candidate = id:lower()
            for _, p in ipairs(priorities) do
                if candidate:find(p, 1, true) then
                    preferred = normalized[i]
                    break
                end
            end
        end
        if preferred then
            identifiers_list = { preferred }
        else
            identifiers_list = normalized
        end
    elseif identifiers_raw ~= '' then
        identifiers_list = { normalizeIdentifier(identifiers_raw) }
    end

    local hash_source = title .. "|" .. table.concat(authors_list, ",") .. "|" .. table.concat(identifiers_list, ",")
    return {
        title = title,
        authors = authors_list,
        identifiers = identifiers_list,
        hash_source = hash_source,
    }
end

function SyncConfig:getDocumentIdentifier(ui)
    return ui.doc_settings:readSetting("partial_md5_checksum")
end

function SyncConfig:getCurrentBookConfig(ui)
    local book_hash = self:getDocumentIdentifier(ui)
    if not book_hash then return nil end

    local config = {
        bookHash  = book_hash,
        progress  = "",
        xpointer  = "",
        updatedAt = os.time() * 1000,
    }

    local current_page = ui:getCurrentPage()
    local page_count = ui.document:getPageCount()
    config.progress = {current_page, page_count}

    if not ui.document.info.has_pages then
        config.xpointer = ui.rolling:getLastProgress()
    end

    return config
end

function SyncConfig:applyBookConfig(ui, config, force)
    logger.dbg("ReadestSync: Applying book config:", config)
    local xpointer = config.xpointer
    local progress = config.progress
    local has_pages = ui.document.info.has_pages
    local progress_pattern = "^%[(%d+),(%d+)%]$"
    if has_pages and progress then
        local progress_str = type(progress) == "table"
            and ("[" .. tostring(progress[1]) .. "," .. tostring(progress[2]) .. "]")
            or tostring(progress)
        local page, _total_pages = progress_str:match(progress_pattern)
        local current_page = ui:getCurrentPage()
        local new_page = tonumber(page)
        if force or new_page > current_page then
            ui.link:addCurrentLocationToStack()
            ui:handleEvent(Event:new("GotoPage", new_page))
        end
    end
    if not has_pages and xpointer then
        local last_xpointer = ui.rolling:getLastProgress()
        local working_xpointer = xpointer
        local cmp_result = ui.document:compareXPointers(last_xpointer, working_xpointer)
        while cmp_result == nil and working_xpointer do
            local last_slash_pos = working_xpointer:match("^.*()/")
            if last_slash_pos and last_slash_pos > 1 then
                working_xpointer = working_xpointer:sub(1, last_slash_pos - 1)
                cmp_result = ui.document:compareXPointers(last_xpointer, working_xpointer)
            else
                break
            end
        end
        if force or (cmp_result and cmp_result > 0) then
            ui.link:addCurrentLocationToStack()
            ui:handleEvent(Event:new("GotoXPointer", working_xpointer))
        end
    end
end

function SyncConfig:push(ui, settings, client, interactive, last_sync_timestamp, notify_fn)
    local config = self:getCurrentBookConfig(ui)
    if not config then return last_sync_timestamp end

    local payload = {
        books = {},
        notes = {},
        configs = { config },
    }

    client:pushChanges(
        payload,
        function(success, _response)
            if success and ui.doc_settings then
                local doc_readest_sync = ui.doc_settings:readSetting("webdav_sync") or {}
                doc_readest_sync.last_pushed_at_config = os.time()
                ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
                ui.doc_settings:flush()
                if notify_fn then notify_fn("progress", "pushed") end
            end
        end
    )

    if not interactive then
        return os.time()
    end
    return last_sync_timestamp
end

function SyncConfig:pull(ui, settings, client, book_hash, interactive, logout_fn, notify_fn)
    client:pullChanges(
        {
            since = 0,
            type = "configs",
            book = book_hash,
        },
        function(success, response, status)
            if not success then
                local is_auth_fail = status == 401 or status == 403
                    or (response and response.error == "Not authenticated")
                if is_auth_fail then
                    if logout_fn then logout_fn() end
                end
                return
            end

            if ui.doc_settings then
                local doc_readest_sync = ui.doc_settings:readSetting("webdav_sync") or {}
                doc_readest_sync.last_synced_at_config = os.time()
                ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
                ui.doc_settings:flush()
            end
            if notify_fn then notify_fn("progress", "pulled") end

            local data = response.configs
            if data and #data > 0 then
                local config = data[1]
                if config then
                    self:applyBookConfig(ui, config, interactive)
                end
            end
        end
    )
end

return SyncConfig
