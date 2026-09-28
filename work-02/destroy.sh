#!/usr/bin/env bash
set -euo pipefail

PREFIX="bashirov-04"

echo "=== Удаление балансировщика ==="
if yc load-balancer network-load-balancer get "$PREFIX-lb" >/dev/null 2>&1; then
  yc load-balancer network-load-balancer delete "$PREFIX-lb"
fi

echo "=== Удаление целевой группы ==="
if yc load-balancer target-group get "$PREFIX-tg" >/dev/null 2>&1; then
  yc load-balancer target-group delete "$PREFIX-tg"
fi

echo "=== Удаление всех виртуальных машин ==="
for vm in $(yc compute instance list --format json | jq -r --arg p "$PREFIX" '.[] | select(.name | startswith($p)) | .name'); do
  echo "Удаление $vm..."
  yc compute instance delete "$vm"
done

echo "=== Удаление диска данных ==="
if yc compute disk get "$PREFIX-data" >/dev/null 2>&1; then
  yc compute disk delete "$PREFIX-data"
fi

echo "=== Удаление подсетей ==="
if yc vpc subnet get "$PREFIX-subnet-a" >/dev/null 2>&1; then
  yc vpc subnet delete "$PREFIX-subnet-a"
fi
if yc vpc subnet get "$PREFIX-subnet-b" >/dev/null 2>&1; then
  yc vpc subnet delete "$PREFIX-subnet-b"
fi

echo "=== Удаление сети ==="
if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  yc vpc network delete "$PREFIX-net"
fi

echo "=== Проверка чистоты ресурсов ==="
yc compute instance list
yc compute disk list
yc load-balancer network-load-balancer list
yc vpc network list
