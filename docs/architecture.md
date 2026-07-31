# Architecture

## Design intent

This repository demonstrates disciplined RTL without publishing a latency-sensitive architecture. The design is deliberately store-and-forward and multi-cycle. That choice creates a clean public separation from proprietary cut-through and transceiver-level implementations while still allowing full line-rate streaming once an output frame begins.

## RX datapath

```text
64-bit MAC RX stream
        |
        v
Byte-addressed frame memory
        |
        v
Ethernet validation state
        |
        v
IPv4 field validation
        |
        v
10-cycle IPv4 checksum accumulation
        |
        v
Optional variable-cycle UDP checksum accumulation
        |
        v
Held metadata transaction
        |
        v
64-bit aligned UDP payload stream
```

The parser does not expose metadata from a partially received header. Full-frame capture also makes truncation, malformed `tkeep`, and length mismatch decisions explicit.

## TX datapath

```text
Descriptor handshake
        |
        v
Payload capture into frame memory
        |
        v
10-cycle IPv4 checksum
        |
        v
Optional UDP pseudo-header/payload checksum
        |
        v
42-cycle bounded header write
        |
        v
64-bit frame output register boundary
```

The header is written one byte per cycle. This is intentionally ordinary: it removes a wide combinational header multiplexer from the preparation path and keeps the public implementation easy to inspect.

## Expected implementation character

At 156.25 MHz the clock period is 6.4 ns. The intended register-to-register paths are small counters, equality checks, byte-memory addressing, 16/32-bit additions, and output packing. The design does not rely on vendor primitives or placement directives.

Packet memory may infer distributed RAM, registers, or block memory depending on device, synthesis settings, and parameter values. Integrators should inspect their own post-synthesis and post-route reports rather than assuming a particular mapping.

## Non-goals

- No direct PHY or transceiver wrapper
- No cut-through latency claim
- No multi-clock CDC
- No IP fragmentation or reassembly
- No TCP state machine
- No congestion control
- No exchange-specific market-data parser
- No private timing, placement, or routing methodology
