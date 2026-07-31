"""Protocol reference model for FPGA-Stream-10G-RTL.

The RTL stream maps byte 0 to tdata[7:0], byte 1 to tdata[15:8], and so on.
Ethernet/IP/UDP fields themselves remain in network byte order.
"""

from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import struct


def mac_bytes(value: int) -> bytes:
    if not 0 <= value < (1 << 48):
        raise ValueError("MAC address must fit 48 bits")
    return value.to_bytes(6, "big")


def ip_bytes(value: int | str) -> bytes:
    if isinstance(value, str):
        return ipaddress.IPv4Address(value).packed
    if not 0 <= value < (1 << 32):
        raise ValueError("IPv4 address must fit 32 bits")
    return value.to_bytes(4, "big")


def ones_complement_sum(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    total = 0
    for offset in range(0, len(data), 2):
        total += int.from_bytes(data[offset : offset + 2], "big")
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total


def checksum16(data: bytes) -> int:
    return (~ones_complement_sum(data)) & 0xFFFF


def checksum_valid(data: bytes) -> bool:
    return ones_complement_sum(data) == 0xFFFF


@dataclass(frozen=True)
class UdpFrame:
    dst_mac: int
    src_mac: int
    src_ip: int
    dst_ip: int
    src_port: int
    dst_port: int
    payload: bytes
    identification: int = 0
    ttl: int = 64
    udp_checksum_enable: bool = True

    def build(self) -> bytes:
        udp_length = 8 + len(self.payload)
        ip_total_length = 20 + udp_length

        ip_header = bytearray(
            struct.pack(
                "!BBHHHBBH4s4s",
                0x45,
                0,
                ip_total_length,
                self.identification,
                0x4000,
                self.ttl,
                17,
                0,
                ip_bytes(self.src_ip),
                ip_bytes(self.dst_ip),
            )
        )
        ip_header[10:12] = checksum16(bytes(ip_header)).to_bytes(2, "big")

        udp_header = bytearray(
            struct.pack(
                "!HHHH",
                self.src_port,
                self.dst_port,
                udp_length,
                0,
            )
        )
        if self.udp_checksum_enable:
            pseudo_header = (
                ip_bytes(self.src_ip)
                + ip_bytes(self.dst_ip)
                + b"\x00\x11"
                + udp_length.to_bytes(2, "big")
            )
            value = checksum16(pseudo_header + udp_header + self.payload)
            udp_header[6:8] = (0xFFFF if value == 0 else value).to_bytes(2, "big")

        ethernet = mac_bytes(self.dst_mac) + mac_bytes(self.src_mac) + b"\x08\x00"
        return ethernet + bytes(ip_header) + bytes(udp_header) + self.payload


def parse_udp_frame(frame: bytes, check_udp_checksum: bool = True) -> dict[str, object]:
    if len(frame) < 42:
        raise ValueError("frame too short")
    if frame[12:14] != b"\x08\x00":
        raise ValueError("not IPv4")
    ip_header = frame[14:34]
    if ip_header[0] != 0x45:
        raise ValueError("only IPv4 IHL=5 is supported")
    if not checksum_valid(ip_header):
        raise ValueError("bad IPv4 checksum")
    flags_fragment = int.from_bytes(ip_header[6:8], "big")
    if flags_fragment & 0xBFFF:
        raise ValueError("fragmented or reserved IPv4 packet")
    if ip_header[9] != 17:
        raise ValueError("not UDP")
    ip_total_length = int.from_bytes(ip_header[2:4], "big")
    if ip_total_length < 28 or 14 + ip_total_length > len(frame):
        raise ValueError("invalid IPv4 total length")

    udp = frame[34 : 14 + ip_total_length]
    udp_length = int.from_bytes(udp[4:6], "big")
    if udp_length != ip_total_length - 20 or udp_length < 8:
        raise ValueError("invalid UDP length")
    udp = udp[:udp_length]
    udp_checksum = int.from_bytes(udp[6:8], "big")
    if check_udp_checksum and udp_checksum != 0:
        pseudo = ip_header[12:20] + b"\x00\x11" + udp_length.to_bytes(2, "big")
        if not checksum_valid(pseudo + udp):
            raise ValueError("bad UDP checksum")

    return {
        "dst_mac": int.from_bytes(frame[0:6], "big"),
        "src_mac": int.from_bytes(frame[6:12], "big"),
        "src_ip": int.from_bytes(ip_header[12:16], "big"),
        "dst_ip": int.from_bytes(ip_header[16:20], "big"),
        "src_port": int.from_bytes(udp[0:2], "big"),
        "dst_port": int.from_bytes(udp[2:4], "big"),
        "payload": bytes(udp[8:]),
        "ip_total_length": ip_total_length,
        "udp_checksum_present": udp_checksum != 0,
    }


def build_arp_frame(
    *,
    eth_dst_mac: int,
    eth_src_mac: int,
    opcode: int,
    sender_mac: int,
    sender_ip: int,
    target_mac: int,
    target_ip: int,
) -> bytes:
    if opcode not in (1, 2):
        raise ValueError("ARP opcode must be request (1) or reply (2)")
    return b"".join(
        [
            mac_bytes(eth_dst_mac),
            mac_bytes(eth_src_mac),
            b"\x08\x06",
            b"\x00\x01",
            b"\x08\x00",
            b"\x06\x04",
            opcode.to_bytes(2, "big"),
            mac_bytes(sender_mac),
            ip_bytes(sender_ip),
            mac_bytes(target_mac),
            ip_bytes(target_ip),
        ]
    )


def axis_beats(frame: bytes) -> list[tuple[int, int, bool]]:
    beats: list[tuple[int, int, bool]] = []
    for offset in range(0, len(frame), 8):
        chunk = frame[offset : offset + 8]
        data = int.from_bytes(chunk.ljust(8, b"\x00"), "little")
        keep = (1 << len(chunk)) - 1
        beats.append((data, keep, offset + len(chunk) == len(frame)))
    return beats


def beats_to_bytes(beats: list[tuple[int, int, bool]]) -> bytes:
    result = bytearray()
    saw_last = False
    for data, keep, last in beats:
        for lane in range(8):
            if keep & (1 << lane):
                result.append((data >> (lane * 8)) & 0xFF)
        if last:
            saw_last = True
            break
    if not saw_last:
        raise ValueError("stream did not contain tlast")
    return bytes(result)
