local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local WebDavAuth = require("webdav_auth")
local SyncConfig = require("readest_syncconfig")
local SyncAnnotations = require("readest_syncannotations")
local SyncStats = require("readest_syncstats")

local Syncest = WidgetContainer:new{
    name = "syncest",
    title = _("Syncest"),
    settings = nil,
}

local API_CALL_DEBOUNCE_DELAY = 30

Syncest.default_settings = {
    sync_server  = nil,
    auto_sync    = false,
    user_id      = nil,
    user_name    = nil,
    last_sync_at = nil,
}

-- ── Lifecycle ──────────────────────────────────────────────────────

function Syncest:init()
    self.last_sync_timestamp = 0
    self.settings = G_reader_settings:readSetting("webdav_sync", self.default_settings)

    -- Migrate pre-SyncService settings (webdav_address/username/password → sync_server)
    if not self.settings.sync_server and self.settings.webdav_address then
        self.settings.sync_server = {
            address  = self.settings.webdav_address,
            username = self.settings.webdav_username or "",
            password = self.settings.webdav_password or "",
            url      = self.settings.webdav_base_path or "",
            type     = "webdav",
            name     = self.settings.user_name or "",
        }
        self.settings.webdav_address   = nil
        self.settings.webdav_username  = nil
        self.settings.webdav_password  = nil
        self.settings.webdav_base_path = nil
        G_reader_settings:saveSetting("webdav_sync", self.settings)
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerFileDialogButton()
end

function Syncest:onDispatcherRegisterActions()
    Dispatcher:registerAction("syncest_open_library",
        { category="none", event="SyncestOpenLibrary",
          title=_("Open Syncest Library"), general=true })
    Dispatcher:registerAction("syncest_push_books",
        { category="none", event="SyncestPushBooks",
          title=_("Push Syncest book library"), general=true })
    Dispatcher:registerAction("syncest_pull_books",
        { category="none", event="SyncestPullBooks",
          title=_("Pull Syncest book library"), general=true })
end

function Syncest:onDispatcherRegisterReaderActions()
    Dispatcher:registerAction("syncest_set_autosync",
        { category="string", event="SyncestToggleAutoSync",
          title=_("Set auto progress sync"), reader=true,
          args={true, false}, toggle={_("on"), _("off")} })
    Dispatcher:registerAction("syncest_toggle_autosync",
        { category="none", event="SyncestToggleAutoSync",
          title=_("Toggle auto Syncest sync"), reader=true })
    Dispatcher:registerAction("syncest_push_progress",
        { category="none", event="SyncestPushProgress",
          title=_("Push progress to Syncest"), reader=true })
    Dispatcher:registerAction("syncest_pull_progress",
        { category="none", event="SyncestPullProgress",
          title=_("Pull progress from Syncest"), reader=true, separator=true })
    Dispatcher:registerAction("syncest_push_annotations",
        { category="none", event="SyncestPushAnnotations",
          title=_("Push annotations to Syncest"), reader=true })
    Dispatcher:registerAction("syncest_pull_annotations",
        { category="none", event="SyncestPullAnnotations",
          title=_("Pull annotations from Syncest"), reader=true, separator=true })
end

function Syncest:onReaderReady()
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        UIManager:nextTick(function()
            self:pullBookConfig(false)
            self:pullBookNotes(false)
            self:pullBookStats(false)
        end)
    end
    self:onDispatcherRegisterReaderActions()
end

-- ── File dialog "Add to Syncest" button ───────────────────────────

local _readest_format_for_ext = nil
local function readest_format_for_ext(ext)
    if not _readest_format_for_ext then
        _readest_format_for_ext = {}
        local EXTS = require("syncest_lib.exts")
        for fmt, e in pairs(EXTS) do _readest_format_for_ext[e] = fmt end
    end
    return ext and _readest_format_for_ext[ext:lower()]
end

function Syncest:registerFileDialogButton()
    local plugin = self
    UIManager:scheduleIn(0, function()
        local ok_FM, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not ok_FM or not FileManager.instance then return end
        FileManager.instance:addFileDialogButtons("syncest_add_to_library",
            function(file, is_file, _book_props)
                if not is_file then return nil end
                local ext = file:match("%.([^./\\]+)$")
                if not readest_format_for_ext(ext) then return nil end
                return {{
                    text = _("Add to Syncest Library"),
                    enabled = not WebDavAuth:needsSetup(plugin.settings),
                    callback = function()
                        local fc = FileManager.instance and FileManager.instance.file_chooser
                        local dlg = fc and fc.file_dialog
                        if dlg then UIManager:close(dlg) end
                        plugin:addToLibrary(file)
                    end,
                }}
            end)
    end)
end

function Syncest:addToLibrary(file)
    local lfs  = require("libs/libkoreader-lfs")
    local util = require("util")

    if WebDavAuth:needsSetup(self.settings) then
        UIManager:show(InfoMessage:new{
            text = _("Configure WebDAV sync first."), timeout = 3,
        })
        return
    end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("File not found."), timeout = 3 })
        return
    end
    local ext = file:match("%.([^./\\]+)$")
    local format = readest_format_for_ext(ext)
    if not format then
        UIManager:show(InfoMessage:new{ text = _("Unsupported book format."), timeout = 3 })
        return
    end

    local progress = InfoMessage:new{ text = _("Hashing book…") }
    UIManager:show(progress)
    UIManager:nextTick(function()
        local hash = util.partialMD5(file)
        UIManager:close(progress)
        if not hash then
            UIManager:show(InfoMessage:new{ text = _("Could not read file."), timeout = 3 })
            return
        end
        self:_addLocalRow(file, hash, format, attr.size)
    end)
end

function Syncest:_addLocalRow(file, hash, format, _size)
    local store = self:getLibraryStore()
    if not store then
        UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first."), timeout = 3 })
        return
    end
    local basename = file:match("([^/]+)$") or file
    local title = basename:gsub("%.[^.]+$", "")
    local now = math.floor(os.time() * 1000)

    local existing = store:_getRowRaw(hash)
    if existing and existing.deleted_at == nil then
        store:upsertBook({ hash = hash, title = existing.title or title,
            file_path = file, local_present = 1, updated_at = now })
        local LibraryWidget = require("syncest_lib.librarywidget")
        if LibraryWidget._menu then LibraryWidget.refresh() end
        UIManager:show(InfoMessage:new{
            text = _("Already in your library: ") .. (existing.title or title),
            timeout = 2,
        })
        return
    end

    store:upsertBook({ hash = hash, title = title, format = format,
        file_path = file, local_present = 1, created_at = now,
        updated_at = now, _clear_fields = { "deleted_at" } })
    local LibraryWidget = require("syncest_lib.librarywidget")
    if LibraryWidget._menu then LibraryWidget.refresh() end
    UIManager:show(InfoMessage:new{
        text = _("Added to library: ") .. title, timeout = 2,
    })
end

function Syncest:onAddToSyncestLibrary(file)
    self:addToLibrary(file)
end

-- ── Menu ───────────────────────────────────────────────────────────

function Syncest:addToMainMenu(menu_items)
    menu_items.syncest = {
        sorting_hint = "tools",
        text = _("Syncest"),
        sub_item_table = {
            {
                text_func = function()
                    if WebDavAuth:needsSetup(self.settings) then
                        return _("Configure WebDAV account")
                    else
                        return T(_("Disconnect (%1)"), self.settings.user_name or "")
                    end
                end,
                callback_func = function()
                    if WebDavAuth:needsSetup(self.settings) then
                        return function(menu)
                            WebDavAuth:setup(self.settings, menu)
                        end
                    else
                        return function(menu)
                            WebDavAuth:disconnect(self.settings, menu)
                        end
                    end
                end,
            },
            {
                text = _("Auto sync"),
                checked_func = function() return self.settings.auto_sync end,
                callback = function() self:onSyncestToggleAutoSync() end,
                separator = true,
            },
            {
                text = _("Syncest Library"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                end,
                callback = function() self:openLibrary() end,
            },
            {
                text = _("Push stats now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                end,
                callback = function() self:pushBookStats(true) end,
            },
            {
                text = _("Pull stats now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                end,
                callback = function() self:pullBookStats(true) end,
            },
            {
                text = _("Push books now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                end,
                callback = function() self:syncBooksLibrary("push", true) end,
            },
            {
                text = _("Pull books now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                end,
                callback = function() self:syncBooksLibrary("pull", true) end,
                separator = true,
            },
            {
                text = _("Push reading progress now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                        and self.ui.document ~= nil
                end,
                callback = function() self:pushBookConfig(true) end,
            },
            {
                text = _("Pull reading progress now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                        and self.ui.document ~= nil
                end,
                callback = function() self:pullBookConfig(true) end,
                separator = true,
            },
            {
                text = _("Push annotations now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                        and self.ui.document ~= nil
                end,
                callback = function() self:pushBookNotes(true) end,
            },
            {
                text = _("Pull annotations now"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                        and self.ui.document ~= nil
                end,
                callback = function() self:pullBookNotes(true) end,
            },
            {
                text = _("Full sync all annotations"),
                enabled_func = function()
                    return not WebDavAuth:needsSetup(self.settings)
                        and self.ui.document ~= nil
                end,
                callback = function() self:fullSyncBookNotes() end,
                separator = true,
            },
            {
                text = _("Sync info"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback = function() self:showSyncInfo() end,
            },
        }
    }
end

-- ── Client helper ──────────────────────────────────────────────────

function Syncest:ensureClient(interactive)
    if WebDavAuth:needsSetup(self.settings) then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Configure WebDAV sync first"), timeout = 2,
            })
        end
        return nil
    end
    return WebDavAuth:getClient(self.settings)
end

function Syncest:getBookIdentifiers()
    local book_hash = SyncConfig:getDocumentIdentifier(self.ui)
    local meta_hash = SyncConfig:getMetaHash(self.ui)
    return book_hash, meta_hash
end

function Syncest:showSyncInfo()
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("No book is open"), timeout = 2 })
        return
    end
    local info = SyncConfig:getMetadataHashInfo(self.ui)
    local doc_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    local stored_meta_hash = doc_sync.meta_hash_v1
    local placeholder = _("(none)")
    local last_synced_at = math.max(
        doc_sync.last_synced_at_config or 0,
        doc_sync.last_synced_at_notes  or 0)
    local last_synced_label = last_synced_at > 0
        and os.date("%Y-%m-%d %H:%M", last_synced_at)
        or _("Never synced")
    local kv_pairs = {
        { _("Book Fingerprint"), stored_meta_hash or info.meta_hash },
        { _("Title"), info.title ~= "" and info.title or placeholder },
        { _("Author"), #info.authors > 0
            and table.concat(info.authors, ", ") or placeholder },
        { _("Identifiers"), #info.identifiers > 0
            and table.concat(info.identifiers, ", ") or placeholder },
        { _("Last Synced"), last_synced_label },
    }
    UIManager:show(KeyValuePage:new{ title = _("Sync Info"), kv_pairs = kv_pairs })
end

-- ── Config sync ────────────────────────────────────────────────────

function Syncest:pushBookConfig(interactive)
    local now = os.time()
    if not interactive and now - self.last_sync_timestamp <= API_CALL_DEBOUNCE_DELAY then
        return
    end
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookConfig(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    self.last_sync_timestamp = SyncConfig:push(
        self.ui, self.settings, client, interactive, self.last_sync_timestamp)
end

function Syncest:pullBookConfig(interactive)
    local book_hash, meta_hash = self:getBookIdentifiers()
    if not book_hash or not meta_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfig(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    SyncConfig:pull(self.ui, self.settings, client, book_hash, meta_hash,
        interactive, function() end)
end

-- ── Stats sync ─────────────────────────────────────────────────────

function Syncest:pushBookStats(interactive)
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookStats(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    SyncStats:push(self.settings, client, interactive)
end

function Syncest:pullBookStats(interactive)
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookStats(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    SyncStats:pull(self.settings, client, interactive, function() end)
end

-- ── Annotation sync ────────────────────────────────────────────────

function Syncest:pushBookNotes(interactive, full_sync)
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookNotes(interactive, full_sync) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    SyncAnnotations:push(self.ui, self.settings, client, interactive, full_sync)
end

function Syncest:pullBookNotes(interactive, full_sync)
    local book_hash, meta_hash = self:getBookIdentifiers()
    if not book_hash or not meta_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookNotes(interactive, full_sync) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    SyncAnnotations:pull(self.ui, self.settings, client, book_hash, meta_hash,
        self.dialog, interactive, full_sync)
end

function Syncest:fullSyncBookNotes()
    self:pushBookNotes(true, true)
    self:pullBookNotes(true, true)
end

-- ── Library ────────────────────────────────────────────────────────

function Syncest:openLibrary()
    if WebDavAuth:needsSetup(self.settings) then
        UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first"), timeout = 2 })
        return
    end
    local client = WebDavAuth:getClient(self.settings)
    local LibraryWidget = require("syncest_lib.librarywidget")
    LibraryWidget.open({
        settings = self.settings,
        client   = client,
    })
end

function Syncest:getLibraryStore()
    if not self.settings.user_id or self.settings.user_id == "" then return nil end
    local LibraryWidget = require("syncest_lib.librarywidget")
    if LibraryWidget._store and LibraryWidget._current_user == self.settings.user_id then
        return LibraryWidget._store
    end
    if self.library_store and self.library_store.user_id == self.settings.user_id then
        return self.library_store
    end
    if self.library_store then self.library_store:close() end
    local LibraryStore = require("syncest_lib.librarystore")
    local DataStorage  = require("datastorage")
    self.library_store = LibraryStore.new({
        user_id = self.settings.user_id,
        db_path = DataStorage:getSettingsDir() .. "/syncest_library.sqlite3",
    })
    return self.library_store
end

function Syncest:touchOpenBook()
    if not self.ui or not self.ui.doc_settings then return nil end
    local hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if not hash or hash == "" then return nil end
    local store = self:getLibraryStore()
    if not store then return nil end
    local progress_lib
    if self.ui.document and self.ui.document.getPageCount and self.ui.getCurrentPage then
        local cur   = self.ui:getCurrentPage()
        local total = self.ui.document:getPageCount()
        if cur and total then
            progress_lib = require("json").encode({ cur, total })
        end
    end
    local touched = store:touchBook(hash, { progress_lib = progress_lib })
    if not touched then
        logger.dbg("Syncest touchOpenBook: no row for " .. hash)
    end
    return touched
end

function Syncest:syncBooksLibrary(mode, interactive)
    if WebDavAuth:needsSetup(self.settings) then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Configure WebDAV sync first"), timeout = 2 })
        end
        return
    end
    local store = self:getLibraryStore()
    if not store then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Library not initialized"), timeout = 2 })
        end
        return
    end
    -- Scan all books in the home directory before pushing.
    if mode == "push" or mode == "both" then
        local localscanner = require("syncest_lib.localscanner")
        local home_dir = G_reader_settings:readSetting("home_dir") or "/sdcard/Books"
        pcall(localscanner.dirScan, { store = store, dir = home_dir })
    end
    local client = WebDavAuth:getClient(self.settings)
    local syncbooks = require("syncest_lib.syncbooks")
    syncbooks.syncBooks({
        client   = client,
        settings = self.settings,
        store    = store,
    }, mode, function(success, _msg, _status)
        if interactive then
            UIManager:show(InfoMessage:new{
                text = success and _("Books synced") or _("Books sync failed"),
                timeout = 2,
            })
        end
        local LibraryWidget = require("syncest_lib.librarywidget")
        if LibraryWidget._menu then LibraryWidget.refresh() end
    end, function()
        self:touchOpenBook()
    end)
end

-- ── Event handlers ─────────────────────────────────────────────────

function Syncest:onSyncestToggleAutoSync(toggle)
    if toggle == self.settings.auto_sync then return true end
    self.settings.auto_sync = not self.settings.auto_sync
    G_reader_settings:saveSetting("webdav_sync", self.settings)
    if self.settings.auto_sync and self.ui.document then
        self:pullBookConfig(false)
    end
end

function Syncest:onSyncestPushProgress()    self:pushBookConfig(true)    end
function Syncest:onSyncestPullProgress()    self:pullBookConfig(true)    end
function Syncest:onSyncestPushAnnotations() self:pushBookNotes(true)     end
function Syncest:onSyncestPullAnnotations() self:pullBookNotes(true)     end
function Syncest:onSyncestOpenLibrary()     self:openLibrary()           end
function Syncest:onSyncestPushBooks()       self:syncBooksLibrary("push", true) end
function Syncest:onSyncestPullBooks()       self:syncBooksLibrary("pull", true) end

function Syncest:onCloseDocument()
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        NetworkMgr:goOnlineToRun(function()
            self:pushBookConfig(false)
            self:pushBookNotes(false)
            self:pushBookStats(false)
            self:syncBooksLibrary("both", false)
        end)
    end
end

function Syncest:onPageUpdate(page)
    if self.settings.auto_sync
            and not WebDavAuth:needsSetup(self.settings) and page then
        if self.delayed_push_task then
            UIManager:unschedule(self.delayed_push_task)
        end
        self.delayed_push_task = function()
            self:pushBookConfig(false)
        end
        UIManager:scheduleIn(5, self.delayed_push_task)
    end
end

function Syncest:onAnnotationsModified(items)
    if not WebDavAuth:needsSetup(self.settings) and items
            and items.index_modified and items.index_modified < 0 and items[1] then
        SyncAnnotations:recordDeletion(self.ui.doc_settings, items[1])
    end
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        UIManager:nextTick(function() self:pushBookNotes(false) end)
    end
end

function Syncest:onCloseWidget()
    if self.delayed_push_task then
        UIManager:unschedule(self.delayed_push_task)
        self.delayed_push_task = nil
    end
end

function Syncest:deletePluginSettings()
    G_reader_settings:delSetting("webdav_sync")
    self.settings = self.default_settings
    return true
end

return Syncest
