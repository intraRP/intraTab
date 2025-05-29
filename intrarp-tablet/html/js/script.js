let isTabletOpen = false;
let characterData = null;
let intraURL = 'https://dev.intrarp.de/enotf/';
let navigationHistory = [];
let historyIndex = -1;
let currentUrl = '';

// Listen for messages from FiveM
window.addEventListener('message', function(event) {
    const data = event.data;
    //console.log('Received message:', data);
    
    switch(data.type) {
        case 'openTablet':
            openTablet(data.characterData, data.intraURL);
            break;
            
        case 'setCharacterData':
            setCharacterData(data.characterData);
            break;
            
        case 'closeTablet':
            closeTablet();
            break;
    }
});

function openTablet(charData, url) {
    //console.log('Opening tablet with data:', charData);
    
    characterData = charData;
    isTabletOpen = true;
    
    if (url) {
        intraURL = url;
    }
    
    const tabletContainer = document.getElementById('tabletContainer');
    const loadingScreen = document.getElementById('loadingScreen');
    const tabletScreen = document.getElementById('tabletScreen');
    
    if (tabletContainer) {
        tabletContainer.style.display = 'flex';
        document.body.style.cursor = 'default';
        tabletContainer.style.cursor = 'default';
    }
    if (loadingScreen) loadingScreen.style.display = 'flex';
    if (tabletScreen) tabletScreen.style.display = 'none';
    
    // Reset navigation
    navigationHistory = [];
    historyIndex = -1;
    currentUrl = '';
    updateNavigationButtons();
    
    if (charData && charData.firstName && charData.lastName) {
        loadIntraSystem(charData);
    } else {
        const loadingText = document.getElementById('loadingText');
        if (loadingText) loadingText.textContent = 'Waiting for character data...';
        
        fetch(`https://${GetParentResourceName()}/getCharacterData`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({})
        }).then(response => response.json())
        .then(data => {
            if (data.firstName && data.lastName) {
                loadIntraSystem(data);
            } else {
                if (loadingText) loadingText.textContent = 'Error: ' + (data.error || 'No character data');
            }
        }).catch(error => {
            console.error('Error getting character data:', error);
            if (loadingText) loadingText.textContent = 'Error connecting to server';
        });
    }
}

function setCharacterData(charData) {
    console.log('Setting character data:', charData);
    characterData = charData;
    
    if (isTabletOpen && charData && charData.firstName && charData.lastName) {
        loadIntraSystem(charData);
    }
}

function loadIntraSystem(charData) {
    //console.log('Loading system for:', charData.firstName, charData.lastName);
    
    const loadingText = document.getElementById('loadingText');
    if (loadingText) {
        loadingText.textContent = 'Loading system for ' + charData.firstName + ' ' + charData.lastName + '...';
    }
    
    const characterName = charData.firstName + ' ' + charData.lastName;
    const url = intraURL + '?charactername=' + encodeURIComponent(characterName);
    
    //console.log('Loading URL:', url);
    
    // Add to navigation history
    addToHistory(url);
    currentUrl = url;
    updatePageTitle('IntraRP Verwaltungsportal');
    
    const iframe = document.getElementById('tabletScreen');
    const loadingScreen = document.getElementById('loadingScreen');
    
    if (iframe) {
        iframe.src = url;
        
        setTimeout(() => {
            if (loadingScreen) loadingScreen.style.display = 'none';
            iframe.style.display = 'block';
            updateNavigationButtons();
        }, 2000);
    }
}

function closeTablet() {
    console.log('Closing tablet');
    
    isTabletOpen = false;
    const tabletContainer = document.getElementById('tabletContainer');
    const tabletScreen = document.getElementById('tabletScreen');
    
    if (tabletContainer) {
        tabletContainer.style.display = 'none';
        document.body.style.cursor = 'default';
    }
    if (tabletScreen) {
        tabletScreen.src = '';
        tabletScreen.style.display = 'none';
    }
    
    fetch(`https://${GetParentResourceName()}/closeTablet`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({})
    }).catch(error => {
        console.error('Error closing tablet:', error);
    });
}

// Navigation functions
function addToHistory(url) {
    if (historyIndex < navigationHistory.length - 1) {
        navigationHistory = navigationHistory.slice(0, historyIndex + 1);
    }
    
    navigationHistory.push(url);
    historyIndex = navigationHistory.length - 1;
    
    if (navigationHistory.length > 50) {
        navigationHistory = navigationHistory.slice(-50);
        historyIndex = navigationHistory.length - 1;
    }
}

function updateNavigationButtons() {
    const backBtn = document.getElementById('backBtn');
    
    if (backBtn) {
        if (historyIndex > 0) {
            backBtn.disabled = false;
            backBtn.style.opacity = '1';
        } else {
            backBtn.disabled = true;
            backBtn.style.opacity = '0.4';
        }
    }
}

function updatePageTitle(title) {
    const pageTitle = document.getElementById('pageTitle');
    if (pageTitle) {
        pageTitle.textContent = title;
    }
}

function goBack() {
    if (!isTabletOpen || historyIndex <= 0) {
        console.log('Cannot go back');
        return;
    }
    
    historyIndex--;
    const previousUrl = navigationHistory[historyIndex];
    
    if (previousUrl) {
        currentUrl = previousUrl;
        const iframe = document.getElementById('tabletScreen');
        const loadingScreen = document.getElementById('loadingScreen');
        
        if (iframe && loadingScreen) {
            loadingScreen.style.display = 'flex';
            iframe.style.display = 'none';
            iframe.src = previousUrl;
            
            setTimeout(() => {
                loadingScreen.style.display = 'none';
                iframe.style.display = 'block';
            }, 1000);
        }
        
        updateNavigationButtons();
        console.log('Navigated back to:', previousUrl);
    }
}

function goHome() {
    if (!isTabletOpen || !characterData) {
        console.log('Cannot go home');
        return;
    }
    
    const characterName = characterData.firstName + ' ' + characterData.lastName;
    const homeUrl = intraURL + '?charactername=' + encodeURIComponent(characterName);
    
    addToHistory(homeUrl);
    currentUrl = homeUrl;
    
    const iframe = document.getElementById('tabletScreen');
    const loadingScreen = document.getElementById('loadingScreen');
    
    if (iframe && loadingScreen) {
        loadingScreen.style.display = 'flex';
        iframe.style.display = 'none';
        iframe.src = homeUrl;
        
        setTimeout(() => {
            loadingScreen.style.display = 'none';
            iframe.style.display = 'block';
        }, 1000);
    }
    
    updateNavigationButtons();
    updatePageTitle('IntraRP Verwaltungsportal');
    console.log('Navigated to home:', homeUrl);
}

function refreshPage() {
    if (!isTabletOpen || !currentUrl) {
        console.log('Cannot refresh');
        return;
    }
    
    const iframe = document.getElementById('tabletScreen');
    const loadingScreen = document.getElementById('loadingScreen');
    
    if (iframe && loadingScreen) {
        loadingScreen.style.display = 'flex';
        iframe.style.display = 'none';
        iframe.src = 'about:blank';
        
        setTimeout(() => {
            iframe.src = currentUrl;
            setTimeout(() => {
                loadingScreen.style.display = 'none';
                iframe.style.display = 'block';
            }, 1000);
        }, 100);
    }
    
    console.log('Refreshed page:', currentUrl);
}

// Handle ESC key
function handleEscapeKey(event) {
    if (event.key === 'Escape' && isTabletOpen) {
        event.preventDefault();
        event.stopPropagation();
        closeTablet();
        return false;
    }
}

// Add event listeners when DOM is ready
function addEventListeners() {
    document.addEventListener('keydown', handleEscapeKey, true);
    document.addEventListener('keyup', function(e) {
        if (e.key === 'Escape' && isTabletOpen) {
            e.preventDefault();
            e.stopPropagation();
            return false;
        }
    }, true);
    
    document.addEventListener('contextmenu', function(e) {
        e.preventDefault();
        return false;
    });
    
    document.addEventListener('mousemove', function() {
        if (isTabletOpen) {
            document.body.style.cursor = 'default';
        }
    });
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addEventListeners);
} else {
    addEventListeners();
}
