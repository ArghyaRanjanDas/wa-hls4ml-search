#!/usr/bin/env python3
"""
Generate Catapult HLS4ML project files from an existing Keras/QKeras .h5 model.

This script is intended to run inside Catapult's /HLS4ML flow environment
(`flow run /HLS4ML/gen_hls4ml ...`) where `catapult_ai_nn` is available.
"""

import argparse
import os
import numpy as np
from tensorflow.keras.models import load_model
from qkeras.utils import _add_supported_quantized_objects
import catapult_ai_nn
try:
    from catapult_dataflow_config import CatapultDataflowConfig
except ImportError:
    from util.catapult_dataflow_config import CatapultDataflowConfig


def _resolve_io_shapes(model):
    in_shape = model.input_shape
    out_shape = model.output_shape

    # Handle models with list inputs/outputs.
    if isinstance(in_shape, list):
        in_shape = in_shape[0]
    if isinstance(out_shape, list):
        out_shape = out_shape[0]

    # Drop batch dimension and replace unknowns with 1.
    in_shape = tuple(1 if dim is None else int(dim) for dim in in_shape[1:])
    if len(in_shape) == 0:
        in_shape = (1,)

    if len(out_shape) <= 1 or out_shape[-1] is None:
        n_classes = 1
    else:
        n_classes = int(out_shape[-1])

    return in_shape, n_classes


def _patch_min_fifo_depth(out_dir: str, project_name: str, min_fifo_depth: int) -> int:
    """
    Work around Catapult FIFO library mapping failures seen with fifo_depth="1"
    in generated io_stream channel pragmas. Clamp to a safer minimum depth.

    Returns:
        number of replacements
    """
    firmware_cpp = os.path.join(out_dir, "firmware", f"{project_name}.cpp")
    if not os.path.isfile(firmware_cpp):
        return 0

    with open(firmware_cpp, "r") as fp:
        cpp_text = fp.read()

    old = 'fifo_depth="1"'
    new = f'fifo_depth="{min_fifo_depth}"'
    replaced_count = cpp_text.count(old)
    if replaced_count > 0:
        cpp_text = cpp_text.replace(old, new)
        with open(firmware_cpp, "w") as fpw:
            fpw.write(cpp_text)
    return replaced_count


def create_parser():
    parser = argparse.ArgumentParser(description="Generate Catapult HLS4ML project from .h5 model")
    parser.add_argument("--model_path", required=True, help="Path to Keras/QKeras .h5 model")
    parser.add_argument("--output_dir", required=True, help="Output directory for generated Catapult project")
    parser.add_argument(
        "--config_json",
        default=None,
        help="Path to CatapultDataflowConfig JSON (controls ALL config_for_dataflow knobs)",
    )
    return parser


def main():
    args = create_parser().parse_args()

    custom_objects = {}
    _add_supported_quantized_objects(custom_objects)
    model = load_model(args.model_path, custom_objects=custom_objects)

    in_shape, n_classes = _resolve_io_shapes(model)

    # Load base config
    # If config_json is absent, fall back to defaults (still works, but you lose reproducibility)
    cfg0 = CatapultDataflowConfig.load_json(args.config_json) if args.config_json else CatapultDataflowConfig()

    # Override run-specific output dir only (all other knobs come from cfg_json)
    cfg = cfg0.override(output_dir=args.output_dir)

    # Dummy dataset for setup
    x_test = np.random.rand(cfg.num_samples, *in_shape).astype("float32")
    y_test = np.zeros((cfg.num_samples,), dtype="int32")
    if n_classes <= 1:
        # Keep labels in valid range if model output has a single channel.
        y_test[:] = 0

    # Full control surface: pass ALL config knobs into config_for_dataflow
    cfg_kwargs = cfg.to_kwargs(signature_only=True, drop_none=True, int_flags=True)

    config_ccs = catapult_ai_nn.config_for_dataflow(
        model=model,
        x_test=x_test,
        y_test=y_test,
        **cfg_kwargs,
    )

    hls_model = catapult_ai_nn.generate_dataflow(model, config_ccs)

    # Post-gen patch (removes need for TCL regsub block)
    nrep = _patch_min_fifo_depth(cfg.output_dir, cfg.project_name, cfg.min_fifo_depth)
    if nrep > 0:
        print(f"[WARN] Patched firmware FIFO depth pragmas: replaced {nrep} entries with depth={cfg.min_fifo_depth}")

    hls_model.compile()

    print(f"Generated Catapult project at: {os.path.abspath(cfg.output_dir)}")


if __name__ == "__main__":
    main()