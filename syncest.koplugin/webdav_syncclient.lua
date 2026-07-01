local DataStorage = require("datastorage")
local WebDavApi = require("apps/cloudstorage/webdavapi")
local json = require("json")
local logger = require("logger")
local http = require("socket.http")
local ok_socket, socket = pcall(require, "socket")

-- LuaSocket reads http.TIMEOUT on every new TCP connection, so this caps
-- the OS-level TCP connect + transfer time and prevents ANR crashes when
-- the WebDAV server is unreachable (e.g. VPN is off).
local SYNC_TIMEOUT = 4

local WebDavSyncClient = {}

local READ_MISSING = {}
local READ_FAILED = {}

local function now_ms()
    return math.floor(os.time() * 1000)
end

local function normalize_authors(authors)
    if type(authors) == "table" then
        return authors
    end
    if type(authors) == "string" and authors ~= "" then
        local out = {}
        for author in authors:gmatch("[^\n]+") do
            out[#out + 1] = author:gsub("^%s*(.-)%s*$", "%1")
        end
        return out
    end
    return {}
end

local function safe_title_filename(title)
    local name = tostring(title or ""):gsub("^%s*(.-)%s*$", "%1")
    if name == "" then name = "Untitled" end
    name = name:gsub('[<>:|"?*\\/%c]', "_")
    name = name:gsub("%s+", " ")
    name = name:gsub("^%s*(.-)%s*$", "%1")
    if #name > 120 then name = name:sub(1, 120) end
    if name == "" or name:match("^_+$") then name = "Untitled" end
    return "_" .. name .. ".json"
end

local function withTimeout(label, fn)
    local prev_timeout = http.TIMEOUT
    http.TIMEOUT = SYNC_TIMEOUT
    local started = now_ms()
    logger.info("WebDavSyncClient " .. label .. ": start timeout=" .. tostring(SYNC_TIMEOUT))
    local ok, a, b, c = pcall(fn)
    http.TIMEOUT = prev_timeout
    logger.info("WebDavSyncClient " .. label .. ": done ok="
        .. tostring(ok) .. " result=" .. tostring(a)
        .. " duration_ms=" .. tostring(now_ms() - started))
    return ok, a, b, c
end

function WebDavSyncClient:new(o)
    local t = setmetatable({}, { __index = self })
    t.server   = o.server
    t.username = o.server.username or ""
    t.password = o.server.password or ""
    t._ensured_folders = {}
    return t
end

-- ── URL helpers ────────────────────────────────────────────────────

function WebDavSyncClient:_url(rel_path)
    local base = WebDavApi:getJoinedPath(
        self.server.address, self.server.url or "")
    if rel_path and rel_path ~= "" then
        return WebDavApi:getJoinedPath(base, rel_path)
    end
    return base
end

local function tmp_path(rel_path)
    local suffix = tostring(rel_path or "root"):gsub("[^%w%.%-_]", "_")
    local now = ok_socket and socket.gettime and socket.gettime() or os.time()
    local nonce = tostring(now):gsub("[^%w]", "_") .. "_" .. tostring(math.random(1000000))
    return DataStorage:getSettingsDir() .. "/syncest_tmp_" .. nonce .. "_" .. suffix .. ".json"
end

function WebDavSyncClient:_markPathExists(rel_path)
    self._base_folder_ensured = true
    if not self._ensured_folders then self._ensured_folders = {} end
    local parent = rel_path and rel_path:match("^(.*)/[^/]+$")
    while parent and parent ~= "" do
        self._ensured_folders[parent] = true
        parent = parent:match("^(.*)/[^/]+$")
    end
end

-- ── JSON read/write ────────────────────────────────────────────────

function WebDavSyncClient:_readJSON(rel_path)
    local tmp = tmp_path(rel_path)
    local ok, code = withTimeout("readJSON " .. tostring(rel_path), function()
        return WebDavApi:downloadFile(
            self:_url(rel_path), self.username, self.password, tmp)
    end)
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return nil, READ_FAILED
    end
    if code == 404 then
        os.remove(tmp)
        return nil, READ_MISSING
    end
    if code ~= 200 then
        logger.dbg("WebDavSyncClient _readJSON: " .. rel_path .. " → " .. tostring(code))
        os.remove(tmp)
        return nil, READ_FAILED
    end
    self:_markPathExists(rel_path)
    local f = io.open(tmp, "r")
    if not f then return nil, READ_FAILED end
    local data = f:read("*a")
    f:close()
    os.remove(tmp)
    if not data or data == "" then return nil, READ_MISSING end
    local ok, parsed = pcall(json.decode, data)
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: parse error for " .. rel_path)
        return nil, READ_FAILED
    end
    return parsed
end

function WebDavSyncClient:_writeJSON(rel_path, data)
    logger.info("WebDavSyncClient writeJSON " .. tostring(rel_path) .. ": encoding")
    local ok, encoded = pcall(json.encode, data)
    if not ok then
        logger.warn("WebDavSyncClient _writeJSON: encode error: " .. tostring(encoded))
        return false
    end
    local tmp = tmp_path(rel_path)
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    local full_url = self:_url(rel_path)
    local ok2, code = withTimeout("writeJSON " .. tostring(rel_path), function()
        return WebDavApi:uploadFile(full_url, self.username, self.password, tmp)
    end)
    os.remove(tmp)
    if not ok2 then
        logger.warn("WebDavSyncClient _writeJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return false
    end
    local success = type(code) == "number" and code >= 200 and code < 300
    if not success then
        logger.warn("WebDavSyncClient _writeJSON: upload failed code=" .. tostring(code) .. " url=" .. full_url)
    else
        self:_markPathExists(rel_path)
    end
    return success
end

function WebDavSyncClient:_writeBookMarker(folder, book)
    if not folder or type(book) ~= "table" then return true end
    local hash = book.bookHash or book.hash or book.book_hash
    if not hash then return true end
    local meta = book.bookMetadata or book.metadata or {}
    local title = meta.title or book.title or book.sourceTitle or book.source_title
    local marker = {
        bookHash = hash,
        title = title or "",
        author = meta.author or book.author,
        authors = normalize_authors(meta.authors or book.authors or book.author),
        identifiers = meta.identifiers,
        format = meta.format,
        fileName = meta.fileName,
        sourceTitle = meta.sourceTitle,
        metaHashSource = meta.hash_source or book.metaHashSource,
        metadata = meta.metadata,
        updatedAt = os.time() * 1000,
    }
    return self:_writeJSON(folder .. "/" .. safe_title_filename(title), marker)
end

local function strip_marker_metadata(configs)
    local out = {}
    for i, config in ipairs(configs or {}) do
        local copy = {}
        for k, v in pairs(config) do
            if k ~= "bookMetadata" then copy[k] = v end
        end
        out[i] = copy
    end
    return out
end

local function strip_note_marker_metadata(notes)
    local out = {}
    for i, note in ipairs(notes or {}) do
        local copy = {}
        for k, v in pairs(note) do
            if k ~= "bookMetadata" then copy[k] = v end
        end
        out[i] = copy
    end
    return out
end

-- MKCOL, tolerating 405 (already exists) and 301/302 redirects.
function WebDavSyncClient:_ensureFolder(rel_path)
    if self._ensured_folders and self._ensured_folders[rel_path] then
        logger.info("WebDavSyncClient ensureFolder " .. tostring(rel_path)
            .. ": cached")
        return true
    end
    local ok, code = withTimeout("ensureFolder " .. tostring(rel_path), function()
        return WebDavApi:createFolder(
            self:_url(rel_path), self.username, self.password, "")
    end)
    if not ok then return false end
    local success = code == 201 or code == 405
    if success then
        if not self._ensured_folders then self._ensured_folders = {} end
        self._ensured_folders[rel_path] = true
    end
    return success
end

-- ── Merge helpers ──────────────────────────────────────────────────

-- Union-merge notes by id. Tombstone (deletedAt) always wins; otherwise
-- the note with the newer updatedAt replaces the existing one.
function WebDavSyncClient:_mergeNotes(existing, incoming)
    local by_id = {}
    for _, n in ipairs(existing or {}) do
        if n.id then by_id[n.id] = n end
    end
    for _, n in ipairs(incoming or {}) do
        if n.id then
            local ex = by_id[n.id]
            if not ex or n.deletedAt
                    or (n.updatedAt or 0) > (ex.updatedAt or 0) then
                by_id[n.id] = n
            end
        end
    end
    local result = {}
    for _, n in pairs(by_id) do result[#result + 1] = n end
    return result
end

-- Union-merge book library rows by hash; newer updatedAt wins.
function WebDavSyncClient:_mergeBooks(existing, incoming)
    local by_hash = {}
    for _, b in ipairs(existing or {}) do
        local h = b.bookHash or b.hash
        if h then by_hash[h] = b end
    end
    for _, b in ipairs(incoming or {}) do
        local h = b.bookHash or b.hash
        if h then
            local ex = by_hash[h]
            if not ex or (b.updatedAt or 0) > (ex.updatedAt or 0) then
                by_hash[h] = b
            end
        end
    end
    local result = {}
    for _, b in pairs(by_hash) do result[#result + 1] = b end
    return result
end

-- Union-merge vocab words by word; higher review_count wins, then newer review_time.
function WebDavSyncClient:_mergeVocab(existing, incoming)
    local by_word = {}
    for _, w in ipairs(existing or {}) do
        if w.word then by_word[w.word] = w end
    end
    for _, w in ipairs(incoming or {}) do
        if w.word then
            local ex = by_word[w.word]
            if not ex
                    or (w.review_count or 0) > (ex.review_count or 0)
                    or ((w.review_count or 0) == (ex.review_count or 0)
                        and (w.review_time or 0) > (ex.review_time or 0)) then
                by_word[w.word] = w
            end
        end
    end
    local result = {}
    for _, w in pairs(by_word) do result[#result + 1] = w end
    return result
end

-- Union-merge stat books by book_hash; union stat pages by
-- (book_hash, page, start_time), taking the longer duration.
function WebDavSyncClient:_mergeStats(existing, incoming_books, incoming_pages)
    local bmap = {}
    for _, b in ipairs(existing.statBooks or {}) do
        if b.book_hash then bmap[b.book_hash] = b end
    end
    for _, b in ipairs(incoming_books or {}) do
        if b.book_hash then bmap[b.book_hash] = b end
    end
    local merged_books = {}
    for _, b in pairs(bmap) do merged_books[#merged_books + 1] = b end

    local pmap = {}
    for _, p in ipairs(existing.statPages or {}) do
        local key = (p.book_hash or "") .. "|" .. (p.page or "") .. "|" .. (p.start_time or "")
        pmap[key] = p
    end
    for _, p in ipairs(incoming_pages or {}) do
        local key = (p.book_hash or "") .. "|" .. (p.page or "") .. "|" .. (p.start_time or "")
        local ex = pmap[key]
        if not ex or (tonumber(p.duration) or 0) > (tonumber(ex.duration) or 0) then
            pmap[key] = p
        end
    end
    local merged_pages = {}
    for _, p in pairs(pmap) do merged_pages[#merged_pages + 1] = p end

    return merged_books, merged_pages
end

-- ── Public API ─────────────────────────────────────────────────────

-- WebDAV layout under {base_path}/:
--   library.json              — book catalog (wire-format rows)
--   sync/{book_hash}/
--     progress.json           — {configs: [...]}
--     annotations.json        — {notes: [...]}
--   stats/
--     data.json               — {statBooks: [...], statPages: [...]}
--   books/{book_hash}/
--     {hash}.{ext}            — book file
--     cover.png

function WebDavSyncClient:pullChanges(params, callback)
    logger.info("WebDavSyncClient pullChanges: type=" .. tostring(params and params.type)
        .. " book=" .. tostring(params and params.book)
        .. " since=" .. tostring(params and params.since))
    local t     = params.type
    local book  = params.book
    local since = tonumber(params.since) or 0

    if t == "configs" then
        local data, read_status = self:_readJSON("sync/" .. book .. "/progress.json")
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {configs = {}}, 200)

    elseif t == "notes" then
        local data, read_status = self:_readJSON("sync/" .. book .. "/annotations.json")
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {notes = {}}, 200)

    elseif t == "stats" then
        local data, read_status = self:_readJSON("stats.json")
        if data then
            -- Filter pages newer than the cursor; stamp updated_at_ms so the
            -- stats module can advance its pull cursor.
            if since > 0 and data.statPages then
                local filtered = {}
                for _, p in ipairs(data.statPages) do
                    if (tonumber(p.start_time) or 0) > since then
                        filtered[#filtered + 1] = p
                    end
                end
                data.statPages = filtered
            end
            for _, p in ipairs(data.statPages or {}) do
                p.updated_at_ms = (tonumber(p.start_time) or 0) * 1000
            end
            callback(true, data, 200)
        else
            if read_status == READ_FAILED then
                callback(false, {}, "read_failed")
                return
            end
            callback(true, {statBooks = {}, statPages = {}}, 200)
        end

    elseif t == "vocab" then
        local data, read_status = self:_readJSON("vocab.json")
        if read_status == READ_FAILED then
            callback(false, {}, "read_failed")
            return
        end
        callback(true, data or {words = {}}, 200)

    else
        callback(false, nil, 400)
    end
end

function WebDavSyncClient:pushChanges(changes, callback)
    logger.info("WebDavSyncClient pushChanges: configs="
        .. tostring(changes.configs and #changes.configs or 0)
        .. " notes=" .. tostring(changes.notes and #changes.notes or 0)
        .. " statBooks=" .. tostring(changes.statBooks and #changes.statBooks or 0)
        .. " statPages=" .. tostring(changes.statPages and #changes.statPages or 0)
        .. " vocab=" .. tostring(changes.vocab and #changes.vocab or 0)
        .. " books=" .. tostring(changes.books and #changes.books or 0))
    local ok = true

    -- Reading progress — last write wins per book
    if changes.configs and #changes.configs > 0 then
        local book_hash = changes.configs[1].bookHash
        if book_hash then
            local progress_configs = strip_marker_metadata(changes.configs)
            local progress_path = "sync/" .. book_hash .. "/progress.json"
            if not self:_writeJSON(progress_path, {configs = progress_configs}) then
                logger.warn("WebDavSyncClient pushChanges: progress write failed, repairing folders")
                if self:_ensureFolder("sync") and self:_ensureFolder("sync/" .. book_hash) then
                    self:_writeBookMarker("sync/" .. book_hash, changes.configs[1])
                    if not self:_writeJSON(progress_path, {configs = progress_configs}) then
                        ok = false
                    end
                else
                    ok = false
                end
            end
        end
    end

    -- Annotations — union merge with remote
    if changes.notes and #changes.notes > 0 then
        local book_hash = changes.notes[1].bookHash
        if book_hash then
            local ann_path = "sync/" .. book_hash .. "/annotations.json"
            local remote, read_status = self:_readJSON(ann_path)
            if remote == nil and read_status ~= READ_MISSING then
                -- Can't read remote — abort rather than overwrite with local-only subset
                logger.warn("WebDavSyncClient pushChanges: could not read remote annotations, skipping write")
                ok = false
            else
                remote = remote or {notes = {}}
                local notes = strip_note_marker_metadata(changes.notes)
                local merged = self:_mergeNotes(remote.notes or {}, notes)
                if not self:_writeJSON(ann_path, {notes = merged}) then
                    logger.warn("WebDavSyncClient pushChanges: annotations write failed, repairing folders")
                    if self:_ensureFolder("sync") and self:_ensureFolder("sync/" .. book_hash) then
                        self:_writeBookMarker("sync/" .. book_hash, changes.notes[1])
                        if not self:_writeJSON(ann_path, {notes = merged}) then
                            ok = false
                        end
                    else
                        ok = false
                    end
                end
            end
        end
    end

    -- Stats — union merge with remote
    if (changes.statBooks and #changes.statBooks > 0)
            or (changes.statPages and #changes.statPages > 0) then
        local remote, read_status = self:_readJSON("stats.json")
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {}
            local mb, mp = self:_mergeStats(
                remote, changes.statBooks, changes.statPages)
            if not self:_writeJSON("stats.json",
                    {statBooks = mb, statPages = mp}) then
                ok = false
            end
        end
    end

    -- Vocab builder words — union merge with remote
    if changes.vocab then
        local remote, read_status = self:_readJSON("vocab.json")
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {words = {}}
            local merged = self:_mergeVocab(remote.words or {}, changes.vocab)
            if not self:_writeJSON("vocab.json", {words = merged}) then
                ok = false
            end
        end
    end

    -- Library book rows — union merge with remote
    if changes.books and #changes.books > 0 then
        local remote, read_status = self:_readJSON("library.json")
        if remote == nil and read_status ~= READ_MISSING then
            ok = false
        else
            remote = remote or {books = {}}
            local merged = self:_mergeBooks(remote.books or {}, changes.books)
            if not self:_writeJSON("library.json",
                    {books = merged, updatedAt = os.time() * 1000}) then
                ok = false
            end
        end
    end

    callback(ok, {}, ok and 200 or 500)
end

function WebDavSyncClient:pullBooks(params, callback)
    logger.info("WebDavSyncClient pullBooks: since=" .. tostring(params and params.since))
    local since = tonumber(params.since) or 0
    local data, read_status = self:_readJSON("library.json")
    if not data or not data.books then
        if read_status == READ_FAILED then
            callback(false, {books = {}}, "read_failed")
            return
        end
        callback(true, {books = {}}, 200)
        return
    end
    -- Return rows changed since the watermark
    local filtered = {}
    for _, b in ipairs(data.books) do
        local ts  = tonumber(b.updatedAt)  or 0
        local dts = tonumber(b.deletedAt)  or 0
        if ts > since or dts > since then
            filtered[#filtered + 1] = b
        end
    end
    callback(true, {books = filtered}, 200)
end

return WebDavSyncClient
