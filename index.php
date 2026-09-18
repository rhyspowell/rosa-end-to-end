<?php
\$log_file = 'ips.txt';

// 1. Capture the current request's IP and timestamp
ip = _SERVER['REMOTE_ADDR'];
if (isset(\$_SERVER['HTTP_X_FORWARDED_FOR'])) {
    ip = _SERVER['HTTP_X_FORWARDED_FOR'];
}
\$timestamp = date('H:i:s');

// 2. Read existing IPs from the file
\$ips = [];
if (file_exists(\$log_file)) {
    \(ips = json_decode(file_get_contents(\)log_file), true) ?? [];
}

// 3. Add new IP to the top and limit to last 20 entries
array_unshift(\$ips, ['ip' => ip, 'timestamp' => timestamp]);
\(ips = array_slice(\)ips, 0, 20);
file_put_contents(\(log_file, json_encode(\)ips));

// 4. Handle AJAX requests to just return the JSON data
if (isset(\$_GET['ajax'])) {
    header('Content-Type: application/json');
    echo json_encode(\$ips);
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Live IP Tracker (PHP)</title>
    <style>
        body { font-family: sans-serif; margin: 40px; background: #f4f4f9; }
        ul { list-style: none; padding: 0; }
        li { background: white; margin: 5px 0; padding: 10px; border-radius: 4px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); display: flex; justify-content: space-between; }
        .time { color: #888; }
    </style>
</head>
<body>

    <h1>Live Requesting IP Addresses</h1>
    <ul id="ip-list">Loading live updates...</ul>

    <script>
        async function fetchIps() {
            try {
                // Fetch from the same page with the ?ajax=1 query parameter
                const response = await fetch('?ajax=1');
                const ips = await response.json();
                const listElement = document.getElementById('ip-list');
                
                listElement.innerHTML = ips.map(item => `
                    <li>
                        <strong>${item.ip}</strong> 
                        <span class="time">${item.timestamp}</span>
                    </li>
                `).join('');
            } catch (error) {
                console.error('Error fetching IPs:', error);
            }
        }

        fetchIps();
        setInterval(fetchIps, 2000); // Auto-update every 2 seconds
    </script>
</body>
</html>
