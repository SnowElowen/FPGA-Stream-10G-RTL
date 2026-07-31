# Interface contract

## Clock and reset

All reusable modules use one synchronous clock domain:

- `clk_i`: nominally 156.25 MHz for a 64-bit 10G MAC-side datapath.
- `rst_i`: active-high synchronous reset.

No CDC logic is hidden inside the public core. If the attached MAC or application uses a different clock, the integrator must provide an explicit CDC bridge outside this boundary.

## Frame stream

The frame stream uses five signals:

- `tdata[63:0]`: eight byte lanes; lane 0 is bits `[7:0]` and is the earliest byte.
- `tkeep[7:0]`: byte-lane validity.
- `tvalid`: source owns and presents a transaction.
- `tready`: destination can accept the current transaction.
- `tlast`: current accepted beat ends the frame.

A transfer occurs only on the rising clock edge where both `tvalid` and `tready` are high.

The source must hold `tdata`, `tkeep`, and `tlast` stable while `tvalid=1` and `tready=0`. Data content never determines whether a transaction exists; an all-zero beat is legal.

For this reference design, all non-final beats require `tkeep=8'hff`. The final beat requires a non-zero contiguous mask starting at lane 0: `01`, `03`, `07`, `0f`, `1f`, `3f`, `7f`, or `ff`.

Frames do not include Ethernet preamble, SFD, or FCS. The external MAC owns those functions.

## RX ordering

`ipv4_udp_rx` operates in this sequence:

1. Capture a complete frame.
2. Validate Ethernet II and fixed-header IPv4 fields.
3. Validate IPv4 header checksum.
4. Validate UDP length and optionally UDP checksum.
5. Present metadata with `m_meta_valid_o`.
6. After metadata is accepted, stream the UDP payload.

Metadata remains stable under backpressure. Payload does not begin before the metadata transaction is accepted.

## TX ordering

`ipv4_udp_tx` operates in this sequence:

1. Accept one descriptor.
2. Accept exactly the declared number of payload bytes and one matching `tlast`.
3. Calculate IPv4 checksum.
4. Optionally calculate UDP checksum.
5. Build the Ethernet/IP/UDP header into packet memory.
6. Emit the complete frame and hold each output beat under backpressure.

The descriptor source must not send another descriptor until `s_desc_ready_o` is asserted again.

## Error channel

Errors use a normal `valid/ready` transaction. `error_code` remains stable until accepted. A rejected frame is not partially delivered.
