# FPGA-Stream-10G-RTL

Many public 10G FPGA RTL projects treat the physical implementation as an afterthought. They describe packets, FIFOs, and state machines, but rarely define a hard contract for clocking, transaction ownership, backpressure, register boundaries, timing closure, or the physical cost of the logic they generate.

This repository is my public answer to that problem.

It presents a deliberately reduced-frequency, non-proprietary 10G-class streaming RTL design so FPGA learners can see what disciplined, physical-layer-aware RTL should look like: explicit cycle ownership, correct ready/valid behavior, bounded arithmetic, registered interfaces, reproducible verification, and implementation-conscious structure.

## Public Design Target

- **Clock:** 156.25 MHz
- **Datapath:** 64-bit streaming interface
- **Nominal throughput:** 10 Gb/s class
- **Style:** synthesizable SystemVerilog
- **Focus:** deterministic transaction contracts, protocol correctness, backpressure, bounded logic, and verification
- **Audience:** FPGA students, independent developers, and engineers studying network datapaths

This is not intended to be a copy of another public NIC project, nor is it a weakened copy of my private HFT implementation. It uses a separate public architecture designed specifically for study, inspection, synthesis, and verification.

## What This Repository Will Demonstrate

- Correct `valid/ready` ownership
- Stable output data during backpressure
- Explicit frame and metadata lifetime
- Registered parser and transmitter boundaries
- Ethernet II, ARP, IPv4, UDP, and ICMP reference paths
- Length, truncation, and malformed-frame handling
- IPv4 and UDP checksum reference models
- Random-stall and back-to-back frame verification
- SystemVerilog assertions for transaction correctness
- Synthesis and timing reports suitable for implementation review

## What Is Intentionally Not Public

My production SnowSakura HFT architecture is not included here. In particular, this repository does **not** publish:

- GTH Raw Mode implementation
- 322.56 MHz datapaths
- RX/TX buffer-bypass architecture
- Manual alignment and deterministic boundary recovery
- HKEX OMD-C parser architecture
- CME MDP 3.0 / iLink 3 architecture
- Dual-line fast-candidate / slow-truth processing
- 36–37 ns deterministic HFT datapath techniques
- Private placement, routing, Pblock, and physical-closure methods

Those systems represent separate proprietary engineering work. For commercial use, private integration, exchange-specific FPGA work, or technical cooperation, contact me directly.

## Purpose

This repository is provided as a technical reference for FPGA learners and engineers who want to study disciplined 10G-class streaming RTL without receiving access to my proprietary low-latency trading architecture.

The goal is simple: show that even a public educational design should respect the hardware beneath the RTL.

---

## 中文说明

目前很多公开的 10G FPGA RTL 只会描述报文、FIFO 和状态机，却没有认真对待 clock、ready/valid、backpressure、寄存器边界、组合深度、timing closure 和真实物理实现成本。

这个仓库就是我的公开回应。

这里将提供一套 **156.25 MHz、64-bit、10 Gb/s class** 的降频公开版 streaming RTL，让 FPGA 学习者看到：真正合格的网络 RTL 应该怎样定义 transaction ownership、cycle boundary、protocol completion、bounded logic 与 verification contract。

这里不会公开我的 SnowSakura GTH Raw Mode、322.56 MHz、HKEX OMD-C、CME MDP 3.0 / iLink 3、36–37 ns deterministic HFT datapath，以及相关的 placement、routing 和物理收敛方法。如果需要相关商业合作、私有集成或交易所协议 FPGA 开发，请直接联系我。

本仓库仅供 FPGA 学习者、独立开发者与工程人员参考、学习和研究。
