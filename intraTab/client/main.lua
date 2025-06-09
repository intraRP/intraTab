-- Framework detection
local Framework = nil
local FrameworkName = nil

-- Auto-detect framework
Citizen.CreateThread(function()
    if Config.Framework == 'auto' then
        if GetResourceState('qb-core') == 'started' then
            Framework = exports['qb-core']:GetCoreObject()
            FrameworkName = 'qbcore'
        elseif GetResourceState('es_extended') == 'started' then
            Framework = exports['es_extended']:getSharedObject()
            FrameworkName = 'esx'
        end
    elseif Config.Framework == 'qbcore' then
        Framework = exports['qb-core']:GetCoreObject()
        FrameworkName = 'qbcore'
    elseif Config.Framework == 'esx' then
        Framework = exports['es_extended']:getSharedObject()
        FrameworkName = 'esx'
    end
    
    if Config.Debug then
        print("^2[intraTab]^7 Client framework detected: " .. (FrameworkName or "None"))
    end
end)

local isTabletOpen = false
local characterData = nil
local tabletProp = nil
local tabletDict = Config.Animation.dict
local tabletAnim = Config.Animation.anim

-- Get the control ID for the configured key
local function GetKeyControl()
    return Config.KeyControls[Config.OpenKey] or Config.OpenKeyControl or 168
end

-- Framework-specific notification function
local function ShowNotification(message, type)
    if FrameworkName == 'qbcore' then
        Framework.Functions.Notify(message, type or "primary")
    elseif FrameworkName == 'esx' then
        Framework.ShowNotification(message)
    else
        -- Fallback notification
        SetNotificationTextEntry("STRING")
        AddTextComponentString(message)
        DrawNotification(false, false)
    end
end

-- Framework-specific player data getter
function GetPlayerCharacterData()
    if FrameworkName == 'qbcore' then
        local PlayerData = Framework.Functions.GetPlayerData()
        
        if PlayerData and PlayerData.charinfo then
            if Config.Debug then
                print("QBCore data found:", json.encode(PlayerData.charinfo))
            end
            
            return {
                firstName = PlayerData.charinfo.firstname,
                lastName = PlayerData.charinfo.lastname,
                cid = PlayerData.citizenid,
                job = PlayerData.job.name
            }
        end
    elseif FrameworkName == 'esx' then
        local PlayerData = Framework.GetPlayerData()
        
        if PlayerData then
            if Config.Debug then
                print("ESX data found:", json.encode(PlayerData))
            end
            
            return {
                firstName = PlayerData.firstName,
                lastName = PlayerData.lastName,
                cid = PlayerData.identifier,
                job = PlayerData.job.name
            }
        end
    end
    
    return nil
end

-- Function to create tablet prop
function CreateTabletProp()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    
    -- Load prop model
    RequestModel(Config.Prop.model)
    while not HasModelLoaded(Config.Prop.model) do
        Wait(100)
    end
    
    -- Create the prop
    tabletProp = CreateObject(GetHashKey(Config.Prop.model), coords.x, coords.y, coords.z, true, true, true)
    
    -- Attach to player
    AttachEntityToEntity(
        tabletProp, 
        ped, 
        GetPedBoneIndex(ped, Config.Prop.bone),
        Config.Prop.offset.x, 
        Config.Prop.offset.y, 
        Config.Prop.offset.z,
        Config.Prop.offset.xRot, 
        Config.Prop.offset.yRot, 
        Config.Prop.offset.zRot,
        true, true, false, true, 1, true
    )
    
    if Config.Debug then
        print("Tablet prop created and attached")
    end
end

-- Function to delete tablet prop
function DeleteTabletProp()
    if tabletProp and DoesEntityExist(tabletProp) then
        DeleteEntity(tabletProp)
        tabletProp = nil
        if Config.Debug then
            print("Tablet prop deleted")
        end
    end
end

-- Function to play tablet animation
function PlayTabletAnimation()
    local ped = PlayerPedId()
    
    -- Load animation dictionary
    RequestAnimDict(tabletDict)
    while not HasAnimDictLoaded(tabletDict) do
        Wait(100)
    end
    
    -- Play animation
    TaskPlayAnim(ped, tabletDict, tabletAnim, 3.0, 3.0, -1, Config.Animation.flag, 0, false, false, false)
    
    if Config.Debug then
        print("Playing tablet animation:", tabletDict, tabletAnim)
    end
end

-- Function to stop tablet animation
function StopTabletAnimation()
    local ped = PlayerPedId()
    
    -- Stop animation
    StopAnimTask(ped, tabletDict, tabletAnim, 1.0)
    
    if Config.Debug then
        print("Stopped tablet animation")
    end
end

-- Open tablet
function OpenIntraRPTablet()
    if isTabletOpen then 
        if Config.Debug then
            print("Tablet already open")
        end
        return 
    end
    
    if Config.Debug then
        print("Opening Tablet...")
    end
    
    -- Get character data
    local charData = GetPlayerCharacterData()
    
    if not charData then
        ShowNotification("Unable to get character data", "error")
        return
    end
    
    if Config.Debug then
        print("Got character data:", json.encode(charData))
    end
    
    isTabletOpen = true
    
    -- Create tablet prop and play animation
    CreateTabletProp()
    PlayTabletAnimation()
    
    -- Enable NUI with proper focus
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    
    -- Send character data to NUI
    SendNUIMessage({
        type = "openTablet",
        characterData = charData,
        IntraURL = Config.IntraURL
    })

    if Config.Debug then
    ShowNotification("intraRP geöffnet: " .. charData.firstName .. " " .. charData.lastName, "success")
    end
end

-- Close tablet
function CloseIntraRPTablet()
    if not isTabletOpen then return end
    
    if Config.Debug then
        print("Closing tablet...")
    end
    
    isTabletOpen = false
    
    -- Stop animation and delete prop
    StopTabletAnimation()
    DeleteTabletProp()
    
    -- Properly disable NUI focus
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    
    SendNUIMessage({
        type = "closeTablet"
    })

    if Config.Debug then
    ShowNotification("Tablet geschlossen", "primary")
    end
end

-- NUI Callbacks
RegisterNUICallback('getCharacterData', function(data, cb)
    if Config.Debug then
        print("NUI requested character data")
    end
    
    local charData = GetPlayerCharacterData()
    if charData then
        if Config.Debug then
            print("Sending character data to NUI:", json.encode(charData))
        end
        cb(charData)
    else
        if Config.Debug then
            print("No character data available")
        end
        cb({error = "Unable to get character data"})
    end
end)

RegisterNUICallback('closeTablet', function(data, cb)
    if Config.Debug then
        print("NUI requested to close tablet")
    end
    CloseIntraRPTablet()
    cb('ok')
end)

-- Key detection thread
CreateThread(function()
    local keyControl = GetKeyControl()
    
    if Config.Debug then
        print("Monitoring key:", Config.OpenKey, "with control ID:", keyControl)
    end
    
    while true do
        if isTabletOpen then
            local ped = PlayerPedId()
            
            -- Handle ESC key
            DisableControlAction(0, 322, true) -- ESC key
            if IsDisabledControlJustPressed(0, 322) then
                if Config.Debug then
                    print("ESC pressed, closing tablet")
                end
                CloseIntraRPTablet()
            end
            
            -- Keep animation playing
            if not IsEntityPlayingAnim(ped, tabletDict, tabletAnim, 3) then
                PlayTabletAnimation()
            end
        else
            -- Check for configured key press when tablet is closed
            if IsControlJustPressed(0, keyControl) then
                if Config.Debug then
                    print(Config.OpenKey .. " pressed (Control ID: " .. keyControl .. "), opening tablet")
                end
                OpenIntraRPTablet()
            end
        end
        Wait(0)
    end
end)

-- Commands
RegisterCommand('intrarp', function()
    if Config.Debug then
        print("tablet command executed")
    end
    OpenIntraRPTablet()
end, false)

RegisterCommand('intrarptest', function()
    local charData = GetPlayerCharacterData()
    if charData then
        ShowNotification("Character: " .. charData.firstName .. " " .. charData.lastName .. " (" .. charData.job .. ")", "success")
        if Config.Debug then
            print("Character Data:", json.encode(charData))
        end
    else
        ShowNotification("No character data found", "error")
    end
end, false)

-- Test command to check key control ID
RegisterCommand('testkeycontrol', function()
    local keyControl = GetKeyControl()
    print("Current key:", Config.OpenKey, "Control ID:", keyControl)
    ShowNotification("Key: " .. Config.OpenKey .. " | Control ID: " .. keyControl, "primary")
end, false)

-- Key mapping
RegisterKeyMapping('intrarp', 'Open IntraRP Tablet', 'keyboard', Config.OpenKey)

-- Framework-specific events
if FrameworkName == 'qbcore' then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        characterData = nil
        if Config.Debug then
            print("QBCore player loaded, character data reset")
        end
    end)
elseif FrameworkName == 'esx' then
    RegisterNetEvent('esx:playerLoaded', function(xPlayer)
        characterData = nil
        if Config.Debug then
            print("ESX player loaded, character data reset")
        end
    end)
end

-- Resource start
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        if Config.Debug then
            print("tablet resource started")
            print("Framework:", FrameworkName or "None")
            print("Configured key:", Config.OpenKey, "Control ID:", GetKeyControl())
        end
        ShowNotification("tablet system loaded! Use /intrarp or " .. Config.OpenKey, "success")
    end
end)

-- Resource stop - cleanup
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        if isTabletOpen then
            SetNuiFocus(false, false)
            SetNuiFocusKeepInput(false)
            StopTabletAnimation()
            DeleteTabletProp()
        end
    end
end)
