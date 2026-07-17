#!/bin/bash
# Sends requests every 0.5s and prints region/priority.
# Run this in one terminal, scale backends in another to watch failover live.
#
# Usage:
#   Terminal 1: ./test-failover.sh
#   Terminal 2:
#     kubectl -n failover-pg scale deployment nginx-omaha --replicas=0
#     kubectl -n failover-pg scale deployment nginx-east1 --replicas=0
#     kubectl -n failover-pg scale deployment nginx-omaha --replicas=1
#     kubectl -n failover-pg scale deployment nginx-east1 --replicas=1

GW_IP=$(kubectl -n kgateway-system get gateway failover-pg-gw -o jsonpath='{.status.addresses[0].value}')

echo "Gateway IP: $GW_IP"
echo "Sending requests every 0.5s — scale backends in another terminal to trigger failover"
echo "Ctrl+C to stop"
echo ""
printf "%-12s %-20s %-10s %-12s\n" "TIME" "REGION" "PRIORITY" "STATUS"
echo "------------------------------------------------------------"

while true; do
  BODY=$(curl -s -H "host: failover-pg.example.com" http://$GW_IP:8090/ 2>/dev/null)
  CODE=$?

  if [ $CODE -eq 0 ] && [ -n "$BODY" ]; then
    REGION=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['region'])" 2>/dev/null || echo "?")
    PRIO=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['priority'])" 2>/dev/null || echo "?")
    ST=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "?")
    printf "%-12s %-20s %-10s %-12s\n" "$(date +%H:%M:%S)" "$REGION" "$PRIO" "$ST"
  else
    printf "%-12s %-20s %-10s %-12s\n" "$(date +%H:%M:%S)" "---" "---" "no response"
  fi
  sleep 0.5
done
