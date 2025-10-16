# Merging Java Truststore with Custom Certificates and Creating a Kubernetes Secret

## Overview
- Java applications use a truststore (cacerts) to validate SSL/TLS connections. The default truststore contains public CAs but not your internal/organizational CAs.
- This process merges your additional PEM CA certificates into a copy of the default Java truststore and packages it as a Kubernetes Secret. Your pods can mount the merged truststore at runtime without rebuilding images.

## What this folder contains
- `merge-cacerts.sh`: Bash script that copies the default Java truststore, imports the provided PEM certificates, and generates a Secret YAML via kubectl (dry-run).
- `stfc-root.pem` and `stfc-intermediate.pem`: Example PEM CA certificates that will be imported into the merged truststore.
- `uows-cacerts.yaml`: Example Secret manifest containing a pre-built merged truststore (`cacerts.jks`). You can use this as-is or regenerate it with the script.

## Prerequisites
- Java JDK installed. `keytool` must be available. `JAVA_HOME` should point to a JDK so that `${JAVA_HOME}/lib/security/cacerts` exists.
- `kubectl` installed and configured to access your Kubernetes cluster.
- The PEM certificates you want to trust (PEM/CRT format). By default, the script expects:
  - `stfc-root.pem`
  - `stfc-intermediate.pem`

## What the script does
1. Copies the default Java truststore to `merged-cacerts.jks`.
2. Imports two PEM certificates (`stfc-root.pem` and `stfc-intermediate.pem`) into `merged-cacerts.jks` using `keytool`.
3. Creates a Kubernetes Secret manifest (YAML) that includes the merged JKS. The default secret name is `uows-cacerts` and namespace is `apps`.

## Quick start
1. Place your PEM certificates in this directory (replace the example certificates if needed).
2. Make the script executable:
   
   ```bash
   chmod +x merge-cacerts.sh
   ```
3. Run the script:
   
   ```bash
   ./merge-cacerts.sh
   ```
   Output: `merged-cacerts.jks` and `uows-cacerts.yaml` (secret YAML).
4. Apply the generated Secret to your cluster:
   
   ```bash
   kubectl apply -f uows-cacerts.yaml
   ```

## Configuring your workload (mount and use the truststore)
- Mount the Secret as a volume and map the file to `/deployments/cacerts.jks`. Example (fragment):

  ```yaml
  volumes:
    - name: cacerts
      secret:
        secretName: uows-cacerts
  volumeMounts:
    - name: cacerts
      mountPath: /deployments/cacerts.jks
      subPath: cacerts.jks
  ```

- Tell your Java app to use the mounted truststore (commonly via JAVA_OPTS or container args/env):

  ```bash
  -Djavax.net.ssl.trustStore=/deployments/cacerts.jks
  -Djavax.net.ssl.trustStorePassword=changeit
  ```

## Customization
- Change secret name and namespace: Edit `SECRET_NAME` and `NAMESPACE` variables at the top of `merge-cacerts.sh` before running it.
- Change truststore password: The default password is `changeit` (the Java default). If you change it in the JKS, ensure your app uses the same password via the `trustStorePassword` JVM option.
- Add/remove certificates: Edit the import lines in `merge-cacerts.sh` to reference your own PEM files. You can add as many `keytool -importcert` lines as needed.

## Validating the result
- List secrets in the namespace:

  ```bash
  kubectl -n apps get secrets | grep uows-cacerts
  ```

- Inspect the mounted file inside a pod:

  ```bash
  kubectl -n apps exec -it <pod-name> -- ls -l /deployments
  kubectl -n apps exec -it <pod-name> -- keytool -list -keystore /deployments/cacerts.jks -storepass changeit | grep -E "stfc|your-ca"
  ```

## Troubleshooting
- JAVA_HOME not set or cacerts not found:

  ```bash
  # Ensure JAVA_HOME points to a JDK (not just a JRE). Example:
  export JAVA_HOME=/usr/lib/jvm/java-17
  ```

- keytool not found:

  ```bash
  # Ensure your JDK bin is on PATH
  export PATH="$JAVA_HOME/bin:$PATH"
  ```

- Permission denied when running the script:

  ```bash
  chmod +x merge-cacerts.sh
  # or
  bash merge-cacerts.sh
  ```

- Wrong namespace or cluster context:

  ```bash
  kubectl config get-contexts
  kubectl config use-context <desired-context>
  ```
  Adjust `NAMESPACE` in the script or pass `-n <ns>` when applying the YAML.

- Import prompts from keytool:
  The script uses `-noprompt`, but if you manually run `keytool`, use `-noprompt` to avoid interactive confirmation.

## Security notes
- CA certificates are generally public, but treat any private or internal CA material with care. Store only what is necessary in your repo.
- If you need to rotate or add a CA, re-run the script to generate a new merged truststore and apply the updated Secret. Rolling restarts will pick up the new Secret when pods are recreated.
- For CI/CD, you can modify the script to directly apply the Secret (remove `--dry-run` and `-o yaml`) or keep YAML generation for review and GitOps workflows.

## Reference: Script defaults (for convenience)
- Secret name: `uows-cacerts`
- Secret namespace: `apps`
- Truststore filename inside the Secret: `cacerts.jks`
- Truststore password: `changeit`
- Imported PEMs: `stfc-root.pem`, `stfc-intermediate.pem`
