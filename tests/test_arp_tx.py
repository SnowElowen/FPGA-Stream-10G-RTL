from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_helpers import receive_axis_frame, start_clock_and_reset
from reference_model import beats_to_bytes, build_arp_frame


@cocotb.test()
async def build_arp_request(dut):
    dut.s_desc_valid_i.value = 0
    dut.m_axis_tready_i.value = 0
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
    dut.s_eth_dst_mac_i.value = fields["eth_dst_mac"]
    dut.s_eth_src_mac_i.value = fields["eth_src_mac"]
    dut.s_opcode_i.value = fields["opcode"]
    dut.s_sender_mac_i.value = fields["sender_mac"]
    dut.s_sender_ip_i.value = fields["sender_ip"]
    dut.s_target_mac_i.value = fields["target_mac"]
    dut.s_target_ip_i.value = fields["target_ip"]

    receiver = cocotb.start_soon(receive_axis_frame(dut, "m_axis", seed=3))
    dut.s_desc_valid_i.value = 1
    while True:
        await Timer(1, units="ns")
        accepted = bool(dut.s_desc_ready_o.value)
        await RisingEdge(dut.clk_i)
        if accepted:
            break
    dut.s_desc_valid_i.value = 0

    observed = beats_to_bytes(await receiver)
    assert observed == build_arp_frame(**fields)
