#!/bin/bash
set -e
MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
RABBITMQ_STATUS=false
NODE="rabbit@rmq-message-broker-server-0.rmq-message-broker-nodes.apps"

echo "Checking RabbitMQ node status for node : $NODE"

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

echo "Enabling message tracing..."
rabbitmqctl -n "$NODE" -l trace_on -p uex
