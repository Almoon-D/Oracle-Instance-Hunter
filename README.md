# Oracle Instance Hunter

Repeatedly asks Oracle Cloud for a free-tier instance until capacity frees up,
then stops.

Ampere A1 capacity in the Always Free tier is genuinely scarce:
`LaunchInstance` returns `Out of host capacity.` most of the time, and the only
way through is to keep asking. The point of this repo is to keep asking
*well* — rotating through every availability domain, backing off when Oracle
throttles, and refusing to launch past the free allowance.

> **Status: finished and running.** The secrets are configured, the workflows
> are live, and the hunt restarts itself. [`hunt.config`](hunt.config) is the
> only file meant to be edited. Nothing here needs further development.

**Currently hunting for: 1 OCPU / 6 GB, stopping after the first one.**

## Start here

1. **Check [`hunt.config`](hunt.config)** says what you want. It is a
   commented file of plain settings — shape, size, when to stop, how fast to
   ask. Edit and commit; the next run picks it up.
2. **It is already running.** If you ever need to start it by hand: Actions →
   *Hunt Oracle instance* → *Run workflow*.
3. **Wait.** A win opens a GitHub issue assigned to you with the instance OCID
   and public IP. Nothing else is needed.

To stop it for good, disable **both** workflows in the Actions tab (*Hunt
Oracle instance* and *Hunt watchdog*). Disabling only one leaves the other
able to restart it.

## How it works

| | |
|---|---|
| **`hunt.config`** | **The dashboard — the one file to edit** |
| `.github/workflows/hunt.yml` | Runs the hunt, wires up secrets, reports a win, queues its own successor |
| `.github/workflows/hunt-watchdog.yml` | Restarts the chain if it ever stops |
| `scripts/oci-setup.sh` | Builds `~/.oci/config` and proves the credentials work |
| `scripts/hunt.sh` | The hunt itself |
| `tests/test_hunt.sh` | 33 offline tests, run against a mock `oci` CLI |

Each run:

1. **Counts what you already have.** Every non-terminated instance of the
   configured shape is added up. If `STOP_AT_TOTAL_OCPUS` is already held, the
   run stops without launching anything. This is the guard that keeps a
   successful hunt from quietly rolling on into a billable second instance.
2. **Narrows the sizes to what still fits.** With 1 of 2 OCPUs already in use,
   only 1 is attempted — never 2.
3. **Rotates availability domains.** Each one in turn, largest size first.
   Capacity frees up per host pool, so a miss in one says nothing about the
   next.
4. **Fits the request to the tenancy's service limits.** They are read up front
   and the ladder is clamped to them, so it never spends attempts asking for
   more than the tenancy is allowed.
5. **Reads the error before reacting.** `Out of host capacity` means rotate and
   retry. `TooManyRequests` means back off. `NotAuthenticated` means stop — no
   retry fixes a wrong fingerprint. `LimitExceeded` means this *size* is too
   big, so the ladder drops a rung and keeps hunting; it is only fatal once
   even the smallest size is refused.
6. **Exits green when it simply did not win.** No capacity is the normal
   outcome, not a failure; failing the job on it would bury the real errors and
   fill your inbox.

### What a run's result means

Every run ends with one of four results, shown in the job summary:

| Result | Meaning | Chain continues? |
|---|---|---|
| `no-capacity` | Oracle had nothing free this window. **The normal outcome.** | Yes |
| `launched` | Got one. An issue is opened with the details. | No — done |
| `already-satisfied` | `STOP_AT_TOTAL_OCPUS` is already held, so nothing was attempted. Runs cost ~45s from here on. | No — done |
| `no-fit` | Some allowance is free but no size in `OCPU_LADDER` fits it. Add a smaller size to the ladder. | No |

A red run means a real problem — bad credentials, no A1 quota at all, or an
unrecognised error — and the job summary says which.

## The dashboard

Everything about *what* is hunted for lives in [`hunt.config`](hunt.config):
shape, size, memory, boot volume, OS, when to stop, how fast to ask, where to
ask. It is a commented shell file — edit a value, commit, done. The workflow
configures none of it.

Precedence is **environment variable > `hunt.config` > built-in default**, so a
one-off override is still possible without editing the file.

The shipped preset:

```sh
SHAPE="VM.Standard.A1.Flex"
OCPU_LADDER="1"            # ask for a 1 OCPU machine
GB_PER_OCPU="6"            # free tier fixes A1 at 6 GB per OCPU -> 6 GB
STOP_AT_TOTAL_OCPUS="1"    # stop for good once one is captured
```

The file also carries commented-out presets for the full 2 OCPU / 12 GB Ampere
box and for the fixed-size AMD `VM.Standard.E2.1.Micro`, as worked examples of
what changing "the kind of instance" involves.

### What Always Free actually gives you

**2 OCPUs and 12 GB of memory in total** for `VM.Standard.A1.Flex`
(1,500 OCPU-hours + 9,000 GB-hours a month), which you may split as one
2-OCPU machine or two 1-OCPU machines.

This was 4 OCPU / 24 GB until **15 June 2026**, when Oracle halved it without
an announcement and began enforcing the lower figure in August. That date
matters when reading anything else about this: a guide or hunter still
describing 4/24 was written before the change. The tenancy's real service
limits are read at startup and clamp the request regardless, so the hunter
cannot ask for more than you are allowed even if the config says otherwise.

## Running it

Each run hunts for up to 350 minutes — the longest a GitHub job may live — and
then, if it ended without capacity, dispatches the next run before it exits.
That is a continuous loop with a handover roughly every 5¾ hours, and the only
minutes not spent asking Oracle are the ~40 seconds each handover spends
reinstalling the CLI.

`workflow_dispatch` is one of only two events `GITHUB_TOKEN` may use to start a
new workflow run — every other event it triggers is ignored, precisely to stop
runaway loops — and that is what makes the chain possible without a personal
access token.

**There is deliberately no cron on the hunt workflow.** GitHub keeps only one
*pending* run per concurrency group, and a newer queued run replaces the older
one. A schedule would therefore keep cancelling the queued 350-minute
successor and putting a short run in its place — competing with the chain
rather than backing it up.

Instead `hunt-watchdog.yml` runs every three hours, checks whether a hunt is
already running or queued, and dispatches one only if the chain has actually
stopped. It is not in the concurrency group, so it can never displace a pending
run; it costs a few seconds per firing.

The chain ends by itself when there is nothing left to hunt for: an instance
captured, the allowance already spent, or no size that fits. It also ends if a
run fails inside the first ten minutes, because that is what a broken
configuration looks like and chaining on it would spin a new run every minute.
A failure *after* ten minutes is treated as transient and the chain continues.
Either way the watchdog will try again within three hours.

Set `chain` to `false` for a one-off test run that should not queue a successor.

### Why no fault domain is pinned

Oracle's documented workaround for `Out of host capacity` is to create the
instance *without* specifying a fault domain. Naming FD-1 asks for a host out
of that one bucket; omitting it asks Oracle for any eligible host in the whole
availability domain. Omitting is a strict superset, so the same API call covers
more ground — which is why the hunt rotates availability domains only, and
leaves the fault domain to Oracle.

`ROTATE_FAULT_DOMAINS="true"` in `hunt.config` pins them again if you want to
experiment.

Worth knowing for this tenancy: `eu-madrid-1` presents a **single availability
domain**, so the rotation has nothing to rotate through and every attempt goes
to the same place. That is not a fault — omitting the fault domain already asks
for any host in that domain, which is the widest request available — but it
means the placement machinery only starts earning its keep in a multi-domain
region.

### When it wins

The run opens a GitHub issue **assigned to the repository owner**, with the
instance OCID and public IP. Assignment is what makes the notification
reliable — GitHub always notifies an assignee, whatever the watch settings —
and it reaches you by email if your account has email notifications enabled
(Settings → Notifications → *Assigned*). The same details go to the run's job
summary.

After a win, later runs cost about 45 seconds each: the pre-flight counts what
you now hold, sees `STOP_AT_TOTAL_OCPUS` is met and exits without launching. So
leaving everything on is safe and free, and hunting restarts by itself if the
instance is ever terminated.

### Cost

On a **public** repository, Actions minutes are free and this costs nothing, so
the chain can be left running indefinitely. On a **private** one it burns
roughly 1,400 minutes a day against a 2,000-minute monthly allowance — under
two days. Make the repo public, or hunt with dispatched runs only.

## Measuring the pace floor

`INTERVAL` is a floor, not a fixed rate: the hunt raises its pace by half on
every `TooManyRequests` and eases it back by a quarter on every clean answer,
converging on the rate the tenancy actually tolerates rather than a guess.

**Asking faster is not the same as asking better.** Every request Oracle
answers with 429 is a capacity check you did *not* make — so the figure worth
maximising is capacity checks per hour, not attempts per hour.

**This has been measured on this tenancy, and the floor turned out not to
matter.** Two full windows of the same length, at the two floors:

| | 45s floor | 75s floor |
|---|---|---|
| Attempts | 230 | 222 |
| Real capacity checks | 167 | 164 |
| Rate-limited (429) | 63 (27%) | 58 (26%) |
| **Capacity checks per hour** | **29** | **28** |
| Pace at end of run | 168s | 113s |

Within the noise, identical. The adaptive backoff converges on the rate the
tenancy tolerates whichever floor it starts from, so the binding constraint is
Oracle's sustained rate for this tenancy — roughly 28–30 capacity checks an
hour — and not `INTERVAL`. The floor stays at 75s because it reaches that rate
with slightly less time spent backing off, but tuning it is not the lever it
looks like.

Every run reports the numbers, in the job summary and as step outputs:

| Output | Meaning |
|---|---|
| `attempts` | Launch calls made |
| `capacity_checks` | Calls Oracle actually answered with a capacity verdict |
| `throttled` / `throttle_pct` | Calls refused with 429 |
| `checks_per_hour` | **The number that matters** |
| `final_pace` | Where the adaptive pace settled |

45s and 75s are measured above and agree, so there is little point repeating
them. What is still untested here is the slow end: one report of an always-on
hunter elsewhere measured 353 real checks/day at 120s against 282 at 60s, which
is the one reason to think a much higher floor might beat both. If you want to
settle it, run ~6-hour hunts at `INTERVAL=120` and `INTERVAL=180` and compare
`checks_per_hour` against the 28 above — that is the only number that decides
it. Expect a null result.

## Capacity report

Oracle offers `CreateComputeCapacityReport` to ask whether a shape can be
placed before trying to place it. `CAPACITY_REPORT="true"` in `hunt.config`
turns it on.

It is used **advisory-only**: it decides which availability domain to try
*first*, and the run logs what the report said next to what the launch actually
did. It never skips a launch attempt. That restraint is deliberate —
[oracle/oci-cli#748](https://github.com/oracle/oci-cli/issues/748) documents the
report returning `AVAILABLE` for a domain where A1 launches failed and
`OUT_OF_HOST_CAPACITY` for one where they succeeded. Gating launches on it
would mean skipping the domain that would have won.

Turn it on for a few runs to see whether it agrees with reality in your region,
then decide. It needs `OCI_TENANCY_OCID`, because the report must be requested
against the root compartment.

## Secrets

**These are already configured on this repository.** The table is here for
rebuilding them, rotating a key, or setting the hunter up somewhere else
(Settings → Secrets and variables → Actions).

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
live API call to confirm the credentials are accepted. If a secret is wrong,
the run fails in its first minute with a checklist rather than hours later with
a cryptic `NotAuthenticated`.

## Tests

```
bash tests/test_hunt.sh      # 33 cases against tests/mock_oci.sh, no tenancy needed
shellcheck -x scripts/*.sh tests/*.sh
shellcheck --shell=bash --exclude=SC2034 hunt.config
actionlint                   # workflow syntax; plain YAML parsing misses this
```

The mock lets the failure paths that matter — the free-tier guard, service
limit clamping and step-down, the capacity/throttle/auth classifier, placement
rotation, and stdout/stderr separation — be exercised without waiting on real
capacity. The suite loads the real `hunt.config`, so the shipped preset is
itself under test. CI runs all of it on every push.
