-- ========================================
-- URL HELPER FUNKTIONEN
-- ========================================
-- Stelle sicher, dass URLs HTTPS verwenden (FiveM-Anforderung)
local function EnsureHttps(url)
    if not url or url == "" then
        return url
    end
    
    -- Entferne führende/trailing Leerzeichen
    url = url:match("^%s*(.-)%s*$")
    
    -- Wenn die URL mit http:// beginnt, ersetze es durch https://
    if url:lower():sub(1, 7) == "http://" then
        url = "https://" .. url:sub(8)
        if Config.Debug then
            print("^3[EMD-Sync]^7 URL converted to HTTPS: " .. url)
        end
    -- Wenn die URL nicht mit einem Protokoll beginnt, füge https:// hinzu
    elseif url:lower():sub(1, 8) ~= "https://" and url:sub(1, 2) ~= "//" then
        url = "https://" .. url
        if Config.Debug then
            print("^3[EMD-Sync]^7 HTTPS prefix added to URL: " .. url)
        end
    end
    
    return url
end

-- Entferne trailing slash
local function RemoveTrailingSlash(url)
    if url and url:sub(-1) == "/" then
        return url:sub(1, -2)
    end
    return url
end

-- Stelle sicher, dass trailing slash vorhanden ist
local function AddTrailingSlash(url)
    if url and url:sub(-1) ~= "/" then
        return url .. "/"
    end
    return url
end

-- Baue relative URLs basierend auf BaseURL
local function BuildURL(basePath)
    local baseURL = EnsureHttps(Config.BaseURL or "")
    baseURL = AddTrailingSlash(baseURL)
    
    -- basePath sollte ohne führenden Slash sein
    if basePath and basePath:sub(1, 1) == "/" then
        basePath = basePath:sub(2)
    end
    
    return baseURL .. (basePath or "")
end

-- Generiere PHPEndpoint einmalig beim Start
local PHPEndpoint = BuildURL("api/emd-sync.php")

if Config.Debug then
    print("^2[EMD-Sync]^7 PHPEndpoint generiert: " .. (PHPEndpoint or "FEHLER"))
end

-- Funktion zum Ausführen von MySQL-Queries (nutzt vorhandene Framework-DB-Connection)
local function ExecuteQuery(query, parameters)
    local promise = promise.new()
    
    -- Versuche oxmysql (QBCore/ESX modern)
    if GetResourceState('oxmysql') == 'started' then
        exports.oxmysql:execute(query, parameters, function(result)
            promise:resolve(result)
        end)
    -- Fallback auf mysql-async (ESX legacy)
    elseif MySQL and MySQL.Async then
        MySQL.Async.fetchAll(query, parameters, function(result)
            promise:resolve(result)
        end)
    else
        if Config.Debug then
            print("^1[EMD-Sync]^7 Keine MySQL-Resource gefunden! Bitte oxmysql oder mysql-async installieren.")
        end
        promise:resolve(nil)
    end
    
    return Citizen.Await(promise)
end

-- Funktion zum Einpflegen von Lagemeldungen aus der PHP-Response in emergencydispatch
local function ProcessSituationReports(responseData)
    if not responseData or not responseData.situation_reports then
        return
    end

    local totalSent = 0
    local totalFailed = 0

    for einsatznummer, reports in pairs(responseData.situation_reports) do
        if type(reports) == 'table' then
            for _, report in ipairs(reports) do
                local text = report.text or ""
                local sender = report.sender or "intraRP"

                if text ~= "" then
                    local success, result = pcall(function()
                        return exports['emergencydispatch']:emf_lagemeldung_send(tonumber(einsatznummer) or einsatznummer, text, sender)
                    end)

                    if success and result then
                        totalSent = totalSent + 1
                        if Config.Debug then
                            print("^2[EMD-Sync]^7 Lagemeldung für Einsatz #" .. einsatznummer .. " eingepflegt: " .. text)
                        end
                    else
                        totalFailed = totalFailed + 1
                        if Config.Debug then
                            print("^1[EMD-Sync]^7 Fehler beim Einpflegen der Lagemeldung für Einsatz #" .. einsatznummer)
                        end
                    end
                end
            end
        end
    end

    if Config.Debug and (totalSent > 0 or totalFailed > 0) then
        print("^2[EMD-Sync]^7 Lagemeldungen aus Response verarbeitet: " .. totalSent .. " erfolgreich, " .. totalFailed .. " fehlgeschlagen")
    end
end

local function SendDataToPHP(data)
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end

    if not PHPEndpoint then
        if Config.Debug then
            print("^1[EMD-Sync]^7 Fehler: PHPEndpoint konnte nicht generiert werden!")
        end
        return
    end

    if Config.Debug then
        print("^2[EMD-Sync]^7 Daten an PHP-Endpunkt senden...")
        print("^2[EMD-Sync]^7 Verwendung des API-Schlüssels: " .. Config.EMDSync.APIKey)
        print("^2[EMD-Sync]^7 Endpunkt: " .. PHPEndpoint)
    end

    PerformHttpRequest(PHPEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            if Config.Debug then
                print("^2[EMD-Sync]^7 Daten erfolgreich gesendet! Antwort: " .. response)
            end

            -- Verarbeite Lagemeldungen aus der Response (FireTab -> emergencydispatch)
            if Config.EMDSync.LagemeldungSync and Config.EMDSync.LagemeldungSync.Enabled then
                local responseData = json.decode(response)
                if responseData then
                    ProcessSituationReports(responseData)
                end
            end
        else
            if Config.Debug then
                print("^1[EMD-Sync]^7 Fehler beim Senden der Daten. Statuscode: " .. statusCode)
                if statusCode == 401 then
                    print("^1[EMD-Sync]^7 API-Key ist ungültig! Bitte Config.EMDSync.APIKey in config.lua korrekt setzen.")
                end
                if response then
                    print("^1[EMD-Sync]^7 Antwort: " .. response)
                end
            end
        end
    end, 'POST', json.encode({
        intraRP_API_Key = Config.EMDSync.APIKey,
        timestamp = os.time(),
        data = data
    }), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-EMDSync/1.0'
    })
end

-- Funktion zum Abrufen der Emergency Dispatch Daten
local function GetDispatchData()
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return nil
    end
    
    local success, mannedVehicles = pcall(function()
        return exports['emergencydispatch']:mannedvehicles()
    end)

    if not success then
        if Config.Debug then
            print("^1[EMD-Sync]^7 Fehler beim Abrufen von Daten aus dem emergencydispatch Export!")
        end
        return nil
    end

    if Config.Debug then
        print("^2[EMD-Sync]^7 Abgerufen: " .. (mannedVehicles and #mannedVehicles or 0) .. " besetzte Fahrzeuge")
    end

    return mannedVehicles
end

-- Funktion zum Abrufen von Dispatch-Details aus emd_dispatchlist
local function GetDispatchListDetails(dispatchNumbers)
    if not dispatchNumbers or #dispatchNumbers == 0 then
        return {}
    end
    
    -- Erstelle Platzhalter für die IN-Klausel
    local placeholders = {}
    for i = 1, #dispatchNumbers do
        table.insert(placeholders, '?')
    end
    
    local query = string.format([[
        SELECT id, number, dispatch
        FROM emd_dispatchlist
        WHERE number IN (%s)
    ]], table.concat(placeholders, ','))
    
    local result = ExecuteQuery(query, dispatchNumbers)
    
    if Config.Debug and result then
        print("^2[EMD-Sync]^7 " .. #result .. " Dispatch-Details aus emd_dispatchlist gefunden")
    end
    
    return result or {}
end

-- Funktion zum Abrufen der Lagemeldungen für eine Einsatznummer
local function GetLagemeldungen(einsatznummer)
    if not einsatznummer then
        return nil
    end

    local success, lagemeldungen = pcall(function()
        return exports['emergencydispatch']:emf_lagemeldung_get(einsatznummer)
    end)

    if not success then
        if Config.Debug then
            print("^1[EMD-Sync]^7 Fehler beim Abrufen der Lagemeldungen für Einsatz " .. tostring(einsatznummer))
        end
        return nil
    end

    if Config.Debug and lagemeldungen then
        local count = 0
        if type(lagemeldungen) == 'table' then
            count = #lagemeldungen
        end
        print("^2[EMD-Sync]^7 " .. count .. " Lagemeldung(en) für Einsatz " .. tostring(einsatznummer) .. " abgerufen")
    end

    return lagemeldungen
end

-- Funktion zum Abrufen aller Lagemeldungen für mehrere Einsatznummern
local function GetAllLagemeldungen(dispatchNumbers)
    if not dispatchNumbers or #dispatchNumbers == 0 then
        return {}
    end

    local lagemeldungMap = {}

    for _, einsatznummer in ipairs(dispatchNumbers) do
        local lagemeldungen = GetLagemeldungen(einsatznummer)
        if lagemeldungen and type(lagemeldungen) == 'table' then
            lagemeldungMap[tostring(einsatznummer)] = lagemeldungen
        end
    end

    if Config.Debug then
        local count = 0
        for _ in pairs(lagemeldungMap) do count = count + 1 end
        print("^2[EMD-Sync]^7 Lagemeldungen für " .. count .. " Einsätze abgerufen")
    end

    return lagemeldungMap
end

-- Haupt-Sync-Funktion
function SyncDispatchData()
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end
    
    local dispatchData = GetDispatchData()
    
    if dispatchData and #dispatchData > 0 then
        -- Sammle alle Einsatznummern
        local dispatchNumbers = {}
        local dispatchNumberSet = {}
        
        for _, vehicle in ipairs(dispatchData) do
            if vehicle.dispatch and not dispatchNumberSet[vehicle.dispatch] then
                table.insert(dispatchNumbers, vehicle.dispatch)
                dispatchNumberSet[vehicle.dispatch] = true
            end
        end
        
        -- Hole Dispatch-Details aus emd_dispatchlist
        local dispatchDetails = GetDispatchListDetails(dispatchNumbers)
        
        -- Erstelle Map für schnellen Zugriff auf Dispatch-Details
        local dispatchMap = {}
        for _, detail in ipairs(dispatchDetails) do
            local dispatchJson = json.decode(detail.dispatch)
            if dispatchJson then
                local dispatchData = {
                    postal = dispatchJson.postal or "",
                    dispatch_code = dispatchJson.dispatch_code or "",
                    dispatch_issue = dispatchJson.dispatch_issue or "",
                    issue = dispatchJson.issue or "",
                    caller_phonenumber = dispatchJson.caller_phonenumber or "",
                    caller_name = dispatchJson.caller_name or "",
                    location_x = dispatchJson.location_x or 0,
                    location_y = dispatchJson.location_y or 0
                }
                
                -- Füge Patientendaten hinzu, falls vorhanden
                if dispatchJson.patienten and dispatchJson.patienten ~= "" then
                    -- patienten ist ein JSON-String, der dekodiert werden muss
                    local patientenDecoded = json.decode(dispatchJson.patienten)
                    if patientenDecoded then
                        -- Filtere nur die benötigten Felder: alter, vorname, nachname
                        local filteredPatienten = {}
                        for _, patient in ipairs(patientenDecoded) do
                            table.insert(filteredPatienten, {
                                alter = patient.alter or "",
                                vorname = patient.vorname or "",
                                nachname = patient.nachname or ""
                            })
                        end
                        dispatchData.patienten = filteredPatienten
                    end
                end
                
                dispatchMap[tostring(detail.number)] = dispatchData
            end
        end
        
        -- Hole Lagemeldungen pro Einsatz, wenn aktiviert
        local lagemeldungMap = {}
        if Config.EMDSync.LagemeldungSync and Config.EMDSync.LagemeldungSync.Enabled and Config.EMDSync.LagemeldungSync.IncludeInDispatchSync then
            lagemeldungMap = GetAllLagemeldungen(dispatchNumbers)
        end

        -- Füge Dispatch-Details (inkl. Patientendaten und Lagemeldungen) zu jedem Fahrzeug hinzu
        for _, vehicle in ipairs(dispatchData) do
            if vehicle.dispatch then
                local dispatchNumber = tostring(vehicle.dispatch)

                -- Füge Dispatch-Daten hinzu
                if dispatchMap[dispatchNumber] then
                    vehicle.dispatch_data = dispatchMap[dispatchNumber]

                    -- Füge Lagemeldungen hinzu
                    if lagemeldungMap[dispatchNumber] then
                        vehicle.dispatch_data.lagemeldungen = lagemeldungMap[dispatchNumber]
                    end

                    if Config.Debug then
                        local patientInfo = ""
                        if dispatchMap[dispatchNumber].patienten then
                            patientInfo = " (inkl. " .. #dispatchMap[dispatchNumber].patienten .. " Patient(en))"
                        end
                        local lageInfo = ""
                        if lagemeldungMap[dispatchNumber] then
                            lageInfo = " (inkl. " .. #lagemeldungMap[dispatchNumber] .. " Lagemeldung(en))"
                        end
                        print("^2[EMD-Sync]^7 Dispatch-Daten für Einsatz " .. vehicle.dispatch .. " hinzugefügt" .. patientInfo .. lageInfo)
                    end
                end
            end
        end
        
        local payload = {
            vehicles = dispatchData,
            serverName = GetConvar('sv_projectName', 'Unknown Server'),
            serverTime = os.date('%Y-%m-%d %H:%M:%S')
        }
        
        if Config.Debug then
            print("^2[EMD-Sync]^7 Payload vorbereitet mit " .. #dispatchData .. " Fahrzeugen")
        end
        
        SendDataToPHP(payload)
    else
        if Config.Debug then
            print("^3[EMD-Sync]^7 Keine Fahrzeuge zum Synchronisieren")
        end
    end
end

-- Event Handler für manuelle Synchronisation
RegisterServerEvent('emd:syncNow')
AddEventHandler('emd:syncNow', function()
    local source = source
    
    -- Prüfe ob Spieler Admin ist (optional)
    if IsPlayerAceAllowed(source, 'command.emdsync') then
        if Config.Debug then
            print("^2[EMD-Sync]^7 Manuelle Synchronisierung durch den Player ausgelöst " .. source)
        end
        SyncDispatchData()
    else
        if Config.Debug then
            print("^1[EMD-Sync]^7 Unbefugter Synchronisierungsversuch durch Spieler " .. source)
        end
    end
end)

-- Event Handler für Fahrzeug-Alarmierung
RegisterServerEvent('emd:vehicleAlerted')
AddEventHandler('emd:vehicleAlerted', function()
    if Config.Debug then
        print("^2[EMD-Sync]^7 Fahrzeugalarmierung ausgelöst, Synchronisierung läuft...")
    end
    
    -- Sende sofort bei Alarmierung (nutzt automatisch den Export)
    SyncDispatchData()
end)

-- Event Handler für Status-Änderungen
RegisterServerEvent('emd:statusChanged')
AddEventHandler('emd:statusChanged', function(vehicleId, newStatus)
    if Config.Debug then
        print("^2[EMD-Sync]^7 Status für Fahrzeug geändert: " .. vehicleId .. " zu " .. newStatus)
    end
    
    -- Sende bei Status-Änderung
    SyncDispatchData()
end)

-- Automatischer Sync-Timer
CreateThread(function()
    Wait(1000) -- Warte bis Config geladen ist
    
    if not Config or not Config.EMDSync or not Config.EMDSync.Enabled then
        if Config.Debug then
            print("^3[EMD-Sync]^7 EMD-Sync ist in der Konfiguration deaktiviert")
        end
        return
    end
    
    if Config.Debug then
        print("^2[EMD-Sync]^7 Automatische Synchronisierung starten (Intervall: " .. (Config.EMDSync.SyncInterval / 1000) .. "s)")
        print("^2[EMD-Sync]^7 PHP-Endpunkt: " .. PHPEndpoint)
    end
    
    while true do
        Wait(Config.EMDSync.SyncInterval)
        
        if Config.Debug then
            print("^2[EMD-Sync]^7 Timer ausgelöst - Synchronisierung wird gestartet...")
        end
        
        SyncDispatchData()
    end
end)

-- Command zum manuellen Triggern
RegisterCommand('emdsync', function(source, args)
    if source == 0 or IsPlayerAceAllowed(source, 'command.emdsync') then
        if Config.Debug then
            print("^2[EMD-Sync]^7 Manueller Synchronisierungsbefehl ausgeführt")
        end
        SyncDispatchData()
    end
end, true)

-- Export für andere Scripts
exports('syncDispatchData', SyncDispatchData)

-- Beim Start einmal synchronisieren
CreateThread(function()
    Wait(5000) -- Warte 5 Sekunden nach Server-Start
    
    if not Config or not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end
    if Config.Debug then
        print("^2[EMD-Sync]^7 Erste Synchronisierung...")
    end
    SyncDispatchData()
end)

if Config.Debug then
    print("^2[EMD-Sync]^7 Skript erfolgreich geladen!")
end

--[[ =========================================
     DISPATCH LOG SYNC - Einsatz-Statusmeldungen
     ========================================= ]]--

-- Tabelle zum Speichern bereits verarbeiteter Einsätze
local processedMissions = {}
local lastProcessedId = 0

-- Funktion zum Abrufen unverarbeiteter Dispatch-Logs
local function GetUnprocessedLogs()
    if not Config.EMDSync or not Config.EMDSync.DispatchLogSync or not Config.EMDSync.DispatchLogSync.Enabled then
        return nil
    end
    
    local query = string.format([[
        SELECT id, number, date, time, sender, type, text
        FROM %s
        WHERE id > ?
        ORDER BY id ASC
    ]], Config.EMDSync.DispatchLogSync.SourceTable)
    
    local result = ExecuteQuery(query, {lastProcessedId})
    
    if Config.Debug and result then
        print("^2[Dispatch-Log-Sync]^7 " .. #result .. " unverarbeitete Logs gefunden")
    end
    
    return result
end

-- Funktion zum Gruppieren von Logs nach Einsatznummer und Fahrzeug
local function GroupLogsByMission(logs)
    local missions = {}
    local activeMissions = {}  -- Tracking aktiver Einsätze pro Fahrzeug
    
    for _, log in ipairs(logs) do
        local missionNumber = tostring(log.number)
        local sender = log.sender
        local missionKey = missionNumber .. '_' .. (activeMissions[sender .. '_' .. missionNumber] or 0)
        
        -- Prüfe auf Status C (Einsatz-Start oder neuer Einsatz)
        if log.type == 'status' and log.text == 'C' then
            -- Wenn bereits ein aktiver Einsatz existiert, beende diesen
            if activeMissions[sender .. '_' .. missionNumber] and missions[missionKey] and missions[missionKey].hasStarted and not missions[missionKey].hasEnded then
                missions[missionKey].endId = log.id - 1
                missions[missionKey].hasEnded = true
                missions[missionKey].endTime = log.date .. ' ' .. log.time
                missions[missionKey].endReason = 'new_mission'
                
                if Config.Debug then
                    print("^2[Dispatch-Log-Sync]^7 Einsatz " .. missionKey .. " durch neuen Status C beendet")
                end
            end
            
            -- Starte neuen Einsatz
            activeMissions[sender .. '_' .. missionNumber] = (activeMissions[sender .. '_' .. missionNumber] or 0) + 1
            missionKey = missionNumber .. '_' .. activeMissions[sender .. '_' .. missionNumber]
            
            missions[missionKey] = {
                number = missionNumber,
                logs = {},
                startId = log.id,
                endId = nil,
                hasStarted = true,
                hasEnded = false,
                startTime = log.date .. ' ' .. log.time,
                sender = sender
            }
        end
        
        -- Füge Log zum aktuellen Einsatz hinzu
        if missions[missionKey] then
            table.insert(missions[missionKey].logs, log)
            
            -- Prüfe auf "Einsatz beendet"
            if log.type == 'einsatz' and log.text == 'Einsatz beendet' then
                missions[missionKey].endId = log.id
                missions[missionKey].hasEnded = true
                missions[missionKey].endTime = log.date .. ' ' .. log.time
                missions[missionKey].endReason = 'completed'
            end
            
            -- Update letzte Log-ID
            missions[missionKey].lastLogId = log.id
        end
    end
    
    return missions
end

-- Funktion zum Filtern abgeschlossener Einsätze
local function GetCompletedMissions(missions)
    local completed = {}
    
    for missionNumber, mission in pairs(missions) do
        -- Ein Einsatz ist abgeschlossen, wenn er mit Status C begonnen und mit "Einsatz beendet" geendet hat
        if mission.hasStarted and mission.hasEnded then
            -- Prüfe, ob dieser Einsatz nicht bereits verarbeitet wurde
            if not processedMissions[missionNumber] then
                table.insert(completed, mission)
                processedMissions[missionNumber] = true
                
                if Config.Debug then
                    print("^2[Dispatch-Log-Sync]^7 Abgeschlossener Einsatz gefunden: " .. missionNumber)
                    print("^2[Dispatch-Log-Sync]^7   Start: " .. mission.startTime .. " (Log-ID: " .. mission.startId .. ")")
                    print("^2[Dispatch-Log-Sync]^7   Ende: " .. mission.endTime .. " (Log-ID: " .. mission.endId .. ")")
                    print("^2[Dispatch-Log-Sync]^7   Anzahl Logs: " .. #mission.logs)
                end
            end
        end
    end
    
    return completed
end

-- Funktion zum Abrufen der Dispatch-Daten aus emd_dispatchlist
local function GetDispatchListData(missionNumbers)
    if not Config.EMDSync or not Config.EMDSync.DispatchLogSync or not Config.EMDSync.DispatchLogSync.Enabled then
        return nil
    end
    
    if #missionNumbers == 0 then
        return {}
    end
    
    -- Erstelle Platzhalter für die IN-Klausel
    local placeholders = {}
    for i = 1, #missionNumbers do
        table.insert(placeholders, '?')
    end
    
    local query = string.format([[
        SELECT id, number, dispatch
        FROM emd_dispatchlist
        WHERE number IN (%s)
    ]], table.concat(placeholders, ','))
    
    local result = ExecuteQuery(query, missionNumbers)
    
    if Config.Debug and result then
        print("^2[Dispatch-Log-Sync]^7 " .. #result .. " Einsatzdaten aus emd_dispatchlist gefunden")
    end
    
    return result or {}
end

-- Funktion zum Senden der Einsatzdaten an PHP (verwendet EMDSync Endpunkt)
local function SendMissionDataToPHP(missions)
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end
    
    if #missions == 0 then
        return
    end
    
    if Config.Debug then
        print("^2[Dispatch-Log-Sync]^7 Sende " .. #missions .. " abgeschlossene Einsätze an PHP-Endpunkt...")
        print("^2[Dispatch-Log-Sync]^7 Endpunkt: " .. PHPEndpoint)
    end
    
    -- Hole die Einsatznummern
    local missionNumbers = {}
    for _, mission in ipairs(missions) do
        table.insert(missionNumbers, mission.number)
    end
    
    -- Hole die zugehörigen Dispatch-Daten
    local dispatchListData = GetDispatchListData(missionNumbers)
    
    -- Erstelle eine Map für schnellen Zugriff
    local dispatchMap = {}
    for _, dispatchEntry in ipairs(dispatchListData) do
        dispatchMap[tostring(dispatchEntry.number)] = dispatchEntry
    end
    
    local payload = {
        intraRP_API_Key = Config.EMDSync.APIKey,
        timestamp = os.time(),
        type = 'dispatch_logs',  -- Kennzeichnung für PHP zur Unterscheidung
        missions = {}
    }
    
    for _, mission in ipairs(missions) do
        local missionData = {
            mission_number = mission.number,
            sender = mission.sender,
            start_time = mission.startTime,
            end_time = mission.endTime,
            end_reason = mission.endReason,  -- 'completed' oder 'new_mission'
            start_log_id = mission.startId,
            end_log_id = mission.endId,
            last_log_id = mission.lastLogId,
            logs = mission.logs
        }
        
        -- Füge Dispatch-Daten hinzu, wenn vorhanden
        local dispatchEntry = dispatchMap[mission.number]
        if dispatchEntry then
            missionData.dispatch_id = dispatchEntry.id
            missionData.dispatch_data = dispatchEntry.dispatch
            
            if Config.Debug then
                print("^2[Dispatch-Log-Sync]^7 Dispatch-Daten für Einsatz " .. mission.number .. " hinzugefügt (ID: " .. dispatchEntry.id .. ")")
            end
        else
            if Config.Debug then
                print("^3[Dispatch-Log-Sync]^7 Keine Dispatch-Daten für Einsatz " .. mission.number .. " gefunden")
            end
        end
        
        table.insert(payload.missions, missionData)
    end
    
    PerformHttpRequest(PHPEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            if Config.Debug then
                print("^2[Dispatch-Log-Sync]^7 Einsatzdaten erfolgreich gesendet! Antwort: " .. response)
            end
            
            -- Update lastProcessedId mit der höchsten verarbeiteten Log-ID nur bei Erfolg
            for _, mission in ipairs(missions) do
                if mission.lastLogId and mission.lastLogId > lastProcessedId then
                    lastProcessedId = mission.lastLogId
                end
            end
            
            if Config.Debug then
                print("^2[Dispatch-Log-Sync]^7 Letzte verarbeitete Log-ID aktualisiert: " .. lastProcessedId)
            end
        else
            if Config.Debug then
                print("^1[Dispatch-Log-Sync]^7 Fehler beim Senden der Einsatzdaten. Statuscode: " .. statusCode)
                if statusCode == 401 then
                    print("^1[Dispatch-Log-Sync]^7 API-Key ist ungültig! Bitte Config.EMDSync.APIKey in config.lua korrekt setzen.")
                end
                if response then
                    print("^1[Dispatch-Log-Sync]^7 Antwort: " .. response)
                end
            end
            -- lastProcessedId NICHT aktualisieren bei Fehler, damit beim nächsten Versuch erneut gesendet wird
        end
    end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-DispatchLogSync/1.0'
    })
end

-- Haupt-Funktion für Dispatch-Log-Sync
function SyncDispatchLogs()
    if not Config.EMDSync or not Config.EMDSync.DispatchLogSync or not Config.EMDSync.DispatchLogSync.Enabled then
        return
    end
    
    -- Hole unverarbeitete Logs
    local logs = GetUnprocessedLogs()
    
    if not logs or #logs == 0 then
        if Config.Debug then
            print("^3[Dispatch-Log-Sync]^7 Keine neuen Logs zum Verarbeiten")
        end
        return
    end
    
    -- Gruppiere Logs nach Einsatznummer
    local missions = GroupLogsByMission(logs)
    
    -- Filtere abgeschlossene Einsätze
    local completedMissions = GetCompletedMissions(missions)
    
    -- Update lastProcessedId auch wenn keine abgeschlossenen Einsätze gefunden wurden
    -- um zu verhindern, dass dieselben Logs immer wieder verarbeitet werden
    if logs and #logs > 0 then
        local maxLogId = logs[#logs].id
        if maxLogId > lastProcessedId then
            lastProcessedId = maxLogId
            if Config.Debug then
                print("^2[Dispatch-Log-Sync]^7 Letzte Log-ID auf " .. lastProcessedId .. " aktualisiert (keine abgeschlossenen Einsätze)")
            end
        end
    end
    
    if #completedMissions > 0 then
        -- Sende abgeschlossene Einsätze an PHP
        SendMissionDataToPHP(completedMissions)
    else
        if Config.Debug then
            print("^3[Dispatch-Log-Sync]^7 Keine abgeschlossenen Einsätze gefunden")
        end
    end
end

-- Automatischer Dispatch-Log-Sync-Timer
CreateThread(function()
    Wait(3000) -- Warte bis Config geladen ist
    
    if not Config or not Config.EMDSync or not Config.EMDSync.DispatchLogSync or not Config.EMDSync.DispatchLogSync.Enabled then
        if Config.Debug then
            print("^3[Dispatch-Log-Sync]^7 Dispatch-Log-Sync ist in der Konfiguration deaktiviert")
        end
        return
    end
    
    if Config.Debug then
        print("^2[Dispatch-Log-Sync]^7 Automatische Dispatch-Log-Synchronisierung gestartet")
        print("^2[Dispatch-Log-Sync]^7 Prüfintervall: " .. (Config.EMDSync.DispatchLogSync.CheckInterval / 1000) .. "s")
        print("^2[Dispatch-Log-Sync]^7 PHP-Endpunkt: " .. PHPEndpoint)
    end
    
    while true do
        Wait(Config.EMDSync.DispatchLogSync.CheckInterval)
        
        if Config.Debug then
            print("^2[Dispatch-Log-Sync]^7 Timer ausgelöst - Prüfe auf abgeschlossene Einsätze...")
        end
        
        SyncDispatchLogs()
    end
end)

-- Command zum manuellen Triggern des Dispatch-Log-Syncs
RegisterCommand('dispatchlogsync', function(source, args)
    if source == 0 or IsPlayerAceAllowed(source, 'command.dispatchlogsync') then
        if Config.Debug then
            print("^2[Dispatch-Log-Sync]^7 Manuelle Synchronisierung ausgeführt")
        end
        SyncDispatchLogs()
    end
end, true)

-- Export für andere Scripts
exports('syncDispatchLogs', SyncDispatchLogs)

if Config.Debug then
    print("^2[Dispatch-Log-Sync]^7 Dispatch-Log-Sync erfolgreich geladen!")
end

--[[ =========================================
     ECHTZEIT STATUS-SYNCHRONISIERUNG
     ========================================= ]]

-- Tabelle zum Speichern der letzten verarbeiteten Status-ID
local lastStatusId = 0

-- Funktion zum Abrufen der letzten Status-ID beim Start
local function LoadLastStatusId()
    if not Config.EMDSync or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        return
    end
    
    local query = string.format([[
        SELECT MAX(id) as max_id 
        FROM %s 
        WHERE type = 'status'
    ]], Config.EMDSync.DispatchLogSync.SourceTable)
    
    local result = ExecuteQuery(query, {})
    
    if result and result[1] and result[1].max_id then
        lastStatusId = result[1].max_id
        if Config.Debug then
            print("^2[Status-Sync]^7 Letzte Status-ID geladen: " .. lastStatusId)
        end
    end
end

-- Funktion zum Abrufen neuer Statusmeldungen
local function GetNewStatusMessages()
    if not Config.EMDSync or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        return nil
    end
    
    -- Erstelle Platzhalter für die IN-Klausel
    local statusList = table.concat(Config.EMDSync.StatusSync.SyncStatuses, "','")
    
    local query = string.format([[
        SELECT id, number, date, time, sender, type, text
        FROM %s
        WHERE id > ? 
        AND type = 'status'
        AND text IN ('%s')
        ORDER BY id ASC
    ]], Config.EMDSync.DispatchLogSync.SourceTable, statusList)
    
    local result = ExecuteQuery(query, {lastStatusId})
    
    if Config.Debug and result and #result > 0 then
        print("^2[Status-Sync]^7 " .. #result .. " neue Statusmeldungen gefunden")
    end
    
    return result
end

-- Funktion zum Senden der Statusmeldungen an PHP
local function SendStatusesToPHP(statuses)
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end
    
    if #statuses == 0 then
        return
    end
    
    if Config.Debug then
        print("^2[Status-Sync]^7 Sende " .. #statuses .. " Statusmeldungen an PHP-Endpunkt...")
        print("^2[Status-Sync]^7 Endpunkt: " .. PHPEndpoint)
    end
    
    local payload = {
        intraRP_API_Key = Config.EMDSync.APIKey,
        timestamp = os.time(),
        type = 'status_updates',  -- Kennzeichnung für PHP
        statuses = {}
    }
    
    for _, status in ipairs(statuses) do
        table.insert(payload.statuses, {
            id = status.id,
            mission_number = status.number,
            date = status.date,
            time = status.time,
            sender = status.sender,
            status = status.text,
            timestamp = status.date .. ' ' .. status.time
        })
    end
    
    PerformHttpRequest(PHPEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            if Config.Debug then
                print("^2[Status-Sync]^7 Statusmeldungen erfolgreich gesendet! Antwort: " .. response)
            end
            
            -- Parse die Response um successful_ids zu bekommen
            local responseData = json.decode(response)
            local successfulIds = responseData and responseData.successful_ids or {}
            
            -- Update lastStatusId NUR mit erfolgreich verarbeiteten IDs
            if successfulIds and #successfulIds > 0 then
                for _, successfulId in ipairs(successfulIds) do
                    if successfulId > lastStatusId then
                        lastStatusId = successfulId
                    end
                end
                
                if Config.Debug then
                    print("^2[Status-Sync]^7 Letzte Status-ID aktualisiert: " .. lastStatusId .. " (" .. #successfulIds .. " erfolgreich verarbeitet)")
                end
            else
                if Config.Debug then
                    print("^3[Status-Sync]^7 Keine Status erfolgreich verarbeitet, lastStatusId bleibt bei " .. lastStatusId)
                end
            end
        else
            if Config.Debug then
                print("^1[Status-Sync]^7 Fehler beim Senden der Statusmeldungen. Statuscode: " .. statusCode)
                if statusCode == 401 then
                    print("^1[Status-Sync]^7 API-Key ist ungültig! Bitte Config.EMDSync.APIKey in config.lua korrekt setzen.")
                end
                if response then
                    print("^1[Status-Sync]^7 Antwort: " .. response)
                end
            end
            -- lastStatusId NICHT aktualisieren bei Fehler
        end
    end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-StatusSync/1.0'
    })
end

-- Haupt-Funktion für Status-Sync
function SyncStatusMessages()
    if not Config.EMDSync or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        return
    end

    -- Hole neue Statusmeldungen
    local statuses = GetNewStatusMessages()

    if not statuses or #statuses == 0 then
        return
    end

    -- Sende Statusmeldungen an PHP
    SendStatusesToPHP(statuses)
end

-- ========================================
-- STATUS-POLL: Statusänderungen von PHP (FireTab) -> emergencydispatch (clientseitig)
-- ========================================

local StatusPollEndpoint = BuildURL("api/emd-status-poll.php")

-- Funktion zum Zuordnen von Fahrzeugnamen zu Spieler-Source via mannedvehicles
local function FindPlayerSourceByVehicleName(vehicleName)
    local success, mannedVehicles = pcall(function()
        return exports['emergencydispatch']:mannedvehicles()
    end)

    if not success or not mannedVehicles then
        return nil
    end

    for _, vehicle in ipairs(mannedVehicles) do
        if vehicle.value == vehicleName then
            return vehicle.source
        end
    end

    return nil
end

-- Funktion zum Verarbeiten der Status-Änderungen aus der PHP-Response
local function ProcessStatusChanges(statusChanges)
    if not statusChanges or #statusChanges == 0 then
        return
    end

    local applied = 0
    local notFound = 0

    for _, change in ipairs(statusChanges) do
        local vehicleName = change.vehicle_name
        local status = change.status

        if vehicleName and status then
            local playerSource = FindPlayerSourceByVehicleName(vehicleName)

            if playerSource then
                TriggerClientEvent('intraTab:applyStatus', playerSource, tostring(status))
                applied = applied + 1

                if Config.Debug then
                    print("^2[Status-Poll]^7 Status '" .. status .. "' an Spieler " .. playerSource .. " gesendet (Fahrzeug: " .. vehicleName .. ")")
                end
            else
                notFound = notFound + 1
                if Config.Debug then
                    print("^3[Status-Poll]^7 Kein Spieler für Fahrzeug '" .. vehicleName .. "' gefunden (Status: " .. status .. ")")
                end
            end
        end
    end

    if Config.Debug and (applied > 0 or notFound > 0) then
        print("^2[Status-Poll]^7 Statusänderungen verarbeitet: " .. applied .. " angewendet, " .. notFound .. " ohne Spieler")
    end
end

-- Funktion zum Polling der Statusänderungen von PHP
function PollFireTabStatusChanges()
    if not Config.EMDSync or not Config.EMDSync.Enabled or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        return
    end

    if not StatusPollEndpoint then
        return
    end

    if Config.Debug then
        print("^2[Status-Poll]^7 Polling Statusänderungen von PHP...")
    end

    PerformHttpRequest(StatusPollEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            local responseData = json.decode(response)

            if responseData and responseData.success and responseData.status_changes and #responseData.status_changes > 0 then
                if Config.Debug then
                    print("^2[Status-Poll]^7 " .. #responseData.status_changes .. " Statusänderung(en) von PHP empfangen")
                end
                ProcessStatusChanges(responseData.status_changes)
            else
                if Config.Debug then
                    print("^3[Status-Poll]^7 Keine neuen Statusänderungen von PHP")
                end
            end
        else
            if Config.Debug then
                print("^1[Status-Poll]^7 Fehler beim Polling. Statuscode: " .. statusCode)
                if response then
                    print("^1[Status-Poll]^7 Antwort: " .. response)
                end
            end
        end
    end, 'POST', json.encode({
        intraRP_API_Key = Config.EMDSync.APIKey,
        type = 'poll_status_changes'
    }), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-StatusPoll/1.0'
    })
end

-- Automatischer Status-Sync-Timer (inkl. Status-Poll von PHP)
CreateThread(function()
    Wait(2000) -- Warte bis Config geladen ist

    if not Config or not Config.EMDSync or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        if Config.Debug then
            print("^3[Status-Sync]^7 Echtzeit-Status-Sync ist in der Konfiguration deaktiviert")
        end
        return
    end

    LoadLastStatusId()

    if Config.Debug then
        print("^2[Status-Sync]^7 Echtzeit-Status-Synchronisierung gestartet")
        print("^2[Status-Sync]^7 Überwachte Status: " .. table.concat(Config.EMDSync.StatusSync.SyncStatuses, ", "))
        print("^2[Status-Sync]^7 Polling-Intervall: " .. (Config.EMDSync.StatusSync.PollInterval / 1000) .. "s")
        print("^2[Status-Sync]^7 PHP-Endpunkt: " .. PHPEndpoint)
        print("^2[Status-Poll]^7 Status-Poll-Endpunkt: " .. StatusPollEndpoint)
    end

    while true do
        Wait(Config.EMDSync.StatusSync.PollInterval)

        if Config.Debug then
            print("^2[Status-Sync]^7 Prüfe auf neue Statusmeldungen...")
        end

        SyncStatusMessages()
        PollFireTabStatusChanges()
    end
end)

-- ========================================
-- FALLBACK: Statusmeldungen ohne Einsatzzuordnung (nur Status-Tracking, kein Einsatzlog)
-- ========================================

-- Funktion zum Senden von Fallback-Statusmeldungen an PHP
local function SendFallbackStatusToPHP(vehicleName, status, time)
    if not PHPEndpoint then
        return
    end

    if Config.Debug then
        print("^2[Status-Fallback]^7 Sende Status '" .. tostring(status) .. "' für Fahrzeug '" .. tostring(vehicleName) .. "' (ohne Einsatz)")
    end

    PerformHttpRequest(PHPEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            if Config.Debug then
                print("^2[Status-Fallback]^7 Fallback-Status erfolgreich gesendet!")
            end
        else
            if Config.Debug then
                print("^1[Status-Fallback]^7 Fehler beim Senden. Statuscode: " .. statusCode)
            end
        end
    end, 'POST', json.encode({
        intraRP_API_Key = Config.EMDSync.APIKey,
        timestamp = os.time(),
        type = 'status_no_dispatch',  -- Markierung: NUR Status-Tracking, KEIN Einsatzlog
        vehicle_name = vehicleName,
        status = tostring(status),
        time = time,
        date = os.date('%d.%m.%Y')
    }), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-StatusFallback/1.0'
    })
end

-- Event-Handler: Fängt ALLE Statusänderungen ab, sendet nur die ohne Einsatz
AddEventHandler('emergencydispatch:status:emf', function(fzg, status, time)
    if not Config.EMDSync or not Config.EMDSync.StatusSync or not Config.EMDSync.StatusSync.Enabled then
        return
    end

    -- Prüfe ob das Fahrzeug einem Einsatz zugeordnet ist
    local hasDispatch = false
    local success, mannedVehicles = pcall(function()
        return exports['emergencydispatch']:mannedvehicles()
    end)

    if success and mannedVehicles then
        for _, vehicle in ipairs(mannedVehicles) do
            if vehicle.value == fzg and vehicle.dispatch and vehicle.dispatch ~= 0 then
                hasDispatch = true
                break
            end
        end
    end

    -- Nur senden wenn KEIN Einsatz zugeordnet (Fallback)
    if not hasDispatch then
        if Config.Debug then
            print("^2[Status-Fallback]^7 Fahrzeug '" .. tostring(fzg) .. "' hat keinen Einsatz - sende Fallback-Status '" .. tostring(status) .. "'")
        end
        SendFallbackStatusToPHP(fzg, status, time)
    else
        if Config.Debug then
            print("^3[Status-Fallback]^7 Fahrzeug '" .. tostring(fzg) .. "' hat Einsatz - überspringe Fallback (normaler StatusSync greift)")
        end
    end
end)

-- Command zum manuellen Triggern des Status-Syncs
RegisterCommand('statussync', function(source, args)
    if source == 0 or IsPlayerAceAllowed(source, 'command.statussync') then
        if Config.Debug then
            print("^2[Status-Sync]^7 Manuelle Status-Synchronisierung ausgeführt")
        end
        SyncStatusMessages()
    end
end, true)

-- Export für andere Scripts
exports('syncStatusMessages', SyncStatusMessages)

print("^2[Status-Sync]^7 Echtzeit-Status-Sync erfolgreich geladen!")

--[[ =========================================
     LAGEMELDUNG-SYNCHRONISIERUNG
     ========================================= ]]

-- Funktion zum Senden der Lagemeldungen an PHP
local function SendLagemeldungenToPHP(lagemeldungData)
    if not Config.EMDSync or not Config.EMDSync.Enabled then
        return
    end

    if not lagemeldungData or not next(lagemeldungData) then
        return
    end

    if Config.Debug then
        local count = 0
        for _ in pairs(lagemeldungData) do count = count + 1 end
        print("^2[Lagemeldung-Sync]^7 Sende Lagemeldungen für " .. count .. " Einsätze an PHP-Endpunkt...")
        print("^2[Lagemeldung-Sync]^7 Endpunkt: " .. PHPEndpoint)
    end

    local payload = {
        intraRP_API_Key = Config.EMDSync.APIKey,
        timestamp = os.time(),
        type = 'lagemeldungen',  -- Kennzeichnung für PHP
        einsaetze = {}
    }

    for einsatznummer, lagemeldungen in pairs(lagemeldungData) do
        table.insert(payload.einsaetze, {
            einsatznummer = einsatznummer,
            lagemeldungen = lagemeldungen
        })
    end

    PerformHttpRequest(PHPEndpoint, function(statusCode, response, headers)
        if statusCode == 200 then
            if Config.Debug then
                print("^2[Lagemeldung-Sync]^7 Lagemeldungen erfolgreich gesendet! Antwort: " .. response)
            end
        else
            if Config.Debug then
                print("^1[Lagemeldung-Sync]^7 Fehler beim Senden der Lagemeldungen. Statuscode: " .. statusCode)
                if statusCode == 401 then
                    print("^1[Lagemeldung-Sync]^7 API-Key ist ungültig! Bitte Config.EMDSync.APIKey in config.lua korrekt setzen.")
                end
                if response then
                    print("^1[Lagemeldung-Sync]^7 Antwort: " .. response)
                end
            end
        end
    end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FiveM-LagemeldungSync/1.0'
    })
end

-- Haupt-Funktion für eigenständige Lagemeldung-Synchronisierung
function SyncLagemeldungen()
    if not Config.EMDSync or not Config.EMDSync.LagemeldungSync or not Config.EMDSync.LagemeldungSync.Enabled then
        return
    end

    -- Hole aktive Einsatznummern über die besetzten Fahrzeuge
    local mannedVehicles = GetDispatchData()

    if not mannedVehicles or #mannedVehicles == 0 then
        if Config.Debug then
            print("^3[Lagemeldung-Sync]^7 Keine aktiven Einsätze für Lagemeldungen")
        end
        return
    end

    -- Sammle einzigartige Einsatznummern
    local dispatchNumbers = {}
    local dispatchNumberSet = {}

    for _, vehicle in ipairs(mannedVehicles) do
        if vehicle.dispatch and not dispatchNumberSet[vehicle.dispatch] then
            table.insert(dispatchNumbers, vehicle.dispatch)
            dispatchNumberSet[vehicle.dispatch] = true
        end
    end

    if #dispatchNumbers == 0 then
        if Config.Debug then
            print("^3[Lagemeldung-Sync]^7 Keine Einsatznummern gefunden")
        end
        return
    end

    -- Hole Lagemeldungen für alle aktiven Einsätze
    local lagemeldungMap = GetAllLagemeldungen(dispatchNumbers)

    if not next(lagemeldungMap) then
        if Config.Debug then
            print("^3[Lagemeldung-Sync]^7 Keine Lagemeldungen vorhanden")
        end
        return
    end

    -- Sende Lagemeldungen an PHP
    SendLagemeldungenToPHP(lagemeldungMap)
end

-- Automatischer Lagemeldung-Sync-Timer
CreateThread(function()
    Wait(3000) -- Warte bis Config geladen ist

    if not Config or not Config.EMDSync or not Config.EMDSync.LagemeldungSync or not Config.EMDSync.LagemeldungSync.Enabled then
        if Config.Debug then
            print("^3[Lagemeldung-Sync]^7 Lagemeldung-Sync ist in der Konfiguration deaktiviert")
        end
        return
    end

    if Config.Debug then
        print("^2[Lagemeldung-Sync]^7 Automatische Lagemeldung-Synchronisierung gestartet")
        print("^2[Lagemeldung-Sync]^7 Sync-Intervall: " .. (Config.EMDSync.LagemeldungSync.SyncInterval / 1000) .. "s")
        print("^2[Lagemeldung-Sync]^7 In Dispatch-Sync eingeschlossen: " .. tostring(Config.EMDSync.LagemeldungSync.IncludeInDispatchSync))
        print("^2[Lagemeldung-Sync]^7 PHP-Endpunkt: " .. PHPEndpoint)
    end

    while true do
        Wait(Config.EMDSync.LagemeldungSync.SyncInterval)

        if Config.Debug then
            print("^2[Lagemeldung-Sync]^7 Timer ausgelöst - Lagemeldungen werden synchronisiert...")
        end

        SyncLagemeldungen()
    end
end)

-- Command zum manuellen Triggern des Lagemeldung-Syncs
RegisterCommand('lagemeldungsync', function(source, args)
    if source == 0 or IsPlayerAceAllowed(source, 'command.lagemeldungsync') then
        if Config.Debug then
            print("^2[Lagemeldung-Sync]^7 Manuelle Lagemeldung-Synchronisierung ausgeführt")
        end
        SyncLagemeldungen()
    end
end, true)

-- Export für andere Scripts
exports('syncLagemeldungen', SyncLagemeldungen)

print("^2[Lagemeldung-Sync]^7 Lagemeldung-Sync erfolgreich geladen!")