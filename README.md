# FPGA-Stream-10G-RTL

Many public 10G FPGA examples can describe packets, FIFOs, and state machines, yet treat the implemented hardware as an afterthought. A network datapath is not correct merely because a waveform looks plausible: transaction ownership, backpressure, byte order, header completion, arithmetic width, register boundaries, and timing closure are part of the design contract.

**FPGA-Stream-10G-RTL is a public, vendor-neutral reference showing what disciplined 10G-class RTL should look like.** It uses a deliberately conventional 156.25 MHz architecture so the implementation remains readable and portable while still respecting the physical machine beneath the SystemVerilog.

This is not a reduced copy of SnowSakura. It is a clean-room public architecture built specifically for inspection, learning, synthesis, and verification.

## Public design target

| Item | Contract |
|---|---|
| Clock | 156.25 MHz nominal (`6.4 ns`) |
| Datapath | 64-bit data + 8-bit byte keep |
| Throughput | One 64-bit beat per cycle when streaming |
| Stream semantics | Explicit `valid/ready/last`; byte 0 is `tdata[7:0]` |
| Frame boundary | Ethernet frame without preamble, SFD, or FCS |
| RX architecture | Store-and-forward packet memory + bounded parser/checksum FSM |
| TX architecture | Descriptor/payload capture + iterative checksums + frame build + stream output |
| Protocols | Ethernet II, fixed-header IPv4, UDP, ARP |
| Vendor dependency | None in the reusable RTL |
| Verification | Python golden model, cocotb randomized stalls, CI compile/regression |

## What is implemented

- `axis_elastic_buffer`: a real elastic register; zero data remains a valid transaction and stalled outputs are held stable.
- `axis_frame_buffer`: complete-frame store-and-forward buffering with keep validation, oversize rejection, and no partial replay of malformed frames.
- `ones_complement_checksum`: bounded multi-cycle 16-bit one's-complement checksum engine.
- `ipv4_udp_rx`: Ethernet/IPv4/UDP frame capture, protocol validation, IPv4 checksum validation, optional UDP checksum validation, metadata handshake, and aligned payload output.
- `ipv4_udp_tx`: descriptor and payload capture, IPv4/UDP checksum generation, header construction, and 64-bit frame output.
- `arp_rx` / `arp_tx`: Ethernet/IPv4 ARP request/reply parsing and generation.
- `fpga_stream10g_core`: vendor-neutral UDP RX/TX integration boundary for connection to an external 64-bit Ethernet MAC.

## Integration boundary

Connect the core to a MAC that already supplies and accepts complete Ethernet frames:

```text
Your PHY / PCS / PMA / 10G MAC
              |
              | 64-bit frame stream @ 156.25 MHz
              v
+----------------------------------+
| fpga_stream10g_core              |
|                                  |
|  RX frame -> IPv4/UDP metadata   |
|           -> UDP payload stream  |
|                                  |
|  TX descriptor + payload         |
|           -> Ethernet frame      |
+----------------------------------+
              |
              v
        Your application RTL
```

The repository does **not** guess your transceiver wrapper, reference clock, reset controller, MAC IP ports, CDC boundary, board pins, or timing constraints. Those belong to the integrator and must be connected deliberately.

See [`docs/interface-contract.md`](docs/interface-contract.md) and [`docs/architecture.md`](docs/architecture.md).

## Transaction rules

Every streaming interface follows these rules:

1. A transaction exists when `valid=1`; data value is never used to infer validity.
2. A transaction is consumed only on `valid && ready`.
3. While `valid && !ready`, `data`, `keep`, `last`, and associated metadata remain stable.
4. Non-final frame beats use `tkeep=8'hff`.
5. The final beat uses a non-zero, contiguous low-lane `tkeep` value.
6. Metadata is not exposed until the complete required header and checksum checks have finished.
7. Malformed frames are reported through a held `error_valid/error_ready` transaction; they are not silently converted into partial payload.

## Verification

The Python reference model checks protocol arithmetic independently from the RTL. Cocotb tests then drive the RTL with zero-valued data, odd payload lengths, metadata stalls, output backpressure, and non-contiguous timing.

```bash
python3 -m pytest -q tests/test_reference_model.py

# With Icarus Verilog and cocotb installed:
make -C tests TOPLEVEL=axis_elastic_buffer MODULE=test_axis_elastic_buffer
make -C tests TOPLEVEL=ipv4_udp_tx MODULE=test_ipv4_udp_tx
make -C tests TOPLEVEL=ipv4_udp_rx MODULE=test_ipv4_udp_rx
make -C tests TOPLEVEL=arp_tx MODULE=test_arp_tx
make -C tests TOPLEVEL=arp_rx MODULE=test_arp_rx
```

GitHub Actions repeats the reference-model tests, compiles the integrated core, and runs the RTL regressions on every push and pull request.

## Deliberate architectural limits

This public design favors correctness, portability, and readable cycle ownership over latency. It stores complete frames, performs iterative checksum work, and uses ordinary FSM-controlled packet memory. It does not claim cut-through latency or deterministic HFT performance.

Only fixed 20-byte IPv4 headers are supported. IPv4 fragmentation is rejected. UDP checksum zero is accepted for IPv4; non-zero UDP checksums are validated when `CHECK_UDP_CHECKSUM=1`.

## Proprietary work not included

SnowSakura remains separate proprietary engineering. This repository does **not** publish or derive from:

- GTH Raw Mode implementation
- 322.56 MHz datapaths or 3.1004 ns cycle contracts
- RX/TX buffer-bypass control
- Manual alignment or deterministic boundary recovery
- HKEX OMD-C parser architecture
- CME MDP 3.0 or iLink 3 architecture
- Dual-Line Fast-Candidate / Slow-Truth processing
- Fixed-slice HFT parser placement
- 36–37 ns deterministic HFT datapaths
- Private Pblock, routing, clocking, or physical-closure methods

For exchange-specific FPGA development, private integration, low-latency architecture, or commercial cooperation, contact **SnowElowen** directly.

## 中文说明

很多公开的 10G FPGA 工程会写报文、FIFO 和状态机，却不认真定义 `valid/ready`、backpressure、byte order、header completion、寄存器边界、算术位宽与 timing closure。波形“看起来能动”不等于 RTL 工程闭环。

本仓库给出一套 **156.25 MHz、64-bit、10G-class** 的通用公开 RTL：架构故意采用普通的 store-and-forward packet memory 与多周期 FSM，不追求 SnowSakura 的低延迟路径，但每一笔 transaction、checksum、length、stall 和错误输出都必须有明确合同和自动验证。

使用者只需将 `fpga_stream10g_core` 的 64-bit frame stream 接到自己的 Ethernet MAC。PHY、PCS/PMA、GT、时钟、复位、CDC、引脚和约束由使用者根据自己的 FPGA 平台完成。

这里不会公开 SnowSakura Raw Mode、322.56 MHz、HKEX、CME、36–37 ns HFT datapath、manual alignment、buffer bypass、双线仲裁及私有物理收敛方法。需要相关 FPGA/HFT 合作可直接联系我。

本仓库供 FPGA 学习者、独立开发者与工程人员参考、学习、综合和验证。

## License

MIT License. See [`LICENSE`](LICENSE).
