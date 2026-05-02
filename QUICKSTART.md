# QUICKSTART — Run Catapult HLS at scale on Perlmutter (NERSC)

This guide gets a new AmSC team member from zero to running 100-task SLURM
synthesis arrays on Perlmutter.

> **Audience**: AmSC project members (`amsc011` group) with NERSC + FNAL
> Kerberos accounts. If you're outside AmSC, you'll need parallel access to
> a Catapult license server and adjust paths/group names accordingly.

## Prerequisites

You need:

1. **NERSC account in `amsc011`**: confirm with `id -nG | tr ' ' '\n' | grep amsc011`
2. **FNAL Kerberos credentials** — you should be able to `kinit <user>@FNAL.GOV` and SSH to `correlator4.fnal.gov`
3. **Perlmutter login access** — you can `ssh <user>@perlmutter.nersc.gov`
4. **`~/bin/siemens.sh`** on Perlmutter — per-user Catapult environment script (CATAPULT_VER, MGC_HOME, etc.). If you don't have one, ask a teammate (Giuseppe / Arghya) to share theirs

## One-time setup

Do these steps once on Perlmutter. Estimated time: 30 minutes (mostly the rsync).

### 1. Clone the repo with submodules

```bash
cd $HOME/work    # or wherever you keep your code
git clone --recurse-submodules https://github.com/<owner>/wa-hls4ml-search.git
cd wa-hls4ml-search
```

> **Note**: the `Perlmutter_scripts/perlmutter_slurm/` submodule is a private
> fork. If `--recurse-submodules` fails with a 404, you'll need a GitHub PAT
> with `repo` scope (or be added as a collaborator to the fork).

### 2. Configure your environment file

```bash
cp Perlmutter_scripts/.env.example Perlmutter_scripts/.env
# Edit .env: set FNAL_USER and NERSC_USER to your account names
nano Perlmutter_scripts/.env
```

### 3. Create your Python virtual environment

```bash
python3 -m venv $SCRATCH/venv_hls4ml
source $SCRATCH/venv_hls4ml/bin/activate
pip install -r requirements.venv.txt
```

> **Custom venv path?** Set `WA_HLS4ML_VENV=/path/to/your/venv/bin/activate`
> in your shell rc — the SLURM scripts will pick it up.

### 4. Get a Kerberos ticket so you can reach correlator4

```bash
KRB5_CONFIG=~/krb5.conf kinit <fnal_user>@FNAL.GOV
# Enter your FNAL password when prompted
klist  # verify the ticket
```

### 5. Rsync Catapult 2026.1_1 from correlator4 → your $SCRATCH (16 GB, ~10 min)

The shared install at `/pscratch/sd/g/gdg/cad/Siemens/Catapult/2026.1_1`
is owned `gdg:gdg` mode 0770 — not readable to amsc011 group members.
Each user gets their own copy:

```bash
mkdir -p $SCRATCH/cad/Siemens/Catapult
rsync -av --partial --info=progress2 \
  -e "ssh -o GSSAPIAuthentication=yes -o GSSAPIDelegateCredentials=yes \
        -o PreferredAuthentications=gssapi-with-mic" \
  <fnal_user>@correlator4.fnal.gov:/data/Siemens/catapult/2026.1_1 \
  $SCRATCH/cad/Siemens/Catapult/
```

> **Custom Catapult location?** Set `CATAPULT_PATH_OVERRIDE=/path/to/2026.1_1`
> before running the SLURM scripts; default is `$SCRATCH/cad/Siemens/Catapult/2026.1_1`.

### 6. Configure your license server

```bash
cp license_servers_perlmutter.example.json license_servers_perlmutter.json
# The default points at fasic-135413.fnal.gov:1717 with 100 license seats
# (CatAIhls4ml_c feature). Edit if you need different config.
```

### 7. Verify `~/bin/siemens.sh` exists with `CATAPULT_VER=2026.1_1`

```bash
grep CATAPULT_VER ~/bin/siemens.sh
# Expected: export CATAPULT_VER=2026.1_1
# If missing or older: ask Giuseppe or Arghya for an updated copy
```

### 8. Verify the Apptainer container image (`catapult_rocky.sif`) is in place

The container provides Rocky Linux 8 + the libraries Catapult depends on
(it does NOT bundle Catapult itself — that's what step 5's rsync is for).
The default expected location is `~/work/tool-containers/catapult_rocky.sif`.

```bash
ls -lh ~/work/tool-containers/catapult_rocky.sif
# Expected: ~1.3 GB file
# If missing: ask Giuseppe or a teammate to scp/rsync their copy, or
# (advanced) build from the recipe at:
#   ~/work/tool-containers/containers/apptainer_catapult_rocky.def
# Override with `--sif /path/to/catapult_rocky.sif` if your copy lives elsewhere.
```

## Run a smoke test (1 task, ~10-30 min)

```bash
cd $HOME/work/wa-hls4ml-search    # repo root — important for relative paths
bash slurm/examples/run_single.sh
```

You should see:

1. Local model generation (~30 sec)
2. `Submitted SLURM job array: <jobid>`
3. Polling output every 30 sec showing the task state
4. Eventually: `All SLURM tasks completed successfully` + report-collection

Outputs land in `$SCRATCH/catapult_runs/run_<timestamp>_<uuid>/`.

## Run the pilot (5 toy tasks, ~5 min)

```bash
bash slurm/examples/run_pilot.sh
```

5 tiny models synthesized in parallel (express_amsc QoS allows up to 32
concurrent tasks; 5 fits comfortably).

## Run at scale (100 toy tasks, ~12 min)

```bash
bash slurm/examples/run_scale_toy.sh
```

100 toy models. **Note**: `express_amsc` QoS is capped at 32 concurrent
nodes (group-wide), so the 100 tasks run in waves of 32. License pool
(105 seats) is NOT the bottleneck — the QoS cap is.

For 100 *real* models (not toy), use:
```bash
bash slurm/examples/run_scale.sh
```
(Real models take ~20-40 min each; total wall-clock with the 32-node cap
is ~1-2 hours.)

## Where outputs go

Each run creates a timestamped directory under `$SCRATCH/catapult_*/`:

```
run_<YYYYMMDD>_<HHMMSS>_<uuid>/
├── data/reports/raw/dense_*.json     ← parsed synthesis reports (USE THESE)
├── tarballs/dense_*.tar.gz           ← full bundled output per model
├── build/dense_*/catapult_native/    ← raw Catapult work dirs (debug)
├── slurm_logs/task_*.{out,err}       ← per-task SLURM logs
├── joblist.txt                        ← inputs to each task
└── job_array.sh                       ← the SBATCH script that ran
```

## Recover from a crashed orchestrator

If your shell session dies (laptop closed, ssh disconnected, etc.) while
the polling loop is running, the SLURM tasks keep going independently —
you just lose the report-collection. To re-collect after the array finishes:

```bash
cd $HOME/work/wa-hls4ml-search
source $SCRATCH/venv_hls4ml/bin/activate
python iter_manager_catapult.py -o $SCRATCH/anywhere \
  --collect-slurm $SCRATCH/catapult_*/run_<timestamp>_<uuid>
```

(The `-o` is required by argparse but ignored when `--collect-slurm` is set;
any path works.)

## Common errors + fixes

| Error | Cause | Fix |
|---|---|---|
| `mgls_errno = 515` | License server unreachable | Verify `nc -zv fasic-135413.fnal.gov 1717` works; check `license_servers_perlmutter.json` points there |
| `command not found: catapult` | Wrong `CATAPULT_PATH_OVERRIDE` | Verify `$SCRATCH/cad/Siemens/Catapult/2026.1_1/Mgc_home/bin/catapult` exists; re-rsync if not |
| `QOSGrpNodeLimit` (PENDING reason) | `express_amsc` is capped at 32 nodes group-wide | Wait for in-flight tasks (yours or other AmSC users') to finish |
| `Permission denied (gssapi-with-mic)` | Missing/expired Kerberos ticket | `KRB5_CONFIG=~/krb5.conf kinit <user>@FNAL.GOV` |
| `apptainer: chdir ...: no such file or directory` | Path symlink mismatch | `Perlmutter_scripts/catapult_shell.sh` already binds both `$HOME` and `$_HOME_REAL`; if it still fails check `readlink -f $HOME` |
| `catapult: invalid argument: -shell` | Using Catapult 2025.4_1 with `-product genesis` | Make sure `~/bin/siemens.sh` has `CATAPULT_VER=2026.1_1`; the `-product genesis` flag only works in 2026 |

## Going further

- **`slurm/README.md`** — internal docs for the SLURM module + an index of every file the SLURM workflow touches
- **`Perlmutter_scripts/perlmutter_slurm/README.md`** — Giuseppe's reference SLURM tutorials (the submodule), great for learning SLURM patterns beyond this project
