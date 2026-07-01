local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local sha2 = require("ffi/sha2")
local T = require("ffi/util").template
local _ = require("syncest_i18n")

local SyncAnnotations = {}

-- KOReader color name → Readest color value
local KO_TO_READEST_COLOR = {
    yellow = "yellow",
    red = "red",
    green = "green",
    blue = "blue",
    purple = "violet",
    orange = "#ff8800",
    cyan = "#00bcd4",
    olive = "#808000",
    gray = "#9e9e9e",
}

-- Readest color value → KOReader color name
local READEST_TO_KO_COLOR = {
    yellow = "yellow",
    red = "red",
    green = "green",
    blue = "blue",
    violet = "purple",
    ["#ff8800"] = "orange",
    ["#00bcd4"] = "cyan",
    ["#808000"] = "olive",
    ["#9e9e9e"] = "gray",
}

function SyncAnnotations:parseDatetimeToMs(dt)
    if not dt then return os.time() * 1000 end
    local y, m, d, h, min, s = dt:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if y then
        return os.time({
            year = tonumber(y), month = tonumber(m), day = tonumber(d),
            hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
        }) * 1000
    end
    return os.time() * 1000
end

function SyncAnnotations:parseISODatetime(dt)
    if not dt then return os.time() end
    local y, m, d, h, min, s = dt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if y then
        return os.time({
            year = tonumber(y), month = tonumber(m), day = tonumber(d),
            hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
        })
    end
    return os.time()
end

function SyncAnnotations:generateNoteId(book_hash, note_type, pos0, pos1)
    local raw = "ko:" .. book_hash .. ":" .. note_type .. ":" .. (pos0 or "") .. ":" .. (pos1 or "")
    return sha2.md5(raw):sub(1, 7)
end

-- Build the Readest note payload for a single KOReader annotation item, or nil
-- if the item isn't a syncable highlight/bookmark. Shared by the push walk
-- (getAnnotations) and the deletion path (recordDeletion) so a note's id is
-- derived identically however it was created.
function SyncAnnotations:buildNoteDescriptor(item, book_hash)
    local note_text = item.note
    if note_text == "" then note_text = nil end

    local pos0 = item.pos0
    local pos1 = item.pos1
    if type(pos0) == "table" then pos0 = nil end
    if type(pos1) == "table" then pos1 = nil end

    if item.drawer and pos0 then
        -- Annotation (highlight/underline/strikeout): has drawer and pos0/pos1
        local style = "highlight"
        if item.drawer == "underscore" then
            style = "underline"
        elseif item.drawer == "strikeout" then
            style = "squiggly"
        end

        local id = item.id or self:generateNoteId(book_hash, "annotation", tostring(pos0), pos1 and tostring(pos1))
        return {
            bookHash = book_hash,
            id = id,
            type = "annotation",
            xpointer0 = tostring(pos0),
            xpointer1 = pos1 and tostring(pos1) or nil,
            text = item.text or "",
            note = note_text,
            style = style,
            color = KO_TO_READEST_COLOR[item.color or "yellow"],
            page = item.pageno,
            createdAt = self:parseDatetimeToMs(item.datetime),
            updatedAt = self:parseDatetimeToMs(item.datetime_updated or item.datetime),
        }
    elseif not item.drawer and type(item.page) == "string" then
        -- Bookmark: no drawer, position in page field (xpointer string)
        local page_xp = item.page
        local id = item.id or self:generateNoteId(book_hash, "bookmark", page_xp)
        return {
            bookHash = book_hash,
            id = id,
            type = "bookmark",
            xpointer0 = page_xp,
            text = item.text or "",
            note = note_text,
            page = item.pageno,
            createdAt = self:parseDatetimeToMs(item.datetime),
            updatedAt = self:parseDatetimeToMs(item.datetime_updated or item.datetime),
        }
    end
    return nil
end

function SyncAnnotations:getAnnotations(ui, settings, book_hash, full_sync)
    local annotations = ui.annotation and ui.annotation.annotations
    if not annotations then return {} end

    local last_sync = full_sync and 0 or (settings.last_notes_sync_at or 0)

    local notes = {}
    for _, item in ipairs(annotations) do
        local updated_at = self:parseDatetimeToMs(item.datetime_updated or item.datetime)
        if updated_at > last_sync then
            local note = self:buildNoteDescriptor(item, book_hash)
            if note then
                notes[#notes + 1] = note
            end
        end
    end
    return notes
end

-- Drop local annotations the server has tombstoned (deleted_at set), so a
-- highlight deleted on Readest also disappears in KOReader. Without this,
-- pull only skips deleted notes — the local copy lingers and any later
-- push resurrects it on the server, making it reappear (issue #4119).
function SyncAnnotations:removeDeletedAnnotations(annotation_mgr, notes, book_hash)
    local annotations = annotation_mgr and annotation_mgr.annotations
    if not annotations or #annotations == 0 then return 0 end

    -- Map every local annotation to its index by id and by position so a
    -- tombstone can be matched however it was originally created: pulled
    -- notes carry a stored id, native KOReader highlights don't (their id
    -- is derived from book hash + positions, matching what push uploads).
    local index_by_id = {}
    local index_by_anno = {}
    local index_by_bookmark = {}
    for i, item in ipairs(annotations) do
        if item.id then
            index_by_id[item.id] = i
        end
        if item.drawer then
            local pos0 = item.pos0
            local pos1 = item.pos1
            if type(pos0) == "table" then pos0 = nil end
            if type(pos1) == "table" then pos1 = nil end
            if pos0 then
                index_by_anno[tostring(pos0) .. "|" .. tostring(pos1 or "")] = i
                if not item.id then
                    local id = self:generateNoteId(book_hash, "annotation", tostring(pos0), pos1 and tostring(pos1))
                    index_by_id[id] = i
                end
            end
        elseif type(item.page) == "string" then
            index_by_bookmark[item.page] = i
            if not item.id then
                local id = self:generateNoteId(book_hash, "bookmark", item.page)
                index_by_id[id] = i
            end
        end
    end

    local to_remove = {}
    for _, note in ipairs(notes) do
        if note.deletedAt or note.deleted_at then
            local idx
            if note.id and index_by_id[note.id] then
                idx = index_by_id[note.id]
            elseif note.type == "bookmark" and note.xpointer0 then
                idx = index_by_bookmark[note.xpointer0]
            elseif note.xpointer0 then
                idx = index_by_anno[note.xpointer0 .. "|" .. (note.xpointer1 or "")]
            end
            if idx then
                to_remove[idx] = true
            end
        end
    end

    -- Remove highest index first so earlier indexes stay valid.
    local indexes = {}
    for idx in pairs(to_remove) do
        indexes[#indexes + 1] = idx
    end
    table.sort(indexes, function(a, b) return a > b end)
    for _, idx in ipairs(indexes) do
        table.remove(annotations, idx)
    end
    return #indexes
end

-- Stash a tombstone for a note deleted locally. By the time auto-sync runs the
-- deleted item is already gone from ui.annotation.annotations, so the push walk
-- can't see it; without this the deletion never reaches the server and the
-- highlight resurrects on the next pull (issue #4119, push direction). The
-- tombstone is a normal note payload with deletedAt set, persisted in the
-- per-book sidecar and folded into the next push (see push()), then cleared
-- once the server accepts it.
function SyncAnnotations:recordDeletion(doc_settings, item)
    if not doc_settings or not item then return end
    local book_hash = doc_settings:readSetting("partial_md5_checksum")
    if not book_hash then return end

    local doc_readest_sync = doc_settings:readSetting("webdav_sync") or {}
    local note = self:buildNoteDescriptor(item, book_hash)
    if not note then return end
    note.deletedAt = os.time() * 1000

    local deleted = doc_readest_sync.deleted_notes or {}
    for _, t in ipairs(deleted) do
        if t.id == note.id then return end -- already recorded
    end
    deleted[#deleted + 1] = note
    doc_readest_sync.deleted_notes = deleted
    doc_settings:saveSetting("webdav_sync", doc_readest_sync)
    doc_settings:flush()
end

function SyncAnnotations:push(ui, settings, client, interactive, full_sync, notify_fn)
    local book_hash = ui.doc_settings:readSetting("partial_md5_checksum")
    if not book_hash then return end
    local doc_readest_sync = ui.doc_settings:readSetting("webdav_sync") or {}

    local annotations = self:getAnnotations(ui, settings, book_hash, full_sync)

    -- Fold in tombstones for notes deleted locally since the last push. These
    -- are gone from ui.annotation.annotations, so getAnnotations can't see them;
    -- re-stamp the current book/meta hash in case they were recorded before the
    -- book was registered for sync.
    local deleted_notes = doc_readest_sync.deleted_notes or {}
    for _, t in ipairs(deleted_notes) do
        t.bookHash = book_hash
        annotations[#annotations + 1] = t
    end

    if #annotations == 0 then return end

    local payload = {
        books = {},
        notes = annotations,
        configs = {},
    }
    logger.dbg("ReadestSync: Pushing annotations, payload:", payload)

    client:pushChanges(
        payload,
        function(success, _response)
            if success then
                settings.last_notes_sync_at = os.time() * 1000
                G_reader_settings:saveSetting("webdav_sync", settings)
                if ui.doc_settings then
                    local synced = ui.doc_settings:readSetting("webdav_sync") or {}
                    synced.last_pushed_at_notes = os.time()
                    -- The server has the tombstones now; drop them so they don't
                    -- ride along on every future push.
                    synced.deleted_notes = nil
                    ui.doc_settings:saveSetting("webdav_sync", synced)
                    ui.doc_settings:flush()
                end
                if notify_fn then notify_fn("annotations", "pushed") end
            end
        end
    )
end

function SyncAnnotations:applyPulledNotes(ui, settings, notes, book_hash, dialog, notify_fn)
    if not notes or #notes == 0 then return false end

    logger.dbg("ReadestSync: Pulled annotations from sync:", #notes)
    local annotation_mgr = ui.annotation
    if not annotation_mgr then return false end

    -- Honor remote deletions before adding: drop local annotations the server
    -- has tombstoned so they don't reappear (issue #4119).
    local removed = self:removeDeletedAnnotations(annotation_mgr, notes, book_hash)

    -- Build dedup sets: by ID, by pos0|pos1 for annotations, by page xpointer for bookmarks.
    local existing_ids = {}
    local existing_annotations = {}
    local existing_bookmarks = {}
    for _, item in ipairs(annotation_mgr.annotations) do
        if item.id then
            existing_ids[item.id] = true
        end
        if item.drawer then
            local pos0 = item.pos0
            local pos1 = item.pos1
            if type(pos0) == "table" then pos0 = nil end
            if type(pos1) == "table" then pos1 = nil end
            local key = tostring(pos0) .. "|" .. tostring(pos1 or "")
            existing_annotations[key] = true
            if not item.id and pos0 then
                local id = self:generateNoteId(book_hash, "annotation", tostring(pos0), pos1 and tostring(pos1))
                existing_ids[id] = true
            end
        elseif type(item.page) == "string" then
            existing_bookmarks[item.page] = true
            if not item.id then
                local id = self:generateNoteId(book_hash, "bookmark", item.page)
                existing_ids[id] = true
            end
        end
    end

    local added = 0
    for _, note in ipairs(notes) do
        if note.deletedAt or note.deleted_at then
            goto continue
        end

        local xp0 = note.xpointer0
        if not xp0 then goto continue end
        if note.id and existing_ids[note.id] then goto continue end

        local note_type = note.type
        local item

        local created = self:parseISODatetime(note.created_at)
        local updated = self:parseISODatetime(note.updated_at) or created
        local datetime_str = os.date("%Y-%m-%d %H:%M:%S", created)
        local datetime_updated_str = os.date("%Y-%m-%d %H:%M:%S", updated)

        local pageno = ui.document:getPageFromXPointer(xp0) or note.page
        local chapter = ui.toc and ui.toc:getTocTitleByPage(xp0) or nil
        if chapter == "" then chapter = nil end

        local note_text = note.note
        if note_text == "" then note_text = nil end

        if note_type == "bookmark" then
            if existing_bookmarks[xp0] then goto continue end

            item = {
                id = note.id,
                page = xp0,
                text = note.text or "",
                note = note_text,
                chapter = chapter,
                pageno = pageno,
                datetime = datetime_str,
                datetime_updated = datetime_updated_str,
            }
            existing_bookmarks[xp0] = true
        else
            local xp1 = note.xpointer1
            local key = xp0 .. "|" .. (xp1 or "")
            if existing_annotations[key] then goto continue end

            local drawer = "lighten"
            if note.style == "underline" then
                drawer = "underscore"
            elseif note.style == "squiggly" then
                drawer = "strikeout"
            end

            item = {
                id = note.id,
                pos0 = xp0,
                pos1 = xp1 or xp0,
                page = xp0,
                text = note.text or "",
                note = note_text,
                drawer = drawer,
                color = READEST_TO_KO_COLOR[note.color] or "yellow",
                chapter = chapter,
                pageno = pageno,
                datetime = datetime_str,
                datetime_updated = datetime_updated_str,
            }
            existing_annotations[key] = true
        end

        local index = annotation_mgr:addItem(item)
        ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index }))
        logger.dbg("ReadestSync: Added annotation from sync:", item)
        added = added + 1

        ::continue::
    end

    settings.last_notes_sync_at = os.time() * 1000
    G_reader_settings:saveSetting("webdav_sync", settings)
    if ui.doc_settings then
        local doc_readest_sync = ui.doc_settings:readSetting("webdav_sync") or {}
        doc_readest_sync.last_synced_at_notes = os.time()
        ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
        ui.doc_settings:flush()
    end

    if added > 0 or removed > 0 then
        UIManager:setDirty(dialog, "ui")
    end
    if notify_fn and (added > 0 or removed > 0) then
        notify_fn("annotations", "updated")
    end
    return true
end

function SyncAnnotations:pull(ui, settings, client, book_hash, dialog, interactive, full_sync, notify_fn)
    if ui.document.info.has_pages then
        if interactive then
            local InfoMessage = require("ui/widget/infomessage")
            local UIManager = require("ui/uimanager")
            UIManager:show(InfoMessage:new{ text = _("Annotation sync is not supported for PDF/CBZ documents."), timeout = 3 })
        end
        return
    end

    client:pullChanges(
        {
            since = full_sync and 0 or (settings.last_notes_sync_at or 0),
            type = "notes",
            book = book_hash,
        },
        function(success, response, status)
            if not success then return end

            local data = response.notes
            self:applyPulledNotes(ui, settings, data, book_hash, dialog, notify_fn)
        end
    )
end

return SyncAnnotations
