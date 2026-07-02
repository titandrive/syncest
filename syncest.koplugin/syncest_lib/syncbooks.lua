-- syncbooks.lua
-- Sync layer for the Library view. Uploads/downloads book files and covers
-- to/from WebDAV, and syncs the book catalog via library.json.

local M = {}

local EXTS = require("syncest_lib.exts")

-- ---------------------------------------------------------------------------
-- build_local_filename: where downloaded book bytes land on disk
-- ---------------------------------------------------------------------------
local MAX_BODY_LEN = 200
local SYNC_TIMEOUT = 4

local function now_ms()
    return math.floor(os.time() * 1000)
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

local function normalize_identifier(identifier)
    identifier = tostring(identifier or "")
    if identifier:match("urn:") then
        return identifier:match("([^:]+)$")
    elseif identifier:match(":") then
        return identifier:match("^[^:]+:(.+)$")
    end
    return identifier
end

local function identifier_type(raw)
    local lower = tostring(raw or ""):lower()
    if lower:find("isbn", 1, true) then return "isbn" end
    if lower:find("calibre", 1, true) then return "calibre" end
    if lower:find("uuid", 1, true) then return "uuid" end
    if lower:find("google", 1, true) then return "google" end
    local prefix = lower:match("^%s*([^:%s]+):")
    return prefix or "unknown"
end

local function split_identifiers(value, out)
    out = out or {}
    if type(value) == "table" then
        for _, v in pairs(value) do split_identifiers(v, out) end
        return out
    end
    if type(value) ~= "string" and type(value) ~= "number" then
        return out
    end
    for raw in tostring(value):gmatch("[^\n]+") do
        raw = raw:gsub("^%s*(.-)%s*$", "%1")
        if raw ~= "" then
            out[#out + 1] = {
                type = identifier_type(raw),
                value = normalize_identifier(raw),
                raw = raw,
            }
        end
    end
    return out
end

local function extract_isbns(value, out, force_context)
    out = out or {}
    local value_type = type(value)
    if value_type == "table" then
        for _, v in pairs(value) do extract_isbns(v, out, force_context) end
        return out
    end
    if value_type ~= "string" and value_type ~= "number" then
        return out
    end

    local text = tostring(value)
    local lower = text:lower()
    local isbn_context = force_context or lower:find("isbn", 1, true) ~= nil
    for candidate in text:gmatch("[%dXx][%dXx%-%s]*[%dXx]") do
        local cleaned = candidate:gsub("[^%dXx]", ""):upper()
        if #cleaned == 10 and isbn_context then
            out.isbn10 = out.isbn10 or cleaned
        elseif #cleaned == 13 and (isbn_context or cleaned:match("^97[89]")) then
            out.isbn13 = out.isbn13 or cleaned
        end
    end
    out.isbn = out.isbn or out.isbn13 or out.isbn10
    return out
end

local function promoted_identifiers(all_identifiers)
    local out = {}
    for _, item in ipairs(all_identifiers or {}) do
        if item.type == "google" then
            out.googleBooksId = out.googleBooksId or item.value
        elseif item.type == "calibre" then
            out.calibreId = out.calibreId or item.value
        elseif item.type == "uuid" then
            out.uuid = out.uuid or item.value
        end
    end
    return out
end

local function marker_metadata(metadata)
    if type(metadata) ~= "table" then return {} end
    local copied = {}
    local skip = {
        identifiers = true,
        isbn = true,
        ISBN = true,
        isbn10 = true,
        isbn13 = true,
        google = true,
        googleBooksId = true,
        google_books_id = true,
        calibre = true,
        calibreId = true,
        calibre_id = true,
        uuid = true,
        UUID = true,
    }
    for k, v in pairs(metadata) do
        if not skip[k] then copied[k] = v end
    end
    return copied
end

local function is_array(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true, count
end

local function encode_pretty_json(value, indent)
    local json = require("json")
    indent = indent or ""
    if type(value) ~= "table" then return json.encode(value) end

    local child_indent = indent .. "  "
    local array, count = is_array(value)
    local parts = {}
    if array then
        for i = 1, count do
            parts[#parts + 1] = child_indent .. encode_pretty_json(value[i], child_indent)
        end
        if #parts == 0 then return "[]" end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end

    local keys = {}
    for k, v in pairs(value) do
        if v ~= nil then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = child_indent .. json.encode(tostring(k)) .. ": "
            .. encode_pretty_json(value[k], child_indent)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function write_temp_json(data)
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir()
        .. "/syncest_book_marker_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1000000)) .. ".json"
    local ok, encoded = pcall(encode_pretty_json, data)
    if not ok then return nil end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(encoded, "\n")
    f:close()
    return path
end

function M.build_local_filename(book)
    if not book then return nil end
    local ext = EXTS[book.format]
    if not ext then return nil end
    local raw = book.source_title or book.title or ""
    if raw == "" then return "book." .. ext end
    local safe = raw:gsub('[<>:|"?*\\/%c]', "_")
    if #safe > MAX_BODY_LEN then safe = safe:sub(1, MAX_BODY_LEN) end
    if safe:match("^_+$") then safe = "book" end
    return safe .. "." .. ext
end

-- ---------------------------------------------------------------------------
-- resolve_collision: bumps {name}.ext → {name} (1).ext on filename clash
-- ---------------------------------------------------------------------------
function M.resolve_collision(candidate, exists)
    if not exists(candidate) then return candidate end
    local base, ext = candidate:match("^(.+)%.([^.]+)$")
    if not base then base = candidate; ext = nil end
    for n = 1, 99 do
        local probe = ext
            and string.format("%s (%d).%s", base, n, ext)
            or  string.format("%s (%d)", base, n)
        if not exists(probe) then return probe end
    end
    return candidate
end

-- ---------------------------------------------------------------------------
-- row_to_wire: internal snake_case row → camelCase wire shape for library.json
-- ---------------------------------------------------------------------------
local function row_to_wire(row)
    if not row then return nil end
    local function num(v) return v and tonumber(v) or v end
    local out = {
        bookHash      = row.hash,
        hash          = row.hash,
        metaHash      = row.meta_hash,
        format        = row.format,
        title         = row.title,
        author        = row.author,
        sourceTitle   = row.source_title,
        groupId       = row.group_id,
        groupName     = row.group_name,
        readingStatus = row.reading_status,
        readingStatusUpdatedAt = num(row.reading_status_updated_at),
        createdAt     = num(row.created_at),
        updatedAt     = num(row.updated_at),
        deletedAt     = num(row.deleted_at),
        uploadedAt    = num(row.uploaded_at),
    }
    if row.metadata_json and row.metadata_json ~= "" then
        local json = require("json")
        local ok, parsed = pcall(json.decode, row.metadata_json)
        if ok and type(parsed) == "table" then out.metadata = parsed end
    end
    if row.progress_lib and row.progress_lib ~= "" then
        local json = require("json")
        local ok, parsed = pcall(json.decode, row.progress_lib)
        if ok and type(parsed) == "table" then out.progress = parsed end
    end
    return out
end
M._row_to_wire = row_to_wire

local function rich_book_marker(book)
    local wire = row_to_wire(book) or {}
    local metadata = wire.metadata or {}
    local all_identifiers = wire.allIdentifiers or split_identifiers({
        wire.identifiers,
        metadata.identifiers,
        metadata.isbn,
        metadata.ISBN,
        metadata.isbn10,
        metadata.isbn13,
    })
    local ids = promoted_identifiers(all_identifiers)
    ids.googleBooksId = ids.googleBooksId
        or metadata.googleBooksId or metadata.google_books_id or metadata.google
    ids.calibreId = ids.calibreId
        or metadata.calibreId or metadata.calibre_id or metadata.calibre
    ids.uuid = ids.uuid or metadata.uuid or metadata.UUID
    local isbns = extract_isbns({
        all_identifiers,
        metadata.identifiers,
    })
    extract_isbns(wire.isbn, isbns, true)
    extract_isbns(wire.isbn10, isbns, true)
    extract_isbns(wire.isbn13, isbns, true)
    extract_isbns(metadata.isbn, isbns, true)
    extract_isbns(metadata.ISBN, isbns, true)
    extract_isbns(metadata.isbn10, isbns, true)
    extract_isbns(metadata.isbn13, isbns, true)
    ids.isbn = isbns.isbn

    local ext = EXTS[book.format]
    local authors = {}
    if book.author and book.author ~= "" then
        for author in tostring(book.author):gmatch("[^\n]+") do
            authors[#authors + 1] = author:gsub("^%s*(.-)%s*$", "%1")
        end
    end

    return {
        bookHash = book.hash,
        title = book.title or book.source_title or "",
        author = book.author,
        authors = authors,
        isbn = ids.isbn,
        googleBooksId = ids.googleBooksId,
        calibreId = ids.calibreId,
        uuid = ids.uuid,
        format = book.format,
        fileName = book.file_path and book.file_path:match("([^/]+)$") or nil,
        sourceTitle = book.source_title,
        bookFile = ext and string.format("%s.%s", book.hash, ext) or nil,
        coverFile = "cover.png",
        metadata = marker_metadata(metadata),
        createdAt = wire.createdAt,
        bookUpdatedAt = wire.updatedAt,
        uploadedAt = wire.uploadedAt,
        updatedAt = os.time() * 1000,
    }
end

-- ---------------------------------------------------------------------------
-- WebDAV helpers
-- ---------------------------------------------------------------------------
-- Returns the WebDavApi module and base URL components from opts.settings.
local function webdav(opts)
    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local srv = opts.settings.sync_server or {}
    local base = WebDavApi:getJoinedPath(srv.address or "", srv.url or "")
    local function url(rel)
        return WebDavApi:getJoinedPath(base, rel)
    end
    return WebDavApi, url, srv.username or "", srv.password or ""
end

local function server_reachable(opts)
    local logger = require("logger")
    local socket = require("socket")
    local srv = opts and opts.settings and opts.settings.sync_server or {}
    local addr = srv.address or ""
    local host = addr:match("https?://([^/:]+)")
    if not host then
        logger.warn("WebDavSync reachable: invalid server address")
        return false
    end
    local port = tonumber(addr:match("//[^/]*:(%d+)"))
        or (addr:match("^https://") and 443 or 80)
    logger.info("WebDavSync reachable: checking host=" .. tostring(host)
        .. " port=" .. tostring(port))
    local ok, connected = pcall(function()
        local s = socket.tcp()
        if not s then return false end
        s:settimeout(1)
        local result = s:connect(host, port)
        s:close()
        return result == 1
    end)
    logger.info("WebDavSync reachable: ok=" .. tostring(ok)
        .. " connected=" .. tostring(connected))
    return ok and connected == true
end

local function safe_webdav_call(label, fn)
    local logger = require("logger")
    local http = require("socket.http")
    local ok_sutil, socketutil = pcall(require, "socketutil")
    local prev_timeout = http.TIMEOUT
    local started = now_ms()

    logger.info("WebDavSync " .. tostring(label) .. ": start timeout=" .. tostring(SYNC_TIMEOUT))
    http.TIMEOUT = SYNC_TIMEOUT
    if ok_sutil then pcall(function() socketutil:set_timeout(SYNC_TIMEOUT, SYNC_TIMEOUT) end) end

    local ok, result = pcall(fn)

    if ok_sutil then pcall(function() socketutil:reset_timeout() end) end
    http.TIMEOUT = prev_timeout

    if not ok then
        logger.warn("WebDavSync " .. tostring(label) .. ": failed err="
            .. tostring(result) .. " duration_ms=" .. tostring(now_ms() - started))
        return nil, result
    end
    logger.info("WebDavSync " .. tostring(label) .. ": done result="
        .. tostring(result) .. " duration_ms=" .. tostring(now_ms() - started))
    return result
end

-- MKCOL tolerating 405 (already exists).
local function ensure_folder(api, url, user, pass)
    local code = safe_webdav_call("MKCOL", function()
        return api:createFolder(url, user, pass, "")
    end)
    return code == 201 or code == 405, code == 201
end

-- DELETE a WebDAV URL (file or collection). Returns HTTP status.
local function webdav_delete(full_url, user, pass)
    local socket     = require("socket")
    local http       = require("socket.http")
    local ltn12      = require("ltn12")
    return safe_webdav_call("DELETE", function()
        return socket.skip(1, http.request{
            url      = full_url,
            method   = "DELETE",
            user     = user,
            password = pass,
            sink     = ltn12.sink.null(),
        })
    end)
end

-- ---------------------------------------------------------------------------
-- pushBook / pushChangedBooks — push book metadata rows to library.json
-- ---------------------------------------------------------------------------
function M.pushBook(book_row, opts, cb)
    if not book_row or not book_row.hash then
        if cb then cb(false, "missing book row") end
        return
    end
    local client = opts.client
    if not client then
        if cb then cb(false, "no sync client") end
        return
    end
    client:pushChanges(
        {books = {row_to_wire(book_row)}, notes = {}, configs = {}},
        function(success, _, _)
            if cb then cb(success, success and nil or "push failed") end
        end)
end

function M.pushChangedBooks(opts, cb)
    local logger = require("logger")
    local store  = opts.store
    local client = opts.client
    if not store or not client then
        if cb then cb(false, "missing store or client") end
        return
    end

    local since   = store:getLastPulledAt() or 0
    local changed = store:getChangedBooks(since)
    logger.info("WebDavSync pushChangedBooks: since=" .. since .. " found=" .. #changed)
    if #changed == 0 then
        if cb then cb(false, "no books found to push — books may not have been opened in KOReader yet (no hash)") end
        return
    end

    local books_wire = {}
    local max_ts = since
    for i, row in ipairs(changed) do
        books_wire[i] = row_to_wire(row)
        if row.updated_at and row.updated_at > max_ts then max_ts = row.updated_at end
        if row.deleted_at and row.deleted_at > max_ts then max_ts = row.deleted_at end
    end

    logger.info("WebDavSync pushChangedBooks: pushing " .. #books_wire .. " row(s)")
    client:pushChanges(
        {books = books_wire, notes = {}, configs = {}},
        function(success, _, status)
            if not success then
                if cb then cb(false, "push failed (HTTP " .. tostring(status) .. ")") end
                return
            end

            -- Upload actual book files to books/{hash}/{hash}.ext
            local DataStorage = require("datastorage")
            local covers_dir = DataStorage:getSettingsDir() .. "/syncest_covers"
            local uploaded, failed = 0, 0
            local total_uploads = 0
            for _, row in ipairs(changed) do
                if row.file_path and row.format then
                    total_uploads = total_uploads + 1
                end
            end
            if opts.on_upload_progress and total_uploads > 0 then
                opts.on_upload_progress({
                    uploaded = uploaded,
                    failed = failed,
                    done = 0,
                    total = total_uploads,
                })
            end
            for _, row in ipairs(changed) do
                if row.file_path and row.format then
                    logger.info("WebDavSync pushChangedBooks: upload candidate hash="
                        .. tostring(row.hash) .. " format=" .. tostring(row.format))
                    local call_ok, up_ok, err_up = pcall(M.uploadBook, row, {
                        client     = opts.client,
                        settings   = opts.settings,
                        covers_dir = covers_dir,
                    }, nil)
                    if call_ok and up_ok then
                        uploaded = uploaded + 1
                        -- Set uploadedAt so the cloud library shows the file is available
                        row_to_wire(row).uploadedAt = os.time() * 1000
                    else
                        failed = failed + 1
                        logger.warn("Syncest uploadBook failed: " .. tostring(err_up))
                    end
                    if opts.on_upload_progress then
                        opts.on_upload_progress({
                            uploaded = uploaded,
                            failed = failed,
                            done = uploaded + failed,
                            total = total_uploads,
                            title = row.title,
                            hash = row.hash,
                        })
                    end
                end
            end
            logger.info("Syncest pushChangedBooks: uploaded=" .. uploaded .. " failed=" .. failed)

            -- Mark pushed rows as cloud_present so they appear in the library view.
            for _, row in ipairs(changed) do
                store:upsertBook({ hash = row.hash, title = row.title, cloud_present = 1 })
            end
            store:setLastPulledAt(max_ts)
            if cb then cb(true, #books_wire) end
        end)
end

-- ---------------------------------------------------------------------------
-- syncBooks — convenience wrapper (push / pull / both)
-- ---------------------------------------------------------------------------
function M.syncBooks(opts, mode, cb, before_push)
    mode = mode or "both"
    local logger = require("logger")
    logger.info("WebDavSync syncBooks: mode=" .. tostring(mode))
    if mode == "push" then
        if before_push then before_push() end
        M.pushChangedBooks(opts, cb)
    elseif mode == "pull" then
        M.pullBooks(opts, cb)
    else
        M.pullBooks(opts, function(pull_ok, pull_msg, pull_status)
            if before_push then before_push() end
            M.pushChangedBooks(opts, function(push_ok, push_msg)
                if cb then
                    cb(pull_ok and push_ok,
                        string.format("pull=%s/%s push=%s/%s",
                            tostring(pull_ok), tostring(pull_msg),
                            tostring(push_ok), tostring(push_msg)),
                        pull_status)
                end
            end)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- pullBooks — download library.json and upsert changed rows into LibraryStore
-- ---------------------------------------------------------------------------
function M.pullBooks(opts, cb)
    local logger       = require("logger")
    local LibraryStore = require("syncest_lib.librarystore")
    local client       = opts.client
    local store        = opts.store

    if not client or not store then
        if cb then cb(false, "missing sync client or store") end
        return
    end

    -- Always fetch the full cloud library (since=0) so the Syncest Library
    -- always reflects exactly what's in WebDAV regardless of push watermarks.
    logger.info("WebDavSync pullBooks: full cloud fetch")

    client:pullBooks({since = 0}, function(success, body, _)
        if not success then
            if cb then cb(false, "pull failed") end
            return
        end
        local rows    = body and body.books or {}
        local max_ts  = 0
        local upserted = 0
        store:clearCloudPresent()
        for _, raw in ipairs(rows) do
            local parsed = LibraryStore.parseSyncRow(raw)
            if parsed then
                parsed.user_id = opts.settings.user_id
                store:upsertBook(parsed)
                upserted = upserted + 1
                if parsed.updated_at and parsed.updated_at > max_ts then
                    max_ts = parsed.updated_at
                end
                if parsed.deleted_at and parsed.deleted_at > max_ts then
                    max_ts = parsed.deleted_at
                end
            end
        end
        if max_ts > 0 then store:setLastPulledAt(max_ts) end
        logger.info("WebDavSync pullBooks: upserted=" .. upserted)
        if cb then cb(true, upserted) end
    end)
end

-- ---------------------------------------------------------------------------
-- downloadBook — pull a book file from WebDAV books/{hash}/{hash}.{ext}
-- ---------------------------------------------------------------------------
function M.downloadBook(book, opts, cb)
    local logger = require("logger")
    local lfs    = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not server_reachable(opts) then
        if cb then cb(false, "unreachable") end
        return false, "unreachable"
    end

    local ext = EXTS[book.format]
    if not ext then
        if cb then cb(false, "unsupported format") end
        return false, "unsupported format"
    end

    local rel   = string.format("books/%s/%s.%s", book.hash, book.hash, ext)
    local local_name = M.build_local_filename(book)
    if not local_name then
        if cb then cb(false, "could not build local filename") end
        return false, "could not build local filename"
    end

    if not lfs.attributes(opts.download_dir, "mode") then
        lfs.mkdir(opts.download_dir)
    end
    local exists = function(name)
        return lfs.attributes(opts.download_dir .. "/" .. name, "mode") ~= nil
    end
    local dst = opts.download_dir .. "/" .. M.resolve_collision(local_name, exists)

    logger.info("WebDavSync downloadBook: " .. rel .. " -> " .. dst)
    local code, err = safe_webdav_call("downloadBook " .. rel, function()
        return api:downloadFile(url(rel), user, pass, dst)
    end)
    if code == 200 then
        if cb then cb(true, dst) end
        return true, dst
    else
        os.remove(dst)
        if cb then cb(false, err or "download failed", code) end
        return false, err or "download failed", code
    end
end

-- ---------------------------------------------------------------------------
-- extractLocalCover — render embedded cover to dst_png
-- ---------------------------------------------------------------------------
function M.extractLocalCover(file_path, dst_png)
    if not file_path or not dst_png then return false end
    local ok, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or not FileManagerBookInfo then return false end
    local got, cover_bb = pcall(FileManagerBookInfo.getCoverImage, FileManagerBookInfo, nil, file_path)
    if not got or not cover_bb then return false end
    local wrote = cover_bb:writeToFile(dst_png, "png")
    if cover_bb.free then cover_bb:free() end
    return wrote == true
end

-- ---------------------------------------------------------------------------
-- uploadBook — push book file (and cover) to WebDAV books/{hash}/
-- ---------------------------------------------------------------------------
function M.uploadBook(book, opts, cb)
    local logger = require("logger")
    local lfs    = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not book or not book.hash or not book.format or not book.file_path then
        if cb then cb(false, "missing book info") end
        return false, "missing book info"
    end
    local ext = EXTS[book.format]
    if not ext then
        if cb then cb(false, "unsupported format") end
        return false, "unsupported format"
    end
    if not lfs.attributes(book.file_path, "mode") then
        if cb then cb(false, "local file missing") end
        return false, "local file missing"
    end

    -- Ensure books/{hash}/ folder exists
    local book_dir = string.format("books/%s", book.hash)
    local books_ok = ensure_folder(api, url("books"), user, pass)
    local book_ok = ensure_folder(api, url(book_dir), user, pass)
    if not books_ok or not book_ok then
        if cb then cb(false, "could not create cloud folder") end
        return false, "could not create cloud folder"
    end

    -- Upload book file
    local file_rel = string.format("books/%s/%s.%s", book.hash, book.hash, ext)
    logger.info("WebDavSync uploadBook: uploading " .. file_rel)
    local code, err = safe_webdav_call("uploadBook " .. file_rel, function()
        return api:uploadFile(url(file_rel), user, pass, book.file_path)
    end)
    if type(code) ~= "number" or code < 200 or code > 299 then
        if cb then cb(false, err or "book upload failed", code) end
        return false, err or "book upload failed", code
    end

    local marker = write_temp_json(rich_book_marker(book))
    if marker then
        local marker_rel = string.format("books/%s/%s", book.hash,
            safe_title_filename(book.title or book.source_title))
        safe_webdav_call("uploadBookMarker " .. marker_rel, function()
            return api:uploadFile(url(marker_rel), user, pass, marker)
        end)
        os.remove(marker)
    end

    -- Upload cover (best-effort)
    local cover_path = opts.covers_dir
        and (opts.covers_dir .. "/" .. book.hash .. ".png")
    local cover_attr = cover_path and lfs.attributes(cover_path)
    local has_cover  = cover_attr and cover_attr.mode == "file"

    if not has_cover and cover_path then
        if not lfs.attributes(opts.covers_dir, "mode") then
            lfs.mkdir(opts.covers_dir)
        end
        if M.extractLocalCover(book.file_path, cover_path) then
            has_cover = true
        end
    end

    if has_cover then
        local cover_rel = string.format("books/%s/cover.png", book.hash)
        safe_webdav_call("uploadCover " .. cover_rel, function()
            return api:uploadFile(url(cover_rel), user, pass, cover_path)
        end)
    end

    if cb then cb(true) end
    return true
end

-- ---------------------------------------------------------------------------
-- downloadCover — fetch cover.png from WebDAV books/{hash}/cover.png
-- ---------------------------------------------------------------------------
function M.downloadCover(book, opts, cb)
    local logger = require("logger")
    local lfs = require("libs/libkoreader-lfs")
    local api, url, user, pass = webdav(opts)

    if not server_reachable(opts) then
        if cb then cb(false, "unreachable") end
        return false, "unreachable"
    end

    local rel = string.format("books/%s/cover.png", book.hash)
    if not lfs.attributes(opts.covers_dir, "mode") then
        lfs.mkdir(opts.covers_dir)
    end
    local dst = opts.covers_dir .. "/" .. book.hash .. ".png"

    logger.info("WebDavSync downloadCover: " .. rel .. " -> " .. dst)
    local code, err = safe_webdav_call("downloadCover " .. rel, function()
        return api:downloadFile(url(rel), user, pass, dst)
    end)
    if code == 200 then
        if cb then cb(true, dst) end
        return true, dst
    elseif code == 404 then
        os.remove(dst)
        if cb then cb(false, "no-cover", 404) end
        return false, "no-cover", 404
    else
        os.remove(dst)
        if cb then cb(false, err or "download failed", code) end
        return false, err or "download failed", code
    end
end

-- ---------------------------------------------------------------------------
-- deleteCloudFiles — DELETE books/{hash}/ collection on WebDAV
-- ---------------------------------------------------------------------------
function M.deleteCloudFiles(book, opts, cb)
    local logger = require("logger")
    local _, url, user, pass = webdav(opts)

    if not server_reachable(opts) then
        if cb then cb(false, "unreachable") end
        return false, "unreachable"
    end

    if not book or not book.hash then
        if cb then cb(false, "missing book") end
        return false, "missing book"
    end

    local rel  = string.format("books/%s/", book.hash)
    local code = webdav_delete(url(rel), user, pass)
    logger.info("WebDavSync deleteCloudFiles: " .. rel .. " → " .. tostring(code))

    local ok = code == 200 or code == 204 or code == 404
    if cb then cb(ok, ok and 1 or 0, code) end
    return ok, code
end

return M
