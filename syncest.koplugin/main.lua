local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local KeyValuePage = require("ui/widget/keyvaluepage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local T = require("ffi/util").template
local _ = require("gettext")

local function serverReachable(address, timeout)
    local host = (address or ""):match("https?://([^/:]+)")
    if not host then return false end
    local port = tonumber((address or ""):match("//[^/]*:(%d+)"))
        or ((address or ""):match("^https://") and 443 or 80)
    local ok, connected = pcall(function()
        local s = socket.tcp()
        if not s then return false end
        s:settimeout(timeout or 1)
        local result = s:connect(host, port)
        s:close()
        return result == 1
    end)
    return ok and connected == true
end

local WebDavAuth = require("webdav_auth")
local SyncConfig = require("syncest_syncconfig")
local SyncAnnotations = require("syncest_syncannotations")
local SyncStats = require("syncest_syncstats")
local SyncVocab = require("syncest_syncvocab")

local GITHUB_RAW_BASE = "https://raw.githubusercontent.com/titandrive/syncest/main/syncest.koplugin/"
local PLUGIN_VERSION = require("_meta").version

local function is_newer_version(latest, current)
    local function parts(v)
        local t = {}
        for n in v:gmatch("%d+") do t[#t+1] = tonumber(n) end
        return t
    end
    local lp, cp = parts(latest), parts(current)
    for i = 1, math.max(#lp, #cp) do
        local l, c = lp[i] or 0, cp[i] or 0
        if l ~= c then return l > c end
    end
    return false
end

local Syncest = WidgetContainer:new{
    name = "syncest",
    title = _("Syncest"),
    settings = nil,
}

local API_CALL_DEBOUNCE_DELAY = 30

Syncest.default_settings = {
    sync_server              = nil,
    auto_sync                = false,
    -- Granular auto sync flags (all default on; only meaningful when auto_sync=true)
    auto_push_progress       = true,
    push_every_x_pages       = false,
    push_page_interval       = 10,
    auto_pull_progress       = true,
    auto_push_annotations    = true,
    auto_pull_annotations    = true,
    auto_push_stats          = true,
    auto_pull_stats          = true,
    auto_sync_catalog        = true,
    mirror_to_kosync         = false,
    user_id      = nil,
    user_name    = nil,
    last_sync_at = nil,
}

-- ── Lifecycle ──────────────────────────────────────────────────────

function Syncest:_autoNotify(label, action)
    if not self._notify_labels then self._notify_labels = {} end
    self._notify_labels[label] = action
    if self._notify_task then UIManager:unschedule(self._notify_task) end
    self._notify_task = function()
        local order = { "progress", "annotations", "stats", "vocab" }
        local parts = {}
        for _, k in ipairs(order) do
            if self._notify_labels[k] then
                parts[#parts + 1] = k .. " " .. self._notify_labels[k]
            end
        end
        UIManager:show(Notification:new{
            text = table.concat(parts, ", "),
            timeout = 2,
        })
        self._notify_labels = nil
        self._notify_task = nil
    end
    UIManager:scheduleIn(0.5, self._notify_task)
end

function Syncest:init()
    self.last_sync_timestamp = 0
    self._last_pushed_page = nil
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
        -- Stagger each sync into its own tick so the UI thread gets to
        -- breathe between calls and Android's ANR timer resets.
        if self.settings.auto_pull_progress ~= false then
            UIManager:nextTick(function() self:pullBookConfig(false, true) end)
        end
        if self.settings.auto_pull_annotations ~= false then
            UIManager:scheduleIn(0.1, function() self:pullBookNotes(false, false, true) end)
        end
        if self.settings.auto_pull_stats ~= false then
            UIManager:scheduleIn(0.2, function() self:pullBookStats(false, true) end)
        end
        if self.settings.auto_pull_vocab ~= false then
            UIManager:scheduleIn(0.3, function() self:pullVocab(false, true) end)
        end
    end
    self._last_pushed_page = nil
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

-- ── Update checker ─────────────────────────────────────────────────

function Syncest:checkForUpdates()
    local checking = InfoMessage:new{ text = _("Checking for updates...") }
    UIManager:show(checking)
    UIManager:forceRePaint()

    local ok_https, https = pcall(require, "ssl.https")
    if not ok_https then
        UIManager:close(checking)
        UIManager:show(InfoMessage:new{ text = _("Update check requires network support."), timeout = 3 })
        return
    end
    local ltn12 = require("ltn12")
    local ok_sutil, socketutil = pcall(require, "socketutil")
    if ok_sutil then socketutil:set_timeout(5, 15) end

    local body = {}
    local ok_req, status = pcall(function()
        local _, s = https.request{
            url = GITHUB_RAW_BASE .. "_meta.lua",
            method = "GET",
            headers = { ["User-Agent"] = "KOReader-Syncest/" .. PLUGIN_VERSION },
            sink = ltn12.sink.table(body),
        }
        return s
    end)

    if ok_sutil then pcall(function() socketutil:reset_timeout() end) end
    UIManager:close(checking)

    if not ok_req or status ~= 200 then
        UIManager:show(InfoMessage:new{
            text = _("Could not reach update server. Check your network connection."),
            timeout = 3,
        })
        return
    end

    local latest = table.concat(body):match('version%s*=%s*"([^"]+)"')
    if not latest then
        UIManager:show(InfoMessage:new{ text = _("Could not read version information."), timeout = 3 })
        return
    end

    if not is_newer_version(latest, PLUGIN_VERSION) then
        UIManager:show(InfoMessage:new{
            text = T(_("Syncest v%1 is up to date."), PLUGIN_VERSION),
            timeout = 3,
        })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Version %1 is available (installed: v%2). Install now?"), latest, PLUGIN_VERSION),
        ok_text = _("Install"),
        cancel_text = _("Later"),
        ok_callback = function() self:installUpdate(latest) end,
    })
end

function Syncest:installUpdate(version)
    local msg = InfoMessage:new{ text = _("Downloading update...") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local ok_https, https = pcall(require, "ssl.https")
    if not ok_https then
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = _("Update failed: network support unavailable."), timeout = 3 })
        return
    end
    local ltn12 = require("ltn12")
    local ok_sutil, socketutil = pcall(require, "socketutil")
    if ok_sutil then socketutil:set_timeout(10, 60) end

    local files = {
        "_meta.lua", "main.lua", "syncest_i18n.lua", "syncest_insert_menu.lua",
        "syncest_syncannotations.lua", "syncest_syncconfig.lua", "syncest_syncstats.lua",
        "syncest_syncvocab.lua", "webdav_auth.lua", "webdav_syncclient.lua",
        "syncest_lib/bim_patch.lua", "syncest_lib/cloud_covers.lua", "syncest_lib/cloud_icons.lua",
        "syncest_lib/coverprovider.lua", "syncest_lib/exts.lua", "syncest_lib/group_covers.lua",
        "syncest_lib/libraryitem.lua", "syncest_lib/librarypaint.lua", "syncest_lib/librarystore.lua",
        "syncest_lib/libraryviewmenu.lua", "syncest_lib/librarywidget.lua", "syncest_lib/list_strip.lua",
        "syncest_lib/localscanner.lua", "syncest_lib/readingstatus.lua", "syncest_lib/statussync.lua",
        "syncest_lib/syncbooks.lua",
    }

    for _, fname in ipairs(files) do
        local f = io.open(self.path .. "/" .. fname, "wb")
        if not f then
            if ok_sutil then pcall(function() socketutil:reset_timeout() end) end
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = T(_("Update failed: could not write %1"), fname), timeout = 3 })
            return
        end
        local ok_req, fstatus = pcall(function()
            local _, s = https.request{
                url = GITHUB_RAW_BASE .. fname,
                method = "GET",
                headers = { ["User-Agent"] = "KOReader-Syncest/" .. version },
                sink = ltn12.sink.file(f),
            }
            return s
        end)
        if not ok_req then pcall(function() f:close() end) end
        if not ok_req or fstatus ~= 200 then
            if ok_sutil then pcall(function() socketutil:reset_timeout() end) end
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = T(_("Update failed: could not download %1"), fname), timeout = 3 })
            return
        end
    end

    if ok_sutil then pcall(function() socketutil:reset_timeout() end) end
    UIManager:close(msg)
    UIManager:show(InfoMessage:new{
        text = T(_("Syncest updated to v%1. Please restart KOReader."), version),
        timeout = 5,
    })
end

-- ── Menu ───────────────────────────────────────────────────────────

function Syncest:addToMainMenu(menu_items)
    local function syncest_menu_items()
        local configured = not WebDavAuth:needsSetup(self.settings)
        local in_book = self.ui.document ~= nil
        local items = {
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
            },
            {
                text = _("Sync settings"),
                sub_item_table = {
                    {
                        text = _("Mirror progress to KOSync"),
                        checked_func = function() return self.settings.mirror_to_kosync end,
                        callback = function()
                            self.settings.mirror_to_kosync = not self.settings.mirror_to_kosync
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                        separator = true,
                    },
                    {
                        text = _("Auto Sync Settings"),
                        enabled_func = function() return false end,
                    },
                    {
                        text = _("Push reading progress on page turn"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_progress ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_progress =
                                self.settings.auto_push_progress == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text_func = function()
                            local n = self.settings.push_page_interval or 10
                            return T(_("Push every %1 pages (hold to change)"), n)
                        end,
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.push_every_x_pages == true
                        end,
                        callback = function()
                            self.settings.push_every_x_pages =
                                not self.settings.push_every_x_pages
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                        hold_callback = function()
                            local menu_widget
                            local stack = UIManager._window_stack
                            if stack then
                                for i = #stack, 1, -1 do
                                    local entry = stack[i]
                                    local w = entry and (entry.widget or entry)
                                    if w and type(w.updateItems) == "function" then
                                        menu_widget = w
                                        break
                                    end
                                end
                            end
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text = _("Push every X pages"),
                                value = self.settings.push_page_interval or 10,
                                value_min = 1,
                                value_max = 500,
                                value_step = 1,
                                ok_always_enabled = true,
                                callback = function(spin)
                                    self.settings.push_page_interval = spin.value
                                    G_reader_settings:saveSetting("webdav_sync", self.settings)
                                    if menu_widget then
                                        UIManager:close(menu_widget)
                                    end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Pull reading progress on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_progress ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_progress =
                                self.settings.auto_pull_progress == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Push annotations on change"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_annotations ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_annotations =
                                self.settings.auto_push_annotations == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull annotations on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_annotations ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_annotations =
                                self.settings.auto_pull_annotations == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Push stats on book close"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_stats ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_stats =
                                self.settings.auto_push_stats == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull stats on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_stats ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_stats =
                                self.settings.auto_pull_stats == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Push vocab on word lookup"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_push_vocab ~= false
                        end,
                        callback = function()
                            self.settings.auto_push_vocab =
                                self.settings.auto_push_vocab == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Pull vocab on book open"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function()
                            return self.settings.auto_pull_vocab ~= false
                        end,
                        callback = function()
                            self.settings.auto_pull_vocab =
                                self.settings.auto_pull_vocab == false
                            G_reader_settings:saveSetting("webdav_sync", self.settings)
                        end,
                    },
                },
                separator = true,
            },
            {
                text = T(_("Syncest v%1"), PLUGIN_VERSION),
                callback = function() self:checkForUpdates() end,
                separator = true,
            },
            -- ── Library & Books ─────────────────────────────────────
            {
                text = _("Syncest Library"),
                enabled_func = function() return configured end,
                callback = function() self:openLibrary() end,
            },
            {
                text = _("Push books now"),
                enabled_func = function() return configured end,
                callback = function() self:syncBooksLibrary("push", true) end,
            },
            {
                text = _("Pull books now"),
                enabled_func = function() return configured end,
                callback = function() self:syncBooksLibrary("pull", true) end,
                separator = true,
            },
            -- ── Stats & Vocab ───────────────────────────────────────
            {
                text = _("Push stats now"),
                enabled_func = function() return configured end,
                callback = function() self:pushBookStats(true, true) end,
            },
            {
                text = _("Pull stats now"),
                enabled_func = function() return configured end,
                callback = function() self:pullBookStats(true, true) end,
            },
            {
                text = _("Push vocab now"),
                enabled_func = function() return configured end,
                callback = function() self:pushVocab(true, true) end,
            },
            {
                text = _("Pull vocab now"),
                enabled_func = function() return configured end,
                callback = function() self:pullVocab(true, true) end,
            },
        }

        if in_book then
            local book_items = {
                {
                    text = _("Push reading progress now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pushBookConfig(true, true) end,
                },
                {
                    text = _("Pull reading progress now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pullBookConfig(true, true) end,
                },
                {
                    text = _("Push annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pushBookNotes(true, true, true) end,
                },
                {
                    text = _("Pull annotations now"),
                    enabled_func = function() return configured end,
                    callback = function() self:pullBookNotes(true, false, true) end,
                    separator = true,
                },
            }
            -- Insert after the 4 settings items (Configure, Auto sync, Sync settings, Version)
            for i = #book_items, 1, -1 do
                table.insert(items, 5, book_items[i])
            end
            -- Sync info always at the very bottom
            items[#items].separator = true
            items[#items + 1] = {
                text = _("Sync info"),
                callback = function() self:showSyncInfo() end,
            }
        end

        return items
    end

    menu_items.syncest = {
        text = _("Syncest"),
        sub_item_table_func = syncest_menu_items,
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
    return SyncConfig:getDocumentIdentifier(self.ui)
end

function Syncest:showSyncInfo()
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("No book is open"), timeout = 2 })
        return
    end
    local info = SyncConfig:getMetadataHashInfo(self.ui)
    local book_hash = SyncConfig:getDocumentIdentifier(self.ui)
    local doc_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
    local gs = G_reader_settings:readSetting("webdav_sync") or {}
    local placeholder = _("(none)")
    local never = _("Never")
    local function fmt(ts)
        return (ts and ts > 0) and os.date("%Y-%m-%d %H:%M", ts) or never
    end
    local function max_ts(...)
        local m = 0
        for _, v in ipairs({...}) do
            local n = tonumber(v) or 0
            if n > m then m = n end
        end
        return m > 0 and m or nil
    end
    local kv_pairs = {
        { _("Book Hash"),  book_hash or placeholder },
        { _("Title"),  info.title ~= "" and info.title or placeholder },
        { _("Author"), #info.authors > 0 and table.concat(info.authors, ", ") or placeholder },
        { _("Progress pushed"),    fmt(max_ts(doc_sync.last_pushed_at_config)) },
        { _("Progress pulled"),    fmt(max_ts(doc_sync.last_synced_at_config)) },
        { _("Annotations pushed"), fmt(max_ts(doc_sync.last_pushed_at_notes)) },
        { _("Annotations pulled"), fmt(max_ts(doc_sync.last_synced_at_notes)) },
        { _("Stats pushed"),       fmt(gs.stats_last_pushed_at) },
    }
    UIManager:show(KeyValuePage:new{ title = _("Sync Info"), kv_pairs = kv_pairs })
end

-- ── Config sync ────────────────────────────────────────────────────

function Syncest:pushBookConfig(interactive, notify)
    local now = os.time()
    if not interactive and now - self.last_sync_timestamp <= API_CALL_DEBOUNCE_DELAY then
        return
    end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookConfig(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    self.last_sync_timestamp = SyncConfig:push(
        self.ui, self.settings, client, interactive, self.last_sync_timestamp, notify_fn)
    if self.settings.mirror_to_kosync and self.ui.kosync then
        pcall(function() self.ui.kosync:updateProgress(true, false) end)
    end
end

function Syncest:pullBookConfig(interactive, notify)
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfig(interactive, notify) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncConfig:pull(self.ui, self.settings, client, book_hash,
        interactive, function() end, notify_fn)
end

-- ── Stats sync ─────────────────────────────────────────────────────

function Syncest:pushBookStats(interactive, notify)
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookStats(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullBookStats(interactive, notify)
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookStats(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:pull(self.settings, client, interactive, function() end, notify_fn)
end

-- ── Vocab sync ─────────────────────────────────────────────────────

function Syncest:pushVocab(interactive, notify)
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushVocab(interactive) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullVocab(interactive, notify)
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullVocab(interactive, notify) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:pull(self.settings, client, interactive, notify_fn)
end

-- ── Annotation sync ────────────────────────────────────────────────

function Syncest:pushBookNotes(interactive, full_sync, notify)
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookNotes(interactive, full_sync) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncAnnotations:push(self.ui, self.settings, client, interactive, full_sync, notify_fn)
end

function Syncest:pullBookNotes(interactive, full_sync, notify)
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookNotes(interactive, full_sync, notify) end) then
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncAnnotations:pull(self.ui, self.settings, client, book_hash,
        self.dialog, interactive, full_sync, notify_fn)
end

function Syncest:fullSyncBookNotes()
    self:pushBookNotes(true, true, true)
    self:pullBookNotes(true, true, true)
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
    }, mode, function(success, msg, _status)
        if success and (mode == "push" or mode == "both") then
            self.settings.catalog_last_pushed_at = os.time()
            G_reader_settings:saveSetting("webdav_sync", self.settings)
        end
        if interactive then
            UIManager:show(InfoMessage:new{
                text = success
                    and _("Books synced")
                    or  ("Books sync failed: " .. tostring(msg)),
                timeout = success and 2 or 8,
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

function Syncest:onSyncestPushProgress()    self:pushBookConfig(true, true)        end
function Syncest:onSyncestPullProgress()    self:pullBookConfig(true, true)        end
function Syncest:onSyncestPushAnnotations() self:pushBookNotes(true, true, true)   end
function Syncest:onSyncestPullAnnotations() self:pullBookNotes(true, false, true)  end
function Syncest:onSyncestOpenLibrary()     self:openLibrary()           end
function Syncest:onSyncestPushBooks()       self:syncBooksLibrary("push", true) end
function Syncest:onSyncestPullBooks()       self:syncBooksLibrary("pull", true) end

function Syncest:onCloseDocument()
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        local addr = self.settings.sync_server and self.settings.sync_server.address
        if not serverReachable(addr, 1) then return end
        pcall(function()
            if self.settings.auto_push_progress ~= false then
                self:pushBookConfig(false, true)
            end
            if self.settings.auto_push_annotations ~= false then
                self:pushBookNotes(false, false, true)
            end
            if self.settings.auto_push_stats ~= false then
                self:pushBookStats(false, true)
            end
            if self.settings.auto_push_vocab ~= false and self._vocab_dirty then
                self._vocab_dirty = false
                self:pushVocab(false, true)
            end
        end)
    end
end

-- Fires when a word is looked up (and potentially added to vocab builder).
-- Debounce so rapid lookups batch into one push.
function Syncest:onWordLookedUp()
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) then return end
    if self.settings.auto_push_vocab == false then return end
    self._vocab_dirty = true
    if self._vocab_push_task then UIManager:unschedule(self._vocab_push_task) end
    self._vocab_push_task = function()
        self._vocab_push_task = nil
        self:pushVocab(false, true)
    end
    UIManager:scheduleIn(2, self._vocab_push_task)
end

function Syncest:onPageUpdate(page)
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) or not page then
        return
    end
    if self.settings.auto_push_progress ~= false then
        if self.delayed_push_task then
            UIManager:unschedule(self.delayed_push_task)
        end
        self.delayed_push_task = function()
            self:pushBookConfig(false)
        end
        UIManager:scheduleIn(5, self.delayed_push_task)
    end
    if self.settings.push_every_x_pages == true then
        local interval = self.settings.push_page_interval or 10
        if self._last_pushed_page == nil
                or math.abs(page - self._last_pushed_page) >= interval then
            self._last_pushed_page = page
            if self.x_page_push_task then
                UIManager:unschedule(self.x_page_push_task)
            end
            self.x_page_push_task = function()
                self.x_page_push_task = nil
                self:pushBookConfig(false, false)
            end
            UIManager:scheduleIn(5, self.x_page_push_task)
        end
    end
end

function Syncest:onAnnotationsModified(items)
    if not WebDavAuth:needsSetup(self.settings) and items
            and items.index_modified and items.index_modified < 0 and items[1] then
        SyncAnnotations:recordDeletion(self.ui.doc_settings, items[1])
    end
    if self.settings.auto_sync and self.settings.auto_push_annotations ~= false
            and not WebDavAuth:needsSetup(self.settings) then
        UIManager:nextTick(function() self:pushBookNotes(false, false, true) end)
    end
end

function Syncest:onCloseWidget()
    if self.delayed_push_task then
        UIManager:unschedule(self.delayed_push_task)
        self.delayed_push_task = nil
    end
    if self.x_page_push_task then
        UIManager:unschedule(self.x_page_push_task)
        self.x_page_push_task = nil
    end
    if self._vocab_push_task then
        UIManager:unschedule(self._vocab_push_task)
        self._vocab_push_task = nil
    end
end

function Syncest:deletePluginSettings()
    G_reader_settings:delSetting("webdav_sync")
    self.settings = self.default_settings
    return true
end

require("syncest_insert_menu")

return Syncest
