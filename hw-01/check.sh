#!/usr/bin/env bash

PREFIX="bashirov-04"
APP_PORT=8012
GREETING="devlab"
STATUS=0

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json 2>/dev/null | jq -r '.listeners[0].address // empty')

# Проверка 1: Балансировщик отвечает 200
if [ -n "$LB_IP" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 4 "http://$LB_IP" || true)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ балансировщик отвечает: 200"
  else
    echo "✗ балансировщик не отвечает: $HTTP_CODE"
    STATUS=1
  fi
else
  echo "✗ балансировщик $PREFIX-lb не найден или не имеет адреса"
  STATUS=1
fi

# Проверка 2: Ответы приходят больше чем с одной машины
if [ -n "$LB_IP" ]; then
  RESPONSES=$(for i in $(seq 1 10); do curl -s --connect-timeout 2 "http://$LB_IP" | grep -m1 -o "$GREETING on [a-z0-9-]*" || true; done)
  UNIQUE_COUNT=$(echo "$RESPONSES" | sort -u | grep -c . || true)
  HOSTS_LIST=$(echo "$RESPONSES" | sort -u | tr '\n' ' ')
  
  if [ "$UNIQUE_COUNT" -gt 1 ]; then
    echo "✓ ответили машины: $HOSTS_LIST"
  else
    echo "✗ ответила только одна машина или ответов нет: $HOSTS_LIST"
    STATUS=1
  fi
else
  echo "✗ невозможно проверить распределение (нет адреса балансировщика)"
  STATUS=1
fi

# Проверка 3: Сервер приложения доступен с веб-сервера по внутреннему адресу
APP_INTERNAL_IP=$(yc compute instance get "$PREFIX-app-1" --format json 2>/dev/null | jq -r '.network_interfaces[0].primary_v4_address.address // empty')
WEB1_EXTERNAL_IP=$(yc compute instance get "$PREFIX-web-1" --format json 2>/dev/null | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty')

if [ -n "$APP_INTERNAL_IP" ] && [ -n "$WEB1_EXTERNAL_IP" ]; then
  APP_HTTP=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 student@"$WEB1_EXTERNAL_IP" "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 http://$APP_INTERNAL_IP:$APP_PORT" 2>/dev/null || true)
  if [ "$APP_HTTP" = "200" ]; then
    echo "✓ сервер приложения ($APP_INTERNAL_IP) доступен с $PREFIX-web-1 по внутреннему адресу"
  else
    echo "✗ сервер приложения ($APP_INTERNAL_IP) недоступен с $PREFIX-web-1 (HTTP $APP_HTTP)"
    STATUS=1
  fi
else
  echo "✗ невозможно проверить сервер приложения (машины не найдены)"
  STATUS=1
fi

exit $STATUS
