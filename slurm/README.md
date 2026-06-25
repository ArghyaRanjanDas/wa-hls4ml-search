# `slurm/` — SLURM job-array submission for Catapult HLS

This directory contains the SLURM-specific code for running Catapult HLS synthesis at scale on Perlmutter (NERSC). The full SLURM surface lives here; the synthesis backend (model generation, `catapult_shell.sh`, report collection) lives in the parent module.

## What's in here

| Path | Purpose |
|---|---|
| `__init__.py` | Package marker + public API doc |
| `cli.py` | `add_slurm_args(parser)` — argparse group for `--slurm`, `--slurm-account`, `--slurm-time`, `--slurm-qos`, `--slurm-constraint`, `--collect-slurm` |
| `job_array.py` | `write_script(...)` and `submit(...)` — render `job_array.sh` SBATCH script, `sbatch` it, poll `squeue` until done, check `sacct` for failures |
| `examples/run_single.sh` | 1-task smoke test (1 real model) |
| `examples/run_pilot.sh` | 5-task pilot (toy models, ~5 min) |
| `examples/run_scale.sh` | 100-task production run (real models, ~45 min wall-clock with the 32-node QoS cap) |
| `examples/run_scale_toy.sh` | 100-task toy stress test (~12 min, 99/100 success rate) |

### Catapult ASIC orchestrators (`examples/`)

The scripts below drive Catapult HLS synthesis via **GNU parallel** (not SLURM job arrays).
Each orchestrator spawns 3 nodes × 100 parallel slots = 300 concurrent Catapult instances
(one per license), submits batches via `sbatch`, and auto-retries with `--resume-failed`.

| Script | Purpose |
|---|---|
| `submit_45nm_sz128.sh` | 45nm sz128 extension: L=1/2/3, `N_LAYERS=N sbatch`. Cartesian (L≤2) or LHS (L=3). |
| `submit_45nm_nlayer_lhs.sh` | 45nm deep networks: L≥4, `N_LAYERS=N sbatch`. LHS from scratch. |
| `run_dense_1layer_gf22_cartesian.sh` | GF22nm 1-layer full cartesian (1,800 archs × 4 RF). |
| `submit_gf22_nlayer_lhs.sh` | GF22nm L≥2 LHS: models extracted from 45nm archive, `N_LAYERS=N sbatch`. Supports `EXCLUDE_FILE`. |
| `run_rerun_from_archive.sh` | Retry failed designs using model extracted from a sibling-RF tarball. |
| `archive_run.sh` | Archive a completed run to nangate45/ or gf22fdx/ (auto-detects tech from path). |
| `check_failures.sh` | Scan a run dir for missing tarballs; write `failed_designs.txt`. |
| `populate_failed_designs.py` | Scan archive JSON reports for synthesis failures → `failed_designs.txt`. |
| `sample_lhs_from_archive.py` | KD-tree LHS sampling from the 45nm archive → candidates file for GF22 runs. |

## Index of files the SLURM workflow touches (across the whole repo)

The SLURM driver lives here, but it depends on a few sibling files. For a complete review:

| File | Role in SLURM flow |
|---|---|
| `iter_manager_catapult.py` | Orchestrator: prepare phase (model gen, joblist creation), dispatch to `slurm.job_array.submit(...)`, then collect reports. Each SLURM array task re-invokes this script with `--run-single-job <line>` to do one synthesis. |
| `slurm/job_array.py` (this dir) | Renders `job_array.sh` and submits it. Polls + reports failures. |
| `slurm/cli.py` (this dir) | argparse group consumed by `iter_manager_catapult.create_parser()` |
| `Perlmutter_scripts/catapult_shell.sh` | Apptainer wrapper. Each SLURM task runs this inside the container. Sources `~/bin/siemens.sh`, applies `LM_LICENSE_FILE` / `SALT_LICENSE_SERVER` / `CATAPULT_PATH` overrides (because siemens.sh hardcodes broken defaults), invokes `catapult -product genesis -shell` |
| `Perlmutter_scripts/perlmutter_slurm/` (submodule) | Reference SLURM tutorials (08_array_parallel_catapult is the same-design-N-times pattern; 07_array_parallel shows outer-array + inner-GNU-parallel for true 100-concurrent on the 32-node QoS cap) |
| `~/bin/siemens.sh` (per-user, NOT in repo) | Catapult environment setup (CATAPULT_VER, MGC_HOME, etc.) — sourced inside the container by catapult_shell.sh |
| `license_servers_perlmutter.json` (gitignored, copy from .example) | Per-user license server config: `{"servers": [{"host": "fasic-135413.fnal.gov", "port": 1717, "licenses": 100}]}`. Drives both `LM_LICENSE_FILE` env var and the SLURM array `%total_licenses` throttle. |
| `$SCRATCH/cad/Siemens/Catapult/2026.1_1/` (per-user) | The Catapult install. Each user rsyncs from correlator4:/data/Siemens/catapult/2026.1_1/ — see QUICKSTART.md. |
| `$SCRATCH/venv_hls4ml/` (per-user, override with `WA_HLS4ML_VENV` env) | Python virtual env activated by each SLURM task before invoking iter_manager_catapult.py |

## How a single SLURM task flows

```
iter_manager_catapult.py --slurm  (on login node)
  ↓ generates models, builds joblist.txt, calls...
slurm.job_array.submit(...)
  ↓ writes job_array.sh, sbatch it
SLURM dispatches array task N to a compute node
  ↓ task reads JOB_LINE from joblist.txt (line N+1 via sed)
  ↓ exports LM_LICENSE_FILE=1717@fasic-135413.fnal.gov
  ↓ activates venv, runs:
    python iter_manager_catapult.py --run-single-job "${JOB_LINE}"
  ↓ iter_manager parses job line into kwargs, calls...
  _run_catapult_flow(hls_dir, shell_script, flow_tcl, cfg_json)
  ↓ which runs catapult_shell.sh inside apptainer
  ↓ catapult_shell.sh sources siemens.sh, overrides LM_LICENSE_FILE
    + SALT_LICENSE_SERVER + CATAPULT_PATH, invokes:
    catapult -product genesis -shell -eval '<TCL>'
  ↓ Catapult does HLS, writes outputs to $WORK_DIR/catapult_native/
SLURM task exits 0
  ↓ slurm.job_array.submit's polling loop sees task gone from squeue
  ↓ once all tasks done, control returns to iter_manager_catapult.py
iter_manager_catapult.py
  ↓ calls _collect_reports(run_dir): parses each catapult_native/ →
    JSON report; bundles into tar.gz per task
DONE — outputs in $SCRATCH/catapult_*/run_<timestamp>/{data/reports/raw,tarballs}/
```

## Public API

```python
# In iter_manager_catapult.py:
from slurm import job_array, cli as slurm_cli

# In create_parser():
slurm_cli.add_slurm_args(parser)

# In main() synthesis branch:
job_array.submit(args, run_dir, joblist_path, job_lines, total_licenses,
                 lm_license_file)
```

## Quick start

See **`QUICKSTART.md` at the repo root** for the full new-user setup (Kerberos, rsync the Catapult install, venv, smoke test).

To run quickly once setup is done:
```bash
bash slurm/examples/run_pilot.sh   # 5 toy tasks, ~5 min
bash slurm/examples/run_single.sh  # 1 real model, ~10-30 min
```

## Notes

- **Code surface**: ~135 lines (`job_array.py` + `cli.py`). `iter_manager_catapult.py`'s synthesis-phase branch (3-way: SLURM / GNU parallel / sequential) calls into here only for the SLURM path.
- **`express_amsc` QoS cap**: `GrpTRES=node=32` — caps concurrent array tasks at 32 nodes total across the AmSC group.
- **Each task uses 1 whole node** (`#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=8 --mem=64G`).
- **Recovery**: if the orchestrator's polling loop dies mid-run, the SLURM tasks keep going. Use `python iter_manager_catapult.py -o $SCRATCH/foo --collect-slurm <run_dir>` to re-collect reports after the array finishes.
