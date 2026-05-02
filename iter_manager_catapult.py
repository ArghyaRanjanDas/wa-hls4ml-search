import argparse
import os
import json
import glob
import sys
import uuid
import tarfile
from datetime import datetime
from tensorflow.keras.models import model_from_json
from qkeras.utils import _add_supported_quantized_objects
import subprocess
import logging
import shutil

from util.catapult_dataflow_config import CatapultDataflowConfig
from catapult_report import parse_catapult_report#, print_catapult_report
from slurm import job_array, cli as slurm_cli

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

JOB_SEP = "\t"


def _format_job_line(hls_dir, shell_script, flow_tcl, cfg_json):
    """Serialize one job's parameters to a single tab-separated line for joblist.txt."""
    parts = [
        os.path.abspath(hls_dir),
        os.path.abspath(shell_script) if shell_script else "",
        os.path.abspath(flow_tcl) if flow_tcl else "",
        os.path.abspath(cfg_json) if cfg_json else "",
    ]
    return JOB_SEP.join(parts)


def _parse_job_line(line):
    """Deserialize a joblist.txt line back into keyword arguments for _run_catapult_flow."""
    parts = line.strip().split(JOB_SEP)
    if len(parts) != 4:
        raise ValueError(f"Expected 4 tab-separated fields, got {len(parts)}: {line!r}")
    hls_dir, shell_script, flow_tcl, cfg_json = parts
    return {
        "hls_dir": hls_dir,
        "shell_script": shell_script or None,
        "flow_tcl": flow_tcl or None,
        "cfg_json": cfg_json or None,
    }


def _load_license_config(path):
    """
    Load license_servers.json and return (total_licenses, lm_license_file_str).

    The JSON format is:
    {
      "servers": [
        {"host": "server1.example.com", "port": 1717, "licenses": 4},
        {"host": "server2.example.com", "port": 1717, "licenses": 2}
      ]
    }

    Returns:
        tuple: (total_licenses: int, lm_license_file: str)
               lm_license_file is in FlexLM format: "port@host1:port@host2:..."
    """
    with open(path, "r") as f:
        cfg = json.load(f)

    servers = cfg["servers"]
    if not servers:
        raise ValueError(f"No servers defined in {path}")

    total_licenses = sum(s["licenses"] for s in servers)
    lm_parts = [f"{s['port']}@{s['host']}" for s in servers]
    lm_license_file = ":".join(lm_parts)

    if total_licenses <= 0:
        raise ValueError(f"Total licenses must be > 0, got {total_licenses}")

    return total_licenses, lm_license_file


def _make_tarfile(output_path, source_dir, extra_files=None, exclude_dirs=None):
    """Create .tar.gz of source_dir, skipping directory names in exclude_dirs.

    extra_files: list of absolute paths added at the tarball root (outside source_dir).
    """
    exclude_set = set(exclude_dirs or [])

    def _filter(tarinfo):
        for part in tarinfo.name.split(os.sep):
            if part in exclude_set:
                return None
        return tarinfo

    with tarfile.open(output_path, "w:gz") as tar:
        tar.add(source_dir, arcname=os.path.basename(source_dir), filter=_filter)
        for extra in (extra_files or []):
            path, arcname = extra if isinstance(extra, tuple) else (extra, os.path.basename(extra))
            if os.path.isfile(path):
                tar.add(path, arcname=arcname)


def _make_run_dir(output_root):
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_id = uuid.uuid4().hex[:8]
    run_dir = os.path.join(output_root, f"run_{ts}_{run_id}")
    os.makedirs(run_dir, exist_ok=False)
    return run_dir


def _generate_models(batch_range, batch_size, config_params_arg, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    repo_dir = os.path.dirname(os.path.abspath(__file__))
    gen_models_script = os.path.join(repo_dir, "gen_models.py")

    cmd = [
        "python",
        gen_models_script,
        "--batch_range",
        str(batch_range),
        "--batch_size",
        str(batch_size),
        "--output_dir",
        output_dir,
    ]

    if config_params_arg:
        if not os.path.isfile(config_params_arg):
            raise ValueError(
                "--gen_model_config_json must be a valid JSON config file path in subprocess mode"
            )
        cmd.extend(["--config", config_params_arg])
        logger.info(f"Loaded configuration from {config_params_arg}")

    logger.info(
        f"Generating models via subprocess: batch_range={batch_range}, batch_size={batch_size}, output_dir={output_dir}"
    )
    subprocess.run(cmd, check=True)

def _run_catapult_flow(hls_dir, shell_script=None, flow_tcl=None, cfg_json=None):
    hls_dir_abs = os.path.abspath(hls_dir)

    if shell_script == None or flow_tcl == None:
        repo_dir = os.path.dirname(os.path.abspath(__file__))
        shell_script = os.path.join(repo_dir, "Correlator4_scripts", "catapult_shell.sh")
        flow_tcl = os.path.join(repo_dir, "util", "catapult_hls4ml_flow.tcl")

    if cfg_json is None:
        cfg_json = ""

    # Full control comes from cfg_json (CatapultDataflowConfig).
    tcl_cmd = (
        f"set model_path {{{hls_dir_abs}/keras_model.h5}}; "
        f"set out_dir {{{hls_dir_abs}/catapult_native}}; "
        f"set cfg_json {{{cfg_json}}}; "
        "set run_synth 1; "
        f"dofile {{{flow_tcl}}}; exit"
    )

    subprocess.run(
        [
            shell_script,
            "--work-dir", hls_dir_abs,
            "--cmd", tcl_cmd,
        ],
        cwd=hls_dir_abs,
        check=True,
    )


def _collect_reports(run_dir):
    """Parse all completed builds in run_dir and create report JSONs + tarballs."""
    build_root = os.path.join(run_dir, "build")
    raw_report_dir = os.path.join(run_dir, "data", "reports", "raw")
    tar_dir = os.path.join(run_dir, "tarballs")

    os.makedirs(raw_report_dir, exist_ok=True)
    os.makedirs(tar_dir, exist_ok=True)

    logger.info("Collecting synthesis reports...")
    build_dirs = sorted(glob.glob(os.path.join(build_root, "*", "catapult_native")))
    parsed_count = 0
    for catapult_dir in build_dirs:
        tag = os.path.basename(os.path.dirname(catapult_dir))
        raw_json_path = os.path.join(raw_report_dir, f"{tag}.json")

        if os.path.exists(raw_json_path):
            logger.info(f"Report already exists for {tag}, skipping.")
            parsed_count += 1
            continue

        report = parse_catapult_report(catapult_dir)
        if report is None:
            logger.warning(f"Failed to parse report for {tag}")
            continue

        with open(raw_json_path, "w") as f:
            json.dump(report, f, indent=2)

        model_json_path = os.path.join(os.path.dirname(catapult_dir), "model.json")
        tar_path = os.path.join(tar_dir, f"{tag}.tar.gz")
        _make_tarfile(
            tar_path,
            catapult_dir,
            extra_files=[(model_json_path, "model.json"), (raw_json_path, "report.json")],
            exclude_dirs=["SIF"],
        )

        parsed_count += 1
        logger.info(f"Saved report for {tag} → {raw_json_path}")
        logger.info(f"Tarball: {tar_path}")

    logger.info(f"Collected {parsed_count}/{len(build_dirs)} reports to {raw_report_dir}")


def main(args):
    os.makedirs(args.output, exist_ok=True)
    run_dir = _make_run_dir(args.output)
    logger.info(f"Run directory: {run_dir}")

    # Output layout
    generated_models_dir = os.path.join(run_dir, "generated_models")
    build_root = os.path.join(run_dir, "build")
    data_root = os.path.join(run_dir, "data")
    data_batches = os.path.join(data_root, "batches")
    data_models = os.path.join(data_root, "models")
    raw_report_dir = os.path.join(data_root, "reports", "raw")
    proc_report_dir = os.path.join(data_root, "reports", "processed")
    tar_dir = os.path.join(run_dir, "tarballs")

    os.makedirs(generated_models_dir, exist_ok=True)
    os.makedirs(data_batches, exist_ok=True)
    os.makedirs(data_models, exist_ok=True)
    os.makedirs(raw_report_dir, exist_ok=True)
    os.makedirs(proc_report_dir, exist_ok=True)
    os.makedirs(tar_dir, exist_ok=True)
    os.makedirs(build_root, exist_ok=True)

    _generate_models(args.batch_range, args.batch_size, args.gen_model_config_json, generated_models_dir)

    batch_files = sorted(glob.glob(os.path.join(generated_models_dir, "dense_latency_fast_batch_*.json")))
    assert batch_files, f"[ERROR] No generated batch JSON files found in {generated_models_dir}"

    # Load base flow config once (optional)
    if args.flow_config_json:
        base_cfg = CatapultDataflowConfig.load_json(args.flow_config_json)
        logger.info(f"Loaded flow config JSON: {args.flow_config_json}")
    else:
        base_cfg = CatapultDataflowConfig()
        logger.info("Using default CatapultDataflowConfig()")

    # --- Prepare phase: generate models, save configs, collect job entries ---
    job_lines = []

    co = {}
    _add_supported_quantized_objects(co)
    for batch_file in batch_files:
        print(f"Found JSON File, loading: {batch_file}")

        # Copy batch JSON into run/data/batches/
        batch_copy = os.path.join(data_batches, os.path.basename(batch_file))
        if os.path.abspath(batch_file) != os.path.abspath(batch_copy):
            shutil.copy2(batch_file, batch_copy)

        with open(batch_file, "r") as file:
            models = json.load(file)
            print(f"[INFO] Loaded {len(models)} models from {batch_file}")

        for model_name, model_desc in models.items():
            tag = model_name
            model = model_from_json(model_desc, custom_objects=co)

            # Portable artifacts
            tag_data_dir = os.path.abspath(os.path.join(data_models, tag))
            os.makedirs(tag_data_dir, exist_ok=True)

            # Build artifacts (Catapult project)
            tag_build_dir = os.path.abspath(os.path.join(build_root, tag))
            os.makedirs(tag_build_dir, exist_ok=True)

            print(f"[INFO] TAG={tag}")
            print(f"[INFO] data:  {tag_data_dir}")
            print(f"[INFO] build: {tag_build_dir}")

            h5_data = os.path.join(tag_data_dir, "keras_model.h5")
            model.save(h5_data, include_optimizer=False)

            model_json_path = os.path.join(tag_build_dir, "model.json")
            with open(model_json_path, "w") as f:
                f.write(model_desc)

            # Copy .h5 into build dir for Catapult
            h5_build = os.path.join(tag_build_dir, "keras_model.h5")
            shutil.copy2(h5_data, h5_build)

            cfg = base_cfg.override(
                output_dir=os.path.join(tag_build_dir, "catapult_native"),
            )
            cfg_json_path = os.path.join(tag_data_dir, "dataflow_config.json")
            cfg.save_json(cfg_json_path)

            job_lines.append(_format_job_line(
                hls_dir=tag_build_dir,
                shell_script=args.catapult_shell,
                flow_tcl=args.flow_tcl,
                cfg_json=cfg_json_path,
            ))


    # Write joblist (for both parallel and sequential runs)
    joblist_path = os.path.join(run_dir, "joblist.txt")
    with open(joblist_path, "w") as jf:
        jf.write("\n".join(job_lines) + "\n")
    logger.info(f"Wrote {len(job_lines)} jobs to {joblist_path}")

    # --- Synthesis phase ---
    if args.slurm:
        # SLURM job array mode
        if not args.license_config:
            raise SystemExit("ERROR: --slurm requires --license_config")
        total_licenses, lm_license_file = _load_license_config(args.license_config)
        logger.info(f"SLURM mode: {total_licenses} licenses, LM_LICENSE_FILE={lm_license_file}")
        job_array.submit(args, run_dir, joblist_path, job_lines, total_licenses,
                         lm_license_file)
    elif args.license_config:
        # Parallel mode via GNU parallel
        total_licenses, lm_license_file = _load_license_config(args.license_config)
        logger.info(f"Parallel mode: {total_licenses} licenses, LM_LICENSE_FILE={lm_license_file}")

        env = os.environ.copy()
        env["LM_LICENSE_FILE"] = lm_license_file

        joblog_path = os.path.join(run_dir, f"parallel_joblog_{datetime.now().strftime('%Y%m%d_%H%M%S')}.tsv")

        parallel_cmd = [
            "parallel",
            "--line-buffer",
            "--halt", "soon,fail=1",
            "--joblog", joblog_path,
            "-j", str(total_licenses),
            sys.executable, os.path.abspath(__file__),
            "-o", args.output,
            "--run-single-job", "{}",
        ]

        logger.info(f"Launching GNU parallel with -j {total_licenses}")
        logger.info(f"Job log: {joblog_path}")

        result = subprocess.run(
            parallel_cmd,
            input="\n".join(job_lines) + "\n",
            text=True,
            env=env,
        )

        if result.returncode != 0:
            logger.error(f"GNU parallel exited with code {result.returncode}")
            logger.error(f"Check job log: {joblog_path}")
            sys.exit(result.returncode)

        logger.info(f"All parallel jobs completed.\nJob log: {joblog_path}")
    else:
        # Sequential mode (backward compatible)
        for i, job_line in enumerate(job_lines):
            job_kwargs = _parse_job_line(job_line)
            logger.info(f"Running job {i+1}/{len(job_lines)}: {job_kwargs['hls_dir']}")
            _run_catapult_flow(**job_kwargs)

    # --- Report collection phase ---
    _collect_reports(run_dir)
    logger.info(f"Run complete. Results in: {run_dir}")


def create_parser():
    """
    Create and configure the argument parser.

    Returns:
        argparse.ArgumentParser: Configured argument parser
    """
    parser = argparse.ArgumentParser(description='Catapult synthesis runner for generated model JSON')
    parser.add_argument('-o', '--output', type=str, required=True, help='Output directory root (output)')
    parser.add_argument('--batch_range', type=int, default=1, help='Number of batch JSON files to generate when --file is not provided')
    parser.add_argument('--batch_size', type=int, default=1, help='Number of models per generated batch JSON when --file is not provided')
    parser.add_argument('--gen_model_config_json', type=str, default=None, help='gen_models config file path or inline JSON string')
    parser.add_argument('--catapult_shell', type=str, default=None, help='Path to catapult_shell.sh')
    parser.add_argument('--flow_tcl', type=str, default=None, help='Path to catapult_hls4ml_flow.tcl')
    parser.add_argument('--flow_config_json', type=str, default=None, help='Path to CatapultDataflowConfig JSON')
    parser.add_argument('--license_config', type=str, default=None, help='Path to license_servers.json. Enables parallel synthesis via GNU parallel.')
    parser.add_argument('--run-single-job', type=str, default=None, metavar='JOB_LINE', help='Run a single synthesis job from a tab-separated job line (used internally by GNU parallel)')

    # SLURM job array options (defined in slurm/cli.py — see slurm/README.md)
    slurm_cli.add_slurm_args(parser)

    return parser


if __name__ == "__main__":
    parser = create_parser()
    args = parser.parse_args()

    if args.collect_slurm is not None:
        _collect_reports(args.collect_slurm)
        sys.exit(0)
    elif args.run_single_job is not None:
        job_kwargs = _parse_job_line(args.run_single_job)
        logger.info(f"Running single job: {job_kwargs['hls_dir']}")
        _run_catapult_flow(**job_kwargs)
    else:
        main(args)

"""
TODO: 

1. "QOFRSummary": {
    "total_area": 101426.0,
    "latency_cycles": 169,
    "thruput_cycles": 64
  },


  Change the spelling

2. Implemet it on the NERSC
""" 