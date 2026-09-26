#!/bin/bash
set -e

# --- ПАРАМЕТРЫ ---
PREFIX="bashirov-04"

echo "=== Удаление виртуальных машин ==="
yc compute instance delete "$PREFIX-app-1"
yc compute instance delete "$PREFIX-app-2"

echo "=== Удаление подсети и сети ==="
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"

echo "=== Проверка очистки ресурсов ==="
yc compute instance list
yc compute disk list
yc vpc network list

