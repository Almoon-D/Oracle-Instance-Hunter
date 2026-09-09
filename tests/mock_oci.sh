#!/usr/bin/env bash
# Stand-in for the `oci` CLI so hunt.sh can be exercised without a tenancy.
# Behaviour is driven by MOCK_* environment variables; see test_hunt.sh.
set -uo pipefail

ARGS="$*"
STATE="${MOCK_STATE_DIR:?}"
mkdir -p "$STATE"

# The real CLI writes this to stderr on every single call unless
# SUPPRESS_LABEL_WARNING is set. Emitting it here keeps the tests honest about
# stdout/stderr separation: folding it into stdout corrupts every JSON read.
if [ -z "${SUPPRESS_LABEL_WARNING:-}" ]; then
  echo "Warning: To increase security of your API key located at /home/runner/.oci/oci_api_key.pem, append an extra line with 'OCI_API_KEY' at the end." >&2
fi

case "$ARGS" in
  *"compute instance list-vnics"*)
    echo '203.0.113.42'; exit 0 ;;

  *"compute instance list"*)
    printf '%s' "${MOCK_EXISTING:-[]}"; exit 0 ;;

  *"compute image list"*)
    echo "${MOCK_IMAGE_ID-ocid1.image.oc1.eu-madrid-1.aaaa}"; exit 0 ;;

  *"iam availability-domain list"*)
    echo "${MOCK_ADS:-[\"kIdk:EU-MADRID-1-AD-1\"]}"; exit 0 ;;

  *"iam fault-domain list"*)
    echo "${MOCK_FDS:-[\"FAULT-DOMAIN-1\",\"FAULT-DOMAIN-2\"]}"; exit 0 ;;

  *"limits value list"*)
    case "$ARGS" in
      *standard-a1-core-count*)   echo "${MOCK_CORE_LIMIT-4}" ;;
      *standard-a1-memory-count*) echo "${MOCK_MEM_LIMIT-24}" ;;
      *) echo "" ;;
    esac
    exit 0 ;;

  *"compute instance launch"*)
    n=$(( $(cat "$STATE/n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STATE/n"
    printf '%s\n' "$ARGS" >> "$STATE/launches"

    # Refuse anything above MOCK_LIMIT_MAX_OCPUS the way OCI refuses a request
    # over the tenancy's service limit.
    if [ -n "${MOCK_LIMIT_MAX_OCPUS:-}" ]; then
      req=$(printf '%s' "$ARGS" | grep -oE '"ocpus": [0-9]+' | grep -oE '[0-9]+')
      if [ "${req:-0}" -gt "$MOCK_LIMIT_MAX_OCPUS" ]; then
        echo 'ServiceError: {"code": "LimitExceeded", "message": "The following service limits were exceeded: standard-a1-memory-count", "status": 400}' >&2
        exit 1
      fi
    fi
    # Throttle a chosen set of attempt numbers, so a run can interleave 429s
    # with capacity misses the way the live tenancy does.
    case " ${MOCK_THROTTLE_ON:-} " in
      *" $n "*)
        echo 'ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}' >&2
        exit 1 ;;
    esac

    if [ -n "${MOCK_SUCCEED_ON:-}" ] && [ "$n" -ge "$MOCK_SUCCEED_ON" ]; then
      echo '{"data": {"id": "ocid1.instance.oc1.eu-madrid-1.WON", "lifecycle-state": "PROVISIONING"}}'
      exit 0
    fi
    printf '%s\n' "${MOCK_LAUNCH_ERROR:-ServiceError: {\"code\": \"InternalError\", \"message\": \"Out of host capacity.\", \"status\": 500}}" >&2
    exit 1 ;;
esac

echo "mock_oci: unhandled command: $ARGS" >&2
exit 127
