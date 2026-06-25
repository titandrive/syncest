-- cloud_covers.lua
-- Per-book cover lifecycle for cloud-only rows. Owns the on-disk
-- <hash>.png cache and the single-slot async download queue that
-- fetches missing covers from WebDAV when cells become visible.

local logger = require("logger")

local M = {}

M.URI_PREFIX = "readest-cloud://"

-- Synthetic metadata cache keyed by hash: { title, author }
local _meta = {}

-- Download lifecycle state
local _cover_pending   = {}
local _missing_covers  = {}
local _visible_hashes  = nil
local _refresh_pending = false
local _download_queue  = {}
local _downloading     = false

-- WebDAV opts (set via M.set_opts). Holds { settings } with webdav_* fields.
local _opts = nil

function M.set_opts(opts)
    _opts = opts
end

function M.set_meta(key, meta)
    _meta[key] = meta
end

function M.get_meta(key)
    return _meta[key] or {}
end

function M.covers_dir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/readest_covers"
end

local function cover_path_for(hash)
    return M.covers_dir() .. "/" .. hash .. ".png"
end

function M.hash_from_uri(filepath)
    local rest = filepath:sub(#M.URI_PREFIX + 1)
    return (rest:match("^([^.]+)") or rest)
end

function M.load_cover_bb(hash)
    local lfs = require("libs/libkoreader-lfs")
    local path = cover_path_for(hash)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then return nil end
    local ok2, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok2 or not bb then return nil end
    return bb
end

local function tag_for(hash)
    local meta = _meta[hash] or {}
    return hash:sub(1, 8) .. " '" .. tostring(meta.title or "?") .. "'"
end

local function process_queue()
    if _downloading then return end
    local hash
    repeat
        hash = table.remove(_download_queue, 1)
        if not hash then return end
        if _missing_covers[hash] then
            _cover_pending[hash] = nil
            hash = nil
        elseif _visible_hashes and not _visible_hashes[hash] then
            logger.dbg("WebDavSync cover dequeue skip: " .. tag_for(hash)
                .. " no longer on visible page")
            _cover_pending[hash] = nil
            hash = nil
        end
    until hash

    _downloading = true
    logger.info("WebDavSync cover download: starting " .. tag_for(hash))

    local syncbooks = require("syncest_lib.syncbooks")
    syncbooks.downloadCover(
        {hash = hash},
        {
            settings   = _opts and _opts.settings,
            covers_dir = M.covers_dir(),
        },
        function(success, path_or_err, status)
            _cover_pending[hash] = nil
            _downloading = false
            if not success then
                if status == 404 then
                    _missing_covers[hash] = true
                    logger.info("WebDavSync cover " .. tag_for(hash)
                        .. " — not on server (404)")
                else
                    logger.warn("WebDavSync cover " .. tag_for(hash)
                        .. " failed: " .. tostring(path_or_err))
                end
            else
                logger.info("WebDavSync cover " .. tag_for(hash)
                    .. " saved → " .. tostring(path_or_err))
                if not _refresh_pending then
                    _refresh_pending = true
                    local UIManager = require("ui/uimanager")
                    UIManager:nextTick(function()
                        _refresh_pending = false
                        local ok, LibraryWidget = pcall(require, "library.librarywidget")
                        if ok and LibraryWidget._menu then LibraryWidget.refresh() end
                    end)
                end
            end
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(process_queue)
        end)
end

function M.trigger_download(hash)
    if _cover_pending[hash] then return end
    if _missing_covers[hash] then return end
    if not _opts or not _opts.settings or not _opts.settings.webdav_address then
        logger.warn("WebDavSync cover skip: " .. tag_for(hash) .. " — WebDAV not configured")
        return
    end
    if _visible_hashes and not _visible_hashes[hash] then return end

    _cover_pending[hash] = true
    table.insert(_download_queue, hash)
    logger.dbg("WebDavSync cover queued: " .. tag_for(hash)
        .. " (queue len=" .. #_download_queue .. ")")
    process_queue()
end

function M.set_visible_hashes(set)
    _visible_hashes = set
    if set == nil then
        logger.dbg("WebDavSync set_visible_hashes: cleared")
    else
        local count = 0
        for _ in pairs(set) do count = count + 1 end
        logger.info("WebDavSync set_visible_hashes: count=" .. count)
    end
end

return M
