import argparse
import os
import json
import glob
import uuid
from datetime import datetime
from tensorflow.keras.models import model_from_json
from qkeras.utils import _add_supported_quantized_objects
import subprocess
import logging
import shutil

from util.catapult_dataflow_config import CatapultDataflowConfig

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


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

            # Copy .h5 into build dir for Catapult
            h5_build = os.path.join(tag_build_dir, "keras_model.h5")
            shutil.copy2(h5_data, h5_build)

            cfg = base_cfg.override(
                output_dir=os.path.join(tag_build_dir, "catapult_native"),
            )
            cfg_json_path = os.path.join(tag_data_dir, "dataflow_config.json")
            cfg.save_json(cfg_json_path)

            _run_catapult_flow(
                hls_dir=tag_build_dir,
                shell_script=args.catapult_shell,
                flow_tcl=args.flow_tcl,
                cfg_json=cfg_json_path,
            )

            # Placeholder for report parsing
            # raw_json = os.path.join(raw_report_dir, f"{tag}.json")


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

    return parser


if __name__ == "__main__":
    parser = create_parser()
    args = parser.parse_args()
    main(args)
