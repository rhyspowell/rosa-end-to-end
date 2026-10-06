#!/bin/bash
set -euxo pipefail

dnf install -y nginx

cat > /usr/share/nginx/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>hello</title>
  <style>
    body {
      background: #87CEEB;
      font-family: sans-serif;
      font-size: 2rem;
      margin: 2rem;
    }
  </style>
</head>
<body>
hello<br>
{{name}}
</body>
</html>
EOF

systemctl enable nginx
systemctl start nginx
