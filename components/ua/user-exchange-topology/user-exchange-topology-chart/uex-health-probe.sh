# This job will run everytime there is a change in any topology CR 
#!/bin/bash
set -e
MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
RABBITMQ_STATUS=false
VHOST_STATUS=false
VHOST="uex"
NODE="rabbit@rmq-message-broker-server-0.rmq-message-broker-nodes.apps"
RETRIES=0

echo "Checking RabbitMQ node status for node : $NODE"

# Check RabbitMQ status with retries
for ((i=1; i<=MAX_RETRIES; i++)); do
  if rabbitmqctl -n "$NODE" -l status > /dev/null 2>&1; then
    echo "RabbitMQ is ready."
    RABBITMQ_STATUS=true
    break
  fi

  # Sleep on the last attempt
  if (( i < MAX_RETRIES )); then
    echo "[$i/$MAX_RETRIES] RabbitMQ not ready. Retrying in ${SLEEP_SECONDS}s..."
    sleep "$SLEEP_SECONDS"
  else
    echo "[$i/$MAX_RETRIES] RabbitMQ not ready. No more attempts, giving up."
  fi
done

if ! $RABBITMQ_STATUS; then
  echo "RabbitMQ never became ready after $((MAX_RETRIES * SLEEP_SECONDS)) seconds."
  exit 1
fi

# Check if the vhost exists
for((i=1; i<=MAX_RETRIES; i++)); do
  if rabbitmqctl -n "$NODE" -l list_vhosts | grep -qx "$VHOST"; then
    echo "Vhost /$VHOST exists."
    VHOST_STATUS=true
    break
  fi

  # Sleep on the last attempt
  if (( i < MAX_RETRIES )); then
    echo "[$i/$MAX_RETRIES] Vhost /$VHOST not found. Retrying in ${SLEEP_SECONDS}s..."
    sleep "$SLEEP_SECONDS"
  else
    echo "[$i/$MAX_RETRIES] Vhost /$VHOST not found. No more attempts, giving up."
  fi
done

if ! $VHOST_STATUS; then
  echo "Vhost /$VHOST never became available after $((MAX_RETRIES * SLEEP_SECONDS)) seconds."
  exit 1
fi

# Check all queues exist
check_queue() {
  local queue=$1
  rabbitmqctl -n "$NODE" -l list_queues -p "$VHOST" name | grep -qw "$queue"
}

all_ready() {
  for queue in $(echo "$QUEUES" | tr ',' ' '); do
    if ! check_queue "$queue"; then
      echo "Queue '$queue' not ready yet..."
      return 1
    fi
  done
  return 0
}

until all_ready; do
  RETRIES=$((RETRIES + 1))
  if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
    echo "Max retries ($MAX_RETRIES) reached. Queues not ready."
    exit 1
  fi
  echo "Retry $RETRIES/$MAX_RETRIES - Waiting ${SLEEP_SECONDS}s..."
  sleep "$SLEEP_SECONDS"
done
echo "All queues are ready!"
exit 0