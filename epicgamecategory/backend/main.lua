local logger     = require("logger")
local millennium = require("millennium")
local json       = require("json")
local http       = require("http")
local ok_utils, utils = pcall(require, "utils")

local TOKEN_URL       = "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token"
local DEVICE_AUTH_URL = "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/deviceAuthorization"
local EXCHANGE_URL    = "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange"
local LIBRARY_URL     = "https://library-service.live.use1a.on.epicgames.com/library/api/public/items?includeMetadata=true"
-- Endpoint catalogue "bulk" inter-namespace : accepte des id bruts (sans
-- namespace) et en résout plusieurs d'un coup, ce qui permet de tout récupérer
-- en quelques requêtes au lieu d'une par jeu (sinon timeout RPC de Millennium).
local CATALOG_URL     = "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/bulk/items?country=US&locale=en-US&includeMainGameDetails=true"
local USER_AGENT      = "EpicGamesLauncher/14.0.8"

-- Client "launcher" (EpicGamesLauncher). C'est lui qui possède la permission
-- library:public:items READ. Les clients de jeu (switch/IOS/PC) ne l'ont pas,
-- d'où l'échange de token avant d'appeler la bibliothèque.
-- base64("34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf")
local LAUNCHER_CLIENT = "MzRhMDJjZjhmNDQxNGUyOWIxNTkyMTg3NmRhMzZmOWE6ZGFhZmJjY2M3Mzc3NDUwMzlkZmZlNTNkOTRmYzc2Y2Y="

-- Clients Epic à essayer dans l'ordre. Seuls certains supportent le flux
-- "device authorization" : fortniteNewSwitchGameClient est vérifié fonctionnel
-- (les autres renvoient unsupported_grant_type / client_disabled).
local CLIENTS = {
    "OThmN2U0MmMyZTNhNGY4NmE3NGViNDNmYmI0MWVkMzk6MGEyNDQ5YTItMDAxYS00NTFlLWFmZWMtM2U4MTI5MDFjNGQ3", -- fortniteNewSwitchGameClient
}

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Requête HTTP via le module natif de Millennium (libcurl), puis décodage JSON.
-- NB : os.execute/curl sont neutralisés dans le bac à sable du backend ; il faut
-- impérativement passer par `http`.
-- Epic renvoie son JSON d'erreur même sur un statut non-200, donc on parse
-- toujours le corps et on laisse l'appelant inspecter errorCode.
local function http_json(url, opts)
    local response, err = http.request(url, opts)
    if not response then return nil, err or "request failed" end
    local body = response.body or ""
    logger:info("HTTP " .. tostring(response.status) .. " -> " .. body:sub(1, 200))
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "parse: " .. body:sub(1, 80) end
    return data, nil
end

-- Étape 1 du flux device : token d'application (grant_type=client_credentials).
-- Ce Bearer est requis pour appeler /deviceAuthorization (l'auth Basic seule y
-- est refusée avec l'erreur 1032 authentication_failed).
local function get_client_token(auth)
    local data, err = http_json(TOKEN_URL, {
        method = "POST",
        headers = {
            ["Authorization"] = "Basic " .. auth,
            ["Content-Type"]  = "application/x-www-form-urlencoded",
            ["User-Agent"]    = USER_AGENT,
            ["Accept"]        = "application/json",
        },
        data = "grant_type=client_credentials",
        timeout = 30,
    })
    if not data then return nil, err end
    return data.access_token, data.errorCode
end

function EpicStartDeviceAuth()
    logger:info("EpicStartDeviceAuth - trying clients")

    for i, auth in ipairs(CLIENTS) do
        logger:info("Trying client " .. i)

        -- Étape 1 : obtenir un token Bearer d'application.
        local token, terr = get_client_token(auth)
        if not token then
            logger:info("Client " .. i .. " : échec client_credentials (" .. tostring(terr) .. ")")
        else
            -- Étape 2 : démarrer le flux device avec le token Bearer.
            local data, err = http_json(DEVICE_AUTH_URL, {
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token,
                    ["Content-Type"]  = "application/x-www-form-urlencoded",
                    ["User-Agent"]    = USER_AGENT,
                    ["Accept"]        = "application/json",
                },
                data = "prompt=login",
                timeout = 30,
            })
            if data and data.device_code then
                logger:info("Success with client " .. i)
                -- Mémoriser le client (auth Basic) pour le polling du token.
                millennium.config.set("working_client", auth)
                return json.encode(data)
            else
                logger:info("Client " .. i .. " failed: " .. tostring(err or (data and data.errorCode)))
            end
        end
    end

    return json.encode({ errorMessage = "Aucun client ne supporte device_auth" })
end

function EpicPollDeviceAuth(device_code)
    local auth = millennium.config.get("working_client") or CLIENTS[1]
    local data, err = http_json(TOKEN_URL, {
        method = "POST",
        headers = {
            ["Authorization"] = "Basic " .. auth,
            ["Content-Type"]  = "application/x-www-form-urlencoded",
            ["User-Agent"]    = USER_AGENT,
            ["Accept"]        = "application/json",
        },
        data = "grant_type=device_code&device_code=" .. urlencode(device_code),
        timeout = 30,
    })
    if not data then return json.encode({ errorMessage = err }) end
    -- Connexion persistante : on mémorise le refresh_token (Epic le fait tourner
    -- à chaque rafraîchissement, on stockera le nouveau dans EpicRefreshLogin).
    if data.access_token and data.refresh_token then
        millennium.config.set("refresh_token", data.refresh_token)
    end
    return json.encode(data)
end

-- Échange un token utilisateur (obtenu via le client switch) contre un token du
-- client launcher, qui possède la permission library:public:items READ.
-- Renvoie (launcher_token, err).
local function exchange_for_launcher_token(token)
    -- 1) Demander un code d'échange avec le token utilisateur courant.
    local ex, exerr = http_json(EXCHANGE_URL, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["User-Agent"]    = USER_AGENT,
            ["Accept"]        = "application/json",
        },
        timeout = 30,
    })
    if not ex or not ex.code then
        return nil, "exchange: " .. tostring(exerr or (ex and ex.errorMessage) or "no code")
    end

    -- 2) Échanger ce code contre un token launcher.
    local tok, tokerr = http_json(TOKEN_URL, {
        method = "POST",
        headers = {
            ["Authorization"] = "Basic " .. LAUNCHER_CLIENT,
            ["Content-Type"]  = "application/x-www-form-urlencoded",
            ["User-Agent"]    = USER_AGENT,
            ["Accept"]        = "application/json",
        },
        data = "grant_type=exchange_code&exchange_code=" .. urlencode(ex.code) .. "&token_type=eg1",
        timeout = 30,
    })
    if not tok or not tok.access_token then
        return nil, "exchange_token: " .. tostring(tokerr or (tok and tok.errorMessage) or "no token")
    end
    return tok.access_token, nil
end

-- Filtre "jeu de base", calqué sur la logique de Heroic / legendary
-- (storeManagers/legendary/library.ts). On écarte :
--   - les DLC (présence de mainGameItem),
--   - le contenu Unreal Engine (namespace "ue" ou catégories d'assets),
--   - les mods,
--   - les addons,
--   - les jeux uniquement mobiles (Android/iOS).
-- et on exige la catégorie "games".
local UE_CATS = { ["assets"] = true, ["asset-format"] = true, ["plugins"] = true, ["projects"] = true }

local function is_base_game(item)
    if item.mainGameItem then return false end          -- DLC
    if item.namespace == "ue" then return false end     -- contenu Unreal Engine

    local has_games = false
    for _, c in ipairs(item.categories or {}) do
        local p = c.path
        if UE_CATS[p] or p == "mods" or p == "addons" then return false end
        if p == "games" then has_games = true end
    end
    if not has_games then return false end

    -- Jeux disponibles uniquement sur Android/iOS (Epic Mobile Store) → exclus.
    local ri = item.releaseInfo
    if ri and #ri > 0 then
        local only_mobile = true
        for _, info in ipairs(ri) do
            local plats = info.platform
            if not plats then only_mobile = false break end
            for _, plat in ipairs(plats) do
                if plat ~= "Android" and plat ~= "iOS" then only_mobile = false break end
            end
            if not only_mobile then break end
        end
        if only_mobile then return false end
    end

    return true
end

-- Récupère les métadonnées catalogue (titre, catégories, artefact de lancement)
-- pour une liste d'ids (tous namespaces confondus), par lots de CHUNK.
local function fetch_catalog(lib_token, ids)
    local out = {}
    local CHUNK = 50
    for start = 1, #ids, CHUNK do
        local query = CATALOG_URL
        for j = start, math.min(start + CHUNK - 1, #ids) do
            query = query .. "&id=" .. urlencode(ids[j])
        end
        local data = http_json(query, {
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. lib_token,
                ["User-Agent"]    = USER_AGENT,
                ["Accept"]        = "application/json",
            },
            timeout = 30,
        })
        if type(data) == "table" then
            for id, item in pairs(data) do
                if type(item) == "table" then out[id] = item end
            end
        end
    end
    return out
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Détecte une installation de Heroic Games Launcher.
-- Renvoie { exe, dir, flatpak } ou nil.
local function detect_heroic()
    local is_windows = package.config:sub(1, 1) == "\\"
    if is_windows then
        local localappdata = os.getenv("LOCALAPPDATA") or ""
        local progfiles   = os.getenv("PROGRAMFILES") or "C:\\Program Files"
        local progfiles86 = os.getenv("PROGRAMFILES(X86)") or "C:\\Program Files (x86)"
        local win_paths = {
            localappdata .. "\\Programs\\heroic\\Heroic.exe",
            progfiles    .. "\\Heroic\\Heroic.exe",
            progfiles86  .. "\\Heroic\\Heroic.exe",
        }
        for _, p in ipairs(win_paths) do
            if file_exists(p) then
                local dir = p:match("^(.*)\\[^\\]*$") or ""
                return { exe = p, dir = dir, flatpak = false }
            end
        end
        return nil
    end
    local home = os.getenv("HOME") or ""
    -- Flatpak
    local flatpaks = {
        home .. "/.local/share/flatpak/exports/bin/com.heroicgameslauncher.hgl",
        "/var/lib/flatpak/exports/bin/com.heroicgameslauncher.hgl",
    }
    for _, p in ipairs(flatpaks) do
        if file_exists(p) then return { exe = "flatpak", dir = home, flatpak = true } end
    end
    -- Installation native
    local natives = {
        "/usr/bin/heroic",
        "/opt/Heroic/heroic",
        "/usr/local/bin/heroic",
        home .. "/.local/bin/heroic",
        home .. "/Applications/heroic",
    }
    for _, p in ipairs(natives) do
        if file_exists(p) then
            return { exe = p, dir = (p:match("^(.*)/[^/]*$") or ""), flatpak = false }
        end
    end
    return nil
end

function EpicGetLibrary(token)
    local lib_token, err = exchange_for_launcher_token(token)
    if not lib_token then return json.encode({ errorMessage = err }) end

    -- 1) Récupérer toute la bibliothèque, en suivant la pagination par cursor.
    --    On déduplique par catalogItemId et on retient namespace + appName.
    local seen, items, ids = {}, {}, {}
    local url = LIBRARY_URL
    while url do
        local data, derr = http_json(url, {
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. lib_token,
                ["User-Agent"]    = USER_AGENT,
                ["Accept"]        = "application/json",
            },
            timeout = 30,
        })
        if not data then return json.encode({ errorMessage = derr }) end
        if data.errorCode then return json.encode(data) end
        for _, rec in ipairs(data.records or {}) do
            local cid, ns = rec.catalogItemId, rec.namespace
            if cid and ns and not seen[cid] then
                seen[cid] = true
                items[cid] = { namespace = ns, catalogItemId = cid, appName = rec.appName }
                table.insert(ids, cid)
            end
        end
        local cursor = data.responseMetadata and data.responseMetadata.nextCursor
        if cursor and cursor ~= "" then
            url = LIBRARY_URL .. "&cursor=" .. urlencode(cursor)
        else
            url = nil
        end
    end

    -- 2) Enrichir via le catalogue (un appel par lot d'ids) et filtrer les jeux.
    local catalog = fetch_catalog(lib_token, ids)
    local games = {}
    for _, cid in ipairs(ids) do
        local meta = catalog[cid]
        if meta and is_base_game(meta) then
            local it = items[cid]
            -- appName de lancement : releaseInfo du catalogue en priorité,
            -- sinon l'appName de la bibliothèque.
            local app = it.appName
            if meta.releaseInfo and meta.releaseInfo[1] and meta.releaseInfo[1].appId then
                app = meta.releaseInfo[1].appId
            end
            -- Jaquettes Epic : DieselGameBoxTall (portrait → cover Steam),
            -- DieselGameBox (paysage → fond/large).
            local img_tall, img_wide, img_logo
            for _, ki in ipairs(meta.keyImages or {}) do
                if ki.type == "DieselGameBoxTall" then img_tall = ki.url
                elseif ki.type == "DieselGameBox" then img_wide = ki.url
                elseif ki.type == "DieselGameBoxLogo" then img_logo = ki.url end
            end
            table.insert(games, {
                namespace     = it.namespace,
                catalogItemId = cid,
                appName       = app,
                title         = meta.title or it.appName or cid,
                imgTall       = img_tall,
                imgWide       = img_wide,
                imgLogo       = img_logo,
            })
        end
    end

    table.sort(games, function(a, b) return (a.title or "") < (b.title or "") end)
    local heroic = detect_heroic()
    logger:info("Library: " .. #games .. " jeux (sur " .. #ids .. " items uniques)"
        .. " | Heroic: " .. tostring(heroic and heroic.exe or "non détecté"))
    return json.encode({ records = games, launcher = heroic })
end

-- Connexion persistante : rejoue le refresh_token stocké pour obtenir un nouvel
-- access_token sans redemander la connexion. Epic fait tourner le refresh_token
-- (usage unique), donc on stocke systématiquement le nouveau.
function EpicRefreshLogin()
    local rt = millennium.config.get("refresh_token")
    if not rt or rt == "" then return json.encode({ errorMessage = "no_session" }) end

    local auth = millennium.config.get("working_client") or CLIENTS[1]
    local data, err = http_json(TOKEN_URL, {
        method = "POST",
        headers = {
            ["Authorization"] = "Basic " .. auth,
            ["Content-Type"]  = "application/x-www-form-urlencoded",
            ["User-Agent"]    = USER_AGENT,
            ["Accept"]        = "application/json",
        },
        data = "grant_type=refresh_token&refresh_token=" .. urlencode(rt) .. "&token_type=eg1",
        timeout = 30,
    })
    if not data or not data.access_token then
        -- refresh_token invalide/expiré → on efface la session pour forcer une
        -- reconnexion propre.
        millennium.config.set("refresh_token", "")
        return json.encode({ errorMessage = (data and (data.errorMessage or data.errorCode)) or err or "refresh_failed" })
    end
    if data.refresh_token then millennium.config.set("refresh_token", data.refresh_token) end
    return json.encode(data)
end

function EpicLogout()
    millennium.config.set("refresh_token", "")
    return json.encode({ ok = true })
end

-- ====== SteamGridDB (jaquettes optionnelles, clé API fournie par l'utilisateur) ======
local SGDB_API = "https://www.steamgriddb.com/api/v2/"

-- Répertoire du plugin : le frontend ne peut lire un fichier local que via
-- https://millennium.ftp/<chemin> et seuls les chemins du plugin sont servis.
local _plugin_dir = nil
local function plugin_cache_dir()
    if _plugin_dir == nil and ok_utils and utils and utils.get_backend_path then
        local ok, p = pcall(utils.get_backend_path)
        if ok and type(p) == "string" then
            _plugin_dir = p:gsub("/[^/]*$", ""):gsub("/backend$", "")
        else
            _plugin_dir = false
        end
    end
    if _plugin_dir and _plugin_dir ~= false then
        local dir = _plugin_dir .. "/.cache"
        if package.config:sub(1, 1) == "\\" then
            pcall(os.execute, 'mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
        else
            pcall(os.execute, "mkdir -p '" .. dir .. "'")
        end
        return dir
    end
    local tmp = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return tmp
end

local function sgdb_get(api_key, endpoint)
    return http_json(SGDB_API .. endpoint, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
            ["Accept"]        = "application/json",
            ["User-Agent"]    = USER_AGENT,
        },
        timeout = 20,
    })
end

-- Cherche une jaquette portrait sur SteamGridDB, la télécharge dans /tmp et
-- renvoie { path, ext }. Le frontend la lit via https://millennium.ftp/<path>
-- (cdn2.steamgriddb.com bloque le CORS, donc pas de fetch direct côté JS ;
-- et http.get tronque le binaire au premier octet nul → on utilise http.download).
function EpicSGDBCover(api_key, title)
    if not api_key or api_key == "" then return json.encode({ errorMessage = "no_key" }) end
    if not title or title == "" then return json.encode({ errorMessage = "no_title" }) end

    local search = sgdb_get(api_key, "search/autocomplete/" .. urlencode(title))
    if not search or not search.success or not search.data or not search.data[1] then
        return json.encode({ errorMessage = "not_found" })
    end
    local game_id = search.data[1].id

    local grids = sgdb_get(api_key, "grids/game/" .. tostring(game_id) ..
        "?dimensions=600x900,342x482&types=static&nsfw=false")
    if not grids or not grids.success or not grids.data or not grids.data[1] or not grids.data[1].url then
        return json.encode({ errorMessage = "no_grid" })
    end
    local url = grids.data[1].url
    local ext = url:match("%.png") and "png" or (url:match("%.jpe?g") and "jpg" or "png")

    local path = plugin_cache_dir() .. "/epiccat-art-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000)) .. "." .. ext
    local ok_call, response = pcall(http.download, url, path)
    if not ok_call or not response or response.status ~= 200 then
        pcall(os.remove, path)
        return json.encode({ errorMessage = "download_failed" })
    end
    response = nil
    collectgarbage("collect")
    return json.encode({ path = path, ext = ext })
end

function EpicCleanupArt(path)
    if path and #path > 0 then pcall(os.remove, path) end
    return json.encode({ ok = true })
end

local function on_load()
    logger:info("Epic Game Category loaded ✅")
    millennium.ready()
end

return {
    on_load             = on_load,
    EpicStartDeviceAuth = EpicStartDeviceAuth,
    EpicPollDeviceAuth  = EpicPollDeviceAuth,
    EpicGetLibrary      = EpicGetLibrary,
    EpicRefreshLogin    = EpicRefreshLogin,
    EpicLogout          = EpicLogout,
    EpicSGDBCover       = EpicSGDBCover,
    EpicCleanupArt      = EpicCleanupArt,
}
