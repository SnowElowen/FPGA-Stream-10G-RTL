from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_helpers import receive_axis_frame, send_axis_frame, start_clock_and_reset
from reference_model import UdpFrame, axis_beats, beats_to_bytes


async def send_descriptor(dut, model: UdpFrame) -> None:
    dut.s_dst_mac_i.value = model.dst_mac
    dut.s_src_mac_i.value = model.src_mac
    dut.s_src_ip_i.value = model.src_ip
    dut.s_dst_ip_i.value = model.dst_ip
    dut.s_src_port_i.value = model.src_port
    dut.s_dst_port_i.value = model.dst_port
    dut.s_payload_length_i.value = len(model.payload)
    dut.s_ip_identification_i.value = model.identification
    dut.s_ip_ttl_i.value = model.ttl
    dut.s_udp_checksum_enable_i.value = int(model.udp_checksum_enable)
    dut.s_desc_valid_i.value = 1
    while True:
        await Timer(1, units="ns")
        accepted = bool(dut.s_desc_ready_o.value)
        await RisingEdge(dut.clk_i)
        if accepted:
            break
    dut.s_desc_valid_i.value = 0


@cocotb.test()
async def build_udp_frame_with_backpressure(dut):
    dut.s_desc_valid_i.value = 0
    dut.s_payload_tvalid_i.value = 0
    dut.s_payload_tdata_i.value = 0
    dut.s_payload_tkeep_i.value = 0
    dut.s_payload_tlast_i.value = 0
    dut.m_axis_tready_i.value = 0
    dut.m_error_ready_i.value = 1
    await start_clock_and_reset(dut)

    model = UdpFrame(
        dst_mac=0x001122334455,
        src_mac=0xAABBCCDDEEFF,
        src_ip=0xC0A80101,
        dst_ip=0xC0A80102,
        src_port=12345,
        dst_port=54321,
        payload=b"\x00SnowSakura public RTL\x00!",
        identification=0x1234,
        ttl=37,
        udp_checksum_enable=True,
    )

    receiver = cocotb.start_soon(receive_axis_frame(dut, "m_axis", seed=7))
    await send_descriptor(dut, model)
    await send_axis_frame(dut, "s_payload", axis_beats(model.payload))
    observed = beats_to_bytes(await receiver)

    assert observed == model.build()
    assert int(dut.m_error_valid_o.value) == 0
