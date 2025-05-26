RegisterServerEvent("intrarp-tablet:tryOpen")
AddEventHandler("intrarp-tablet:tryOpen", function()
    local src = source

    if Framework.HasAllowedJob(src) then
        TriggerClientEvent("intrarp-tablet:open", src)
    else
        TriggerClientEvent('chat:addMessage', src, {
            args = { '^1[Tablet]', 'Du hast keinen Zugriff auf das Tablet.' }
        })
    end
end)