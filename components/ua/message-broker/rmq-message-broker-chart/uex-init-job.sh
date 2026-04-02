#!/bin/bash
set -e
echo "Checking RabbitMQ node status for node : rabbit@rmq-message-broker-server-0.rmq-message-broker-nodes.apps"

MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
RABBITMQ_STATUS=false

for i in $(seq 1 "$MAX_RETRIES"); do
  if rabbitmqctl -n rabbit@rmq-message-broker-server-0.rmq-message-broker-nodes.apps -l status > /dev/null 2>&1; then
    echo "RabbitMQ is ready."
    RABBITMQ_STATUS=true
    break
  fi

  echo "[$i/$MAX_RETRIES] RabbitMQ not ready. Retrying in ${SLEEP_SECONDS}s..."  

  # Don't sleep on the last attempt
  if [ "$i" -lt "$MAX_RETRIES" ]; then
    sleep "$SLEEP_SECONDS"
  fi
done

if [ "$RABBITMQ_STATUS" != true ]; then
  echo "RabbitMQ never became ready after $((MAX_RETRIES * SLEEP_SECONDS)) seconds."  
  exit 1
fi

echo "Enabling message tracing..."
rabbitmqctl -n rabbit@rmq-message-broker-server-0.rmq-message-broker-nodes.apps -l trace_on -p uex