"""SLURM job array submission for Catapult HLS synthesis.

Two functions:
    write_script(...)  — Render `job_array.sh` SBATCH script from args + joblist.
    submit(...)        — Write the script, sbatch it, poll squeue, check sacct.

Each array task runs one synthesis via `iter_manager_catapult.py --run-single-job`.
The license server is configured directly (no SSH tunneling) — see
QUICKSTART.md for the prerequisite Perlmutter setup.
"""

import logging
import math
import os
import subprocess
import sys
import time
from collections import Counter

logger = logging.getLogger(__name__)


def _lm_assignment_bash(servers, parallelism):
    """Return bash snippet that sets JOB_LM based on GLOBAL_IDX.

    Jobs are assigned to servers in order: first server gets jobs 0..c1-1,
    second gets c1..c1+c2-1, etc. Each synthesis sets its own LM_LICENSE_FILE
    so separate pools are used independently.
    """
    if len(servers) == 1:
        lm = f"{servers[0]['port']}@{servers[0]['host']}"
        return f'    JOB_LM="{lm}"'

    lines = ['    GLOBAL_IDX=$(( SLURM_ARRAY_TASK_ID * ' + str(parallelism) + ' + local_idx ))']
    cumulative = 0
    for i, s in enumerate(servers):
        lm = f"{s['port']}@{s['host']}"
        cumulative += s['licenses']
        if i == 0:
            lines.append(f'    if (( GLOBAL_IDX < {cumulative} )); then')
        elif i < len(servers) - 1:
            lines.append(f'    elif (( GLOBAL_IDX < {cumulative} )); then')
        else:
            lines.append(f'    else')
        lines.append(f'        JOB_LM="{lm}"')
    lines.append('    fi')
    return '\n'.join(lines)


def write_script(run_dir, joblist_path, total_licenses, lm_license_file,
                 output_dir, args, servers=None):
    """Write {run_dir}/job_array.sh for SLURM job array submission.

    Each array task gets one compute node, sets LM_LICENSE_FILE directly to
    the configured server (no SSH tunneling), activates the venv, and runs
    a single synthesis via --run-single-job.

    Args:
        run_dir:         Run directory (job_array.sh + slurm_logs/ live here).
        joblist_path:    Absolute path to joblist.txt (one job line per task).
        total_licenses:  Concurrency cap for the array (--array=0-N%total_licenses).
        lm_license_file: FlexLM-format license-server string (e.g.
                         "1717@fasic-135413.fnal.gov").
        output_dir:      The original `-o` value (passed through to per-task
                         iter_manager_catapult.py invocation).
        args:            argparse Namespace with slurm_account, slurm_time,
                         slurm_qos, slurm_constraint.

    Returns:
        Absolute path to the written job_array.sh.
    """
    n_jobs = sum(1 for _ in open(joblist_path) if _.strip())
    # Path to the iter_manager script — assumes slurm/ is a sibling of it.
    script_path = os.path.abspath(
        os.path.join(os.path.dirname(__file__), os.pardir, 'iter_manager_catapult.py')
    )
    # Override the venv path with WA_HLS4ML_VENV so other users can point at
    # their own venv without editing this code.
    venv_activate = os.environ.get(
        "WA_HLS4ML_VENV",
        os.path.join(os.environ.get("SCRATCH", ""), "venv_hls4ml", "bin", "activate"),
    )

    parallelism = getattr(args, 'slurm_parallelism', 1)
    cpus_per_job = getattr(args, 'slurm_cpus_per_job', 2)
    mem_per_job = getattr(args, 'slurm_mem_per_job', '32G')
    mem_per_job_gb = int(mem_per_job.rstrip('Gg'))

    if servers is None:
        servers = [{"host": lm_license_file.split("@")[1],
                    "port": lm_license_file.split("@")[0],
                    "licenses": total_licenses}]
    lm_assignment = _lm_assignment_bash(servers, parallelism)

    n_arrays = math.ceil(n_jobs / parallelism)
    total_cpus = parallelism * cpus_per_job
    total_mem_gb = parallelism * mem_per_job_gb
    concurrent_arrays = max(1, total_licenses // parallelism)

    script_content = f"""#!/bin/bash
#SBATCH --job-name=catapult_hls4ml
#SBATCH --account={args.slurm_account}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={total_cpus}
#SBATCH --mem={total_mem_gb}G
#SBATCH --constraint={args.slurm_constraint}
#SBATCH --time={args.slurm_time}
#SBATCH --qos={args.slurm_qos}
#SBATCH --array=0-{n_arrays - 1}%{concurrent_arrays}
#SBATCH --output={run_dir}/slurm_logs/task_%a.out
#SBATCH --error={run_dir}/slurm_logs/task_%a.err

set -euo pipefail

# ---- Read job lines for this array task ({parallelism} per node) ----
START=$(( SLURM_ARRAY_TASK_ID * {parallelism} + 1 ))
END=$(( START + {parallelism} - 1 ))
mapfile -t JOB_LINES < <(sed -n "${{START}},${{END}}p" "{joblist_path}")
if [[ ${{#JOB_LINES[@]}} -eq 0 ]]; then
    echo "ERROR: no job lines for SLURM_ARRAY_TASK_ID=$SLURM_ARRAY_TASK_ID" >&2
    exit 1
fi
echo "Task $SLURM_ARRAY_TASK_ID: ${{#JOB_LINES[@]}} synthesis job(s) (lines ${{START}}-${{END}})"

# ---- Activate venv and run syntheses in parallel ----
# Each synthesis gets its own LM_LICENSE_FILE to distribute across server pools.
source "{venv_activate}"
pids=()
local_idx=0
for JOB_LINE in "${{JOB_LINES[@]}}"; do
{lm_assignment}
    LM_LICENSE_FILE="$JOB_LM" python "{script_path}" -o "{output_dir}" --run-single-job "${{JOB_LINE}}" &
    pids+=($!)
    local_idx=$(( local_idx + 1 ))
done
failed=0
for pid in "${{pids[@]}}"; do
    wait "$pid" || failed=$(( failed + 1 ))
done
if [[ $failed -gt 0 ]]; then
    echo "ERROR: $failed synthesis job(s) failed" >&2
    exit 1
fi
"""

    script_path_out = os.path.join(run_dir, "job_array.sh")
    with open(script_path_out, "w") as f:
        f.write(script_content)
    os.chmod(script_path_out, 0o755)
    logger.info(f"Wrote SLURM job array script: {script_path_out}")
    return script_path_out


def submit(args, run_dir, joblist_path, job_lines, total_licenses,
           lm_license_file, servers=None):
    """Write job_array.sh, submit via sbatch, poll until done, report failures.

    Args:
        args:            argparse Namespace.
        run_dir:         Run directory.
        joblist_path:    Absolute path to joblist.txt.
        job_lines:       List of joblist lines (just used for the count log).
        total_licenses:  Concurrency cap for the array.
        lm_license_file: FlexLM license-server string.
        servers:         List of {"host", "port", "licenses"} dicts for per-pool
                         assignment. If None, all jobs use lm_license_file.
    """
    # Create slurm_logs directory
    slurm_logs_dir = os.path.join(run_dir, "slurm_logs")
    os.makedirs(slurm_logs_dir, exist_ok=True)

    # Write job_array.sh
    script_path = write_script(
        run_dir, joblist_path, total_licenses, lm_license_file, args.output, args,
        servers=servers,
    )

    # Submit via sbatch
    logger.info(f"Submitting SLURM job array ({len(job_lines)} tasks, "
                f"max {total_licenses} concurrent)...")
    result = subprocess.run(
        ["sbatch", script_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        logger.error(f"sbatch failed:\n{result.stderr}")
        sys.exit(result.returncode)

    # Parse job ID from "Submitted batch job 12345678"
    job_id = result.stdout.strip().split()[-1]
    logger.info(f"Submitted SLURM job array: {job_id}")
    logger.info(f"SLURM logs: {slurm_logs_dir}")

    # Persist job ID so check_failures.sh can query sacct without knowing it
    jobid_path = os.path.join(run_dir, "slurm_job_id.txt")
    with open(jobid_path, "w") as f:
        f.write(job_id + "\n")
    logger.info(f"Job ID saved: {jobid_path}")

    # Poll squeue until all tasks finish
    logger.info("Polling squeue every 30s until all tasks complete...")
    while True:
        time.sleep(30)
        sq = subprocess.run(
            ["squeue", "-j", job_id, "--noheader", "-o", "%T"],
            capture_output=True, text=True,
        )
        states = [s.strip() for s in sq.stdout.strip().splitlines() if s.strip()]
        if not states:
            logger.info("All SLURM tasks have finished.")
            break
        state_counts = Counter(states)
        logger.info(f"  SLURM tasks: {dict(state_counts)}")

    # Check for failures via sacct
    sacct = subprocess.run(
        ["sacct", "-j", job_id, "--format=JobID,State,ExitCode", "--noheader", "-P"],
        capture_output=True, text=True,
    )
    failed_tasks = []
    for line in sacct.stdout.strip().splitlines():
        parts = line.split("|")
        if len(parts) >= 3:
            task_id, state, exit_code = parts[0], parts[1], parts[2]
            if state == "FAILED" or (exit_code != "0:0" and "batch" not in task_id
                                     and "." not in task_id):
                failed_tasks.append((task_id, state, exit_code))

    if failed_tasks:
        logger.warning(f"{len(failed_tasks)} task(s) failed:")
        for task_id, state, exit_code in failed_tasks:
            logger.warning(f"  {task_id}: {state} (exit {exit_code})")
        logger.warning(f"Check logs in {slurm_logs_dir}")
    else:
        logger.info("All SLURM tasks completed successfully.")
