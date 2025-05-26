window.addEventListener('message', function(event) {
    if (event.data.type === "show") {
        document.getElementById('tabletFrame').src = event.data.url;
        document.body.style.display = "block";
    }
});

document.getElementById('closeBtn').addEventListener('click', function () {
    fetch(`https://${GetParentResourceName()}/close`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({})
    });
    document.body.style.display = "none";
});