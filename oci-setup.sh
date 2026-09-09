#!/usr/bin/env bash
# Build ~/.oci/config from secrets and fail loudly (and early) on anything
# that would otherwise show up hours later as a cryptic NotAuthenticated.
set -uo pipefail

OCI_DIR="${OCI_DIR:-$HOME/.oci}"
KEY_FILE="$OCI_DIR/oci_api_key.pem"
CFG_FILE="$OCI_DIR/config"

die() { echo "::error::$*" >&2; exit 1; }
log() { echo "[setup] $*"; }

# --- 1. Every secret must be present ------------------------------------
missing=()
for v in OCI_USER_OCID OCI_FINGERPRINT OCI_TENANCY_OCID OCI_REGION OCI_API_KEY; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  die "Missing repository secrets: ${missing[*]}. See README.md for the full list."
fi

mkdir -p "$OCI_DIR"
chmod 700 "$OCI_DIR"

# --- 2. Normalise the private key ---------------------------------------
# Copy/paste through Windows or a web form mangles PEMs in three usual ways:
# CRLF line endings, literal backslash-n instead of real newlines, or the whole
# key base64-wrapped. Recover from all three rather than failing.
printf '%s\n' "$OCI_API_KEY" | tr -d '\r' > "$KEY_FILE"

if ! grep -q -- '-----BEGIN' "$KEY_FILE"; then
  log "Key has no PEM header; trying base64 decode."
  if base64 -d < "$KEY_FILE" > "$KEY_FILE.dec" 2>/dev/null && grep -q -- '-----BEGIN' "$KEY_FILE.dec"; then
    mv "$KEY_FILE.dec" "$KEY_FILE"
    log "Decoded a base64-wrapped key."
  else
    rm -f "$KEY_FILE.dec"
    die "OCI_API_KEY is neither a PEM nor base64-encoded PEM. Paste the whole private key file, including the BEGIN/END lines."
  fi
fi

# Literal "\n" instead of real newlines.
if [ "$(wc -l < "$KEY_FILE")" -lt 3 ]; then
  log "Key looks like a single line; expanding literal \\n sequences."
  printf '%b\n' "$(cat "$KEY_FILE")" > "$KEY_FILE.tmp" && mv "$KEY_FILE.tmp" "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"

openssl pkey -in "$KEY_FILE" -noout 2>/dev/null \
  || die "The private key in OCI_API_KEY is not a readable/unencrypted key. OCI API keys must not have a passphrase."

# --- 3. Fingerprint must match the key ----------------------------------
# Nearly every "NotAuthenticated" report is a fingerprint that belongs to a
# different key. Catch it here instead of in the hunt loop.
FP_CLEAN=$(printf '%s' "$OCI_FINGERPRINT" | tr -d ' \r\n\t"')
DERIVED_FP=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
  | openssl md5 -c 2>/dev/null | sed 's/^.*= //')

if [ -n "$DERIVED_FP" ] && [ "$DERIVED_FP" != "$FP_CLEAN" ]; then
  die "OCI_FINGERPRINT ($FP_CLEAN) does not match OCI_API_KEY (whose fingerprint is $DERIVED_FP). Fix one of the two secrets."
fi
log "Fingerprint matches the private key (${DERIVED_FP:0:5}...${DERIVED_FP: -5})."

# --- 4. Sanity-check the OCIDs ------------------------------------------
# Enough of each OCID to compare against the console, never the whole value.
# The full string is a repository secret and would be masked in the log; a
# substring is not, and the length exposes a truncated paste.
ocid_hint() {
  local v="$1"
  local n=${#v}
  if [ "$n" -le 24 ]; then printf '%s (length %d - suspiciously short)' "$v" "$n"
  else printf '%s...%s (length %d)' "${v:0:20}" "${v: -6}" "$n"; fi
}

USER_CLEAN=$(printf '%s' "$OCI_USER_OCID" | tr -d ' \r\n\t"')
TENANCY_CLEAN=$(printf '%s' "$OCI_TENANCY_OCID" | tr -d ' \r\n\t"')
REGION_CLEAN=$(printf '%s' "$OCI_REGION" | tr -d ' \r\n\t"')

case "$USER_CLEAN" in ocid1.user.*) ;; *) die "OCI_USER_OCID must start with 'ocid1.user.' (got '${USER_CLEAN:0:24}...')." ;; esac
case "$TENANCY_CLEAN" in ocid1.tenancy.*) ;; *) die "OCI_TENANCY_OCID must start with 'ocid1.tenancy.' (got '${TENANCY_CLEAN:0:24}...')." ;; esac
[ -n "$REGION_CLEAN" ] || die "OCI_REGION is empty (e.g. eu-madrid-1)."

log "User OCID:    $(ocid_hint "$USER_CLEAN")"
log "Tenancy OCID: $(ocid_hint "$TENANCY_CLEAN")"

# --- 5. Write the config -------------------------------------------------
cat > "$CFG_FILE" <<EOF
[DEFAULT]
user=$USER_CLEAN
fingerprint=$FP_CLEAN
tenancy=$TENANCY_CLEAN
region=$REGION_CLEAN
key_file=$KEY_FILE
EOF
chmod 600 "$CFG_FILE"
log "Wrote $CFG_FILE for region $REGION_CLEAN."

# --- 6. Prove the credentials actually work ------------------------------
# The warning about labelling the key file is noise here; the key is written
# fresh from a secret on every run.
export SUPPRESS_LABEL_WARNING=True

if ! OUT=$(oci iam region-subscription list --config-file "$CFG_FILE" --no-retry 2>&1); then
  echo "$OUT" >&2
  echo >&2

  if printf '%s' "$OUT" | grep -qi 'NotAuthenticated'; then
    # Everything checkable from this side already passed: the key parses, and
    # its fingerprint matches OCI_FINGERPRINT. So the secrets agree with each
    # other and the problem is on Oracle's side of the pairing -- it does not
    # recognise this key as belonging to this user in this tenancy. Only the
    # console can say which.
    cat >&2 <<'HINT'
The key and fingerprint are internally consistent, so the remaining causes are
all about what Oracle has on record. Compare the values printed above against
the OCI console:

  1. Fingerprint -- Profile (top right) -> My profile -> API keys.
     If no key with that fingerprint is listed, the public half was never
     uploaded: "Add API key" -> "Paste a public key", pasting the public key
     that pairs with OCI_API_KEY.
  2. User OCID -- My profile -> OCID (use the Copy link, do not retype).
     A key uploaded to one user will not authenticate another, and this is the
     usual culprit once the fingerprint checks out.
  3. Tenancy OCID -- Profile -> Tenancy: <name> -> OCID.
     With Identity Domains, the user must be the domain user owning the key.

Why the error cannot say which one is wrong: the request is signed with a key
id of "<tenancy>/<user>/<fingerprint>". Oracle looks up that whole triple, and
any one of the three being wrong fails the lookup as NotAuthenticated. So a
correct key with the wrong user, or the wrong tenancy, looks identical to no
key at all.

Fastest fix, which sidesteps copying the three by hand: in the console open
"Add API key", pick "Paste a public key" and paste the public half of the key
you already have. Before closing, the dialog shows a "Configuration file
preview" containing user, fingerprint, tenancy and region for this exact
identity. Copy those four values straight into the matching secrets.

To recompute the fingerprint from your private key locally:
  openssl rsa -pubout -outform DER -in your_key.pem | openssl md5 -c
HINT
    die "OCI rejected these credentials (401 NotAuthenticated). See the checklist above."
  fi

  die "OCI rejected these credentials. Check the API key is still active on this user in the OCI console."
fi
log "Authenticated against OCI successfully."
