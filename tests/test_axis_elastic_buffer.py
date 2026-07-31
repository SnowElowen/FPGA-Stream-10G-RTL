from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_helpers import start_clock_and_reset


@cocotb.test()
async def zero_data_is_a_real_transaction_and_stalls_hold_state(dut):
    dut.s_axis_tdata_i.value = 0
    dut.s_axis_tkeep_i.value = 0
    dut.s_axis_tvalid_i.value = 0
    dut.s_axis_tlast_i.value = 0
    dut.s_axis_tuser_i.value = 0
    dut.m_axis_tready_i.value = 0
    await start_clock_and_reset(dut)

    dut.s_axis_tdata_i.value = 0
    dut.s_axis_tkeep_i.value = 0xFF
    dut.s_axis_tlast_i.value = 1
    dut.s_axis_tuser_i.value = 1
    dut.s_axis_tvalid_i.value = 1
    await Timer(1, units="ns")
    assert int(dut.s_axis_tready_o.value) == 1
    await RisingEdge(dut.clk_i)
    dut.s_axis_tvalid_i.value = 0

    for _ in range(5):
        await Timer(1, units="ns")
        assert int(dut.m_axis_tvalid_o.value) == 1
        assert int(dut.m_axis_tdata_o.value) == 0
        assert int(dut.m_axis_tkeep_o.value) == 0xFF
        assert int(dut.m_axis_tlast_o.value) == 1
        assert int(dut.m_axis_tuser_o.value) == 1
        await RisingEdge(dut.clk_i)

    dut.m_axis_tready_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, units="ns")
    assert int(dut.m_axis_tvalid_o.value) == 0
