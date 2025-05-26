Framework = {}

CreateThread(function()
    if Config.Framework == "esx" then
        TriggerEvent('esx:getSharedObject', function(obj)
            Framework.Object = obj
        end)

        if not Framework.Object then
            print("[Tablet] Fehler: ESX Framework konnte nicht geladen werden.")
        else
            print("[Tablet] ESX Framework erkannt.")
        end

    elseif Config.Framework == "qbcore" then
        local ok, obj = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        if ok and obj then
            Framework.Object = obj
            print("[Tablet] QBCore Framework erkannt.")
        else
            print("[Tablet] Fehler: QBCore konnte nicht geladen werden.")
        end

    else
        print("[Tablet] Standalone-Modus aktiviert.")
    end
end)

--- Funktion: Hat Spieler erlaubten Job?
function Framework.HasAllowedJob(source)
    if Config.Framework == "esx" then
        local xPlayer = Framework.Object.GetPlayerFromId(source)
        if not xPlayer then return false end
        local jobName = xPlayer.job and xPlayer.job.name
        return jobName and Framework.IsJobAllowed(jobName)

    elseif Config.Framework == "qbcore" then
        local Player = Framework.Object.Functions.GetPlayer(source)
        if not Player then return false end
        local jobName = Player.PlayerData.job and Player.PlayerData.job.name
        return jobName and Framework.IsJobAllowed(jobName)

    else
        -- Im Standalone-Modus erlauben wir alles
        return true
    end
end

function Framework.IsJobAllowed(jobName)
    for _, allowedJob in pairs(Config.AllowedJobs or {}) do
        if allowedJob == jobName then
            return true
        end
    end
    return false
end
