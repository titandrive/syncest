local DataStorage = require("datastorage")
local WebDavApi = require("apps/cloudstorage/webdavapi")
local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")

local WebDavSyncClient = {}

function WebDavSyncClient:new(o)
    local t = setmetatable({}, { __index = self })
    t.server   = o.server
    t.username = o.server.username or ""
    t.password = o.server.password or ""
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

local function tmp_path()
    return DataStorage:getSettingsDir() .. "/syncest_tmp.json"
end

-- ── JSON read/write ────────────────────────────────────────────────

function WebDavSyncClient:_readJSON(rel_path)
    local tmp = tmp_path()
    socketutil:set_timeout(10, 30)
    local ok, code = pcall(WebDavApi.downloadFile, WebDavApi,
        self:_url(rel_path), self.username, self.password, tmp)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return nil
    end
    if code ~= 200 then
        logger.dbg("WebDavSyncClient _readJSON: " .. rel_path .. " → " .. tostring(code))
        return nil
    end
    local f = io.open(tmp, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    os.remove(tmp)
    if not data or data == "" then return nil end
    local ok, parsed = pcall(json.decode, data)
    if not ok then
        logger.warn("WebDavSyncClient _readJSON: parse error for " .. rel_path)
        return nil
    end
    return parsed
end

function WebDavSyncClient:_writeJSON(rel_path, data)
    local ok, encoded = pcall(json.encode, data)
    if not ok then
        logger.warn("WebDavSyncClient _writeJSON: encode error: " .. tostring(encoded))
        return false
    end
    local tmp = tmp_path()
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    local full_url = self:_url(rel_path)
    socketutil:set_timeout(10, 30)
    local ok2, code = pcall(WebDavApi.uploadFile, WebDavApi, full_url, self.username, self.password, tmp)
    socketutil:reset_timeout()
    os.remove(tmp)
    if not ok2 then
        logger.warn("WebDavSyncClient _writeJSON: network error for " .. rel_path .. ": " .. tostring(code))
        return false
    end
    local success = type(code) == "number" and code >= 200 and code < 300
    if not success then
        logger.warn("WebDavSyncClient _writeJSON: upload failed code=" .. tostring(code) .. " url=" .. full_url)
    end
    return success
end

-- MKCOL, tolerating 405 (already exists) and 301/302 redirects.
function WebDavSyncClient:_ensureFolder(rel_path)
    local ok, code = pcall(WebDavApi.createFolder, WebDavApi,
        self:_url(rel_path), self.username, self.password, "")
    if not ok then return false end
    return code == 201 or code == 405
end

-- DELETE a single URL (file or collection). Returns HTTP status code.
function WebDavSyncClient:_delete(rel_path)
    socketutil:set_timeout()
    local code = socket.skip(1, http.request{
        url      = self:_url(rel_path),
        method   = "DELETE",
        user     = self.username,
        password = self.password,
        sink     = ltn12.sink.null(),
    })
    socketutil:reset_timeout()
    return code
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
    local t     = params.type
    local book  = params.book
    local since = tonumber(params.since) or 0

    if t == "configs" then
        local data = self:_readJSON("sync/" .. book .. "/progress.json")
        callback(true, data or {configs = {}}, 200)

    elseif t == "notes" then
        local data = self:_readJSON("sync/" .. book .. "/annotations.json")
        callback(true, data or {notes = {}}, 200)

    elseif t == "stats" then
        local data = self:_readJSON("stats.json")
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
            callback(true, {statBooks = {}, statPages = {}}, 200)
        end

    elseif t == "vocab" then
        local data = self:_readJSON("vocab.json")
        callback(true, data or {words = {}}, 200)

    else
        callback(false, nil, 400)
    end
end

function WebDavSyncClient:pushChanges(changes, callback)
    -- Ensure the base sync folder exists before writing anything.
    local mkcol_ok, mkcol_code = pcall(WebDavApi.createFolder, WebDavApi,
        self:_url(""), self.username, self.password, "")
    if not mkcol_ok or (mkcol_code ~= 201 and mkcol_code ~= 405) then
        logger.warn("WebDavSyncClient pushChanges: failed to create base folder, code=" .. tostring(mkcol_code))
        callback(false, {}, mkcol_code)
        return
    end
    local ok = true

    -- Reading progress — last write wins per book
    if changes.configs and #changes.configs > 0 then
        local book_hash = changes.configs[1].bookHash
        if book_hash then
            self:_ensureFolder("sync")
            self:_ensureFolder("sync/" .. book_hash)
            if not self:_writeJSON("sync/" .. book_hash .. "/progress.json",
                    {configs = changes.configs}) then
                ok = false
            end
        end
    end

    -- Annotations — union merge with remote
    if changes.notes and #changes.notes > 0 then
        local book_hash = changes.notes[1].bookHash
        if book_hash then
            self:_ensureFolder("sync")
            self:_ensureFolder("sync/" .. book_hash)
            local ann_path = "sync/" .. book_hash .. "/annotations.json"
            local remote = self:_readJSON(ann_path)
            if remote == nil then
                -- Can't read remote — abort rather than overwrite with local-only subset
                logger.warn("WebDavSyncClient pushChanges: could not read remote annotations, skipping write")
                ok = false
            else
                local merged = self:_mergeNotes(remote.notes or {}, changes.notes)
                if not self:_writeJSON(ann_path, {notes = merged}) then
                    ok = false
                end
            end
        end
    end

    -- Stats — union merge with remote
    if (changes.statBooks and #changes.statBooks > 0)
            or (changes.statPages and #changes.statPages > 0) then
        local remote = self:_readJSON("stats.json") or {}
        local mb, mp = self:_mergeStats(
            remote, changes.statBooks, changes.statPages)
        if not self:_writeJSON("stats.json",
                {statBooks = mb, statPages = mp}) then
            ok = false
        end
    end

    -- Vocab builder words — union merge with remote
    if changes.vocab then
        local remote = self:_readJSON("vocab.json") or {words = {}}
        local merged = self:_mergeVocab(remote.words or {}, changes.vocab)
        if not self:_writeJSON("vocab.json", {words = merged}) then
            ok = false
        end
    end

    -- Library book rows — union merge with remote
    if changes.books and #changes.books > 0 then
        local remote = self:_readJSON("library.json") or {books = {}}
        local merged = self:_mergeBooks(remote.books or {}, changes.books)
        if not self:_writeJSON("library.json",
                {books = merged, updatedAt = os.time() * 1000}) then
            ok = false
        end
    end

    callback(ok, {}, ok and 200 or 500)
end

function WebDavSyncClient:pullBooks(params, callback)
    local since = tonumber(params.since) or 0
    local data  = self:_readJSON("library.json")
    if not data or not data.books then
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
