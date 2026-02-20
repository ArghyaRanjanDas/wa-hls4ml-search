import argparse
import os
import sys
import json
import pandas as pd
from tensorflow.keras.models import model_from_json
from qkeras.utils import _add_supported_quantized_objects
from run_search_iteration import _setup_hls4ml_backend, print_dict, make_tarfile
from dataclasses import dataclass, asdict
import subprocess
import gen_models
import logging

from util.catapult_dataflow_config import CatapultDataflowConfig 

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def _generate_models(batch_range, batch_size, config_params, output_dir):
    # Load configuration
    if args.config:
        config_params = gen_models.load_config(args.config)
        logger.info("Using configuration from file")
    else:
        config_params = gen_models.get_default_config()
        logger.info("Using default configuration")

    # Ensure output directory exists
    os.makedirs(args.output_dir, exist_ok=True)

    gen_models.threaded_exec(batch_range, batch_size, config_params, output_dir)

def _run_catapult_flow(hls_dir, rf=None, shell_script=None, flow_tcl=None):
    hls_dir_abs = os.path.abspath(hls_dir)
    run_rf = rf if rf is not None else 1

    if shell_script==None or flow_tcl==None:
        repo_dir = os.path.dirname(os.path.abspath(__file__))
        shell_script = os.path.join(repo_dir, "Correlator4_scripts", "catapult_shell.sh")
        flow_tcl = os.path.join(repo_dir, "util", "catapult_hls4ml_flow.tcl")

    tcl_cmd = (
        f"set model_path {hls_dir}/keras_model.h5; "
        f"set out_dir {hls_dir}/catapult_native; "
        f"set reuse_factor {rf}; "
        "set tech asic; "
        "set run_synth 1; "
        f"dofile {flow_tcl}; exit"
    )

    subprocess.run(
        [
            shell_script, 
            "--work-dir", hls_dir, 
            "--cmd", tcl_cmd
        ], cwd=hls_dir, check=True
    )

def main(args):
    # elif args.file.endswith('.json'):
    os.makedirs(args.output, exist_ok=True)
    os.makedirs(args.hlsproj, exist_ok=True)

    raw_report_dir = os.path.join(args.output, "raw_reports")
    proc_report_dir = os.path.join(args.output, "processed_reports")
    tar_dir = os.path.join(args.output, "tarballs")

    os.makedirs(raw_report_dir, exist_ok=True)
    os.makedirs(proc_report_dir, exist_ok=True)
    os.makedirs(tar_dir, exist_ok=True)

    assert os.path.isfile(args.file), f"[ERROR] File not found: {args.file}"

    print("Found JSON File, loading...")
    with open(args.file, 'r') as file:
        co = {}
        _add_supported_quantized_objects(co)
        models = json.load(file)
        print(f"[INFO] Loaded {len(models)} models from {args.file}")
        
        for model_name, model_desc in models.items():
            model = model_from_json(model_desc, custom_objects=co)
            for rf in range(args.rf_lower, args.rf_upper, args.rf_step):
                assert rf > 0, f"RF must be greater than 0, got {rf}"
                # print("Running hls4ml Synth (vsynth: {}) for {} with RF of {}".format(args.vsynth, model_name, rf))

                tag = f"{model_name}_rf{rf}"
                hls_dir = os.path.abspath(os.path.join(args.hlsproj, tag))
                os.makedirs(hls_dir, exist_ok=True)

                print(f"[INFO] RF={rf} | HLS dir: {hls_dir}")

                h5_path = os.path.join(hls_dir, "keras_model.h5")
                model.save(h5_path, include_optimizer=False)

                _run_catapult_flow(
                    hls_dir=hls_dir,
                    rf=rf,
                    shell_script=args.catapult_shell,
                    flow_tcl=args.flow_tcl,
                )
                synth_ok = True
                err_msg = None

                raw_json = os.path.join(raw_report_dir, f"{tag}_report.json")

def create_parser():
    """
    Create and configure the argument parser.
    
    Returns:
        argparse.ArgumentParser: Configured argument parser
    """
    parser = argparse.ArgumentParser(description='Catapult synthesis runner for generated model JSON')
    parser.add_argument('-f', '--file', type=str, required=True,
                        help='Path to generated model batch JSON')
    parser.add_argument('-o', '--output', type=str, required=True,
                        help='Output directory')
    parser.add_argument('--hlsproj', type=str, required=True,
                        help='HLS project directory root')

    parser.add_argument('-p', '--part', type=str, default='xcu250-figd2104-2L-e',
                        help='Target part (kept for compatibility)')
    parser.add_argument('--model_name', type=str, default=None,
                        help='Optional single model key from batch JSON')

    parser.add_argument('--rf_lower', type=int, default=1,
                        help='Lower RF (inclusive)')
    parser.add_argument('--rf_upper', type=int, default=1,
                        help='Upper RF (inclusive)')
    parser.add_argument('--rf_step', type=int, default=1,
                        help='RF sweep step')

    parser.add_argument('--catapult_shell', type=str, default=None,
                        help='Path to catapult_shell.sh')
    parser.add_argument('--flow_tcl', type=str, default=None,
                        help='Path to catapult_hls4ml_flow.tcl')
    parser.add_argument('--catapult_report_parser', type=str, default=None,
                        help='Path to catapult_report_from_log.py')

    return parser


if __name__ == "__main__":
    parser = create_parser()
    args = parser.parse_args()
    main(args)