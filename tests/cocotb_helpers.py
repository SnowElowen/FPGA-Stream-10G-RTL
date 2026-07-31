from __future__ import annotations

from collections.abc import Iterable
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def start_clock_and_reset(dut, period_ns: float = 6.4) -> None:
    cocotb.start_soon(Clock(dut.clk_i, period_ns, units="ns").start())
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    await RisingEdge(dut.clk_i)


async def send_axis_frame(dut, prefix: str, beats: Iterable[tuple[int, int, bool]]) -> None:
    tdata = getattr(dut, f"{prefix}_tdata_i")
    tkeep = getattr(dut, f"{prefix}_tkeep_i")
    tvalid = getattr(dut, f"{prefix}_tvalid_i")
    tready = getattr(dut, f"{prefix}_tready_o")
    tlast = getattr(dut, f"{prefix}_tlast_i")

    tvalid.value = 0
    for data, keep, last in beats:
        tdata.value = data
        tkeep.value = keep
        tlast.value = int(last)
        tvalid.value = 1
        while True:
            await Timer(1, units="ns")
            accepted = bool(tready.value)
            await RisingEdge(dut.clk_i)
            if accepted:
                break
    tvalid.value = 0
    tlast.value = 0


async def receive_axis_frame(
    dut,
    prefix: str,
    *,
    seed: int = 1,
    max_cycles: int = 10000,
) -> list[tuple[int, int, bool]]:
    tdata = getattr(dut, f"{prefix}_tdata_o")
    tkeep = getattr(dut, f"{prefix}_tkeep_o")
    tvalid = getattr(dut, f"{prefix}_tvalid_o")
    tready = getattr(dut, f"{prefix}_tready_i")
    tlast = getattr(dut, f"{prefix}_tlast_o")

    rng = random.Random(seed)
    result: list[tuple[int, int, bool]] = []
    for _ in range(max_cycles):
        ready = rng.randrange(4) != 0
        tready.value = int(ready)
        await Timer(1, units="ns")
        valid = bool(tvalid.value)
        sample = (
            int(tdata.value),
            int(tkeep.value),
            bool(tlast.value),
        )
        await RisingEdge(dut.clk_i)
        if valid and ready:
            result.append(sample)
            if sample[2]:
                tready.value = 0
                return result
    raise TimeoutError(f"timed out receiving {prefix}")
