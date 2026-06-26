local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local _ = require("syncest_i18n")

local SyncVocab = {}

local function db_path()
    return DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
end

function SyncVocab:getWords()
    local path = db_path()
    local f = io.open(path, "r")
    if not f then return {} end
    f:close()

    local ok, conn = pcall(SQ3.open, path)
    if not ok then return {} end

    local words = {}
    local ok2, stmt = pcall(function()
        return conn:prepare([[
            SELECT v.word, t.name, v.create_time, v.review_time, v.due_time,
                   v.review_count, v.streak_count, v.highlight, v.prev_context, v.next_context
            FROM vocabulary v
            LEFT JOIN title t ON v.title_id = t.id
        ]])
    end)
    if ok2 and stmt then
        local row = stmt:step()
        while row ~= nil do
            words[#words + 1] = {
                word         = row[1],
                title        = row[2],
                create_time  = tonumber(row[3]),
                review_time  = tonumber(row[4]),
                due_time     = tonumber(row[5]),
                review_count = tonumber(row[6]) or 0,
                streak_count = tonumber(row[7]) or 0,
                highlight    = row[8],
                prev_context = row[9],
                next_context = row[10],
            }
            row = stmt:step()
        end
        stmt:close()
    end
    conn:close()
    return words
end

function SyncVocab:applyWords(words)
    if not words or #words == 0 then return 0 end

    local ok, conn = pcall(SQ3.open, db_path())
    if not ok then return 0 end

    conn:exec([[
        CREATE TABLE IF NOT EXISTS "vocabulary" (
            "word" TEXT NOT NULL UNIQUE,
            "title_id" INTEGER,
            "create_time" INTEGER NOT NULL,
            "review_time" INTEGER,
            "due_time" INTEGER NOT NULL,
            "review_count" INTEGER NOT NULL DEFAULT 0,
            "prev_context" TEXT,
            "next_context" TEXT,
            "streak_count" INTEGER NOT NULL DEFAULT 0,
            "highlight" TEXT,
            PRIMARY KEY("word")
        );
        CREATE TABLE IF NOT EXISTS "title" (
            "id" INTEGER NOT NULL UNIQUE,
            "name" TEXT UNIQUE,
            "filter" INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY("id")
        );
        CREATE INDEX IF NOT EXISTS due_time_index ON vocabulary(due_time);
        CREATE INDEX IF NOT EXISTS title_name_index ON title(name);
    ]])

    conn:exec("BEGIN;")
    local added = 0

    local ok_prep, find_title, insert_title, last_rowid, find_word, insert_word, update_word
    ok_prep, find_title   = pcall(function() return conn:prepare("SELECT id FROM title WHERE name = ?") end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end
    ok_prep, insert_title = pcall(function() return conn:prepare("INSERT OR IGNORE INTO title (name, filter) VALUES (?, 1)") end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end
    ok_prep, last_rowid   = pcall(function() return conn:prepare("SELECT last_insert_rowid()") end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end
    ok_prep, find_word    = pcall(function() return conn:prepare("SELECT review_count, streak_count FROM vocabulary WHERE word = ?") end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end
    ok_prep, insert_word  = pcall(function() return conn:prepare([[
        INSERT OR IGNORE INTO vocabulary
        (word, title_id, create_time, review_time, due_time, review_count, streak_count, highlight, prev_context, next_context)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]) end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end
    ok_prep, update_word  = pcall(function() return conn:prepare([[
        UPDATE vocabulary SET review_count = ?, streak_count = ?, review_time = ?, due_time = ?
        WHERE word = ?
    ]]) end)
    if not ok_prep then conn:exec("ROLLBACK;") conn:close() return 0 end

    for _, w in ipairs(words) do
        if not w.word then goto continue end

        local title_id = nil
        if w.title then
            local t_row = find_title:reset():bind(w.title):step()
            if t_row then
                title_id = tonumber(t_row[1])
            else
                insert_title:reset():bind(w.title):step()
                local r = last_rowid:reset():step()
                if r then title_id = tonumber(r[1]) end
            end
        end

        local existing = find_word:reset():bind(w.word):step()
        if not existing then
            insert_word:reset():bind(
                w.word, title_id,
                w.create_time or os.time(),
                w.review_time,
                w.due_time or os.time(),
                w.review_count or 0,
                w.streak_count or 0,
                w.highlight,
                w.prev_context,
                w.next_context
            ):step()
            added = added + 1
        else
            local local_rc = tonumber(existing[1]) or 0
            local local_sc = tonumber(existing[2]) or 0
            local remote_rc = w.review_count or 0
            local remote_sc = w.streak_count or 0
            if remote_rc > local_rc or (remote_rc == local_rc and remote_sc > local_sc) then
                update_word:reset():bind(remote_rc, remote_sc, w.review_time, w.due_time, w.word):step()
            end
        end

        ::continue::
    end

    find_title:close()
    insert_title:close()
    last_rowid:close()
    find_word:close()
    insert_word:close()
    update_word:close()

    conn:exec("COMMIT;")
    conn:close()
    return added
end

function SyncVocab:push(settings, client, interactive, notify_fn)
    local words = self:getWords()
    logger.dbg("SyncVocab push: " .. #words .. " words")
    if #words == 0 and not interactive then return end

    client:pushChanges(
        { vocab = words },
        function(success, _response)
            if success then
                settings.vocab_last_pushed_at = os.time()
                G_reader_settings:saveSetting("webdav_sync", settings)
                if notify_fn then notify_fn("vocab", "pushed") end
            end
        end
    )
end

function SyncVocab:pull(settings, client, interactive, notify_fn)
    client:pullChanges(
        { type = "vocab" },
        function(success, response, _status)
            if not success then return end
            local words = response and response.words
            if not words or #words == 0 then return end
            self:applyWords(words)
            settings.vocab_last_pulled_at = os.time()
            G_reader_settings:saveSetting("webdav_sync", settings)
            if notify_fn then notify_fn("vocab", "pulled") end
        end
    )
end

return SyncVocab
