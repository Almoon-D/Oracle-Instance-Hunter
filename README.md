# Oracle Ampere A1 hunter

Repeatedly asks Oracle Cloud for a free-tier `VM.Standard.A1.Flex` instance
until capacity frees up, then stops.

Ampere A1 capacity in the Always Free tier is genuinely scarce: `LaunchInstance`
returns `Out of host capacity.` most of the time, and the only way through is to
keep asking. The point of this repo is to keep asking *well* — rotating through
every placement, backing off when Oracle throttles, and refusing to launch past
the free allowance.

## How it works

| | |
|---|---|
| `.github/workflows/hunt_ampere.yml` | Schedules the hunt, wires up secrets, reports a win |
| `scripts/oci-setup.sh` | Builds `~/.oci/config` and proves the credentials work |
| `scripts/hunt.sh` | The hunt itself |
| `tests/test_hunt.sh` | Offline tests, run against a mock `oci` CLI |

Each run:

1. **Counts what you already have.** Every non-terminated A1 instance in the
   compartment is added up. If all 4 free OCPUs are allocated, the run stops
   without launching anything. This is the guard that keeps a successful hunt
   from quietly rolling on into a billable second instance.
2. **Narrows the sizes to what still fits.** With 2 OCPUs already in use, only
   2 and 1 are attempted — never 4.
3. **Rotates placements.** Every availability domain and every fault domain, in
   turn, largest size first at each one. Capacity frees up per host pool, so a
   miss in one fault domain says nothing about the next.
4. **Fits the request to the tenancy's service limits.** The A1 limits are read
   up front and the ladder is clamped to them, so it never spends attempts
   asking for more than the tenancy is allowed.
5. **Reads the error before reacting.** `Out of host capacity` means rotate and
   retry. `TooManyRequests` means back off exponentially. `NotAuthenticated`
   means stop — no retry fixes a wrong fingerprint. `LimitExceeded` means this
   *size* is too big, so the ladder drops a rung and keeps hunting; it is only
   fatal once even the smallest size is refused.
6. **Exits green when it simply did not win.** No capacity is the normal
   outcome, not a failure; failing the job on it would bury the real errors and
   fill your inbox.

## Setup

Create these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Where it comes from |
|---|---|
| `OCI_API_KEY` | The whole `.pem` private key, `BEGIN`/`END` lines included, no passphrase |
| `OCI_FINGERPRINT` | Shown next to the API key in the OCI console |
| `OCI_USER_OCID` | Profile → User settings (`ocid1.user...`) |
| `OCI_TENANCY_OCID` | Profile → Tenancy (`ocid1.tenancy...`) |
| `OCI_REGION` | Your **home** region, e.g. `eu-madrid-1` — Always Free A1 only exists there |
| `OCI_COMPARTMENT_OCID` | The compartment to launch into (the tenancy OCID works) |
| `OCI_SUBNET_OCID` | A subnet in a VCN that already has an internet gateway and route |
| `SSH_PUBLIC_KEY` | Contents of `id_ed25519.pub` — the **public** key, one line |

`scripts/oci-setup.sh` checks all of this before the first launch attempt: it
repairs CRLF-mangled and base64-wrapped keys, derives the fingerprint from the
key and refuses to continue if it disagrees with `OCI_FINGERPRINT`, and makes a
live API call to confirm the credentials are accepted.

## Running it

It is built to be left alone, and it keeps itself alive **by chaining, not by
the schedule**.

Each run hunts for up to 350 minutes — the longest a GitHub job may live — and
then, if it ended without capacity, dispatches the next run before it exits.
That is a continuous loop with a handover roughly every 5¾ hours, depending on
no scheduler at all.

The chain exists because **the cron never fired**. Not once, across a full day,
on `*/5` or on `7,37`, with the workflow `active` and the repository committed
to all day. GitHub's scheduler is best-effort and it simply never ran this
repository's schedule. The cron stays declared as a backstop in case it ever
starts working; the `concurrency` group keeps a scheduled run and a chained one
from overlapping.

`workflow_dispatch` is one of only two events `GITHUB_TOKEN` may use to start a
new workflow run — every other event it triggers is ignored, precisely to stop
runaway loops — and that is what makes the chain possible without a personal
access token.

The chain ends by itself when there is nothing left to hunt for: an instance
captured, the allowance already spent, or no size that fits. It also ends if a
run fails inside the first ten minutes, because that is what a broken
configuration looks like and chaining on it would spin a new run every minute.
A failure *after* ten minutes is treated as transient and the chain continues.

To restart a stopped chain, or to run a one-off, use Actions → *Hunt Oracle
Ampere A1* → *Run workflow*. Set `chain` to `false` for a test run that should
not queue a successor.

`duration_minutes` is the whole job budget and doubles as the job timeout; the
hunt gets that minus four minutes, so a win still has time to be recorded
rather than being cut off by the runner. A chained run always asks for 350.

### When it wins

The run opens a GitHub issue **assigned to the repository owner**, with the
instance OCID and public IP. Assignment is what makes the notification
reliable — GitHub always notifies an assignee, whatever the watch settings —
and it reaches you by email if your account has email notifications enabled
(Settings → Notifications → *Assigned*). The same details go to the run's job
summary.

No extra secrets are needed for that. If you want mail sent somewhere other
than your GitHub account address, that needs an SMTP action and its own
credentials as secrets; ask and it can be added.

After a win, later runs cost about 45 seconds each: the pre-flight counts the
A1 OCPUs you now hold, sees the allowance is spent and exits without launching.
Leaving the schedule on is therefore safe and free, and it means hunting
restarts by itself if the instance is ever terminated. To stop for good,
disable the workflow in the Actions tab.

### Cost

On a **public** repository, Actions minutes are free and this costs nothing, so
the chain can be left running indefinitely. On a **private** one, this
schedule burns roughly 1,200 minutes a day against a 2,000-minute monthly
allowance — under two days. Make the repo public, or hunt with dispatched runs
only.

## Tuning

Set these as `env:` on the *Hunt* step:

| Variable | Default | Meaning |
|---|---|---|
| `OCPU_LADDER` | `2` | Sizes tried at each placement, largest first. `2` alone means the full 2 OCPU / 12 GB or nothing |
| `TARGET_OCPUS` | `4` | Free-tier allowance to fill; the run stops at it |
| `GB_PER_OCPU` | `6` | Fixed by the free tier |
| `BOOT_VOLUME_GB` | `50` | Free tier gives 200 GB total block storage |
| `OS_NAME` / `OS_VERSION` | `Canonical Ubuntu` / `24.04` | Image to launch |
| `INTERVAL` | `45` | Floor for seconds between attempts; the pace adapts upward from here |
| `JITTER` | `5` | Random 0–4s added, so parallel hunters desynchronise |

`INTERVAL` is only a floor. The hunt raises its pace by half on every
`TooManyRequests` and eases it back by a quarter on every clean answer, so it
converges on the rate the tenancy actually tolerates rather than a guess.

Those constants come from live runs. At a 20s floor with doubling, a 10-minute
run spent two thirds of its window throttled — which set the floor to 45s. A
5h45m run then made **230 attempts, 167 of them real capacity checks and 63
throttled**, but doubling had overshot to 168s between attempts by the end,
which is why a throttle now costs half again rather than double. The
end-of-run summary reports misses against throttles; if throttles dominate,
raise the floor.

## Tests

```
bash tests/test_hunt.sh      # 21 cases against tests/mock_oci.sh, no tenancy needed
shellcheck -x scripts/*.sh tests/*.sh
actionlint                   # workflow syntax; plain YAML parsing misses this
```

The mock lets the failure paths that matter — the free-tier guard, service
limit clamping and step-down, the capacity/throttle/auth classifier, placement
rotation, and stdout/stderr separation — be exercised
without waiting on real capacity. CI runs both on every push.

## When you win

The run opens a GitHub issue with the instance OCID and public IP, and writes
the same to the job summary. From then on every later run sees the allowance is
full and stops immediately, so it is safe to leave the schedule on — though
turning it off once you have what you wanted is tidier.
