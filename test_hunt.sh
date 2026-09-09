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
}

echo "hunt.sh"

# --- 1. Free-tier allowance already spent -> stop, do not launch -----------
run_hunt already-full MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":4.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$TMP/already-full/state/launches" ]; then
  ok "stops without launching when all 4 free OCPUs are already used"
else
  bad "stops without launching when all 4 free OCPUs are already used" "$LOG"
fi

# --- 2. Partial usage narrows the ladder to what still fits ---------------
run_hunt partial MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":2.0}]' MOCK_SUCCEED_ON=999
if grep -q '4 OCPU, 2 already allocated, 2 left' <<< "$LOG" && grep -q 'Sizes to try: 2 1 OCPU' <<< "$LOG" \
   && [ -s "$TMP/partial/state/launches" ] \
   && ! grep -q '"ocpus": 4' "$TMP/partial/state/launches"; then
  ok "with 2 of 4 OCPUs used, never asks for more than the remaining 2"
else
  bad "with 2 of 4 OCPUs used, never asks for more than the remaining 2" "$LOG"
fi

# --- 3. STOPPED instances still count against the allowance ---------------
run_hunt stopped MOCK_EXISTING='[{"n":"a","s":"STOPPED","o":4.0}]'
if grep -q 'result=already-satisfied' <<< "$OUT"; then
  ok "counts STOPPED instances against the free-tier allowance"
else
  bad "counts STOPPED instances against the free-tier allowance" "$LOG"
fi

# --- 4. Out of host capacity is a normal miss, not a failure --------------
run_hunt capacity MOCK_SUCCEED_ON=999
if [ "$RC" -eq 0 ] && grep -q 'result=no-capacity' <<< "$OUT" \
   && grep -q 'No capacity here' <<< "$LOG"; then
  ok "treats 'Out of host capacity' (HTTP 500) as a miss and exits green"
else
  bad "treats 'Out of host capacity' (HTTP 500) as a miss and exits green" "$LOG"
fi

# --- 5. Placements and sizes are actually rotated -------------------------
run_hunt rotate MOCK_SUCCEED_ON=999 MOCK_ADS='["AD-1","AD-2"]' HUNT_SECONDS=6 INTERVAL=1 JITTER=0
COMBOS=$(grep -oE '\-\-availability-domain [A-Za-z0-9:-]+ .*--fault-domain [A-Z0-9-]+' \
          "$TMP/rotate/state/launches" 2>/dev/null | sort -u | wc -l)
SIZES=$(grep -oE '"ocpus": [0-9]+' "$TMP/rotate/state/launches" | sort -u | wc -l)
if [ "$COMBOS" -ge 2 ] && [ "$SIZES" -ge 2 ]; then
  ok "rotates through multiple availability/fault domains and sizes ($COMBOS placements, $SIZES sizes)"
else
  bad "rotates through multiple availability/fault domains and sizes" "combos=$COMBOS sizes=$SIZES
$LOG"
fi

# --- 6. A win is reported with its details --------------------------------
run_hunt win MOCK_SUCCEED_ON=2
if [ "$RC" -eq 0 ] && grep -q 'result=launched' <<< "$OUT" \
   && grep -q 'instance_id=ocid1.instance.oc1.eu-madrid-1.WON' <<< "$OUT" \
   && grep -q 'public_ip=203.0.113.42' <<< "$OUT"; then
  ok "reports instance id and public IP on a successful launch"
else
  bad "reports instance id and public IP on a successful launch" "$OUT
$LOG"
fi

# --- 7. Auth errors stop immediately instead of burning the window --------
run_hunt auth MOCK_SUCCEED_ON=999 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "NotAuthenticated", "message": "The required information to complete authentication was not provided.", "status": 401}'
if [ "$RC" -ne 0 ] && grep -q 'Configuration error' <<< "$LOG" \
   && [ "$(wc -l < "$TMP/auth/state/launches")" -eq 1 ]; then
  ok "fails fast on NotAuthenticated instead of retrying for the whole window"
else
  bad "fails fast on NotAuthenticated instead of retrying for the whole window" "$LOG"
fi

# --- 8. LimitExceeded on a big size steps down instead of giving up -------
# The live tenancy refused 4 OCPU / 24 GB on standard-a1-mem. Quitting there
# would never have tried the 1 OCPU that the same limit allows.
run_hunt quota_stepdown MOCK_SUCCEED_ON=999 MOCK_LIMIT_MAX_OCPUS=1 HUNT_SECONDS=20 INTERVAL=1 JITTER=0
if grep -q 'exceeds the A1 service limit. Dropping to sizes 2 1' <<< "$LOG" \
   && grep -q 'Dropping to sizes 1 OCPU' <<< "$LOG" \
   && grep -q '"ocpus": 1' "$TMP/quota_stepdown/state/launches"; then
  ok "steps the ladder down on LimitExceeded instead of quitting"
else
  bad "steps the ladder down on LimitExceeded instead of quitting" "$LOG"
fi

# --- 8b. A size the limit allows still wins after the step-down -----------
run_hunt quota_then_win MOCK_SUCCEED_ON=3 MOCK_LIMIT_MAX_OCPUS=1 HUNT_SECONDS=20 INTERVAL=1 JITTER=0
if [ "$RC" -eq 0 ] && grep -q 'result=launched' <<< "$OUT" && grep -q 'ocpus=1' <<< "$OUT"; then
  ok "still captures a 1 OCPU instance after stepping past the limit"
else
  bad "still captures a 1 OCPU instance after stepping past the limit" "$OUT
$LOG"
fi

# --- 8c. A limit that forbids every size is genuinely fatal ---------------
run_hunt quota_all MOCK_SUCCEED_ON=999 MOCK_LIMIT_MAX_OCPUS=0 HUNT_SECONDS=20 INTERVAL=1 JITTER=0
if [ "$RC" -ne 0 ] && grep -q 'Even the smallest size' <<< "$LOG"; then
  ok "fails when even the smallest size exceeds the limit"
else
  bad "fails when even the smallest size exceeds the limit" "$LOG"
fi

# --- 8d. A zero service limit is caught before any launch ----------------
run_hunt zero_limit MOCK_CORE_LIMIT=0 MOCK_MEM_LIMIT=0
if [ "$RC" -ne 0 ] && grep -q 'allowed 0 A1 capacity' <<< "$LOG" \
   && [ ! -f "$TMP/zero_limit/state/launches" ]; then
  ok "refuses to launch at all when the tenancy A1 limit is zero"
else
  bad "refuses to launch at all when the tenancy A1 limit is zero" "$LOG"
fi

# --- 8f. A tenancy capped at 2 OCPU that already runs 2 is done ----------
# The real tenancy is limited to 2 OCPU / 12 GB. Clamping the *remainder* to
# that total would ask for 2 more once the first 2 landed, taking the tenancy
# to 4 against a limit of 2 and failing the run red forever after.
run_hunt capped_satisfied MOCK_CORE_LIMIT=2 MOCK_MEM_LIMIT=12 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":2.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=already-satisfied' <<< "$OUT" \
   && [ ! -f "$TMP/capped_satisfied/state/launches" ]; then
  ok "a 2 OCPU tenancy already running 2 OCPU stops instead of over-launching"
else
  bad "a 2 OCPU tenancy already running 2 OCPU stops instead of over-launching" "$OUT
$LOG"
fi

# --- 8g. Same tenancy with 1 of 2 used tops up by exactly 1 --------------
run_hunt capped_topup MOCK_SUCCEED_ON=999 MOCK_CORE_LIMIT=2 MOCK_MEM_LIMIT=12 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":1.0}]'
if grep -q 'Allowance 2 OCPU, 1 already allocated, 1 left' <<< "$LOG" \
   && grep -q 'Sizes to try: 1 OCPU' <<< "$LOG" \
   && [ -s "$TMP/capped_topup/state/launches" ] \
   && ! grep -qE '"ocpus": [234]' "$TMP/capped_topup/state/launches"; then
  ok "a 2 OCPU tenancy already running 1 OCPU asks for exactly 1 more"
else
  bad "a 2 OCPU tenancy already running 1 OCPU asks for exactly 1 more" "$LOG"
fi

# --- 8h. A ladder with nothing that fits exits green, not red ------------
# This runs unattended every half hour; a permanently red run is worse than
# useless because it trains you to ignore the failure mail.
run_hunt no_fit OCPU_LADDER=2 MOCK_CORE_LIMIT=2 MOCK_MEM_LIMIT=12 \
  MOCK_EXISTING='[{"n":"a","s":"RUNNING","o":1.0}]'
if [ "$RC" -eq 0 ] && grep -q 'result=no-fit' <<< "$OUT" \
   && [ ! -f "$TMP/no_fit/state/launches" ]; then
  ok "exits green when no ladder size fits the remaining allowance"
else
  bad "exits green when no ladder size fits the remaining allowance" "$OUT
$LOG"
fi

# --- 8i. The 2-only ladder never settles for a smaller instance ----------
run_hunt two_only OCPU_LADDER=2 MOCK_SUCCEED_ON=999 MOCK_CORE_LIMIT=2 MOCK_MEM_LIMIT=12 \
  HUNT_SECONDS=6 INTERVAL=1 JITTER=0
if grep -q 'Sizes to try: 2 OCPU' <<< "$LOG" \
   && [ -s "$TMP/two_only/state/launches" ] \
   && ! grep -qE '"ocpus": [134]' "$TMP/two_only/state/launches"; then
  ok "with OCPU_LADDER=2 it only ever asks for 2 OCPU"
else
  bad "with OCPU_LADDER=2 it only ever asks for 2 OCPU" "$LOG"
fi

# --- 8e. Limits clamp the ladder before the first attempt ----------------
run_hunt clamp MOCK_SUCCEED_ON=999 MOCK_CORE_LIMIT=2 MOCK_MEM_LIMIT=12
if grep -q 'Tenancy A1 service limits: 2 OCPU / 12 GB' <<< "$LOG" \
   && grep -q 'Sizes to try: 2 1 OCPU' <<< "$LOG" \
   && ! grep -q '"ocpus": 4' "$TMP/clamp/state/launches"; then
  ok "clamps the ladder to the service limits before attempting"
else
  bad "clamps the ladder to the service limits before attempting" "$LOG"
fi

# --- 9. Throttling backs off instead of hammering -------------------------
run_hunt throttle MOCK_SUCCEED_ON=999 HUNT_SECONDS=10 INTERVAL=1 JITTER=0 \
  MOCK_LAUNCH_ERROR='ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}'
if [ "$RC" -eq 0 ] && grep -q 'Slowing to 2s between attempts' <<< "$LOG" \
   && grep -q 'Slowing to 3s' <<< "$LOG"; then
  ok "backs off on every 429, half again each time"
else
  bad "backs off on every 429, half again each time" "$LOG"
fi

# --- 9b. A capacity miss must not throw away the learned pace -------------
# The live run went clean/429/429/clean/429/429 because the pace reset to the
# floor on every clean answer and instantly earned the next throttle.
run_hunt pace MOCK_SUCCEED_ON=999 MOCK_THROTTLE_ON='1 2' HUNT_SECONDS=40 INTERVAL=4 JITTER=0
FIRST_EASE=$(grep -oE 'Next attempt in [0-9]+s' <<< "$LOG" | head -1)
if grep -q 'Slowing to 6s' <<< "$LOG" && grep -q 'Slowing to 9s' <<< "$LOG" \
   && [ "$FIRST_EASE" = "Next attempt in 6s" ]; then
  ok "eases the pace down after a throttle instead of resetting to the floor"
else
  bad "eases the pace down after a throttle instead of resetting to the floor" "first eased pace: ${FIRST_EASE:-none}
$LOG"
fi

# --- 9c. The summary calls out a window lost to throttling ----------------
run_hunt throttle_report MOCK_SUCCEED_ON=999 MOCK_THROTTLE_ON='1 2 3' \
  HUNT_SECONDS=25 INTERVAL=2 JITTER=0
if grep -q 'were rate-limited' "$TMP/throttle_report/summary" \
   && grep -q 'More attempts were throttled than answered' "$TMP/throttle_report/summary"; then
  ok "reports throttling in the summary when it dominates the window"
else
  bad "reports throttling in the summary when it dominates the window" "$(cat "$TMP/throttle_report/summary" 2>/dev/null)"
fi

# --- 10. A missing image is caught before the loop ------------------------
run_hunt noimage MOCK_IMAGE_ID=''
if [ "$RC" -ne 0 ] && grep -q 'No Canonical Ubuntu 24.04 aarch64 image found' <<< "$LOG" \
   && [ ! -f "$TMP/noimage/state/launches" ]; then
  ok "refuses to launch when no aarch64 image was resolved"
else
  bad "refuses to launch when no aarch64 image was resolved" "$LOG"
fi

# --- 11. An unreadable SSH key is caught before the loop ------------------
run_hunt badkey MOCK_SUCCEED_ON=999 SSH_KEY_FILE=/nonexistent.pub
if [ "$RC" -ne 0 ] && grep -q 'is missing' <<< "$LOG"; then
  ok "refuses to launch when the SSH public key is missing"
else
  bad "refuses to launch when the SSH public key is missing" "$LOG"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
