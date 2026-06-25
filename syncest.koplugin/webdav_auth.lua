local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local WebDavAuth = {}

function WebDavAuth:needsSetup(settings)
    return not settings.webdav_address or settings.webdav_address == ""
end

function WebDavAuth:getUserId(settings)
    if not settings.webdav_address then return nil end
    return (settings.webdav_username or "") .. "@" .. settings.webdav_address
end

function WebDavAuth:getClient(settings)
    if self:needsSetup(settings) then return nil end
    local WebDavSyncClient = require("webdav_syncclient")
    return WebDavSyncClient:new{
        address   = settings.webdav_address,
        username  = settings.webdav_username or "",
        password  = settings.webdav_password or "",
        base_path = settings.webdav_base_path or "koreader-sync",
    }
end

-- Returns the list of WebDAV accounts from KOReader's cloud storage settings.
function WebDavAuth:getWebDavAccounts()
    local LuaSettings  = require("luasettings")
    local DataStorage  = require("datastorage")
    local cs = LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua")
                          :readSetting("cs_servers") or {}
    local accounts = {}
    for _, item in ipairs(cs) do
        if item.type == "webdav" then
            accounts[#accounts + 1] = item
        end
    end
    return accounts
end

function WebDavAuth:setup(settings, menu)
    local accounts = self:getWebDavAccounts()

    if #accounts == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No WebDAV accounts found. Please add a WebDAV account in Cloud Storage settings first."),
            timeout = 4,
        })
        return
    end

    if #accounts == 1 then
        self:_applyAccount(settings, accounts[1], menu)
        return
    end

    -- Multiple accounts: show a picker
    local buttons = {}
    for _, account in ipairs(accounts) do
        local a = account
        buttons[#buttons + 1] = {{
            text = a.name or a.address,
            callback = function()
                UIManager:close(self._dialog)
                self:_applyAccount(settings, a, menu)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(self._dialog) end,
    }}

    self._dialog = ButtonDialogTitle:new{
        title = _("Select WebDAV account for sync"),
        buttons = buttons,
    }
    UIManager:show(self._dialog)
end

function WebDavAuth:_applyAccount(settings, account, menu)
    settings.webdav_address  = account.address
    settings.webdav_username = account.username
    settings.webdav_password = account.password
    settings.webdav_base_path = "koreader-sync"
    settings.user_id   = self:getUserId(settings)
    settings.user_name = account.name or account.username
    G_reader_settings:saveSetting("webdav_sync", settings)
    if menu then menu:updateItems() end
    UIManager:show(InfoMessage:new{
        text = _("WebDAV sync configured: ") .. (account.name or account.address),
        timeout = 2,
    })
end

function WebDavAuth:disconnect(settings, menu)
    settings.webdav_address  = nil
    settings.webdav_username = nil
    settings.webdav_password = nil
    settings.user_id   = nil
    settings.user_name = nil
    G_reader_settings:saveSetting("webdav_sync", settings)
    if menu then menu:updateItems() end
    UIManager:show(InfoMessage:new{
        text = _("WebDAV sync disconnected"),
        timeout = 2,
    })
end

return WebDavAuth
