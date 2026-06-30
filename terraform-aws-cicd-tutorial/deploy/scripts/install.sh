#!/bin/bash
set -eux

useradd --system --no-create-home --shell /sbin/nologin tutorial-app || true

chmod +x /opt/tutorial-app/tutorial-app
chown -R tutorial-app:tutorial-app /opt/tutorial-app

cat > /etc/systemd/system/tutorial-app.service <<'UNIT'
[Unit]
Description=Tutorial App
After=network.target

[Service]
User=tutorial-app
Group=tutorial-app
WorkingDirectory=/opt/tutorial-app
ExecStart=/opt/tutorial-app/tutorial-app
Restart=always
RestartSec=3
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable tutorial-app
