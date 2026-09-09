#!/usr/bin/env bash
# Offline tests for scripts/hunt.sh, driven by tests/mock_oci.sh.
# Run with: bash tests/test_hunt.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A real (throwaway) ed25519 public key: hunt.sh validates the key with
# ssh-keygen when it is available, so a hand-written placeholder would not get
# past the pre-flight checks.
cat > "$TMP/id.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDVkBeC4Ug0FzT64FHm6MqQMt5s/8zcwqPmvZyDUXcU7 test@hunter
KEY

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$(( PASS + 1 )); }
bad()  { echo "  FAIL- $1"; printf '        %s\n' "$2"; FAIL=$(( FAIL + 1 )); }

# Runs hunt.sh against the mock. Extra args are VAR=VALUE overrides.
#
# HUNT_CONFIG is deliberately left unset, so every case loads the real
# hunt.config the repository ships. That makes the shipped preset itself part
# of the suite: a case that needs different settings passes them as env
# overrides, which is exactly the precedence the workflow relies on.
run_hunt() {
  local name="$1"; shift
  RUN_DIR="$TMP/$name"; mkdir -p "$RUN_DIR"
  cp "$TMP/id.pub" "$RUN_DIR/ssh_key.pub"
  ( cd "$RUN_DIR" && env -i \
      PATH="$PATH" HOME="$HOME" RANDOM_SEED=1 \
      OCI_BIN="$ROOT/tests/mock_oci.sh" \
      MOCK_STATE_DIR="$RUN_DIR/state" \
      OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..test \
      OCI_SUBNET_OCID=ocid1.subnet.oc1..test \
      OCI_TENANCY_OCID=ocid1.tenancy.oc1..test \
      GITHUB_OUTPUT="$RUN_DIR/out" \
      GITHUB_STEP_SUMMARY="$RUN_DIR/summary" \
      HUNT_SECONDS=3 INTERVAL=1 JITTER=0 \
      "$@" \
      bash "$ROOT/scripts/hunt.sh" ) > "$RUN_DIR/log" 2>&1
  RC=$?
  OUT=$(cat "$RUN_DIR/out" 2>/dev/null)
  LOG=$(cat "$RUN_DIR/log")
  SUMMARY=$(cat "$RUN_DIR/summary" 2>/dev/null)
  LAUNCHES="$RUN_DIR/state/launches"
}

echo "hunt.sh"

# =========================================================================
#  The dashboard
# =========================================================================

# --- 1. hunt.config is loaded and its preset is what gets asked for -------
run_hunt config_default MOCK_SUCCEED_ON=999
if grep -q "Config: $ROOT/hunt.config" <<< "$LOG" \
   && grep -q 'Hunting for VM.Standard.A1.Flex, sizes \[1\] OCPU, stopping at 1 OCPU held' <<< "$LOG" \
   && grep -q '1 OCPU / 6 GB' <<< "$LOG" \
   && grep -q '"ocpus": 1, "memoryInGBs": 6' "$LAUNCHES"; then
  ok "reads hunt.config and hunts for the 1 OCPU / 6 GB preset it ships"
else
  bad "reads hunt.config and hunts for the 1 OCPU / 6 GB preset it ships" "$LOG"
fi

# --- 2. An environment variable beats the file ----------------------------
# This is the precedence the workflow and these tests both rely on.
run_hunt config_override MOCK_SUCCEED_ON=999 OCPU_LADDER=2 STOP_AT_TOTAL_OCPUS=2
if grep -q 'Sizes to try: 2 OCPU' <<< "$LOG" \
   && grep -q '"ocpus": 2, "memoryInGBs": 12' "$LAUNCHES"; then
  ok "an environment variable overrides hunt.config"
else
  bad "an environment variable overrides hunt.config" "$LOG"
fi

# =========================================================================
#  The free-tier guard
# =========================================================================

# --- 3. Allowance already spent -> stop, do not launch --------------------
run_hunt already_full MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":1.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$LAUNCHES" ]; then
  ok "stops without launching once STOP_AT_TOTAL_OCPUS is already held"
else
  bad "stops without launching once STOP_AT_TOTAL_OCPUS is already held" "$LOG"
fi

# --- 4. Partial usage narrows the ladder to what still fits ---------------
run_hunt partial MOCK_SUCCEED_ON=999 OCPU_LADDER='4 2 1' STOP_AT_TOTAL_OCPUS=4 \
  MOCK_CORE_LIMIT=4 MOCK_MEM_LIMIT=24 MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":2.0}]'
if grep -q 'Allowance 4 OCPU, 2 already allocated, 2 left' <<< "$LOG" \
   && grep -q 'Sizes to try: 2 1 OCPU' <<< "$LOG" \
   && [ -s "$LAUNCHES" ] && ! grep -q '"ocpus": 4' "$LAUNCHES"; then
  ok "with 2 of 4 OCPUs used, never asks for more than the remaining 2"
else
  bad "with 2 of 4 OCPUs used, never asks for more than the remaining 2" "$LOG"
fi

# --- 5. STOPPED instances still count against the allowance ---------------
run_hunt stopped MOCK_EXISTING='[{"n":"a","s":"STOPPED","o":1.0}]'
if grep -q 'result=already-satisfied' <<< "$OUT"; then
  ok "counts STOPPED instances against the allowance"
else
  bad "counts STOPPED instances against the allowance" "$LOG"
fi

# --- 6. A ladder with nothing that fits exits green, not red --------------
# This runs unattended; a permanently red run is worse than useless because it
# trains you to ignore the failure mail.
run_hunt no_fit OCPU_LADDER=2 STOP_AT_TOTAL_OCPUS=2 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":1.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=no-fit' <<< "$OUT" && [ ! -f "$LAUNCHES" ]; then
  ok "exits green when no ladder size fits the remaining allowance"
else
  bad "exits green when no ladder size fits the remaining allowance" "$OUT
$LOG"
fi

# --- 7. A tenancy capped at 2 OCPU that already runs 2 is done ------------
# Clamping the *remainder* to the total would ask for 2 more once the first 2
# landed, taking the tenancy to 4 against a limit of 2.
run_hunt capped_satisfied STOP_AT_TOTAL_OCPUS=2 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":2.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$LAUNCHES" ]; then
  ok "a 2 OCPU tenancy already running 2 OCPU stops instead of over-launching"
else
  bad "a 2 OCPU tenancy already running 2 OCPU stops instead of over-launching" "$OUT
$LOG"
fi

# --- 8. Same tenancy with 1 of 2 used tops up by exactly 1 ----------------
run_hunt capped_topup MOCK_SUCCEED_ON=999 OCPU_LADDER='2 1' STOP_AT_TOTAL_OCPUS=2 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":1.0}]'
if grep -q 'Allowance 2 OCPU, 1 already allocated, 1 left' <<< "$LOG" \
   && grep -q 'Sizes to try: 1 OCPU' <<< "$LOG" \
   && [ -s "$LAUNCHES" ] && ! grep -qE '"ocpus": [234]' "$LAUNCHES"; then
  ok "a 2 OCPU tenancy already running 1 OCPU asks for exactly 1 more"
else
  bad "a 2 OCPU tenancy already running 1 OCPU asks for exactly 1 more" "$LOG"
fi

# =========================================================================
#  Service limits
# =========================================================================

# --- 9. Limits clamp the ladder before the first attempt -----------------
run_hunt clamp MOCK_SUCCEED_ON=999 OCPU_LADDER='4 2 1' STOP_AT_TOTAL_OCPUS=4
if grep -q 'service limits: 2 OCPU / 12 GB' <<< "$LOG" \
   && grep -q 'Sizes to try: 2 1 OCPU' <<< "$LOG" \
   && ! grep -q '"ocpus": 4' "$LAUNCHES"; then
  ok "clamps the ladder to the tenancy service limits before attempting"
else
  bad "clamps the ladder to the tenancy service limits before attempting" "$LOG"
fi

# --- 10. LimitExceeded on a big size steps down instead of giving up ------
run_hunt quota_stepdown MOCK_SUCCEED_ON=999 OCPU_LADDER='4 2 1' STOP_AT_TOTAL_OCPUS=4 \
  MOCK_CORE_LIMIT=4 MOCK_MEM_LIMIT=24 MOCK_LIMIT_MAX_OCPUS=1 HUNT_SECONDS=20
if grep -q 'exceeds the service limit. Dropping to sizes 2 1' <<< "$LOG" \
   && grep -q 'Dropping to sizes 1 OCPU' <<< "$LOG" \
   && grep -q '"ocpus": 1' "$LAUNCHES"; then
  ok "steps the ladder down on LimitExceeded instead of quitting"
else
  bad "steps the ladder down on LimitExceeded instead of quitting" "$LOG"
fi

# --- 11. A size the limit allows still wins after the step-down ----------
run_hunt quota_then_win MOCK_SUCCEED_ON=3 OCPU_LADDER='4 2 1' STOP_AT_TOTAL_OCPUS=4 \
  MOCK_CORE_LIMIT=4 MOCK_MEM_LIMIT=24 MOCK_LIMIT_MAX_OCPUS=1 HUNT_SECONDS=20
if [ "$RC" -eq 0 ] && grep -q 'result=launched' <<< "$OUT" && grep -q 'ocpus=1' <<< "$OUT"; then
  ok "still captures a 1 OCPU instance after stepping past the limit"
else
  bad "still captures a 1 OCPU instance after stepping past the limit" "$OUT
$LOG"
fi

# --- 12. A limit that forbids every size is genuinely fatal --------------
run_hunt quota_all MOCK_SUCCEED_ON=999 MOCK_LIMIT_MAX_OCPUS=0 HUNT_SECONDS=20
if [ "$RC" -ne 0 ] && grep -q 'Even the smallest size' <<< "$LOG"; then
  ok "fails when even the smallest size exceeds the limit"
else
  bad "fails when even the smallest size exceeds the limit" "$LOG"
fi

# --- 13. A zero service limit is caught before any launch ----------------
run_hunt zero_limit MOCK_CORE_LIMIT=0 MOCK_MEM_LIMIT=0
if [ "$RC" -ne 0 ] && grep -q 'allowed 0 VM.Standard.A1.Flex capacity' <<< "$LOG" \
   && [ ! -f "$LAUNCHES" ]; then
  ok "refuses to launch at all when the tenancy limit is zero"
else
  bad "refuses to launch at all when the tenancy limit is zero" "$LOG"
fi

# --- 14. Blank limit names skip the limits pre-flight --------------------
# Needed for a shape the standard-a1-* limits do not govern.
run_hunt no_limit_names MOCK_SUCCEED_ON=999 LIMIT_CORE_NAME= LIMIT_MEMORY_NAME= \
  MOCK_CORE_LIMIT=0 MOCK_MEM_LIMIT=0
if grep -q 'No service limit names configured' <<< "$LOG" \
   && ! grep -q 'allowed 0' <<< "$LOG" && [ -s "$LAUNCHES" ]; then
  ok "skips the limits check when no limit names are configured"
else
  bad "skips the limits check when no limit names are configured" "$LOG"
fi

# =========================================================================
#  Placement
# =========================================================================

# --- 15. No fault domain is pinned by default ---------------------------
# Oracle's own workaround for "Out of host capacity" is to create the instance
# WITHOUT a fault domain: naming one asks for a single bucket of hosts,
# omitting it asks for any eligible host in the whole availability domain.
run_hunt no_fd MOCK_SUCCEED_ON=999 MOCK_ADS='["AD-1","AD-2"]' HUNT_SECONDS=6
if ! grep -q -- '--fault-domain' "$LAUNCHES" \
   && grep -q 'no fault domain pinned' <<< "$LOG"; then
  ok "pins no fault domain by default"
else
  bad "pins no fault domain by default" "$LOG"
fi

# --- 16. Availability domains are still rotated -------------------------
run_hunt rotate_ad MOCK_SUCCEED_ON=999 MOCK_ADS='["AD-1","AD-2"]' HUNT_SECONDS=6
ADS_SEEN=$(grep -oE '\-\-availability-domain [A-Za-z0-9:-]+' "$LAUNCHES" | sort -u | wc -l)
if [ "$ADS_SEEN" -ge 2 ]; then
  ok "rotates through every availability domain ($ADS_SEEN seen)"
else
  bad "rotates through every availability domain" "ads=$ADS_SEEN
$LOG"
fi

# --- 17. Fault-domain rotation is still available when asked for --------
run_hunt rotate_fd MOCK_SUCCEED_ON=999 ROTATE_FAULT_DOMAINS=true HUNT_SECONDS=6
FDS_SEEN=$(grep -oE '\-\-fault-domain [A-Z0-9-]+' "$LAUNCHES" | sort -u | wc -l)
if [ "$FDS_SEEN" -ge 2 ] && grep -q 'fault domains pinned' <<< "$LOG"; then
  ok "rotates fault domains when ROTATE_FAULT_DOMAINS is true ($FDS_SEEN seen)"
else
  bad "rotates fault domains when ROTATE_FAULT_DOMAINS is true" "fds=$FDS_SEEN
$LOG"
fi

# =========================================================================
#  Error classification
# =========================================================================

# --- 18. Out of host capacity is a normal miss, not a failure -----------
run_hunt capacity MOCK_SUCCEED_ON=999
if [ "$RC" -eq 0 ] && grep -q 'result=no-capacity' <<< "$OUT" \
   && grep -q 'No capacity here' <<< "$LOG"; then
  ok "treats 'Out of host capacity' (HTTP 500) as a miss and exits green"
else
  bad "treats 'Out of host capacity' (HTTP 500) as a miss and exits green" "$LOG"
fi

# --- 19. Auth errors stop immediately instead of burning the window -----
run_hunt auth MOCK_SUCCEED_ON=999 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "NotAuthenticated", "message": "The required information to complete authentication was not provided.", "status": 401}'
if [ "$RC" -ne 0 ] && grep -q 'Configuration error' <<< "$LOG" \
   && [ "$(wc -l < "$LAUNCHES")" -eq 1 ]; then
  ok "fails fast on NotAuthenticated instead of retrying for the whole window"
else
  bad "fails fast on NotAuthenticated instead of retrying for the whole window" "$LOG"
fi

# --- 20. A request id containing "403" is not an auth failure -----------
# Every OCI error body carries an opc-request-id of 30-odd alphanumerics.
# Matching bare digits anywhere in the response meant a request id that
# happened to contain 403 was classified as an auth error, which calls fail()
# and kills the whole run. Status codes must be read from the status field.
run_hunt reqid_403 MOCK_SUCCEED_ON=999 HUNT_SECONDS=4 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "SomethingNobodyAnticipated", "message": "unrecognised condition", "opc-request-id": "A403B404C401D", "status": 503}'
if [ "$RC" -eq 0 ] && grep -q 'result=no-capacity' <<< "$OUT" \
   && ! grep -q 'Configuration error' <<< "$LOG" \
   && grep -q 'Transient OCI error' <<< "$LOG"; then
  ok "does not read an opc-request-id containing 403 as an auth failure"
else
  bad "does not read an opc-request-id containing 403 as an auth failure" "$LOG"
fi

# --- 21. A genuinely unrecognised error still gives up eventually -------
run_hunt unknown_streak MOCK_SUCCEED_ON=999 HUNT_SECONDS=20 MAX_UNKNOWN=3 \
  MOCK_LAUNCH_ERROR='the service said something entirely new'
if [ "$RC" -ne 0 ] && grep -q '3 consecutive unrecognised errors' <<< "$LOG"; then
  ok "gives up after MAX_UNKNOWN consecutive unrecognised errors"
else
  bad "gives up after MAX_UNKNOWN consecutive unrecognised errors" "$LOG"
fi

# =========================================================================
#  Pacing
# =========================================================================

# --- 22. Throttling backs off instead of hammering ----------------------
run_hunt throttle MOCK_SUCCEED_ON=999 HUNT_SECONDS=10 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}'
if [ "$RC" -eq 0 ] && grep -q 'Slowing to 2s between attempts' <<< "$LOG" \
   && grep -q 'Slowing to 3s' <<< "$LOG"; then
  ok "backs off on every 429, half again each time"
else
  bad "backs off on every 429, half again each time" "$LOG"
fi

# --- 23. A capacity miss must not throw away the learned pace -----------
# The live run went clean/429/429/clean/429/429 because the pace reset to the
# floor on every clean answer and instantly earned the next throttle.
run_hunt pace MOCK_SUCCEED_ON=999 MOCK_THROTTLE_ON='1 2' HUNT_SECONDS=40 INTERVAL=4
FIRST_EASE=$(grep -oE 'Next attempt in [0-9]+s' <<< "$LOG" | head -1)
if grep -q 'Slowing to 6s' <<< "$LOG" && grep -q 'Slowing to 9s' <<< "$LOG" \
   && [ "$FIRST_EASE" = "Next attempt in 6s" ]; then
  ok "eases the pace down after a throttle instead of resetting to the floor"
else
  bad "eases the pace down after a throttle instead of resetting to the floor" "first eased pace: ${FIRST_EASE:-none}
$LOG"
fi

# --- 24. PACE_CEILING caps the backoff ----------------------------------
run_hunt ceiling MOCK_SUCCEED_ON=999 HUNT_SECONDS=12 INTERVAL=2 PACE_CEILING=4 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}'
if grep -q 'Slowing to 4s' <<< "$LOG" && ! grep -qE 'Slowing to ([5-9]|[0-9]{2,})s' <<< "$LOG"; then
  ok "never backs off past PACE_CEILING"
else
  bad "never backs off past PACE_CEILING" "$LOG"
fi

# =========================================================================
#  Reporting
# =========================================================================

# --- 25. A win is reported with its details -----------------------------
run_hunt win MOCK_SUCCEED_ON=2
if [ "$RC" -eq 0 ] && grep -q 'result=launched' <<< "$OUT" \
   && grep -q 'instance_id=ocid1.instance.oc1.eu-madrid-1.WON' <<< "$OUT" \
   && grep -q 'public_ip=203.0.113.42' <<< "$OUT" \
   && grep -q 'ocpus=1' <<< "$OUT" && grep -q 'memory=6' <<< "$OUT"; then
  ok "reports instance id, size and public IP on a successful launch"
else
  bad "reports instance id, size and public IP on a successful launch" "$OUT
$LOG"
fi

# --- 26. Every run reports metrics a pace floor can be judged on --------
# Attempts per hour is not the figure that matters: an attempt answered with
# 429 asked nothing. Capacity checks per hour is what makes 45 / 75 / 90 / 120
# comparable across runs.
run_hunt metrics MOCK_SUCCEED_ON=999 HUNT_SECONDS=5
if grep -q 'capacity_checks=' <<< "$OUT" && grep -q 'checks_per_hour=' <<< "$OUT" \
   && grep -q 'throttle_pct=' <<< "$OUT" && grep -q 'attempts=' <<< "$OUT" \
   && grep -q 'final_pace=' <<< "$OUT" \
   && grep -q 'Real capacity checks' <<< "$SUMMARY" \
   && grep -q 'Capacity checks per hour' <<< "$SUMMARY"; then
  ok "emits capacity-check metrics to the job output and summary"
else
  bad "emits capacity-check metrics to the job output and summary" "$OUT
$SUMMARY"
fi

# --- 27. The summary calls out a window lost to throttling --------------
run_hunt throttle_report MOCK_SUCCEED_ON=999 MOCK_THROTTLE_ON='1 2 3' \
  HUNT_SECONDS=25 INTERVAL=2
if grep -q 'Rate-limited (429)' <<< "$SUMMARY" \
   && grep -q 'More attempts were throttled than answered' <<< "$SUMMARY"; then
  ok "reports throttling in the summary when it dominates the window"
else
  bad "reports throttling in the summary when it dominates the window" "$SUMMARY"
fi

# =========================================================================
#  Other shapes
# =========================================================================

# --- 28. A fixed shape sends no shape-config ----------------------------
# VM.Standard.E2.1.Micro has its OCPU and memory set by Oracle and rejects a
# --shape-config outright.
run_hunt fixed_shape MOCK_SUCCEED_ON=999 SHAPE=VM.Standard.E2.1.Micro \
  SHAPE_IS_FLEX=false OCPU_LADDER=1 MEMORY_GB=1 STOP_AT_TOTAL_OCPUS=2 \
  LIMIT_CORE_NAME= LIMIT_MEMORY_NAME=
if ! grep -q -- '--shape-config' "$LAUNCHES" \
   && grep -q -- '--shape VM.Standard.E2.1.Micro' "$LAUNCHES" \
   && grep -q '1 OCPU / 1 GB' <<< "$LOG"; then
  ok "omits --shape-config and uses MEMORY_GB for a fixed shape"
else
  bad "omits --shape-config and uses MEMORY_GB for a fixed shape" "$LOG"
fi

# --- 29. A fixed-shape instance with no shape-config still counts -------
# Its size comes back as null, which must count as the 1 OCPU it is rather
# than as zero, or the guard would launch forever.
run_hunt fixed_counted SHAPE=VM.Standard.E2.1.Micro SHAPE_IS_FLEX=false \
  MEMORY_GB=1 STOP_AT_TOTAL_OCPUS=2 LIMIT_CORE_NAME= LIMIT_MEMORY_NAME= \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":null},{"n":"b","s":"RUNNING","o":null}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$LAUNCHES" ]; then
  ok "counts fixed-shape instances that report no shape-config"
else
  bad "counts fixed-shape instances that report no shape-config" "$OUT
$LOG"
fi

# =========================================================================
#  Capacity report (advisory only)
# =========================================================================

# --- 30. Off by default -------------------------------------------------
run_hunt report_off MOCK_SUCCEED_ON=999
if [ ! -f "$TMP/report_off/state/capacity_reports" ]; then
  ok "does not call the capacity report unless CAPACITY_REPORT is on"
else
  bad "does not call the capacity report unless CAPACITY_REPORT is on" "$LOG"
fi

# --- 31. When on, it only reorders -- it never suppresses a launch ------
# oracle/oci-cli#748 has the report calling a domain OUT_OF_HOST_CAPACITY
# where launches succeeded. Skipping that domain would mean skipping the one
# that would have won, so the report may reorder and nothing more.
run_hunt report_on MOCK_SUCCEED_ON=999 CAPACITY_REPORT=true HUNT_SECONDS=6 \
  MOCK_ADS='["AD-1","AD-2"]' MOCK_CAPACITY_REPORT='AD-2=AVAILABLE'
FIRST_AD=$(grep -oE '\-\-availability-domain [A-Za-z0-9:-]+' "$LAUNCHES" | head -1 | awk '{print $2}')
if [ "$FIRST_AD" = "AD-2" ] \
   && grep -q 'capacity report: AD-1 -> OUT_OF_HOST_CAPACITY' <<< "$LOG" \
   && grep -q -- '--availability-domain AD-1' "$LAUNCHES"; then
  ok "the capacity report reorders availability domains but never skips one"
else
  bad "the capacity report reorders availability domains but never skips one" "first=$FIRST_AD
$LOG"
fi

# =========================================================================
#  Pre-flight
# =========================================================================

# --- 32. A missing image is caught before the loop ----------------------
run_hunt noimage MOCK_IMAGE_ID=''
if [ "$RC" -ne 0 ] && grep -q 'No Canonical Ubuntu 24.04 image found' <<< "$LOG" \
   && [ ! -f "$LAUNCHES" ]; then
  ok "refuses to launch when no image was resolved"
else
  bad "refuses to launch when no image was resolved" "$LOG"
fi

# --- 33. An unreadable SSH key is caught before the loop ----------------
run_hunt badkey MOCK_SUCCEED_ON=999 SSH_KEY_FILE=/nonexistent.pub
if [ "$RC" -ne 0 ] && grep -q 'is missing' <<< "$LOG"; then
  ok "refuses to launch when the SSH public key is missing"
else
  bad "refuses to launch when the SSH public key is missing" "$LOG"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
