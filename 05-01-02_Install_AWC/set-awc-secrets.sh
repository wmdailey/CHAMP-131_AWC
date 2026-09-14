#!/usr/bin/env bash
# set-awc-secrets.sh — master setup script for exercise 05-01-02
# "Installing Anywhere Cloud Console".
#
# Two independent duties:
#
#   1. SOURCE the script (no flags) to interactively set and export the
#      eight shell environment variables that Phase A depends on:
#
#          source ./set-awc-secrets.sh
#
#   2. EXECUTE the script with a per-secret flag to create one Kubernetes
#      resource at a time, reading the values it needs from the environment
#      variables you exported in step 1:
#
#          ./set-awc-secrets.sh --verify-env  # confirm the eight env vars are set
#          ./set-awc-secrets.sh --namespace   # create the awc-core namespace
#          ./set-awc-secrets.sh --ccf         # create the CCF API secret
#          ./set-awc-secrets.sh --reg         # create the registry pull secret
#          ./set-awc-secrets.sh --route       # create the Route53 creds secret
#          ./set-awc-secrets.sh --ldap        # create the LDAP admin secret
#          ./set-awc-secrets.sh --all         # namespace + all four secrets
#          ./set-awc-secrets.sh --check       # verify everything exists
#          ./set-awc-secrets.sh --delete      # delete all four secrets (keep ns)
#          ./set-awc-secrets.sh -h            # print usage
#
# The env-var flow MUST be sourced (child-shell exports don't reach the
# parent). The kubectl-side flows can be either sourced or executed — the
# script picks the correct return/exit path at runtime.
#
# Note on secret keys: the shell-side variables the student types in are
# named CCF_* (CCF_API_HOST, CCF_ACCESS_KEY, CCF_SECRET_KEY, …) because
# CCF is the product name the credentials belong to. The Kubernetes
# secret this script creates uses TWO different key-naming conventions,
# because the AWC Console binary reads its config from env vars with two
# different hardcoded prefixes:
#
#   TAIKUN_*        — CCF/Taikun API auth: API host, project id, robot
#                     access/secret, account name, organization id.
#   MARKETPLACE_*   — marketplace catalog sync loop: registry URL and
#                     poll interval. These keys are BARE (no TAIKUN_
#                     prefix). If you set them as TAIKUN_MARKETPLACE_*
#                     the console silently ignores them and the
#                     marketplace stays empty — no error is surfaced
#                     anywhere.
#
# `envFrom: secretRef:` injects every key of this secret verbatim as an
# env var into the pod, so the key names must match what the app looks
# up. The values are copied through unchanged; only the mapping label
# differs between shell-side names and secret-side names.

# =========================================================================
# Constants
# =========================================================================

NAMESPACE="awc-core"
CCF_SECRET="awc-taikun-secrets"
REG_SECRET="awc-console-registry-creds"
LDAP_SECRET="ldap-bootstrap-credentials"

# AWC marketplace values that are the same for every student in this
# training tenant. Kept out of the sourced-flow env vars because they are
# not credentials; they are baked-in configuration.
AWC_MARKETPLACE_REGISTRIES="container.repository.cloudera.com/cloudera/awc/marketplace"
AWC_MARKETPLACE_SYNC_INTERVAL="60"
CCF_API_HOST="api.ccf-preprod.internal.cloudera.com"
CCF_ACCOUNT_NAME="cloudera"
CCF_ORGANIZATION_ID="109"

# The three Cloudera private registries. All three authenticate with the
# same paywall credentials.
REG_CONTAINER="container.repository.cloudera.com"
REG_DOCKER_PRIVATE="docker-private.infra.cloudera.com"
REG_DOCKER_SANDBOX="docker-sandbox.infra.cloudera.com"

# =========================================================================
# Meta functions
# =========================================================================

# Print the -h/--help usage block.
usage() {
    cat <<'USAGE'
Usage:
  source ./set-awc-secrets.sh          Interactively set eight env vars (must source).
  ./set-awc-secrets.sh --verify-env    Confirm the eight env vars are set (OK/MISSING).
  ./set-awc-secrets.sh --namespace     Create the awc-core namespace.
  ./set-awc-secrets.sh --ccf           Create the CCF API secret.
  ./set-awc-secrets.sh --reg           Create the registry pull secret.
  ./set-awc-secrets.sh --route         Create the AWS Route53 creds secret.
  ./set-awc-secrets.sh --ldap          Create the LDAP admin secret.
  ./set-awc-secrets.sh --all           namespace + all four secrets, in order.
  ./set-awc-secrets.sh --check         Verify namespace and all four secrets.
  ./set-awc-secrets.sh --delete        Delete all four secrets (namespace kept).
  ./set-awc-secrets.sh -h | --help     Show this message.

Environment variables prompted for by the sourced flow (in order):

  STUDENT_NUMBER                       (default 33)

  ── CCF Robot User (from 04-01-02) ──
  CCF_PROJECT_ID                       (echoed)
  CCF_ACCESS_KEY                       (hidden)
  CCF_SECRET_KEY                       (hidden)

  ── Cloudera paywall (private registries) ──
  PAYWALL_USER                         (echoed)
  PAYWALL_PASS                         (hidden)

  ── IAM user student${N}-awc (from 03-02-03) ──
  STUDENT${N}_ACCESS_KEY_ID            (echoed)
  STUDENT${N}_SECRET_ACCESS_KEY        (hidden)

  ── AWC Console admin bootstrap password ──
  ADMIN_PASSWORD                       (hidden)

Purpose of each secret (all live in namespace awc-core):

  --ccf creates awc-taikun-secrets  [type Opaque, 8 keys]
      Feeds the running AWC Console the credentials it needs to
      authenticate back to the CCF API and read the
      marketplace catalog. Contains three CCF identifiers
      (project id, access key, secret key) plus five tenant-wide
      constants (marketplace URL, sync interval, API host,
      account name, organization id). The keys inside the secret
      use two different naming conventions, matching the two
      hardcoded prefixes the console binary looks for:
        - TAIKUN_*        for the CCF API auth keys
        - MARKETPLACE_*   (bare, no TAIKUN_ prefix) for the
                          marketplace catalog registry URL and
                          sync interval
      If you set the marketplace keys with a TAIKUN_ prefix the
      console silently ignores them and the marketplace stays
      empty. The shell-side variable names remain CCF_* — only
      the secret-side key names take these two prefixes.

  --reg creates awc-console-registry-creds  [type kubernetes.io/dockerconfigjson]
        and container.repository.cloudera.com  [same type, alias]
      A docker-registry secret used to pull AWC images from the
      three private Cloudera registries — container.repository.
      cloudera.com, docker-private.infra.cloudera.com, and
      docker-sandbox.infra.cloudera.com. The same paywall
      username/password authenticates to all three; the script
      computes the base64 auth string, builds a docker-config
      JSON in a temp file, hands it to kubectl, and shreds the
      temp file.
      Two Kubernetes-side names for the same docker-config: the
      canonical awc-console-registry-creds (set as
      global.registryCredsSecret in the CCF UI) and a hostname-
      named alias container.repository.cloudera.com. Several
      AWC sub-chart pre-install Jobs (patch-registry-creds,
      patch-ldap-creds, patch-external-dns-creds) ignore the
      global and fall back to the registry hostname as the
      pull-secret name — creating both here means every
      image-pull path resolves without a second CCF UI knob.

  --route creates student${N}-route53-creds  [type Opaque, 2 keys]
      aws-access-key-id and aws-secret-access-key. Read at
      runtime by the external-dns sidecar so it can write DNS
      records for console.<your-cluster-domain> into Route 53.
      The cluster domain is whatever your CCF admin provisioned
      as your per-student Route 53 hosted zone — read it out of
      Route 53 with:
        aws route53 list-hosted-zones \
          --query 'HostedZones[?Config.PrivateZone==`false`].Name' \
          --output text
      and use that zone name as your dns.baseDomain in 05-01-02.

  --ldap creates ldap-bootstrap-credentials  [type Opaque, 2 keys]
      username=admin and password=$ADMIN_PASSWORD. Read once at
      install time by the Console's Knox LDAP module to seed the
      bootstrap admin account you sign in with the first time.

  --delete removes all four secrets from the awc-core namespace.
      Uses `kubectl delete --ignore-not-found` so it is idempotent
      and safe to re-run. The namespace itself is left in place —
      re-run --ccf/--reg/--route/--ldap (or --all) to recreate.
      Does NOT touch the AWC Console Helm release; if you want to
      fully tear down the installed Console, `helm uninstall` it
      first, then run --delete.

Sourced-flow behavior:
  - Hidden prompts do not echo what you type.
  - Press Enter at any prompt to keep the value already in the shell.
  - The summary prints variable names and lengths only, never values.
  - Nothing is written to disk; values live only in the current shell.

Order for exercise 05-01-02:
  1.  source ./set-awc-secrets.sh      # set the eight env vars
  2.  ./set-awc-secrets.sh --verify-env # confirm the eight env vars are set
  3.  ./set-awc-secrets.sh --namespace  # namespace first
  4.  ./set-awc-secrets.sh --ccf
  5.  ./set-awc-secrets.sh --reg
  6.  ./set-awc-secrets.sh --route
  7.  ./set-awc-secrets.sh --ldap
  8.  ./set-awc-secrets.sh --check      # verify all four before moving on

Or in one shot after sourcing:
  1.  source ./set-awc-secrets.sh
  2.  ./set-awc-secrets.sh --verify-env
  3.  ./set-awc-secrets.sh --all
  4.  ./set-awc-secrets.sh --check

Every secret-create call uses `--dry-run=client -o yaml | kubectl apply -f -`
so re-running is safe — the existing secret is patched, not duplicated.
USAGE
}

# Refuse to continue if the script was executed instead of sourced. Used
# only by the sourced env-setup flow, not by the executable secret flags.
#   $1 = "1" if sourced, "0" otherwise
require_sourced() {
    if [ "${1:-0}" != "1" ]; then
        echo "ERROR: this flow must be sourced; do not execute it." >&2
        echo "       source ./set-awc-secrets.sh" >&2
        echo "       (run with -h for full usage)" >&2
        exit 1
    fi
}

# Verify every environment variable the kubectl-side flows will read is
# present and non-empty. Returns 1 (and prints what is missing) if any
# variable is unset. Uses STUDENT_NUMBER to name the two IAM-key vars.
require_env_vars() {
    local _n="${STUDENT_NUMBER:-33}"
    local _missing=0 _v _val
    for _v in CCF_PROJECT_ID CCF_ACCESS_KEY CCF_SECRET_KEY \
             PAYWALL_USER PAYWALL_PASS \
             "STUDENT${_n}_ACCESS_KEY_ID" \
             "STUDENT${_n}_SECRET_ACCESS_KEY" \
             ADMIN_PASSWORD; do
        _val=$(printenv "$_v" 2>/dev/null || true)
        if [ -z "$_val" ]; then
            echo "MISSING env var: $_v" >&2
            _missing=1
        fi
    done
    if [ "$_missing" = "1" ]; then
        echo "" >&2
        echo "One or more required environment variables is unset." >&2
        echo "Run:  source ./set-awc-secrets.sh" >&2
        echo "then re-run this command." >&2
        return 1
    fi
    return 0
}

# Print an OK/MISSING report for every environment variable the kubectl-side
# flows will read, plus a chars-set length for each present one. Returns 0
# if every variable is set, 1 otherwise. Safe to run whether sourced or
# executed — it never touches the cluster.
verify_env() {
    local _n="${STUDENT_NUMBER:-33}"
    local _fail=0 _v _val
    echo "Env-var check (student ${_n}):"
    for _v in CCF_PROJECT_ID CCF_ACCESS_KEY CCF_SECRET_KEY \
             PAYWALL_USER PAYWALL_PASS \
             "STUDENT${_n}_ACCESS_KEY_ID" \
             "STUDENT${_n}_SECRET_ACCESS_KEY" \
             ADMIN_PASSWORD; do
        _val=$(printenv "$_v" 2>/dev/null || true)
        if [ -z "$_val" ]; then
            printf '  %-42s  MISSING\n' "$_v"
            _fail=1
        else
            printf '  %-42s  OK (%d chars)\n' "$_v" "${#_val}"
        fi
    done
    echo
    if [ "$_fail" = "0" ]; then
        echo "All eight variables are set. Next: ./set-awc-secrets.sh --all"
        return 0
    else
        echo "One or more variables is missing. Re-source and fill them in:" >&2
        echo "  source ./set-awc-secrets.sh" >&2
        return 1
    fi
}

# =========================================================================
# Env-setup functions (sourced flow)
# =========================================================================

# Prompt for STUDENT_NUMBER. Defaults to whatever is in the environment,
# or 33 if unset. Exports STUDENT_NUMBER back out.
ask_student_number() {
    local _default="${STUDENT_NUMBER:-33}"
    local _input=""
    printf 'Student number [%s]: ' "$_default"
    read -r _input
    STUDENT_NUMBER="${_input:-$_default}"
    export STUDENT_NUMBER
}

# Prompt for one variable and export it.
#   $1 = variable name
#   $2 = human-readable description
#   $3 = "1" to hide input, "0" to echo it
prompt_var() {
    local _name="$1" _desc="$2" _secret="$3"
    local _cur _hint="" _val=""
    _cur=$(printenv "$_name" 2>/dev/null || true)
    [ -n "$_cur" ] && _hint=" [${#_cur} chars set]"
    if [ "$_secret" = "1" ]; then
        printf '  %s%s: ' "$_desc" "$_hint"
        read -rs _val
        echo
    else
        printf '  %s%s: ' "$_desc" "$_hint"
        read -r _val
    fi
    if [ -n "$_val" ]; then
        export "$_name=$_val"
        echo "    → set $_name (${#_val} chars)"
    elif [ -n "$_cur" ]; then
        echo "    → kept existing $_name (${#_cur} chars)"
    else
        echo "    → WARNING: $_name is still empty"
    fi
    echo
}

print_intro() {
    echo
    echo "Setting Phase A credentials for student ${STUDENT_NUMBER}."
    echo "Press Enter at any prompt to keep the value shown in [brackets]."
    echo "Secret prompts do not echo what you type."
    echo
}

ask_taikun() {
    echo "── CCF Robot User (from 04-01-02) ──"
    prompt_var CCF_PROJECT_ID  "CCF Project ID"  0
    prompt_var CCF_ACCESS_KEY  "CCF Access Key"  1
    prompt_var CCF_SECRET_KEY  "CCF Secret Key"  1
}

ask_paywall() {
    echo "── Cloudera paywall (private registries) ──"
    prompt_var PAYWALL_USER "Paywall username" 0
    prompt_var PAYWALL_PASS "Paywall password" 1
}

ask_aws_keys() {
    local _n="$1"
    echo "── IAM user student${_n}-awc (from 03-02-03) ──"
    prompt_var "STUDENT${_n}_ACCESS_KEY_ID"     "IAM access-key ID"     0
    prompt_var "STUDENT${_n}_SECRET_ACCESS_KEY" "IAM secret access key" 1
}

ask_admin_password() {
    echo "── AWC Console admin bootstrap password ──"
    prompt_var ADMIN_PASSWORD "Admin password (LDAP bootstrap)" 1
}

print_summary() {
    local _n="$1"
    local _v _val
    echo "──────────────── Env-var Summary ────────────────"
    for _v in CCF_PROJECT_ID CCF_ACCESS_KEY CCF_SECRET_KEY \
             PAYWALL_USER PAYWALL_PASS \
             "STUDENT${_n}_ACCESS_KEY_ID" \
             "STUDENT${_n}_SECRET_ACCESS_KEY" \
             ADMIN_PASSWORD; do
        _val=$(printenv "$_v" 2>/dev/null || true)
        if [ -z "$_val" ]; then
            printf '  %-40s  MISSING\n' "$_v"
        else
            printf '  %-40s  OK (%d chars)\n' "$_v" "${#_val}"
        fi
    done
    echo "─────────────────────────────────────────────────"
    echo "Every variable above is exported into the current shell."
    echo "Next: ./set-awc-secrets.sh --all   (or --namespace, --ccf, …)"
}

# =========================================================================
# Secret-creation functions (executable flows)
# =========================================================================

# Create the awc-core namespace (idempotent).
create_namespace() {
    echo "── Namespace: $NAMESPACE ──"
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "  already exists, skipping"
    else
        kubectl create namespace "$NAMESPACE"
    fi
    echo
}

# Create the CCF API secret. Requires CCF_PROJECT_ID, CCF_ACCESS_KEY,
# CCF_SECRET_KEY in the environment.
#
# NB: this secret uses TWO different key-naming conventions, matching
# two independent hardcoded prefixes the AWC Console binary reads:
#
#   TAIKUN_API_HOST, TAIKUN_ACCOUNT_NAME, TAIKUN_ORGANIZATION_ID,
#   TAIKUN_PROJECT_ID, TAIKUN_ACCESS_KEY, TAIKUN_SECRET_KEY
#       → CCF/Taikun API authentication. TAIKUN_ prefix is required.
#
#   MARKETPLACE_REGISTRIES, MARKETPLACE_SYNC_INTERVAL
#       → marketplace catalog OCI sync loop. NO TAIKUN_ prefix. If
#         you accidentally name these TAIKUN_MARKETPLACE_* the
#         console silently ignores them and the marketplace stays
#         empty with no error surfaced anywhere.
#
# `envFrom: secretRef:` injects every key of this secret verbatim as an
# env var into the pod, so the key names must match what the app looks
# up. The shell-side variables the student types remain CCF_* because
# CCF is the product name the credentials belong to; only the
# secret-side key names take these two prefixes.
create_ccf_secret() {
    require_env_vars || return 1
    echo "── Secret: $CCF_SECRET in $NAMESPACE ──"
    kubectl -n "$NAMESPACE" create secret generic "$CCF_SECRET" \
        --from-literal=MARKETPLACE_REGISTRIES="$AWC_MARKETPLACE_REGISTRIES" \
        --from-literal=MARKETPLACE_SYNC_INTERVAL="$AWC_MARKETPLACE_SYNC_INTERVAL" \
        --from-literal=TAIKUN_API_HOST="$CCF_API_HOST" \
        --from-literal=TAIKUN_ACCOUNT_NAME="$CCF_ACCOUNT_NAME" \
        --from-literal=TAIKUN_ORGANIZATION_ID="$CCF_ORGANIZATION_ID" \
        --from-literal=TAIKUN_PROJECT_ID="$CCF_PROJECT_ID" \
        --from-literal=TAIKUN_ACCESS_KEY="$CCF_ACCESS_KEY" \
        --from-literal=TAIKUN_SECRET_KEY="$CCF_SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo
}

# Create the registry pull secret. Requires PAYWALL_USER, PAYWALL_PASS.
create_reg_secret() {
    require_env_vars || return 1
    echo "── Secret: $REG_SECRET in $NAMESPACE ──"

    # Step 1: base64-encode "user:pass" as a single line (no trailing NL,
    # no wrapping).
    local _b64
    _b64=$(printf '%s:%s' "$PAYWALL_USER" "$PAYWALL_PASS" | base64 | tr -d '\n')

    # Step 2: write a docker-config JSON to a mode-600 tempfile.
    local _tmp
    _tmp=$(mktemp -t awc-dockerconfig.XXXXXX) || return 1
    chmod 600 "$_tmp"
    cat > "$_tmp" <<EOF
{
  "auths": {
    "$REG_DOCKER_PRIVATE": {"auth": "$_b64"},
    "$REG_DOCKER_SANDBOX": {"auth": "$_b64"},
    "$REG_CONTAINER":      {"auth": "$_b64"}
  }
}
EOF

    # Step 3: hand the file to kubectl — create the canonical name.
    kubectl -n "$NAMESPACE" create secret generic "$REG_SECRET" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="$_tmp" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Step 3b: create a hostname-named alias of the same secret.
    #
    # The Anywhere Cloud umbrella chart honors global.registryCredsSecret
    # for the top-level Deployment, but several pre-install patch Jobs
    # (patch-registry-creds, patch-ldap-creds, patch-external-dns-creds)
    # ship with a hardcoded default of the registry hostname as the
    # secret name — they read spec.template.spec.imagePullSecrets from
    # their own sub-chart values.yaml, which is not overridden by the
    # global. Symptom when the alias is missing:
    #   FailedToRetrieveImagePullSecret ... Unable to retrieve some
    #   image pull secrets (container.repository.cloudera.com)
    # followed by ImagePullBackOff on every patch-* pre-install Job,
    # which blocks the install indefinitely.
    #
    # Creating both names atomically here means every image-pull path
    # resolves without requiring students to touch a second knob in the
    # CCF UI. Same docker-config JSON, different Kubernetes name.
    kubectl -n "$NAMESPACE" create secret generic "$REG_CONTAINER" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="$_tmp" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Step 4: shred the tempfile and clear the in-memory base64.
    shred -u "$_tmp" 2>/dev/null || rm -f "$_tmp"
    unset _b64
    echo
}

# Create the per-student AWS credentials secret used by external-dns.
#
# external-dns runs in its own namespace (external-dns), but this secret is
# authored in awc-core. Emberstack Reflector — installed by the AWC umbrella
# chart — mirrors annotated secrets into the namespaces listed on
# reflection-auto-namespaces. Without those three annotations, external-dns
# starts up with CreateContainerConfigError ("secret not found") and no DNS
# records are ever written, which is what the DNS section of the exercise
# turns on. Annotate at creation time so the mirror happens as soon as
# reflector's HelmRelease reconciles.
create_route_secret() {
    require_env_vars || return 1
    local _n="${STUDENT_NUMBER:-33}"
    local _secret="student${_n}-route53-creds"
    local _key_id_var="STUDENT${_n}_ACCESS_KEY_ID"
    local _key_sk_var="STUDENT${_n}_SECRET_ACCESS_KEY"
    local _key_id _key_sk
    _key_id=$(printenv "$_key_id_var")
    _key_sk=$(printenv "$_key_sk_var")

    echo "── Secret: $_secret in $NAMESPACE ──"
    kubectl -n "$NAMESPACE" create secret generic "$_secret" \
        --from-literal=aws-access-key-id="$_key_id" \
        --from-literal=aws-secret-access-key="$_key_sk" \
        --dry-run=client -o yaml | kubectl apply -f -
    unset _key_id _key_sk

    # Annotate for Reflector auto-mirroring into external-dns namespace.
    # --overwrite so re-running --route on an existing secret updates the
    # annotations rather than erroring on "already exists".
    kubectl -n "$NAMESPACE" annotate secret "$_secret" \
        reflector.v1.k8s.emberstack.com/reflection-allowed=true \
        reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
        reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=external-dns \
        --overwrite >/dev/null
    echo
}

# Create the LDAP bootstrap-admin secret.
create_ldap_secret() {
    require_env_vars || return 1
    echo "── Secret: $LDAP_SECRET in $NAMESPACE ──"
    kubectl -n "$NAMESPACE" create secret generic "$LDAP_SECRET" \
        --from-literal=username=admin \
        --from-literal=password="$ADMIN_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo
}

# Run every kubectl-side step in the exercise order.
create_all() {
    require_env_vars   || return 1
    create_namespace   || return 1
    create_ccf_secret  || return 1
    create_reg_secret  || return 1
    create_route_secret || return 1
    create_ldap_secret || return 1
}

# Delete all four secrets from the awc-core namespace. Idempotent: uses
# --ignore-not-found so a missing secret is a no-op, not an error. Does
# NOT delete the namespace itself — re-run --ccf/--reg/--route/--ldap
# (or --all) to recreate the secrets into the same namespace.
delete_all_secrets() {
    local _n="${STUDENT_NUMBER:-33}"
    local _aws_secret="student${_n}-route53-creds"

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "Namespace $NAMESPACE does not exist — nothing to delete."
        return 0
    fi

    echo "── Deleting secrets from $NAMESPACE ──"
    kubectl -n "$NAMESPACE" delete secret --ignore-not-found \
        "$CCF_SECRET" \
        "$REG_SECRET" \
        "$REG_CONTAINER" \
        "$_aws_secret" \
        "$LDAP_SECRET"
    echo
    echo "Done. Namespace $NAMESPACE was kept — re-run --all (or the"
    echo "per-secret flags) to recreate the four secrets in it."
}

# =========================================================================
# Check function
# =========================================================================

# Inspect one secret. Prints one line: OK or MISSING (plus type + data
# key count when present). Returns 0 if present, 1 if missing.
#   $1 = secret name
#   $2 = expected type (for display only)
check_secret() {
    local _name="$1" _expected_type="$2"
    local _actual_type _data_json _n_keys
    _actual_type=$(kubectl -n "$NAMESPACE" get secret "$_name" \
        -o jsonpath='{.type}' 2>/dev/null || true)
    if [ -z "$_actual_type" ]; then
        printf '  %-42s  MISSING\n' "$_name"
        return 1
    fi
    _data_json=$(kubectl -n "$NAMESPACE" get secret "$_name" \
        -o jsonpath='{.data}' 2>/dev/null || true)
    _n_keys=$(printf '%s' "$_data_json" | tr ',' '\n' | grep -c ':' || true)
    printf '  %-42s  OK  (type=%s, %d keys)\n' \
        "$_name" "$_actual_type" "$_n_keys"
    if [ "$_actual_type" != "$_expected_type" ]; then
        printf '        ⚠ expected type %s, found %s\n' \
            "$_expected_type" "$_actual_type"
        return 1
    fi
    return 0
}

# Verify the namespace and all four secrets exist. Prints a summary and
# returns 0 iff everything is present and typed as expected.
check_all() {
    local _n="${STUDENT_NUMBER:-33}"
    local _aws_secret="student${_n}-route53-creds"
    local _fail=0

    echo "Namespace check:"
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        printf '  %-42s  OK\n' "$NAMESPACE"
    else
        printf '  %-42s  MISSING\n' "$NAMESPACE"
        _fail=1
    fi
    echo

    echo "Secrets check (in $NAMESPACE):"
    check_secret "$CCF_SECRET"     "Opaque"                          || _fail=1
    check_secret "$REG_SECRET"     "kubernetes.io/dockerconfigjson"  || _fail=1
    check_secret "$REG_CONTAINER"  "kubernetes.io/dockerconfigjson"  || _fail=1
    check_secret "$_aws_secret"    "Opaque"                          || _fail=1
    check_secret "$LDAP_SECRET"    "Opaque"                          || _fail=1
    echo

    if [ "$_fail" = "0" ]; then
        echo "All required resources present. Phase A complete — proceed to Phase B."
        return 0
    else
        echo "One or more required resources is missing or misconfigured." >&2
        echo "Re-run the missing create step, or './set-awc-secrets.sh --all'." >&2
        return 1
    fi
}

# =========================================================================
# Cleanup
# =========================================================================

# Unset every helper function and helper variable this script defines so
# the parent shell is not polluted after a source.
cleanup() {
    unset -f usage require_sourced require_env_vars verify_env
    unset -f ask_student_number prompt_var print_intro
    unset -f ask_taikun ask_paywall ask_aws_keys ask_admin_password
    unset -f print_summary
    unset -f create_namespace create_ccf_secret create_reg_secret
    unset -f create_route_secret create_ldap_secret create_all
    unset -f delete_all_secrets
    unset -f check_secret check_all
    unset -f main
    unset _AWC_SOURCED
    unset NAMESPACE CCF_SECRET REG_SECRET LDAP_SECRET
    unset AWC_MARKETPLACE_REGISTRIES AWC_MARKETPLACE_SYNC_INTERVAL
    unset CCF_API_HOST CCF_ACCOUNT_NAME CCF_ORGANIZATION_ID
    unset REG_CONTAINER REG_DOCKER_PRIVATE REG_DOCKER_SANDBOX
    # cleanup unsets itself last.
    unset -f cleanup
}

# =========================================================================
# main — dispatcher on $1
# =========================================================================
# Runs from the top-level statement at the very bottom. Reads
# $_AWC_SOURCED (set at top level) to choose return vs exit.
main() {
    local _was_sourced="${_AWC_SOURCED:-0}"
    local _rc=0

    case "${1:-}" in
        -h|--help)
            usage
            ;;
        --verify-env)
            verify_env
            _rc=$?
            ;;
        --namespace)
            create_namespace
            _rc=$?
            ;;
        --ccf)
            create_ccf_secret
            _rc=$?
            ;;
        --reg)
            create_reg_secret
            _rc=$?
            ;;
        --route)
            create_route_secret
            _rc=$?
            ;;
        --ldap)
            create_ldap_secret
            _rc=$?
            ;;
        --all)
            create_all
            _rc=$?
            ;;
        --check)
            check_all
            _rc=$?
            ;;
        --delete)
            delete_all_secrets
            _rc=$?
            ;;
        "")
            # Default: interactive env-var setup, must be sourced.
            require_sourced "$_was_sourced"
            ask_student_number
            print_intro
            ask_taikun
            ask_paywall
            ask_aws_keys "$STUDENT_NUMBER"
            ask_admin_password
            print_summary "$STUDENT_NUMBER"
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "       run with -h for usage" >&2
            _rc=2
            ;;
    esac

    cleanup
    [ "$_was_sourced" = "1" ] && return "$_rc" || exit "$_rc"
}

# =========================================================================
# Top-level orchestration
# =========================================================================
# Sourced-vs-executed MUST be detected here, at top level. The
# `(return 0 2>/dev/null)` idiom only works outside function scope.

_AWC_SOURCED=0
(return 0 2>/dev/null) && _AWC_SOURCED=1

main "$@"
