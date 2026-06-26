"""SLURM job array submission for Catapult HLS synthesis.

Two functions:
    write_script(...)  — Render `job_array.sh` SBATCH script from args + joblist.
    submit(...)        — Write the script, sbatch it, poll squeue, check sacct.

Each array task runs one synthesis via `iter_manager_catapult.py --run-single-job`.
The license server is configured directly (no SSH tunneling) — see
QUICKSTART.md for the prerequisite Perlmutter setup.
"""

import logging
import os
import subprocess
import sys
import time
from collections import Counter

logger = logging.getLogger(__name__)


def write_script(run_dir, joblist_path, total_licenses, lm_license_file,
                 output_dir, args):
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

    # Build the --run-single-job invocation. shell_script/flow_tcl/cfg_json
    # come from JOB_LINE itself (set by _format_job_line in the prepare phase),
    # so we don't pass --catapult_shell or --flow_tcl here — they'd be ignored.
    single_job_cmd = (
        f'python "{script_path}" -o "{output_dir}" '
        f'--run-single-job "${{JOB_LINE}}"'
    )

    script_content = f"""#!/bin/bash
#SBATCH --job-name=catapult_hls4ml
#SBATCH --account={args.slurm_account}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --constraint={args.slurm_constraint}
#SBATCH --time={args.slurm_time}
#SBATCH --qos={args.slurm_qos}
#SBATCH --array=0-{n_jobs - 1}%{total_licenses}
#SBATCH --output={run_dir}/slurm_logs/task_%a.out
#SBATCH --error={run_dir}/slurm_logs/task_%a.err

set -euo pipefail

# ---- Read job line for this array task ----
JOB_LINE=$(sed -n "$(($SLURM_ARRAY_TASK_ID + 1))p" "{joblist_path}")
if [[ -z "${{JOB_LINE}}" ]]; then
    echo "ERROR: no job line for SLURM_ARRAY_TASK_ID=$SLURM_ARRAY_TASK_ID" >&2
    exit 1
fi
echo "Task $SLURM_ARRAY_TASK_ID: ${{JOB_LINE}}"

# ---- License: direct connection to FNAL Catapult license server ----
# Compute nodes can reach this directly via Perlmutter outbound NAT; no SSH
# tunnels or KRB5 ccache needed.
export LM_LICENSE_FILE="{lm_license_file}"

# ---- Activate venv and run synthesis ----
source "{venv_activate}"
{single_job_cmd}
"""

    script_path_out = os.path.join(run_dir, "job_array.sh")
    with open(script_path_out, "w") as f:
        f.write(script_content)
    os.chmod(script_path_out, 0o755)
    logger.info(f"Wrote SLURM job array script: {script_path_out}")
    return script_path_out


def submit(args, run_dir, joblist_path, job_lines, total_licenses,
           lm_license_file):
    """Write job_array.sh, submit via sbatch, poll until done, report failures.

    Args:
        args:            argparse Namespace.
        run_dir:         Run directory.
        joblist_path:    Absolute path to joblist.txt.
        job_lines:       List of joblist lines (just used for the count log).
        total_licenses:  Concurrency cap for the array.
        lm_license_file: FlexLM license-server string.
    """
    # Create slurm_logs directory
    slurm_logs_dir = os.path.join(run_dir, "slurm_logs")
    os.makedirs(slurm_logs_dir, exist_ok=True)

    # Write job_array.sh
    script_path = write_script(
        run_dir, joblist_path, total_licenses, lm_license_file, args.output, args,
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
