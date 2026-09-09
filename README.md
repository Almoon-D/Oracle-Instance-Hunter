# Oracle Instance Hunter

Repeatedly asks Oracle Cloud for a free-tier instance until capacity frees up,
then stops.

Ampere A1 capacity in the Always Free tier is genuinely scarce:
`LaunchInstance` returns `Out of host capacity.` most of the time, and the only
way through is to keep asking. The point of this repo is to keep asking
*well* — rotating through every availability domain, backing off when Oracle
throttles, and refusing to launch past the free allowance.

Currently set to hunt for **1 OCPU / 6 GB**, stopping after the first one.
Change that in [`hunt.config`](hunt.config).

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

This was **4 OCPU / 24 GB until 15 June 2026**, when Oracle halved it without
an announcement and began enforcing the lower figure in August. Any repository,
guide or hunter still describing 4/24 is out of date — check the date on
anything you read about this. The tenancy's real service limits are read at
startup and clamp the request regardless, so the hunter cannot ask for more
than you are allowed even if the config says otherwise.

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

Start it once: Actions → *Hunt Oracle instance* → *Run workflow*. After that it
keeps itself alive.

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
one. A schedule firing every half hour therefore kept cancelling the queued
350-minute successor and replacing it with a 29-minute run — the scheduler was
not helping the chain, it was competing with it.

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

Earlier versions rotated through every availability domain **and** every fault
domain, pinning each launch to one specific fault domain. That is backwards.
Oracle's own documented workaround for `Out of host capacity` is to *create the
instance without specifying a fault domain*: naming FD-1 asks for a host out of
that one bucket, while omitting it asks Oracle for any eligible host in the
whole availability domain. Omitting is a strict superset, so the same API call
covers more ground.

`ROTATE_FAULT_DOMAINS="true"` in `hunt.config` restores the old behaviour if
you want to experiment.

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
instance is ever terminated. To stop for good, disable both workflows in the
Actions tab.

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
answers with 429 is a capacity check you did *not* make. A 5h45m run at a 45s
floor made 230 attempts of which only 167 were real capacity checks — 27%
thrown away. The floor is currently **75s** on that reasoning, but that figure
is inherited, not measured here.

So every run now reports the numbers that settle it, in the job summary and as
step outputs:

| Output | Meaning |
|---|---|
| `attempts` | Launch calls made |
| `capacity_checks` | Calls Oracle actually answered with a capacity verdict |
| `throttled` / `throttle_pct` | Calls refused with 429 |
| `checks_per_hour` | **The number that matters** |
| `final_pace` | Where the adaptive pace settled |

To tune it, run four ~6-hour hunts with `INTERVAL` set to 45, 75, 90 and 120 in
`hunt.config`, and keep whichever gives the highest **`checks_per_hour`** — not
the highest `attempts`. One report of an always-on hunter elsewhere measured
353 real checks/day at 120s against 282 at 60s, so the curve is not monotonic;
your region and tenancy may sit somewhere else on it entirely.

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
