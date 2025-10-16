#!/bin/bash
set -e

# --- Configuration ---
JAVA_CACERTS="${JAVA_HOME}/lib/security/cacerts"
MERGED_JKS="merged-cacerts.jks"
SECRET_NAME="uows-cacerts"
NAMESPACE="apps"
PEM_ROOT="stfc-root.pem"
PEM_INTERMEDIATE="stfc-intermediate.pem"

# --- Step 1: Copy default Java cacerts ---
cp "$JAVA_CACERTS" "$MERGED_JKS"

# --- Step 2: Import PEM certificates ---
keytool -importcert -trustcacerts -alias stfc-root-ca \
    -file "$PEM_ROOT" -keystore "$MERGED_JKS" \
    -storepass changeit -noprompt

keytool -importcert -trustcacerts -alias stfc-intermediate-ca \
    -file "$PEM_INTERMEDIATE" -keystore "$MERGED_JKS" \
    -storepass changeit -noprompt

# --- Step 3: Create Kubernetes Secret via kubectl ---
kubectl create secret generic "$SECRET_NAME" \
    --from-file=cacerts.jks="$MERGED_JKS" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml > "${SECRET_NAME}.yaml"

echo "Secret YAML created: ${SECRET_NAME}.yaml"
