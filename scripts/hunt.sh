#!/usr/bin/env bash
# Hunt for free-tier capacity for the shape configured in hunt.config.
#
# Deliberately not `set -e`: a failed launch is the expected case, not an
# error, and the classifier below decides what each failure means.
set -uo pipefail

: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
: "${OCI_SUBNET_OCID:?OCI_SUBNET_OCID is required}"

# ---------------------------------------------------------------------------
# Configuration. hunt.config is the dashboard: one commented file holding
# every knob. An environment variable still wins over it, so a workflow step
# or a test can override a single value without editing the file -- hence the
# snapshot/restore around the source.
# ---------------------------------------------------------------------------
CONFIG_VARS="SHAPE SHAPE_IS_FLEX OCPU_LADDER GB_PER_OCPU MEMORY_GB BOOT_VOLUME_GB
             OS_NAME OS_VERSION DISPLAY_NAME STOP_AT_TOTAL_OCPUS INTERVAL JITTER
             PACE_CEILING MAX_UNKNOWN ROTATE_FAULT_DOMAINS LIMIT_CORE_NAME
             LIMIT_MEMORY_NAME CAPACITY_REPORT SSH_KEY_FILE HUNT_SECONDS"

HUNT_CONFIG="${HUNT_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hunt.config}"

declare -A ENV_OVERRIDE=()
for v in $CONFIG_VARS; do
  [ -n "${!v+set}" ] && ENV_OVERRIDE[$v]="${!v}"
done
if [ -r "$HUNT_CONFIG" ]; then
  # shellcheck disable=SC1090  # path is configuration, not a fixed file
  . "$HUNT_CONFIG"
  CONFIG_SOURCE="$HUNT_CONFIG"
else
  CONFIG_SOURCE="none (built-in defaults)"
fi
for v in "${!ENV_OVERRIDE[@]}"; do
  printf -v "$v" '%s' "${ENV_OVERRIDE[$v]}"
done

# Built-in defaults, used only when neither the environment nor hunt.config
# set the value. hunt.config is the place to change these.
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
SHAPE_IS_FLEX="${SHAPE_IS_FLEX:-true}"
OCPU_LADDER="${OCPU_LADDER:-1}"
GB_PER_OCPU="${GB_PER_OCPU:-6}"
# Note the "-" rather than ":-" on the three settings below: for these an
# empty value is a deliberate choice ("this shape has no such limit", "derive
# memory from the ratio"), and ":-" would silently put the default back.
MEMORY_GB="${MEMORY_GB-}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
DISPLAY_NAME="${DISPLAY_NAME:-ObliskIQ-lite}"
OS_NAME="${OS_NAME:-Canonical Ubuntu}"
OS_VERSION="${OS_VERSION:-24.04}"
SSH_KEY_FILE="${SSH_KEY_FILE:-ssh_key.pub}"
HUNT_SECONDS="${HUNT_SECONDS:-240}"
# Always Free Ampere A1 has been 2 OCPU / 12 GB in total since 15 June 2026;
# it was 4 OCPU / 24 GB before that. The tenancy's real service limits are
# read below and clamp this down further if they disagree.
STOP_AT_TOTAL_OCPUS="${STOP_AT_TOTAL_OCPUS:-2}"
INTERVAL="${INTERVAL:-75}"               # floor for seconds between attempts
JITTER="${JITTER:-5}"                    # random 0..JITTER-1s added to each wait
PACE_CEILING="${PACE_CEILING:-300}"
MAX_UNKNOWN="${MAX_UNKNOWN:-5}"
ROTATE_FAULT_DOMAINS="${ROTATE_FAULT_DOMAINS:-false}"
LIMIT_CORE_NAME="${LIMIT_CORE_NAME-standard-a1-core-count}"
LIMIT_MEMORY_NAME="${LIMIT_MEMORY_NAME-standard-a1-memory-count}"
CAPACITY_REPORT="${CAPACITY_REPORT:-false}"

OCI="${OCI_BIN:-oci}"
COMPARTMENT=$(printf '%s' "$OCI_COMPARTMENT_OCID" | tr -d ' \r\n\t"')
SUBNET=$(printf '%s' "$OCI_SUBNET_OCID" | tr -d ' \r\n\t"')

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }
emit()    { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$*" >> "$GITHUB_OUTPUT"; return 0; }

# Memory for a given OCPU count. A fixed (non-flex) shape has its memory set
# by Oracle, so MEMORY_GB is used verbatim; a flex shape derives it from the
# free tier's fixed GB-per-OCPU ratio.
mem_for() {
  if [ -n "$MEMORY_GB" ]; then printf '%s' "$MEMORY_GB"
  else printf '%s' "$(( $1 * GB_PER_OCPU ))"; fi
}

# The CLI writes a key-file label warning to stderr on every call; without this
# every JSON read would have to strip it.
export SUPPRESS_LABEL_WARNING=True

ocic() { "$OCI" --no-retry "$@"; }

# Run an oci command keeping the streams apart, because stdout is parsed as
# JSON and stderr carries warnings that would corrupt it. Sets OCI_OUT/OCI_ERR.
OCI_OUT=""; OCI_ERR=""
ocic_capture() {
  local err_file rc
  err_file=$(mktemp)
  OCI_OUT=$("$OCI" --no-retry "$@" 2>"$err_file")
  rc=$?
  OCI_ERR=$(cat "$err_file")
  rm -f "$err_file"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Classify an OCI error.
#
# Two rules govern the order and the patterns:
#
# 1. "Out of host capacity" is delivered as an HTTP 500 InternalError, so it
#    has to be matched before the generic 5xx rule, or every capacity miss
#    would look like a transient server fault.
# 2. HTTP status codes are matched against the "status" FIELD, never as bare
#    digits anywhere in the response. Every OCI error body carries an
#    opc-request-id of 30-odd alphanumeric characters, so "403" and "500"
#    appear inside perfectly ordinary responses by chance. Matching those
#    loose would classify a random capacity miss as an auth failure, and an
#    auth failure calls fail() and ends the run. Never loosen this.
# ---------------------------------------------------------------------------
status_is() {
  case "$CLASSIFY_MSG" in
    *"\"status\": $1"*|*"\"status\":$1"*|*"status: $1"*) return 0 ;;
    *) return 1 ;;
  esac
}

classify() {
  CLASSIFY_MSG=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$CLASSIFY_MSG" in
    *"out of host capacity"*|*"out of capacity"*|*"insufficient capacity"*|*"capacity is not available"*)
      echo capacity; return ;;
    *"too many requests"*|*toomanyrequests*|*"rate limit"*)
      echo throttled; return ;;
    *limitexceeded*|*"limit exceeded"*|*"quota"*|*"service limit"*|*"exceeded the limit"*)
      echo quota; return ;;
    *notauthenticated*|*notauthorized*|*"not authorized"*|*"authorization failed"*|*"invalid signature"*)
      echo auth; return ;;
    *invalidparameter*|*"cannot be null"*|*"is not valid"*|*notfound*|*"not found"*)
      echo badrequest; return ;;
    *internalerror*|*timeout*|*"timed out"*|*"connection"*)
      echo transient; return ;;
  esac

  # No recognisable error code in the text; fall back to the status field.
  if status_is 429; then echo throttled; return; fi
  if status_is 401 || status_is 403; then echo auth; return; fi
  if status_is 400 || status_is 404; then echo badrequest; return; fi
  if status_is 500 || status_is 502 || status_is 503 || status_is 504; then
    echo transient; return
  fi
  echo unknown
}

# Ease the pace back toward the floor by a quarter at a time.
ease_pace() {
  PACE=$(( PACE * 3 / 4 ))
  [ "$PACE" -lt "$INTERVAL" ] && PACE=$INTERVAL
  return 0
}

log "Config: $CONFIG_SOURCE"
log "Hunting for $SHAPE, sizes [$OCPU_LADDER] OCPU, stopping at ${STOP_AT_TOTAL_OCPUS} OCPU held."

# ---------------------------------------------------------------------------
# Pre-flight: never launch past the configured allowance.
#
# This is the guard that separates a hunter from a billing accident. It runs
# unattended and repeatedly, so without a count of what is already held every
# successful run would be followed by another launch, and the free tier is
# only free up to the allowance. Everything already held counts, including
# STOPPED instances -- Oracle bills the shape, not the uptime.
# ---------------------------------------------------------------------------
log "Checking what this compartment already holds..."
if ! ocic_capture compute instance list \
  --compartment-id "$COMPARTMENT" --all \
  --query "data[?\"shape\"=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].{n:\"display-name\",s:\"lifecycle-state\",o:\"shape-config\".ocpus}" \
  --output json; then
  echo "$OCI_ERR" >&2
  fail "Could not list existing instances; refusing to launch blind."
fi
EXISTING=$OCI_OUT

# A fixed shape reports no shape-config, so an instance of one counts as the
# single OCPU it has rather than as zero.
USED=$(printf '%s' "$EXISTING" | OCPUS_WHEN_NULL="$( [ "$SHAPE_IS_FLEX" = true ] && echo 0 || echo 1 )" python3 -c '
import os, sys, json
fallback = float(os.environ["OCPUS_WHEN_NULL"])
try:
    rows = json.loads(sys.stdin.read().strip() or "[]") or []
except Exception:
    sys.exit(9)
print(int(sum(float(r["o"]) if r.get("o") is not None else fallback for r in rows)))
' 2>/dev/null) || fail "Unexpected response while counting existing $SHAPE instances."

printf '%s' "$EXISTING" | python3 -c '
import sys, json
for r in json.loads(sys.stdin.read().strip() or "[]") or []:
    print(f"  - {r.get(\"n\")}: {r.get(\"s\")} ({r.get(\"o\")} OCPU)")
' 2>/dev/null

log "$SHAPE OCPUs already allocated: $USED."

# Service limits. Asking for more than the tenancy is allowed comes back as
# LimitExceeded, so read the limits and shrink the request to fit rather than
# spending attempts discovering it. Limits live on the tenancy (root
# compartment), which may not be the compartment we launch into.
TENANCY=$(printf '%s' "${OCI_TENANCY_OCID:-}" | tr -d ' \r\n\t"')
if [ -z "$TENANCY" ]; then
  TENANCY=$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' \
    "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" 2>/dev/null)
fi

read_limit() {
  ocic_capture limits value list -c "$1" --service-name compute --name "$2" --all \
    --query 'max(data[].value)' --raw-output || return 1
  printf '%s' "$OCI_OUT" | tr -cd '0-9'
}

CORE_LIMIT=""; MEM_LIMIT=""
if [ -n "$TENANCY" ] && [ -n "$LIMIT_CORE_NAME" ] && [ -n "$LIMIT_MEMORY_NAME" ]; then
  CORE_LIMIT=$(read_limit "$TENANCY" "$LIMIT_CORE_NAME")
  MEM_LIMIT=$(read_limit "$TENANCY" "$LIMIT_MEMORY_NAME")
elif [ -z "$LIMIT_CORE_NAME" ] || [ -z "$LIMIT_MEMORY_NAME" ]; then
  log "No service limit names configured for $SHAPE; skipping the limits check."
fi

# The tenancy's total allowance is the smallest of what hunt.config asks for,
# what the core limit allows, and what the memory limit allows at the fixed
# GB-per-OCPU ratio. These limits are totals for the tenancy, so what is left to
# hunt for is that total minus what is already running -- clamping the remainder
# to a total would ask for a second full allowance once the first one landed.
ALLOWANCE=$STOP_AT_TOTAL_OCPUS
if [ -n "$CORE_LIMIT" ] && [ -n "$MEM_LIMIT" ]; then
  log "Tenancy $SHAPE service limits: ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB."
  MEM_CAP=$(( MEM_LIMIT / GB_PER_OCPU ))
  [ "$CORE_LIMIT" -lt "$ALLOWANCE" ] && ALLOWANCE=$CORE_LIMIT
  [ "$MEM_CAP" -lt "$ALLOWANCE" ] && ALLOWANCE=$MEM_CAP
  if [ "$ALLOWANCE" -le 0 ]; then
    summary "### $SHAPE hunt stopped — no quota"
    summary "This tenancy's limit is ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB, so no $SHAPE instance of any size can be launched."
    summary "Raise it under Governance & Administration -> Limits, Quotas and Usage -> Compute -> ${LIMIT_CORE_NAME} (Request a service limit increase)."
    fail "This tenancy is allowed 0 $SHAPE capacity (limits: ${CORE_LIMIT} OCPU / ${MEM_LIMIT} GB). Request a service limit increase before hunting."
  fi
elif [ -n "$LIMIT_CORE_NAME" ]; then
  log "Could not read the $SHAPE service limits; going with the configured $STOP_AT_TOTAL_OCPUS OCPU."
fi

REMAINING=$(( ALLOWANCE - USED ))
log "Allowance ${ALLOWANCE} OCPU, ${USED} already allocated, ${REMAINING} left to hunt for."

if [ "$REMAINING" -le 0 ]; then
  log "The whole allowance is already allocated. Nothing to hunt."
  summary "### $SHAPE hunt — nothing to do"
  summary "All ${ALLOWANCE} allowed OCPUs are already allocated, so this run stopped without launching."
  emit "result=already-satisfied"
  exit 0
fi

# Only ladder rungs that still fit in the remaining allowance.
LADDER=()
for n in $OCPU_LADDER; do
  [ "$n" -le "$REMAINING" ] && LADDER+=("$n")
done
if [ ${#LADDER[@]} -eq 0 ]; then
  # Nothing to do rather than something broken: the allowance is partly used
  # and no configured size fits what is left. Exit green, because this runs
  # unattended and a permanently red run trains you to ignore it.
  echo "::warning::No size in OCPU_LADDER ('$OCPU_LADDER') fits the $REMAINING OCPU still available; nothing to hunt for."
  summary "### $SHAPE hunt — nothing that fits"
  summary "$REMAINING OCPU of the ${ALLOWANCE} OCPU allowance is unallocated, but no size in \`$OCPU_LADDER\` fits it. Add a smaller size to \`OCPU_LADDER\` in hunt.config to use the remainder."
  emit "result=no-fit"
  exit 0
fi
log "Sizes to try: ${LADDER[*]} OCPU."

# ---------------------------------------------------------------------------
# Resources: the image, and every availability domain.
#
# Every domain is rotated through, not just the first. Capacity is released
# per host pool, so a refusal in one availability domain says nothing at all
# about the next; trying only one throws away most of the places a free
# machine can appear.
# ---------------------------------------------------------------------------
ocic_capture compute image list \
  --compartment-id "$COMPARTMENT" \
  --operating-system "$OS_NAME" \
  --operating-system-version "$OS_VERSION" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query "data[?contains(\"display-name\", 'aarch64') && !contains(\"display-name\", 'Minimal')].id | [0]" \
  --raw-output
IMAGE_ID=$(printf '%s' "$OCI_OUT" | tr -d '[:space:]')

# aarch64 images only exist for Arm shapes; for anything else take the newest
# non-Minimal image of the requested OS instead.
if [ "${IMAGE_ID:0:11}" != "ocid1.image" ]; then
  ocic_capture compute image list \
    --compartment-id "$COMPARTMENT" \
    --operating-system "$OS_NAME" \
    --operating-system-version "$OS_VERSION" \
    --shape "$SHAPE" \
    --sort-by TIMECREATED --sort-order DESC \
    --query "data[?!contains(\"display-name\", 'Minimal')].id | [0]" \
    --raw-output
  IMAGE_ID=$(printf '%s' "$OCI_OUT" | tr -d '[:space:]')
fi

case "$IMAGE_ID" in
  ocid1.image.*) ;;
  *) fail "No $OS_NAME $OS_VERSION image found for $SHAPE. Response: ${OCI_ERR:-${OCI_OUT:-<empty>}}" ;;
esac
log "Image: $IMAGE_ID"

mapfile -t ADS < <(ocic iam availability-domain list \
  --compartment-id "$COMPARTMENT" --query 'data[].name' --output json 2>/dev/null \
  | python3 -c 'import sys,json; [print(x) for x in json.loads(sys.stdin.read() or "[]") or []]' 2>/dev/null)
[ ${#ADS[@]} -gt 0 ] || fail "Could not list availability domains for this compartment."
log "Availability domains: ${ADS[*]}"

# ---------------------------------------------------------------------------
# Capacity report: advisory only.
#
# Oracle offers CreateComputeCapacityReport to ask whether a shape can be
# placed before trying. It is used here purely to decide which availability
# domain to try FIRST, and never to skip a launch: oracle/oci-cli issue #748
# documents it reporting AVAILABLE for a domain where A1 launches failed and
# OUT_OF_HOST_CAPACITY for one where they succeeded, so acting on it would
# mean skipping the domain that would have won. Each run logs what it said
# against what the launches did, so its accuracy here can be judged on
# evidence rather than on Oracle's word.
# ---------------------------------------------------------------------------
declare -A REPORT_SAID=()

capacity_report() {
  [ "$CAPACITY_REPORT" = true ] || return 0
  if [ -z "$TENANCY" ]; then
    log "CAPACITY_REPORT is on but OCI_TENANCY_OCID is unset; the report needs the root compartment. Skipping."
    CAPACITY_REPORT=false
    return 0
  fi

  local ad shapes status available=() other=() unavailable=()
  shapes="[{\"instanceShape\": \"$SHAPE\"}]"
  if [ "$SHAPE_IS_FLEX" = true ]; then
    shapes="[{\"instanceShape\": \"$SHAPE\", \"instanceShapeConfig\": {\"ocpus\": ${LADDER[0]}, \"memoryInGBs\": $(mem_for "${LADDER[0]}")}}]"
  fi

  for ad in "${ADS[@]}"; do
    status=""
    if ocic_capture compute compute-capacity-report create \
         --availability-domain "$ad" --compartment-id "$TENANCY" \
         --shape-availabilities "$shapes" --output json; then
      status=$(printf '%s' "$OCI_OUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("data") or {}
    rows = d.get("shape-availabilities") or []
    print((rows[0].get("availability-status") or "") if rows else "")
except Exception:
    print("")
' 2>/dev/null)
    fi
    REPORT_SAID[$ad]="${status:-UNKNOWN}"
    case "$status" in
      AVAILABLE)          available+=("$ad") ;;
      OUT_OF_HOST_CAPACITY|HARDWARE_NOT_SUPPORTED) unavailable+=("$ad") ;;
      *)                  other+=("$ad") ;;
    esac
    log "  capacity report: $ad -> ${REPORT_SAID[$ad]}"
  done

  # Most promising first, never-tried-because-unknown next, discouraged last.
  # Every domain stays in the rotation regardless of what the report said.
  ADS=(${available[@]+"${available[@]}"} ${other[@]+"${other[@]}"} ${unavailable[@]+"${unavailable[@]}"})
}
capacity_report

# Placements, in round-robin order across availability domains.
#
# No fault domain is pinned by default. Oracle's own documented workaround for
# "Out of host capacity" is to create the instance WITHOUT specifying a fault
# domain: naming FD-1 asks for a host out of that one bucket, while omitting it
# asks for any eligible host in the whole availability domain. Omitting is a
# strict superset, so the same API call covers more ground.
build_placements() {
  PLACEMENTS=()
  local ad fd
  for ad in "${ADS[@]}"; do
    if [ "$ROTATE_FAULT_DOMAINS" = true ]; then
      mapfile -t FDS < <(ocic iam fault-domain list \
        --compartment-id "$COMPARTMENT" --availability-domain "$ad" \
        --query 'data[].name' --output json 2>/dev/null \
        | python3 -c 'import sys,json; [print(x) for x in json.loads(sys.stdin.read() or "[]") or []]' 2>/dev/null)
      # An empty fault-domain list is fine: "" means "let OCI choose".
      [ ${#FDS[@]} -gt 0 ] || FDS=("")
      for fd in "${FDS[@]}"; do
        PLACEMENTS+=("$ad|$fd")
      done
    else
      PLACEMENTS+=("$ad|")
    fi
  done
}
build_placements
log "Placements to rotate through: ${#PLACEMENTS[@]}$( [ "$ROTATE_FAULT_DOMAINS" = true ] && echo " (fault domains pinned)" || echo " (no fault domain pinned)")"

# Flat attempt list: every placement, largest size first at each one.
ATTEMPTS=()
build_attempts() {
  ATTEMPTS=()
  local p n
  for p in "${PLACEMENTS[@]}"; do
    for n in "${LADDER[@]}"; do
      ATTEMPTS+=("$n|$p")
    done
  done
}
build_attempts

[ -r "$SSH_KEY_FILE" ] || fail "SSH public key file '$SSH_KEY_FILE' is missing."
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1 || SSH_BAD=1
elif ! grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+' "$SSH_KEY_FILE"; then
  SSH_BAD=1
fi
[ -z "${SSH_BAD:-}" ] \
  || fail "SSH_PUBLIC_KEY is not a valid OpenSSH public key. It must be the one-line .pub file (starting with ssh-ed25519 or ssh-rsa), not the private key."

# ---------------------------------------------------------------------------
# The hunt.
# ---------------------------------------------------------------------------
RUN_START=$SECONDS
DEADLINE=$(( SECONDS + HUNT_SECONDS ))
ATTEMPT=0
UNKNOWN_STREAK=0
MISSES=0
THROTTLES=0
TRANSIENTS=0
UNKNOWNS=0
# How fast the tenancy actually tolerates being asked. It rises on a 429 and
# eases back down on a clean answer, converging on the sustainable rate instead
# of being guessed up front.
PACE="$INTERVAL"
declare -A SEEN_ERRORS=()

log "Hunting for ${HUNT_SECONDS}s, starting at one attempt every ${INTERVAL}s."

while [ "$SECONDS" -lt "$DEADLINE" ]; do
  IFS='|' read -r ocpus ad fd <<< "${ATTEMPTS[$(( ATTEMPT % ${#ATTEMPTS[@]} ))]}"
  ATTEMPT=$(( ATTEMPT + 1 ))
  mem=$(mem_for "$ocpus")

  args=(
    compute instance launch
    --availability-domain "$ad"
    --compartment-id "$COMPARTMENT"
    --shape "$SHAPE"
    --image-id "$IMAGE_ID"
    --subnet-id "$SUBNET"
    --display-name "$DISPLAY_NAME"
    --assign-public-ip true
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB"
    --ssh-authorized-keys-file "$SSH_KEY_FILE"
    --freeform-tags '{"created-by":"oracle-instance-hunter"}'
  )
  # A fixed shape has its OCPU and memory set by Oracle and rejects a
  # shape-config outright.
  [ "$SHAPE_IS_FLEX" = true ] && args+=(--shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $mem}")
  [ -n "$fd" ] && args+=(--fault-domain "$fd")

  log "Attempt #$ATTEMPT: ${ocpus} OCPU / ${mem} GB in $ad${fd:+ / $fd}"
  ocic_capture "${args[@]}"
  RC=$?
  RESPONSE=${OCI_ERR:-$OCI_OUT}

  if [ "$RC" -eq 0 ]; then
    INSTANCE_ID=$(printf '%s' "$OCI_OUT" | python3 -c \
      'import sys,json; print((json.load(sys.stdin).get("data") or {}).get("id",""))' 2>/dev/null)
    if [ -n "$INSTANCE_ID" ]; then
      log "GOT ONE. Instance $INSTANCE_ID (${ocpus} OCPU / ${mem} GB, $ad${fd:+ / $fd})"
      [ "$CAPACITY_REPORT" = true ] && log "Capacity report had said ${REPORT_SAID[$ad]:-?} for $ad; the launch succeeded."
      emit "result=launched"
      emit "instance_id=$INSTANCE_ID"
      emit "ocpus=$ocpus"
      emit "memory=$mem"
      emit "placement=$ad${fd:+ / $fd}"

      IP=""
      for _ in $(seq 1 20); do
        IP=$(ocic compute instance list-vnics --instance-id "$INSTANCE_ID" \
              --query 'data[0]."public-ip"' --raw-output 2>/dev/null | tr -d '[:space:]')
        [ -n "$IP" ] && [ "$IP" != "null" ] && break
        IP=""
        sleep 6
      done
      emit "public_ip=$IP"

      summary "### 🎉 Captured a $SHAPE"
      summary ""
      summary "| | |"
      summary "|---|---|"
      summary "| Instance | \`$INSTANCE_ID\` |"
      summary "| Shape | $SHAPE — ${ocpus} OCPU / ${mem} GB |"
      summary "| Placement | $ad${fd:+ / $fd} |"
      summary "| Public IP | ${IP:-pending} |"
      summary "| Attempts this run | $ATTEMPT |"
      exit 0
    fi
    log "Launch returned success but no instance id; treating as a failure."
    RESPONSE="empty response body"
  fi

  KIND=$(classify "$RESPONSE")
  FIRST_LINE=$(printf '%s' "$RESPONSE" | tr '\n' ' ' | tr -s ' ' | cut -c1-500)

  case "$KIND" in
    capacity)
      MISSES=$(( MISSES + 1 ))
      if [ "$CAPACITY_REPORT" = true ] && [ "${REPORT_SAID[$ad]:-}" = AVAILABLE ]; then
        log "Capacity report said AVAILABLE for $ad, but the launch was refused for lack of capacity."
      fi
      ease_pace
      log "No capacity here. Rotating placement. Next attempt in ${PACE}s."
      ;;
    throttled)
      THROTTLES=$(( THROTTLES + 1 ))
      # Half again, not double. Over a 5h45m run doubling overshot to 168s
      # between attempts, and every second above the sustainable rate is a
      # capacity check not made. Rounded up so small paces still grow.
      PACE=$(( (PACE * 3 + 1) / 2 )); [ "$PACE" -gt "$PACE_CEILING" ] && PACE=$PACE_CEILING
      log "Rate-limited by OCI. Slowing to ${PACE}s between attempts."
      ;;
    transient)
      TRANSIENTS=$(( TRANSIENTS + 1 ))
      ease_pace
      log "Transient OCI error, retrying: $FIRST_LINE"
      ;;
    quota)
      # This size is over the tenancy's limit, but a smaller rung may still
      # fit, so drop this size and anything larger and keep hunting. Only when
      # nothing is left is the limit genuinely the end of the road.
      NEW_LADDER=()
      for n in "${LADDER[@]}"; do
        [ "$n" -lt "$ocpus" ] && NEW_LADDER+=("$n")
      done
      if [ ${#NEW_LADDER[@]} -eq 0 ]; then
        summary "### $SHAPE hunt stopped — service limit"
        summary "Even ${ocpus} OCPU / ${mem} GB exceeds this tenancy's limit."
        summary "\`\`\`"
        summary "$FIRST_LINE"
        summary "\`\`\`"
        summary "Raise it under Governance & Administration -> Limits, Quotas and Usage -> Compute."
        fail "Even the smallest size (${ocpus} OCPU / ${mem} GB) exceeds this tenancy's service limit: $FIRST_LINE"
      fi
      LADDER=("${NEW_LADDER[@]}")
      log "${ocpus} OCPU exceeds the service limit. Dropping to sizes ${LADDER[*]} OCPU."
      build_attempts
      ;;
    auth|badrequest)
      summary "### $SHAPE hunt stopped — configuration error"
      summary "\`\`\`"
      summary "$FIRST_LINE"
      summary "\`\`\`"
      fail "Configuration error, which retrying cannot fix: $FIRST_LINE"
      ;;
    unknown)
      UNKNOWNS=$(( UNKNOWNS + 1 ))
      UNKNOWN_STREAK=$(( UNKNOWN_STREAK + 1 ))
      if [ -z "${SEEN_ERRORS[$FIRST_LINE]:-}" ]; then
        SEEN_ERRORS[$FIRST_LINE]=1
        log "Unrecognised OCI error (#$UNKNOWN_STREAK): $FIRST_LINE"
      fi
      if [ "$UNKNOWN_STREAK" -ge "$MAX_UNKNOWN" ]; then
        fail "$MAX_UNKNOWN consecutive unrecognised errors, last: $FIRST_LINE"
      fi
      ease_pace
      ;;
  esac
  [ "$KIND" = unknown ] || UNKNOWN_STREAK=0

  # Jitter, so a fleet of these does not hammer OCI on the same second.
  SLEEP=$(( PACE + (JITTER > 0 ? RANDOM % JITTER : 0) ))
  [ $(( SECONDS + SLEEP )) -lt "$DEADLINE" ] || break
  sleep "$SLEEP"
done

# ---------------------------------------------------------------------------
# Metrics. The number that matters is capacity checks per hour, not attempts
# per hour: an attempt Oracle answers with 429 asked nothing. These are what
# make a pace floor of 45 / 75 / 90 / 120 comparable across runs instead of a
# matter of opinion.
# ---------------------------------------------------------------------------
ELAPSED=$(( SECONDS - RUN_START ))
[ "$ELAPSED" -gt 0 ] || ELAPSED=1
THROTTLE_PCT=0
[ "$ATTEMPT" -gt 0 ] && THROTTLE_PCT=$(( THROTTLES * 100 / ATTEMPT ))
CHECKS_PER_HOUR=$(( MISSES * 3600 / ELAPSED ))

log "Window closed after $ATTEMPT attempts in ${ELAPSED}s ($MISSES capacity checks, $THROTTLES throttled, $TRANSIENTS transient, $UNKNOWNS unrecognised). No capacity. This is normal."
log "Capacity checks per hour: $CHECKS_PER_HOUR at an INTERVAL floor of ${INTERVAL}s (pace ended at ${PACE}s)."

emit "result=no-capacity"
emit "attempts=$ATTEMPT"
emit "capacity_checks=$MISSES"
emit "throttled=$THROTTLES"
emit "throttle_pct=$THROTTLE_PCT"
emit "checks_per_hour=$CHECKS_PER_HOUR"
emit "final_pace=$PACE"

summary "### $SHAPE hunt — no capacity this run"
summary ""
summary "| Metric | Value |"
summary "|---|---|"
summary "| Launch attempts | $ATTEMPT |"
summary "| Real capacity checks | $MISSES |"
summary "| Rate-limited (429) | $THROTTLES (${THROTTLE_PCT}%) |"
summary "| Transient / unrecognised | $TRANSIENTS / $UNKNOWNS |"
summary "| **Capacity checks per hour** | **$CHECKS_PER_HOUR** |"
summary "| INTERVAL floor | ${INTERVAL}s |"
summary "| Pace at end of run | ${PACE}s |"
summary "| Placements rotated | ${#PLACEMENTS[@]} |"
summary "| Window | ${ELAPSED}s |"
if [ "$THROTTLES" -gt "$MISSES" ]; then
  summary ""
  summary "More attempts were throttled than answered, so most of the window went to backing off. Raise \`INTERVAL\` (currently ${INTERVAL}s) in \`hunt.config\` to hunt at a rate this tenancy tolerates."
fi
exit 0
