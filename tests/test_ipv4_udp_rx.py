from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_helpers import receive_axis_frame, send_axis_frame, start_clock_and_reset
from reference_model import UdpFrame, axis_beats, beats_to_bytes


@cocotb.test()
async def parse_udp_frame_and_hold_metadata(dut):
    dut.s_axis_tvalid_i.value = 0
    dut.s_axis_tdata_i.value = 0
    dut.s_axis_tkeep_i.value = 0
    dut.s_axis_tlast_i.value = 0
    dut.m_meta_ready_i.value = 0
    dut.m_payload_tready_i.value = 0
    dut.m_error_ready_i.value = 1
    await start_clock_and_reset(dut)

    model = UdpFrame(
        dst_mac=0x001122334455,
        src_mac=0xAABBCCDDEEFF,
        src_ip=0x0A000001,
        dst_ip=0x0A000002,
        src_port=1000,
        dst_port=2000,
        payload=b"\x00abc\x00defghij\xff",
        identification=0xCAFE,
        ttl=64,
        udp_checksum_enable=True,
    )

    await send_axis_frame(dut, "s_axis", axis_beats(model.build()))

    for _ in range(5000):
        await Timer(1, units="ns")
        if int(dut.m_meta_valid_o.value):
            break
        await RisingEdge(dut.clk_i)
    else:
        raise TimeoutError("metadata did not become valid")

    snapshot = (
        int(dut.m_dst_mac_o.value),
        int(dut.m_src_mac_o.value),
        int(dut.m_src_ip_o.value),
        int(dut.m_dst_ip_o.value),
        int(dut.m_src_port_o.value),
        int(dut.m_dst_port_o.value),
        int(dut.m_payload_length_o.value),
    )
    for _ in range(4):
        await RisingEdge(dut.clk_i)
        await Timer(1, units="ns")
        assert int(dut.m_meta_valid_o.value) == 1
        assert snapshot == (
            int(dut.m_dst_mac_o.value),
            int(dut.m_src_mac_o.value),
            int(dut.m_src_ip_o.value),
            int(dut.m_dst_ip_o.value),
            int(dut.m_src_port_o.value),
            int(dut.m_dst_port_o.value),
            int(dut.m_payload_length_o.value),
        )

    assert snapshot == (
        model.dst_mac,
        model.src_mac,
        model.src_ip,
        model.dst_ip,
        model.src_port,
        model.dst_port,
        len(model.payload),
    )
    assert int(dut.m_udp_checksum_present_o.value) == 1
    assert int(dut.m_udp_checksum_ok_o.value) == 1

    payload_receiver = cocotb.start_soon(
        receive_axis_frame(dut, "m_payload", seed=11)
    )
    dut.m_meta_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.m_meta_ready_i.value = 0
    observed_payload = beats_to_bytes(await payload_receiver)
    assert observed_payload == model.payload
    assert int(dut.m_error_valid_o.value) == 0
