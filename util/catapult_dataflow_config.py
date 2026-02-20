from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Optional, Literal, Dict, Any


@dataclass(slots=True)
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
    csim: bool = True
    SCVerify: bool = True
    Synth: bool = True
    vhdl: bool = True
    verilog: bool = True
    RTLSynth: bool = False

    # Testbench / misc
    RandomTBFrames: int = 2
    ParamStore: Literal["global", "inline", "interface", "merged"] = "global"

    PowerEst: bool = False
    PowerOpt: bool = False
    BuildBUP: bool = False
    BUPWorkers: int = 0
    LaunchDA: bool = False
    startup: str = ""

    write_weights_txt: bool = True
    write_tar: bool = False

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

    def to_kwargs(self, *, int_flags: bool = False, drop_none: bool = False) -> Dict[str, Any]:
        """
        Convert to kwargs matching your `config_for_dataflow(...)` signature.

        int_flags=True converts bools to 0/1 (some Catapult flows prefer ints).
        drop_none=True removes keys whose value is None.
        """
        d = asdict(self)

        if int_flags:
            for k, v in list(d.items()):
                if isinstance(v, bool):
                    d[k] = int(v)

        if drop_none:
            d = {k: v for k, v in d.items() if v is not None}

        return d