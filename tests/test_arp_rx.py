from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_helpers import send_axis_frame, start_clock_and_reset
from reference_model import axis_beats, build_arp_frame


@cocotb.test()
async def parse_arp_request(dut):
    dut.s_axis_tvalid_i.value = 0
    dut.s_axis_tdata_i.value = 0
    dut.s_axis_tkeep_i.value = 0
    dut.s_axis_tlast_i.value = 0
    dut.m_arp_ready_i.value = 0
    dut.m_error_ready_i.value = 1
    await start_clock_and_reset(dut)

    fields = dict(
        eth_dst_mac=0xFFFFFFFFFFFF,
        eth_src_mac=0x001122334455,
        opcode=1,
        sender_mac=0x001122334455,
        sender_ip=0xC0A80101,
        target_mac=0,
        target_ip=0xC0A80102,
    )
    await send_axis_frame(dut, "s_axis", axis_beats(build_arp_frame(**fields)))

    for _ in range(100):
        await Timer(1, units="ns")
        if int(dut.m_arp_valid_o.value):
            break
        await RisingEdge(dut.clk_i)
    else:
        raise TimeoutError("ARP metadata did not become valid")

    assert int(dut.m_eth_dst_mac_o.value) == fields["eth_dst_mac"]
    assert int(dut.m_eth_src_mac_o.value) == fields["eth_src_mac"]
    assert int(dut.m_opcode_o.value) == fields["opcode"]
    assert int(dut.m_sender_mac_o.value) == fields["sender_mac"]
    assert int(dut.m_sender_ip_o.value) == fields["sender_ip"]
    assert int(dut.m_target_mac_o.value) == fields["target_mac"]
    assert int(dut.m_target_ip_o.value) == fields["target_ip"]
    assert int(dut.m_error_valid_o.value) == 0

    dut.m_arp_ready_i.value = 1
    await RisingEdge(dut.clk_i)
