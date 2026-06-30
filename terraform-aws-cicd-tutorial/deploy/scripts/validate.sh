#!/bin/bash
set -eux

for i in $(seq 1 30); do
  if curl -fsS http://localhost:8080/health; then
    exit 0
  fi
  sleep 2
done

journalctl -u tutorial-app --no-pager -n 100 || true
exit 1
