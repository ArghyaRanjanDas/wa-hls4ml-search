from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Optional, Literal, Dict, Any
import json
import os


@dataclass
class CatapultDataflowConfig:
    # Core conversion knobs
    num_samples: int = 20
    granularity: Literal["model", "type", "name"] = "name"
    default_precision: str = "ac_fixed<16,6>"
    default_reuse_factor: int = 1
    max_precision: Optional[str] = None

    # Project layout
    output_dir: str = "my-hls-test"
    project_name: str = "myproject"
    project_dir: str = "Catapult"
    namespace: Optional[str] = None

    # Tech target
    tech: Literal["asic", "fpga"] = "asic"

    # ASIC libs
    asiclibs: str = "nangate-45nm_beh"
    asicfifo: str = "hls4ml_lib.mgc_pipe_mem"
    asicram: str = "ccs_sample_mem.ccs_ram_sync_1R1W"

    # FPGA target (kept for completeness; used when tech="fpga")
    part: str = "xcku115-flvb2104-2-i"
    fifo: str = "Xilinx_FIFO.FIFO_SYNC"
    ram: str = "Xilinx_RAMS.BLOCK_1R1W_RBW"

    # HLS choices
    io_type: Literal["io_parallel", "io_stream"] = "io_parallel"
    strategy: Literal["Latency", "Resource"] = "Latency"
    clock_period: float = 5.0

    # Flow switches (Catapult backend)
    # NOTE: catapult_ai_nn.config_for_dataflow uses 0/1 style flags [0: False, 1: True]
    csim: int = 1
    SCVerify: int = 1
    Synth: int = 1
    vhdl: int = 1
    verilog: int = 1
    RTLSynth: int = 0

    # Testbench / misc
    RandomTBFrames: int = 2
    ParamStore: Literal["global", "inline", "interface", "merged"] = "global"

    PowerEst: int = 0
    PowerOpt: int = 0
    BuildBUP: int = 0
    BUPWorkers: int = 0
    LaunchDA: int = 0
    startup: str = ""

    write_weights_txt: int = 1
    write_tar: int = 0

    # Extra knobs (NOT part of catapult_ai_nn.config_for_dataflow signature)
    # Used as a post-gen patch to avoid TCL complexity.
    min_fifo_depth: int = 16

    def __post_init__(self) -> None:
        # Basic sanity checks
        if self.num_samples <= 0:
            raise ValueError("num_samples must be > 0")
        if self.default_reuse_factor <= 0:
            raise ValueError("default_reuse_factor must be > 0")
        if self.clock_period <= 0:
            raise ValueError("clock_period must be > 0")
        if self.BUPWorkers < 0:
            raise ValueError("BUPWorkers must be >= 0")
        if self.RandomTBFrames < 0:
            raise ValueError("RandomTBFrames must be >= 0")
        if self.min_fifo_depth < 1:
            raise ValueError("min_fifo_depth must be >= 1")

    def to_kwargs(self, *, signature_only: bool = True, drop_none: bool = False, int_flags: bool = False) -> Dict[str, Any]:
        """
        Convert to kwargs matching your `config_for_dataflow(...)` signature.

        signature_only=True drops extra keys not in the signature (e.g. min_fifo_depth).
        int_flags=True converts bools to 0/1 (safe even if you keep ints already).
        drop_none=True removes keys whose value is None.
        """
        d = asdict(self)

        if signature_only:
            allowed = {
                "num_samples",
                "granularity",
                "default_precision",
                "default_reuse_factor",
                "max_precision",
                "output_dir",
                "project_name",
                "project_dir",
                "namespace",
                "tech",
                "asiclibs",
                "asicfifo",
                "asicram",
                "part",
                "fifo",
                "ram",
                "io_type",
                "strategy",
                "clock_period",
                "csim",
                "SCVerify",
                "Synth",
                "vhdl",
                "verilog",
                "RTLSynth",
                "RandomTBFrames",
                "ParamStore",
                "PowerEst",
                "PowerOpt",
                "BuildBUP",
                "BUPWorkers",
                "LaunchDA",
                "startup",
                "write_weights_txt",
                "write_tar",
            }
            d = {k: v for k, v in d.items() if k in allowed}

        if int_flags:
            for k, v in list(d.items()):
                if isinstance(v, bool):
                    d[k] = int(v)

        if drop_none:
            d = {k: v for k, v in d.items() if v is not None}

        return d

    def save_json(self, path: str) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump(asdict(self), f, indent=2, sort_keys=True)

    @staticmethod
    def load_json(path: str) -> "CatapultDataflowConfig":
        with open(path, "r") as f:
            d = json.load(f)
        return CatapultDataflowConfig(**d)

    def override(self, **kwargs: Any) -> "CatapultDataflowConfig":
        d = asdict(self)
        for k, v in kwargs.items():
            if v is None:
                continue
            if k not in d:
                raise KeyError(f"Unknown config key: {k}")
            d[k] = v
        return CatapultDataflowConfig(**d)