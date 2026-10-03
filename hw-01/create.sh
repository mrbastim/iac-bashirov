#!/usr/bin/env bash
set -euo pipefail

# 1. Приоритет параметров: CLI-аргумент > ENV > Дефолт из варианта
WEB_COUNT="${WEB_COUNT:-3}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-count|-w)
      WEB_COUNT="$2"
      shift 2
      ;;
    *)
      echo "Неизвестный параметр: $1" >&2
      exit 1
      ;;
  esac
done

PREFIX="bashirov-04"
ENV_NAME="stage"
ZONE_A="ru-central1-d"
ZONE_B="ru-central1-b"
CIDR_A="10.14.1.0/24"
CIDR_B="10.14.2.0/24"
APP_PORT=8012
GREETING="devlab"
BOOT_SIZE=15
IMAGE_FAMILY="ubuntu-2404-lts"

echo "=== 1. Сеть и подсети ==="
if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  echo "Сеть $PREFIX-net уже существует, пропускаю."
else
  yc vpc network create --name "$PREFIX-net" --labels "env=$ENV_NAME,owner=$PREFIX"
fi

if yc vpc subnet get "$PREFIX-subnet-a" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-a уже существует, пропускаю."
else
  yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
    --zone "$ZONE_A" --range "$CIDR_A" --labels "env=$ENV_NAME,owner=$PREFIX"
fi

if yc vpc subnet get "$PREFIX-subnet-b" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-b уже существует, пропускаю."
else
  yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
    --zone "$ZONE_B" --range "$CIDR_B" --labels "env=$ENV_NAME,owner=$PREFIX"
fi

echo "=== 2. NAT-шлюз и таблица маршрутизации ==="
if yc vpc gateway get "$PREFIX-nat" >/dev/null 2>&1; then
  echo "NAT-шлюз $PREFIX-nat уже существует, пропускаю."
else
  yc vpc gateway create --name "$PREFIX-nat" --labels "env=$ENV_NAME,owner=$PREFIX"
fi

GW_ID=$(yc vpc gateway get --name "$PREFIX-nat" --format json | jq -r .id)

if yc vpc route-table get "$PREFIX-rt" >/dev/null 2>&1; then
  echo "Таблица маршрутизации $PREFIX-rt уже существует, пропускаю."
else
  yc vpc route-table create --name "$PREFIX-rt" --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" --labels "env=$ENV_NAME,owner=$PREFIX"
  yc vpc subnet update --name "$PREFIX-subnet-a" --route-table-name "$PREFIX-rt"
fi

echo "=== 3. Генерация cloud-init ==="
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < hw-01/cloud-init.tpl.yaml > hw-01/cloud-init.yaml

echo "=== 4. Веб-серверы ($WEB_COUNT шт.) ==="
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  VM_NAME="$PREFIX-web-$i"
  if yc compute instance get "$VM_NAME" >/dev/null 2>&1; then
    echo "Машина $VM_NAME уже существует, пропускаю."
  else
    yc compute instance create \
      --name "$VM_NAME" \
      --zone "${ZONES[$idx]}" \
      --platform standard-v3 \
      --cores=2 --core-fraction=20 --memory=2 \
      --preemptible \
      --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
      --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
      --hostname "$VM_NAME" \
      --metadata-from-file user-data=hw-01/cloud-init.yaml \
      --labels "env=$ENV_NAME,owner=$PREFIX"
  fi
done

echo "=== 5. Сервер приложения (закрытый от интернета) ==="
APP_VM="$PREFIX-app-1"
if yc compute instance get "$APP_VM" >/dev/null 2>&1; then
  echo "Сервер приложения $APP_VM уже существует, пропускаю."
else
  # Без флага nat-ip-version=ipv4 — у машины ТОЛЬКО внутренний IP!
  yc compute instance create \
    --name "$APP_VM" \
    --zone "$ZONE_A" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet-a" \
    --hostname "$APP_VM" \
    --metadata-from-file user-data=hw-01/cloud-init.yaml \
    --labels "env=$ENV_NAME,owner=$PREFIX"
fi

echo "=== 6. Целевая группа и балансировщик ==="
TARGETS=""
for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-web-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done

if yc load-balancer target-group get "$PREFIX-tg" >/dev/null 2>&1; then
  echo "Целевая группа $PREFIX-tg уже существует, пропускаю."
else
  yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS --labels "env=$ENV_NAME,owner=$PREFIX"
fi

if yc load-balancer network-load-balancer get "$PREFIX-lb" >/dev/null 2>&1; then
  echo "Балансировщик $PREFIX-lb уже существует, пропускаю."
else
  TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)
  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --region-id ru-central1 \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/ \
    --labels "env=$ENV_NAME,owner=$PREFIX"
fi

echo "=== Стенд готов! ==="
yc compute instance list
yc load-balancer network-load-balancer list
