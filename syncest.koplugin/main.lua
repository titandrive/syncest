local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local KeyValuePage = require("ui/widget/keyvaluepage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local _ = require("gettext")

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
local AUTO_PUSH_SUPPRESS_AFTER_PULL = 45
local AUTO_PUSH_WEBDAV_ENABLED = true
local STARTUP_AUTO_PULL_PROGRESS_ENABLED = true
local SYNC_PLUGIN_INERT_DIAGNOSTIC = false
local AUTO_SYNC_POLL_INTERVAL = 0.25
local AUTO_SYNC_MAX_POLLS = 80

local function write_background_result(path, success, message)
    local file = io.open(path, "w")
    if not file then return end
    file:write(success and "ok" or "error", "\n", message or "")
    file:close()
end

local function read_background_result(path)
    local file = io.open(path, "r")
    if not file then return false, "background sync produced no result" end
    local status = file:read("*l")
    local message = file:read("*a")
    file:close()
    os.remove(path)
    return status == "ok", message
end

local function write_background_json_result(path, data)
    local ok_json, json = pcall(require, "json")
    if not ok_json then return false end
    local ok, encoded = pcall(json.encode, data or {})
    if not ok then return false end
    local file = io.open(path, "w")
    if not file then return false end
    file:write(encoded)
    file:close()
    return true
end

local function read_background_json_result(path)
    local file = io.open(path, "r")
    if not file then return nil, "background sync produced no result" end
    local content = file:read("*a")
    file:close()
    os.remove(path)
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "json module unavailable" end
    local ok, parsed = pcall(json.decode, content or "")
    if not ok or type(parsed) ~= "table" then
        return nil, "background sync produced invalid result"
    end
    return parsed
end

local function copy_settings(settings)
    local copied = {}
    for k, v in pairs(settings or {}) do
        if type(v) == "table" then
            local nested = {}
            for nk, nv in pairs(v) do nested[nk] = nv end
            copied[k] = nested
        else
            copied[k] = v
        end
    end
    return copied
end

function Syncest:_runSafely(label, fn, interactive)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then return true end
    logger.warn("Syncest " .. tostring(label) .. " failed: " .. tostring(err))
    if interactive then
        UIManager:show(InfoMessage:new{
            text = _("Syncest sync failed. Check the KOReader log for details."),
            timeout = 4,
        })
    end
    return false
end

function Syncest:_runBackgroundJSON(label, result_prefix, child_fn, on_complete, on_failure)
    if not self._background_jobs then self._background_jobs = {} end
    if self._background_jobs[label] then
        logger.info("Syncest " .. label .. ": already running, skipped")
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/" .. result_prefix .. "_" .. tostring(os.time()) .. ".json"
    os.remove(result_file)

    logger.info("Syncest " .. label .. ": launching")
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local ok, result = xpcall(child_fn, debug.traceback)
        if not ok then
            result = { success = false, message = tostring(result) }
        elseif type(result) ~= "table" then
            result = { success = result == true, message = tostring(result) }
        elseif result.success == nil then
            result.success = true
        end
        write_background_json_result(result_file, result)
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest " .. label .. ": launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        if on_failure then on_failure("launch failed") end
        return false
    end

    local pid = pid_or_err
    self._background_jobs[label] = pid
    local polls = 0
    local poll
    poll = function()
        polls = polls + 1
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < AUTO_SYNC_MAX_POLLS then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest " .. label .. ": timed out")
            self._background_jobs[label] = nil
            os.remove(result_file)
            if on_failure then on_failure("timed out") end
            return
        end

        self._background_jobs[label] = nil
        local result, message = read_background_json_result(result_file)
        if not result or result.success ~= true then
            logger.warn("Syncest " .. label .. ": failed "
                .. tostring(result and result.message or message))
            if on_failure then
                on_failure(result and result.message or message)
            end
            return
        end
        logger.info("Syncest " .. label .. ": success")
        self:_syncConnectionRestored()
        if on_complete then on_complete(result) end
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
    return true
end

function Syncest:_backgroundPushProgress(payload, notify)
    if self._auto_push_progress_running then
        logger.info("Syncest background progress push: already running, skipped")
        return false
    end
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then
        logger.warn("Syncest background progress push: missing sync server")
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/syncest_progress_push_" .. tostring(os.time()) .. ".result"
    os.remove(result_file)

    logger.info("Syncest background progress push: launching")
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local ok, success, message = xpcall(function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local done_success = false
            local done_message = nil
            client:pushChanges(payload, function(success2, _response, status)
                done_success = success2 == true
                done_message = tostring(status or "")
            end)
            return done_success, done_message
        end, debug.traceback)
        if not ok then
            write_background_result(result_file, false, success)
        else
            write_background_result(result_file, success, message)
        end
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest background progress push: launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        if notify then self:_autoFailureNotify("progress") end
        return false
    end

    local pid = pid_or_err
    self._auto_push_progress_running = true
    self._auto_push_progress_pid = pid
    local polls = 0
    local poll
    poll = function()
        polls = polls + 1
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < AUTO_SYNC_MAX_POLLS then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest background progress push: timed out")
            self._auto_push_progress_running = false
            self._auto_push_progress_pid = nil
            os.remove(result_file)
            if notify then self:_autoFailureNotify("progress") end
            return
        end

        self._auto_push_progress_running = false
        self._auto_push_progress_pid = nil
        local success, message = read_background_result(result_file)
        if success then
            logger.info("Syncest background progress push: success")
            self:_syncConnectionRestored()
            if self.ui and self.ui.doc_settings then
                local doc_readest_sync =
                    self.ui.doc_settings:readSetting("webdav_sync") or {}
                doc_readest_sync.last_pushed_at_config = os.time()
                self.ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
                self.ui.doc_settings:flush()
            end
            if notify then self:_autoNotify("progress", "pushed") end
        else
            logger.warn("Syncest background progress push: failed "
                .. tostring(message))
            if notify then self:_autoFailureNotify("progress") end
        end
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
    return true
end

function Syncest:_backgroundPullProgress(book_hash, notify, force_apply)
    if self._auto_pull_progress_running then
        logger.info("Syncest background progress pull: already running, skipped")
        return false
    end
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" or not book_hash then
        logger.warn("Syncest background progress pull: missing sync server/book")
        return false
    end

    local DataStorage = require("datastorage")
    local result_file = DataStorage:getSettingsDir()
        .. "/syncest_progress_pull_" .. tostring(os.time()) .. ".json"
    os.remove(result_file)

    logger.info("Syncest background progress pull: launching book="
        .. tostring(book_hash))
    local launch_ok, pid_or_err = pcall(FFIUtil.runInSubProcess, function()
        local result = { success = false, message = "" }
        local ok, err = xpcall(function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            client:pullChanges({
                since = 0,
                type = "configs",
                book = book_hash,
            }, function(success, response, status)
                result.success = success == true
                result.status = status
                if result.success and response and response.configs then
                    result.config = response.configs[1]
                else
                    result.message = tostring(status or "")
                end
            end)
        end, debug.traceback)
        if not ok then
            result.success = false
            result.message = tostring(err)
        end
        write_background_json_result(result_file, result)
    end)
    if not launch_ok or not pid_or_err then
        logger.warn("Syncest background progress pull: launch failed "
            .. tostring(pid_or_err))
        os.remove(result_file)
        if notify then self:_autoFailureNotify("progress") end
        return false
    end

    local pid = pid_or_err
    self._auto_pull_progress_running = true
    self._auto_pull_progress_pid = pid
    local polls = 0
    local poll
    poll = function()
        polls = polls + 1
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < AUTO_SYNC_MAX_POLLS then
                UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Syncest background progress pull: timed out")
            self._auto_pull_progress_running = false
            self._auto_pull_progress_pid = nil
            os.remove(result_file)
            if notify then self:_autoFailureNotify("progress") end
            return
        end

        self._auto_pull_progress_running = false
        self._auto_pull_progress_pid = nil
        local result, message = read_background_json_result(result_file)
        if not result or result.success ~= true then
            logger.warn("Syncest background progress pull: failed "
                .. tostring(result and result.message or message))
            if notify then self:_autoFailureNotify("progress") end
            return
        end

        logger.info("Syncest background progress pull: success")
        self:_syncConnectionRestored()
        if self:getBookIdentifiers() ~= book_hash then
            logger.warn("Syncest background progress pull: current book changed, skipping apply")
            return
        end
        self._suppress_auto_push_config_until =
            os.time() + AUTO_PUSH_SUPPRESS_AFTER_PULL
        if self.ui and self.ui.doc_settings then
            local doc_readest_sync =
                self.ui.doc_settings:readSetting("webdav_sync") or {}
            doc_readest_sync.last_synced_at_config = os.time()
            self.ui.doc_settings:saveSetting("webdav_sync", doc_readest_sync)
            self.ui.doc_settings:flush()
        end
        if notify then self:_autoNotify("progress", "pulled") end
        if result.config then
            SyncConfig:applyBookConfig(self.ui, result.config, force_apply == true)
        end
    end
    UIManager:scheduleIn(AUTO_SYNC_POLL_INTERVAL, poll)
    return true
end

function Syncest:_backgroundPushStats(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local settings = copy_settings(self.settings)
    local failure_fn = notify and function() self:_autoFailureNotify("stats") end or nil
    return self:_runBackgroundJSON("background stats push", "syncest_stats_push", function()
        local Stats = require("syncest_syncstats")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local cursor = settings.stats_push_cursor or 0
        local books, pages = Stats:collectSince(cursor)
        if #pages == 0 then
            return { success = true, empty = true }
        end
        local max_start = cursor
        for _, p in ipairs(pages) do
            if p.start_time > max_start then max_start = p.start_time end
        end
        local pushed = false
        local message = nil
        client:pushChanges({
            books = {},
            notes = {},
            configs = {},
            statBooks = books,
            statPages = pages,
        }, function(success, _body, status)
            pushed = success == true
            message = tostring(status or "")
        end)
        if not pushed then
            return { success = false, message = message }
        end
        return {
            success = true,
            stats_push_cursor = max_start,
            stats_last_pushed_at = os.time(),
        }
    end, function(result)
        if not result.empty then
            self.settings.stats_push_cursor = result.stats_push_cursor
            self.settings.stats_last_pushed_at = result.stats_last_pushed_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            if notify then self:_autoNotify("stats", "pushed") end
        end
    end, failure_fn)
end

function Syncest:_backgroundPullStats(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local settings = copy_settings(self.settings)
    local failure_fn = notify and function() self:_autoFailureNotify("stats") end or nil
    return self:_runBackgroundJSON("background stats pull", "syncest_stats_pull", function()
        local Stats = require("syncest_syncstats")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local since = settings.stats_pull_cursor or 0
        local pulled = false
        local message = nil
        local response_data = nil
        client:pullChanges({
            since = since,
            type = "stats",
            book = "",
            meta_hash = "",
        }, function(success, response, status)
            pulled = success == true
            response_data = response
            message = tostring(status or "")
        end)
        if not pulled then
            return { success = false, message = message }
        end
        local stat_books = response_data and response_data.statBooks or {}
        local stat_pages = response_data and response_data.statPages or {}
        Stats:applyRemote(stat_books, stat_pages)
        local newest = since
        for _, p in ipairs(stat_pages) do
            local u = tonumber(p.updated_at_ms) or 0
            if u > newest then newest = u end
        end
        return {
            success = true,
            stats_pull_cursor = newest,
            changed = newest > since,
            count = #stat_pages,
        }
    end, function(result)
        if result.changed then
            self.settings.stats_pull_cursor = result.stats_pull_cursor
            G_reader_settings:saveSetting("webdav_sync", self.settings)
        end
        if notify and (tonumber(result.count) or 0) > 0 then
            self:_autoNotify("stats", "pulled")
        end
    end, failure_fn)
end

function Syncest:_backgroundPushVocab(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("vocab") end or nil
    return self:_runBackgroundJSON("background vocab push", "syncest_vocab_push", function()
        local Vocab = require("syncest_syncvocab")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local words = Vocab:getWords()
        if #words == 0 then
            return { success = true, empty = true }
        end
        local pushed = false
        local message = nil
        client:pushChanges({ vocab = words }, function(success, _response, status)
            pushed = success == true
            message = tostring(status or "")
        end)
        if not pushed then
            return { success = false, message = message }
        end
        return { success = true, vocab_last_pushed_at = os.time() }
    end, function(result)
        if not result.empty then
            self.settings.vocab_last_pushed_at = result.vocab_last_pushed_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            if notify then self:_autoNotify("vocab", "pushed") end
        end
    end, failure_fn)
end

function Syncest:_backgroundPullVocab(notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("vocab") end or nil
    return self:_runBackgroundJSON("background vocab pull", "syncest_vocab_pull", function()
        local Vocab = require("syncest_syncvocab")
        local Client = require("webdav_syncclient")
        local client = Client:new{ server = server }
        local pulled = false
        local response_data = nil
        local message = nil
        client:pullChanges({ type = "vocab" }, function(success, response, status)
            pulled = success == true
            response_data = response
            message = tostring(status or "")
        end)
        if not pulled then
            return { success = false, message = message }
        end
        local words = response_data and response_data.words or {}
        local added = Vocab:applyWords(words)
        return {
            success = true,
            added = added,
            vocab_last_pulled_at = os.time(),
        }
    end, function(result)
        self.settings.vocab_last_pulled_at = result.vocab_last_pulled_at
        G_reader_settings:saveSetting("webdav_sync", self.settings)
        if notify and (tonumber(result.added) or 0) > 0 then
            self:_autoNotify("vocab", "pulled")
        end
    end, failure_fn)
end

function Syncest:_backgroundPushAnnotations(payload, notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" then return false end
    local failure_fn = notify and function() self:_autoFailureNotify("annotations") end or nil
    return self:_runBackgroundJSON(
        "background annotations push",
        "syncest_annotations_push",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pushed = false
            local message = nil
            client:pushChanges(payload, function(success, _response, status)
                pushed = success == true
                message = tostring(status or "")
            end)
            if not pushed then
                return { success = false, message = message }
            end
            return {
                success = true,
                last_notes_sync_at = os.time() * 1000,
                last_pushed_at_notes = os.time(),
            }
        end,
        function(result)
            self.settings.last_notes_sync_at = result.last_notes_sync_at
            G_reader_settings:saveSetting("webdav_sync", self.settings)
            if self.ui and self.ui.doc_settings then
                local synced = self.ui.doc_settings:readSetting("webdav_sync") or {}
                synced.last_pushed_at_notes = result.last_pushed_at_notes
                synced.deleted_notes = nil
                self.ui.doc_settings:saveSetting("webdav_sync", synced)
                self.ui.doc_settings:flush()
            end
            if notify then self:_autoNotify("annotations", "pushed") end
        end,
        failure_fn)
end

function Syncest:_backgroundPullAnnotations(book_hash, full_sync, notify)
    local server = self.settings and self.settings.sync_server
    if type(server) ~= "table" or not book_hash then return false end
    local since = full_sync and 0 or (self.settings.last_notes_sync_at or 0)
    local failure_fn = notify and function() self:_autoFailureNotify("annotations") end or nil
    return self:_runBackgroundJSON(
        "background annotations pull",
        "syncest_annotations_pull",
        function()
            local Client = require("webdav_syncclient")
            local client = Client:new{ server = server }
            local pulled = false
            local response_data = nil
            local message = nil
            client:pullChanges({
                since = since,
                type = "notes",
                book = book_hash,
            }, function(success, response, status)
                pulled = success == true
                response_data = response
                message = tostring(status or "")
            end)
            if not pulled then
                return { success = false, message = message }
            end
            return {
                success = true,
                notes = response_data and response_data.notes or {},
            }
        end,
        function(result)
            if self:getBookIdentifiers() ~= book_hash then
                logger.warn("Syncest background annotations pull: current book changed, skipping apply")
                return
            end
            if self.ui and self.ui.document and self.ui.document.info
                    and self.ui.document.info.has_pages then
                logger.warn("Syncest background annotations pull: paged document, skipping apply")
                return
            end
            local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
            SyncAnnotations:applyPulledNotes(
                self.ui, self.settings, result.notes, book_hash, self.dialog, notify_fn)
        end,
        failure_fn)
end

function Syncest:pushBookConfigAsync(notify)
    logger.info("Syncest pushBookConfigAsync: notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookConfigAsync(notify) end) then
        return
    end
    local config = SyncConfig:getCurrentBookConfig(self.ui)
    if not config then return end
    local launched = self:_backgroundPushProgress({
        books = {},
        notes = {},
        configs = { config },
    }, notify)
    if launched then
        self.last_sync_timestamp = os.time()
        if self.settings.mirror_to_kosync and self.ui.kosync then
            pcall(function() self.ui.kosync:updateProgress(true, false) end)
        end
    end
end

function Syncest:pullBookConfigAsync(notify, force_apply)
    logger.info("Syncest pullBookConfigAsync: notify=" .. tostring(notify)
        .. " force_apply=" .. tostring(force_apply))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfigAsync(notify, force_apply) end) then
        return
    end
    self._suppress_auto_push_config_until =
        os.time() + AUTO_PUSH_SUPPRESS_AFTER_PULL
    logger.info("Syncest pullBookConfigAsync: suppressing auto push until "
        .. tostring(self._suppress_auto_push_config_until))
    self:_backgroundPullProgress(book_hash, notify, force_apply)
end

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

function Syncest:_autoFailureNotify(_label)
    if self._syncest_connection_state == false then return end
    self._syncest_connection_state = false
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
    end
    self._failure_notify_task = function()
        UIManager:show(Notification:new{
            text = _("Syncest disconnected"),
            timeout = 3,
        })
        self._failure_notify_task = nil
    end
    UIManager:scheduleIn(0.2, self._failure_notify_task)
end

function Syncest:_syncConnectionRestored()
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
        self._failure_notify_task = nil
    end
    if self._syncest_connection_state ~= false then
        self._syncest_connection_state = true
        return
    end
    self._syncest_connection_state = true
    UIManager:show(Notification:new{
        text = _("Syncest connected"),
        timeout = 2,
    })
end

function Syncest:init()
    self.last_sync_timestamp = 0
    self._last_pushed_page = nil
    self.settings = G_reader_settings:readSetting("webdav_sync", self.default_settings)
    if SYNC_PLUGIN_INERT_DIAGNOSTIC then
        logger.warn("Syncest init: inert diagnostic mode enabled; no menus, hooks, or WebDAV")
        return
    end

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
        if STARTUP_AUTO_PULL_PROGRESS_ENABLED
                and self.settings.auto_pull_progress ~= false then
            UIManager:scheduleIn(0.5, function()
                self:_runSafely("auto pull progress", function()
                    self:pullBookConfig(false, true)
                end)
            end)
        else
            logger.warn("Syncest onReaderReady: startup auto progress pull disabled")
        end
        if self.settings.auto_pull_annotations ~= false then
            UIManager:scheduleIn(4, function()
                self:_runSafely("auto pull annotations", function()
                    self:pullBookNotes(false, false, true)
                end)
            end)
        end
        if self.settings.auto_pull_stats ~= false then
            UIManager:scheduleIn(8, function()
                self:_runSafely("auto pull stats", function()
                    self:pullBookStats(false, true)
                end)
            end)
        end
        if self.settings.auto_pull_vocab ~= false then
            UIManager:scheduleIn(16, function()
                self:_runSafely("auto pull vocab", function()
                    self:pullVocab(false, true)
                end)
            end)
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
            -- ── Push/Pull All ───────────────────────────────────────
            {
                text = _("Sync all"),
                enabled_func = function() return false end,
            },
            {
                text = _("Push all now"),
                enabled_func = function() return configured end,
                callback = function() self:pushAll(true) end,
            },
            {
                text = _("Pull all now"),
                enabled_func = function() return configured end,
                callback = function() self:pullAll(true) end,
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
    local server = self.settings.sync_server or {}
    local key = table.concat({
        tostring(server.address or ""),
        tostring(server.url or ""),
        tostring(server.username or ""),
    }, "|")
    if not self._sync_client or self._sync_client_key ~= key then
        self._sync_client = WebDavAuth:getClient(self.settings)
        self._sync_client_key = key
    end
    return self._sync_client
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
    logger.info("Syncest pushBookConfig: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    local now = os.time()
    if not interactive and self._suppress_auto_push_config_until
            and now < self._suppress_auto_push_config_until then
        logger.info("Syncest pushBookConfig: suppressed after pull until "
            .. tostring(self._suppress_auto_push_config_until))
        return
    end
    if not interactive and now - self.last_sync_timestamp <= API_CALL_DEBOUNCE_DELAY then
        return
    end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookConfig(interactive) end) then
        return
    end
    if not interactive then
        self:pushBookConfigAsync(notify)
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
    logger.info("Syncest pullBookConfig: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookConfig(interactive, notify) end) then
        return
    end
    if not interactive then
        self:pullBookConfigAsync(notify, false)
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
    logger.info("Syncest pushBookStats: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushBookStats(interactive) end) then
        return
    end
    if not interactive then
        self:_backgroundPushStats(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullBookStats(interactive, notify)
    logger.info("Syncest pullBookStats: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookStats(interactive) end) then
        return
    end
    if not interactive then
        self:_backgroundPullStats(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncStats:pull(self.settings, client, interactive, function() end, notify_fn)
end

-- ── Vocab sync ─────────────────────────────────────────────────────

function Syncest:pushVocab(interactive, notify)
    logger.info("Syncest pushVocab: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pushVocab(interactive) end) then
        return
    end
    if not interactive then
        self:_backgroundPushVocab(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:push(self.settings, client, interactive, notify_fn)
end

function Syncest:pullVocab(interactive, notify)
    logger.info("Syncest pullVocab: interactive=" .. tostring(interactive)
        .. " notify=" .. tostring(notify))
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullVocab(interactive, notify) end) then
        return
    end
    if not interactive then
        self:_backgroundPullVocab(notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncVocab:pull(self.settings, client, interactive, notify_fn)
end

-- ── Annotation sync ────────────────────────────────────────────────

function Syncest:pushBookNotes(interactive, full_sync, notify)
    logger.info("Syncest pushBookNotes: interactive=" .. tostring(interactive)
        .. " full_sync=" .. tostring(full_sync) .. " notify=" .. tostring(notify))
    if interactive and NetworkMgr:willRerunWhenOnline(
            function() self:pushBookNotes(interactive, full_sync) end) then
        return
    end
    if not interactive then
        local book_hash = self:getBookIdentifiers()
        if not book_hash then return end
        local annotations =
            SyncAnnotations:getAnnotations(self.ui, self.settings, book_hash, full_sync)
        local doc_readest_sync = self.ui.doc_settings:readSetting("webdav_sync") or {}
        for _, t in ipairs(doc_readest_sync.deleted_notes or {}) do
            t.bookHash = book_hash
            annotations[#annotations + 1] = t
        end
        if #annotations == 0 then return end
        self:_backgroundPushAnnotations({
            books = {},
            notes = annotations,
            configs = {},
        }, notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncAnnotations:push(self.ui, self.settings, client, interactive, full_sync, notify_fn)
end

function Syncest:pullBookNotes(interactive, full_sync, notify)
    logger.info("Syncest pullBookNotes: interactive=" .. tostring(interactive)
        .. " full_sync=" .. tostring(full_sync) .. " notify=" .. tostring(notify))
    local book_hash = self:getBookIdentifiers()
    if not book_hash then return end
    if NetworkMgr:willRerunWhenOnline(
            function() self:pullBookNotes(interactive, full_sync, notify) end) then
        return
    end
    if not interactive then
        if self.ui and self.ui.document and self.ui.document.info
                and self.ui.document.info.has_pages then
            logger.warn("Syncest pullBookNotes: auto pull skipped for paged document")
            return
        end
        self:_backgroundPullAnnotations(book_hash, full_sync, notify)
        return
    end
    local client = self:ensureClient(interactive)
    if not client then return end
    local notify_fn = notify and function(l, a) self:_autoNotify(l, a) end or nil
    SyncAnnotations:pull(self.ui, self.settings, client, book_hash,
        self.dialog, interactive, full_sync, notify_fn)
end

function Syncest:pushAll(interactive)
    self:_runSafely("push all", function()
        local in_book = self.ui and self.ui.document
        if in_book then
            self:pushBookConfigAsync(true)
            self:pushBookNotes(false, true, true)
        end
        self:pushBookStats(false, true)
        self:pushVocab(false, true)
        self:syncBooksLibrary("push", interactive)
    end, interactive)
end

function Syncest:pullAll(interactive)
    self:_runSafely("pull all", function()
        local in_book = self.ui and self.ui.document
        if in_book then
            self:pullBookConfigAsync(true, true)
            self:pullBookNotes(false, false, true)
        end
        self:pullBookStats(false, true)
        self:pullVocab(false, true)
        self:syncBooksLibrary("pull", interactive)
    end, interactive)
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

function Syncest:onSyncestPushProgress()
    self:_runSafely("manual push progress", function() self:pushBookConfigAsync(true) end, true)
end
function Syncest:onSyncestPullProgress()
    self:_runSafely("manual pull progress", function() self:pullBookConfigAsync(true, true) end, true)
end
function Syncest:onSyncestPushAnnotations()
    self:_runSafely("manual push annotations", function() self:pushBookNotes(true, true, true) end, true)
end
function Syncest:onSyncestPullAnnotations()
    self:_runSafely("manual pull annotations", function() self:pullBookNotes(true, false, true) end, true)
end
function Syncest:onSyncestOpenLibrary()
    self:_runSafely("open library", function() self:openLibrary() end, true)
end
function Syncest:onSyncestPushBooks()
    self:_runSafely("manual push books", function() self:syncBooksLibrary("push", true) end, true)
end
function Syncest:onSyncestPullBooks()
    self:_runSafely("manual pull books", function() self:syncBooksLibrary("pull", true) end, true)
end

function Syncest:onCloseDocument()
    if self.settings.auto_sync and not WebDavAuth:needsSetup(self.settings) then
        if not AUTO_PUSH_WEBDAV_ENABLED then
            logger.warn("Syncest onCloseDocument: auto-push WebDAV sync skipped")
            return
        end
        pcall(function()
            if self.settings.auto_push_progress ~= false then
                self:pushBookConfig(false, true)
            end
            if self.settings.auto_push_stats ~= false then
                self:pushBookStats(false, true)
            end
            if self.settings.auto_push_vocab ~= false and self._vocab_dirty then
                self._vocab_dirty = false
                self:pushVocab(false, true)
            end
            if self.settings.auto_push_annotations ~= false then
                self:pushBookNotes(false, false, true)
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
        self._vocab_dirty = false
        self:pushVocab(false, true)
    end
    UIManager:scheduleIn(2, self._vocab_push_task)
end

function Syncest:onPageUpdate(page)
    if not self.settings.auto_sync or WebDavAuth:needsSetup(self.settings) or not page then
        return
    end
    if not AUTO_PUSH_WEBDAV_ENABLED then
        logger.warn("Syncest onPageUpdate: auto progress push skipped")
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
        if self._annotations_push_task then
            UIManager:unschedule(self._annotations_push_task)
        end
        self._annotations_push_task = function()
            self._annotations_push_task = nil
            self:pushBookNotes(false, false, true)
        end
        UIManager:scheduleIn(1, self._annotations_push_task)
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
    if self._annotations_push_task then
        UIManager:unschedule(self._annotations_push_task)
        self._annotations_push_task = nil
    end
    if self._failure_notify_task then
        UIManager:unschedule(self._failure_notify_task)
        self._failure_notify_task = nil
    end
end

function Syncest:deletePluginSettings()
    G_reader_settings:delSetting("webdav_sync")
    self.settings = self.default_settings
    return true
end

require("syncest_insert_menu")

return Syncest
