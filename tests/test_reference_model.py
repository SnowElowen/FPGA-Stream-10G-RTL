from __future__ import annotations

import pytest

from reference_model import (
    UdpFrame,
    axis_beats,
    beats_to_bytes,
    build_arp_frame,
    checksum16,
    checksum_valid,
    parse_udp_frame,
)


def test_checksum_known_ipv4_header() -> None:
    header_without_checksum = bytes.fromhex(
        "450000730000400040110000c0a80001c0a800c7"
    )
    assert checksum16(header_without_checksum) == 0xB861


def test_udp_round_trip_with_odd_payload_and_zero_bytes() -> None:
    model = UdpFrame(
        dst_mac=0x001122334455,
        src_mac=0xAABBCCDDEEFF,
        src_ip=0xC0A80101,
        dst_ip=0xC0A80102,
        src_port=10000,
        dst_port=20000,
        payload=b"\x00snow\x00sakura\xff",
        identification=0x1234,
        ttl=37,
        udp_checksum_enable=True,
    )
    frame = model.build()
    parsed = parse_udp_frame(frame)
    assert parsed["payload"] == model.payload
    assert parsed["src_port"] == model.src_port
    assert parsed["dst_port"] == model.dst_port
    assert parsed["udp_checksum_present"] is True
    assert beats_to_bytes(axis_beats(frame)) == frame


def test_zero_length_udp_payload() -> None:
    model = UdpFrame(
        dst_mac=0xFFFFFFFFFFFF,
        src_mac=0x020000000001,
        src_ip=0x0A000001,
        dst_ip=0x0A000002,
        src_port=1,
        dst_port=2,
        payload=b"",
        udp_checksum_enable=False,
    )
    frame = model.build()
    parsed = parse_udp_frame(frame)
    assert parsed["payload"] == b""
    assert parsed["udp_checksum_present"] is False


def test_corrupted_ipv4_checksum_is_rejected() -> None:
    frame = bytearray(
        UdpFrame(
            dst_mac=1,
            src_mac=2,
            src_ip=0x0A000001,
            dst_ip=0x0A000002,
            src_port=3,
            dst_port=4,
            payload=b"abc",
        ).build()
    )
    frame[22] ^= 0x01
    with pytest.raises(ValueError, match="IPv4 checksum"):
        parse_udp_frame(bytes(frame))


def test_corrupted_udp_checksum_is_rejected() -> None:
    frame = bytearray(
        UdpFrame(
            dst_mac=1,
            src_mac=2,
            src_ip=0x0A000001,
            dst_ip=0x0A000002,
            src_port=3,
            dst_port=4,
            payload=b"abcdefg",
        ).build()
    )
    frame[-1] ^= 0x80
    with pytest.raises(ValueError, match="UDP checksum"):
        parse_udp_frame(bytes(frame))


def test_arp_frame_layout() -> None:
    frame = build_arp_frame(
        eth_dst_mac=0xFFFFFFFFFFFF,
        eth_src_mac=0x001122334455,
        opcode=1,
        sender_mac=0x001122334455,
        sender_ip=0xC0A80101,
        target_mac=0,
        target_ip=0xC0A80102,
    )
    assert len(frame) == 42
    assert frame[12:14] == b"\x08\x06"
    assert frame[20:22] == b"\x00\x01"
    assert checksum_valid(bytes.fromhex("ffff0000")) is True
