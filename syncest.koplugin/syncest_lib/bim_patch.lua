-- bim_patch.lua
-- Two global monkey-patches that make our cloud-only / group entries
-- coexist with KOReader's coverbrowser pipeline:
--
--   1. BookInfoManager:getBookInfo — intercepts readest-cloud:// and
--      readest-group:// URIs. Without this, MosaicMenuItem's
--      "info incomplete → schedule background extraction" path fires;
--      BIM forks a subprocess that crashes at bookinfomanager.lua:492
--      trying to lfs.attributes the synthetic URI.
--
--   2. ListMenuItem:update + paintTo — list-mode group rows use a
--      custom widget tree (4-cell cover strip), and book rows get a
--      cloud-up/cloud-down icon overlay below the format text.
--
-- ListMenuItem is `local` to coverbrowser/listmenu.lua, so we reach
-- it via debug.getupvalue on the exported _updateItemsBuildUI mixin.

local logger = require("logger")
local cloud_covers = require("syncest_lib.cloud_covers")
local group_covers = require("syncest_lib.group_covers")
local cloud_icons  = require("syncest_lib.cloud_icons")
local list_strip   = require("syncest_lib.list_strip")

local M = {}

local _bim_patched = false
local _list_item_patched = false
local _mosaic_archive_patched = false
local _orig_get_book_info = nil  -- captured pre-patch; needed by list_strip

-- Tracks file_paths that came from our LibraryStore (= entries we
-- render in the Library widget). The BIM patch tags returned info
-- with _no_provider so ListMenuItem.update renders mandatory verbatim
-- (the format string), keeping right-side text right-aligned with
-- cloud rows that already use _no_provider.
local _library_local_paths = {}

-- Sentinel used by entry_from_row to flag cloud-only rows. Re-exported
-- here so the patches can read it without a circular libraryitem import.
M.CLOUD_ONLY_FLAG = "_readest_cloud_only"
M.LOCAL_ONLY_FLAG = "_readest_local_only"
M.ARCHIVED_FLAG   = "_readest_archived"

function M.register_local_path(path)
    _library_local_paths[path] = true
end

function M.orig_get_book_info()
    return _orig_get_book_info
end

-- Patch BIM:getBookInfo with a router that dispatches on URI prefix.
-- Idempotent.
local function patch_bim(opts)
    if _bim_patched then return end
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM then
        logger.warn("ReadestLibrary bim_patch: bookinfomanager not available")
        return
    end
    _bim_patched = true
    _orig_get_book_info = BIM.getBookInfo

    local function build_cloud_info(filepath, do_cover_image)
        local hash = cloud_covers.hash_from_uri(filepath)
        local meta = cloud_covers.get_meta(hash)
        local info = {
            has_meta      = true,
            cover_fetched = true,
            ignore_cover  = false,
            title         = meta.title,
            authors       = meta.author,
            has_cover     = false,
            -- Render mandatory verbatim (no "<filetype>  size" prefix).
            _no_provider  = true,
        }
        if do_cover_image then
            local settings = M._opts and M._opts.settings or {}
            local variant = settings.library_view_mode == "list" and "list" or "grid"
            local bb = cloud_covers.load_cover_bb(hash, variant)
            if bb then
                local w, h = bb:getWidth(), bb:getHeight()
                info.cover_bb      = bb
                info.cover_w       = w
                info.cover_h       = h
                -- BookInfoManager.isCachedCoverInvalid (bookinfomanager.lua:1017)
                -- crashes if cover_sizetag is nil. Format is "<w>x<h>".
                info.cover_sizetag = w .. "x" .. h
                info.has_cover     = true
            else
                -- Lazy fetch: only currently-visible cells trigger.
                cloud_covers.trigger_download(hash)
            end
        end
        return info
    end

    local function build_group_info(filepath, do_cover_image)
        local group_by, value, shape = group_covers.parse_uri(filepath)
        local meta = cloud_covers.get_meta(filepath)
        local info = {
            has_meta      = true,
            cover_fetched = true,
            ignore_cover  = false,
            title         = meta.title,
            authors       = meta.author,
            has_cover     = false,
            _no_provider  = true,
        }
        if do_cover_image and group_by and value then
            local LibraryWidget = package.loaded["syncest_lib.librarywidget"]
            local store = LibraryWidget and LibraryWidget._store
            local settings = M._opts and M._opts.settings or {}
            local bb = group_covers.serve_or_compose(
                group_by, value, shape,
                store, settings, _orig_get_book_info, BIM)
            if bb then
                local w, h = bb:getWidth(), bb:getHeight()
                info.cover_bb      = bb
                info.cover_w       = w
                info.cover_h       = h
                info.cover_sizetag = w .. "x" .. h
                info.has_cover     = true
            end
        end
        return info
    end

    function BIM:getBookInfo(filepath, do_cover_image)
        if type(filepath) == "string" then
            if filepath:sub(1, #cloud_covers.URI_PREFIX) == cloud_covers.URI_PREFIX then
                return build_cloud_info(filepath, do_cover_image)
            end
            if filepath:sub(1, #group_covers.URI_PREFIX) == group_covers.URI_PREFIX then
                return build_group_info(filepath, do_cover_image)
            end
        end
        -- Real local file: forward to the original BIM, then add
        -- _no_provider for paths that came from our LibraryStore so
        -- the right-side text right-aligns with cloud rows. Shallow
        -- copy first so we don't mutate BIM's cached entry.
        local result = _orig_get_book_info(self, filepath, do_cover_image)
        if result and type(filepath) == "string" and _library_local_paths[filepath] then
            local copy = {}
            for k, v in pairs(result) do copy[k] = v end
            copy._no_provider = true
            return copy
        end
        return result
    end
end

-- Locate listmenu's local ListMenuItem class via its captured upvalue
-- on the exported _updateItemsBuildUI mixin. Cheapest path that
-- doesn't require modifying coverbrowser.koplugin or copy-pasting the
-- ~50-line build loop.
local function patch_list_menu_item()
    if _list_item_patched then return end
    local debug = require("debug")
    local ok, ListMenu = pcall(require, "listmenu")
    if not ok or type(ListMenu._updateItemsBuildUI) ~= "function" then return end
    local ListMenuItem
    for i = 1, 50 do
        local name, val = debug.getupvalue(ListMenu._updateItemsBuildUI, i)
        if not name then break end
        if name == "ListMenuItem" and type(val) == "table" then
            ListMenuItem = val
            break
        end
    end
    if not ListMenuItem or type(ListMenuItem.update) ~= "function" then
        logger.warn("ReadestLibrary: couldn't locate ListMenuItem class for patching")
        return
    end

    -- Custom group-row widget tree (wider cover strip).
    local orig_update = ListMenuItem.update
    function ListMenuItem:update()
        if self.entry and self.entry._readest_group then
            local LibraryWidget = package.loaded["syncest_lib.librarywidget"]
            return list_strip.build(self, {
                store              = LibraryWidget and LibraryWidget._store,
                settings           = M._opts and M._opts.settings,
                orig_getBookInfo   = _orig_get_book_info,
            })
        end
        if self._readest_cloud_cover then
            self._readest_cloud_cover:free()
            self._readest_cloud_cover = nil
        end
        local result = orig_update(self)
        -- ListMenu may reject a perfectly valid synthetic cloud cover during
        -- its cached-cover validation and replace it with a FakeCover. Keep
        -- that stock layout for metadata, then paint our validated persistent
        -- thumbnail directly into the reserved square cover slot.
        if self.entry and self.entry[M.CLOUD_ONLY_FLAG]
                and type(self.entry.file) == "string" then
            local hash = cloud_covers.hash_from_uri(self.entry.file)
            local cover_bb = hash and cloud_covers.load_cover_bb(hash, "list")
            if cover_bb then
                local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
                if ok_iw then
                    local slot = math.max(1, self.height - 2)
                    local scale = math.min(
                        slot / cover_bb:getWidth(),
                        slot / cover_bb:getHeight())
                    self._readest_cloud_cover = ImageWidget:new{
                        image = cover_bb,
                        scale_factor = scale,
                    }
                    self._readest_cloud_cover:_render()
                else
                    cover_bb:free()
                end
            end
        end
        return result
    end

    -- Cloud icon overlay painted on top of the standard widget tree.
    --   cloud-only (cloud_present=1, local_present=0) → download icon
    --   local-only (cloud_present=0, local_present=1) → upload icon
    local orig_paint = ListMenuItem.paintTo
    function ListMenuItem:paintTo(bb, x, y)
        orig_paint(self, bb, x, y)
        if not self.entry then return end
        if self._readest_cloud_cover then
            local size = self._readest_cloud_cover:getSize()
            self._readest_cloud_cover:paintTo(
                bb,
                x + math.floor((self.height - size.w) / 2),
                y + math.floor((self.height - size.h) / 2))
        end
        if self.entry[M.CLOUD_ONLY_FLAG] and cloud_icons.has_icon("dl") then
            cloud_icons.paint(self, bb, x, y, "dl")
        elseif self.entry[M.LOCAL_ONLY_FLAG] and cloud_icons.has_icon("up") then
            cloud_icons.paint(self, bb, x, y, "up")
        end
    end
    local orig_free = ListMenuItem.free
    function ListMenuItem:free(...)
        if self._readest_cloud_cover then
            self._readest_cloud_cover:free()
            self._readest_cloud_cover = nil
        end
        if orig_free then return orig_free(self, ...) end
    end
    _list_item_patched = true
    logger.info("ReadestLibrary: patched ListMenuItem update + paintTo")
end

-- Add cloud-state icons and the archived banner after the active mosaic cover
-- renderer, so both overlays work with stock KOReader, Zen UI, and other
-- cover-browser patches alike.
local function patch_mosaic_archive_banner()
    if _mosaic_archive_patched then return end
    local debug = require("debug")
    local ok_menu, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_menu or type(MosaicMenu._updateItemsBuildUI) ~= "function" then
        return
    end
    -- Zen UI replaces stock book tiles with its own class. Prefer that
    -- explicitly exported class; the builder's MosaicMenuItem upvalue is
    -- retained only for folder tiles and never paints Syncest book entries.
    local MosaicMenuItem = MosaicMenu._zen_mosaic_item_class
    if not MosaicMenuItem then
        for i = 1, 50 do
            local name, val = debug.getupvalue(MosaicMenu._updateItemsBuildUI, i)
            if not name then break end
            if name == "MosaicMenuItem" and type(val) == "table" then
                MosaicMenuItem = val
                break
            end
        end
    end
    if not MosaicMenuItem or type(MosaicMenuItem.paintTo) ~= "function" then
        logger.warn("ReadestLibrary: couldn't locate MosaicMenuItem for archive banner")
        return
    end

    local Blitbuffer = require("ffi/blitbuffer")
    local CornerBanner = require("syncest_lib.corner_banner")
    local _ = require("gettext")
    local orig_update = MosaicMenuItem.update
    if orig_update then
        function MosaicMenuItem:update(...)
            local result = orig_update(self, ...)
            if self.entry and self.entry._zen_effective_status then
                self._zen_effective_status = self.entry._zen_effective_status
            end
            return result
        end
    end
    local orig_paint = MosaicMenuItem.paintTo
    function MosaicMenuItem:paintTo(bb, x, y)
        -- Zen UI reserves a title strip below the cover but the stock
        -- CenterContainer vertically centers shorter covers in the remaining
        -- area. Bottom-align Syncest covers in that area so aspect-ratio
        -- differences don't create a large, variable cover-to-title gap.
        local cover_container = self.menu
            and self.menu.name == "readest_library"
            and self._underline_container
            and self._underline_container[1]
        local center_paint = cover_container and cover_container.paintTo
        if center_paint and cover_container.dimen and cover_container[1]
                and cover_container[1].getSize then
            cover_container.paintTo = function(container, target_bb, cx, cy)
                local child_size = container[1]:getSize()
                local spare = math.max(0,
                    (container.dimen.h or 0) - (child_size.h or 0))
                return center_paint(
                    container, target_bb, cx, cy + math.floor(spare / 2))
            end
        end
        orig_paint(self, bb, x, y)
        if center_paint then cover_container.paintTo = center_paint end
        if not self.entry then return end
        local target = self._zen_cover_frame or self._cover_frame
            or (self[1] and self[1][1] and self[1][1][1])
        if not (target and target.dimen and target.dimen.w
                and target.dimen.h and target.dimen.y) then
            return
        end
        local border = target.bordersize or 0
        local cover_left = x + math.floor((self.width - target.dimen.w) / 2)
        local icon_kind
        if self.entry[M.CLOUD_ONLY_FLAG] then
            icon_kind = "dl"
        elseif self.entry[M.LOCAL_ONLY_FLAG] then
            icon_kind = "up"
        end
        if icon_kind and cloud_icons.has_icon(icon_kind) then
            local icon_size = math.max(8, math.floor(target.dimen.w * 0.20))
            local icon_pad = math.max(2, math.floor(target.dimen.w * 0.04))
            cloud_icons.paint_at(
                bb,
                cover_left + target.dimen.w - icon_pad - icon_size,
                target.dimen.y + target.dimen.h - icon_pad - icon_size,
                icon_size, icon_kind)
        end
        if not self.entry[M.ARCHIVED_FLAG] then return end
        local eff_size = math.max(1, math.floor(target.dimen.w * 0.14))
        local span = math.floor(eff_size * 2.5)
        local band_thick = math.floor(span * 0.35)
        local font_size = math.max(6, math.floor(eff_size * 0.25))
        CornerBanner.paint(
            bb, cover_left, cover_left + target.dimen.w,
            target.dimen.y, target.dimen.h,
            span, band_thick, _("Archived"), font_size,
            Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE)
        if border > 0 then
            local color = target.bordercolor or Blitbuffer.COLOR_BLACK
            bb:paintRect(cover_left, target.dimen.y, target.dimen.w, border, color)
            bb:paintRect(
                cover_left + target.dimen.w - border,
                target.dimen.y, border, target.dimen.h, color)
        end
    end
    _mosaic_archive_patched = true
    logger.info("ReadestLibrary: patched MosaicMenuItem archive banner")
end

function M.install(opts)
    M._opts = opts or {}
    cloud_covers.set_opts(M._opts)
    logger.info("ReadestLibrary bim_patch.install: opts="
        .. (opts and "set" or "nil")
        .. " sync_auth=" .. tostring(opts and opts.sync_auth ~= nil)
        .. " bim_patched_before=" .. tostring(_bim_patched))
    -- Both patches are idempotent so the order + repeated calls are
    -- safe. ListMenuItem first since it doesn't need BIM.
    patch_list_menu_item()
    patch_mosaic_archive_banner()
    patch_bim()
end

return M
