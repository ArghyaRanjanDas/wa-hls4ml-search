#!/usr/bin/env python3
"""
Generate Catapult HLS4ML project files from an existing Keras/QKeras .h5 model.

This script is intended to run inside Catapult's /HLS4ML flow environment
(`flow run /HLS4ML/gen_hls4ml ...`) where `catapult_ai_nn` is available.
"""

import argparse
import os
import numpy as np
import tensorflow as tf
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


def create_parser():
    parser = argparse.ArgumentParser(description="Generate Catapult HLS4ML project from .h5 model")
    parser.add_argument("--model_path", required=True, help="Path to Keras/QKeras .h5 model")
    parser.add_argument("--output_dir", required=True, help="Output directory for generated Catapult project")
    parser.add_argument("--project_name", default="myproject", help="Project name (default: myproject)")
    parser.add_argument("--reuse_factor", type=int, default=16, help="Default reuse factor")
    parser.add_argument("--clock_period", type=float, default=5.0, help="Clock period in ns")
    parser.add_argument("--strategy", default="Latency", help="HLS strategy (Latency/Resource)")
    parser.add_argument("--tech", default="fpga", help="Target technology (fpga|asic)")
    parser.add_argument("--io_type", default="io_stream", help="hls4ml IO type (io_stream|io_parallel)")
    parser.add_argument("--granularity", default="name", help="hls4ml config granularity")
    parser.add_argument(
        "--default_precision",
        default="ac_fixed<16,8,true>",
        help="hls4ml default precision",
    )
    parser.add_argument(
        "--max_precision",
        default="ac_fixed<16,8,true>",
        help="hls4ml max precision",
    )
    parser.add_argument(
        "--part",
        default="xcku115-flvb2104-2-i",
        help="Target FPGA part (default known-good Catapult example part)",
    )
    parser.add_argument("--num_samples", type=int, default=8, help="Number of dummy samples for setup")
    return parser


def main():
    args = create_parser().parse_args()
    if args.num_samples <= 0:
        raise ValueError("--num_samples must be > 0")

    custom_objects = {}
    _add_supported_quantized_objects(custom_objects)
    model = load_model(args.model_path, custom_objects=custom_objects)

    in_shape, n_classes = _resolve_io_shapes(model)
    x_test = np.random.rand(args.num_samples, *in_shape).astype("float32")
    y_test = np.zeros((args.num_samples,), dtype="int32")
    if n_classes <= 1:
        # Keep labels in valid range if model output has a single channel.
        y_test[:] = 0

    dataflow_cfg = CatapultDataflowConfig(
        num_samples=args.num_samples,
        granularity=args.granularity,
        default_precision=args.default_precision,
        default_reuse_factor=args.reuse_factor,
        max_precision=args.max_precision,
        output_dir=args.output_dir,
        project_name=args.project_name,
        tech=args.tech,
        part=args.part,
        io_type=args.io_type,
        strategy=args.strategy,
        clock_period=args.clock_period,
    )

    cfg_kwargs = dict(
        model=model,
        x_test=x_test,
        y_test=y_test,
        num_samples=dataflow_cfg.num_samples,
        granularity=dataflow_cfg.granularity,
        default_precision=dataflow_cfg.default_precision,
        max_precision=dataflow_cfg.max_precision,
        clock_period=dataflow_cfg.clock_period,
        project_name=dataflow_cfg.project_name,
        output_dir=dataflow_cfg.output_dir,
        default_reuse_factor=dataflow_cfg.default_reuse_factor,
        strategy=dataflow_cfg.strategy,
        io_type=dataflow_cfg.io_type,
        tech=dataflow_cfg.tech,
    )
    if dataflow_cfg.part:
        cfg_kwargs["part"] = dataflow_cfg.part
    cfg = catapult_ai_nn.config_for_dataflow(**cfg_kwargs)

    hls_model = catapult_ai_nn.generate_dataflow(model, cfg)
    hls_model.compile()

    print(f"Generated Catapult project at: {os.path.abspath(args.output_dir)}")


if __name__ == "__main__":
    main()
