`timescale 1ns / 1ps

// Store-and-forward Ethernet II / IPv4 / UDP receiver.
//
// Public-reference architecture:
//   64-bit frame stream -> byte-addressed packet memory -> bounded parser FSM
//   -> iterative IPv4/UDP checksum validation -> metadata -> payload stream.
//
// The input and output streams are MAC-facing Ethernet frames without preamble
// or FCS. Only fixed 20-byte IPv4 headers are accepted. IPv4 fragmentation is
// rejected. A zero UDP checksum is accepted as "checksum not supplied".
module ipv4_udp_rx #(
    parameter int MAX_FRAME_BYTES   = 2048,
    parameter bit CHECK_UDP_CHECKSUM = 1'b1
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [63:0] s_axis_tdata_i,
    input  logic [7:0]  s_axis_tkeep_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,

    output logic        m_meta_valid_o,
    input  logic        m_meta_ready_i,
    output logic [47:0] m_dst_mac_o,
    output logic [47:0] m_src_mac_o,
    output logic [31:0] m_src_ip_o,
    output logic [31:0] m_dst_ip_o,
    output logic [15:0] m_src_port_o,
    output logic [15:0] m_dst_port_o,
    output logic [15:0] m_payload_length_o,
    output logic [15:0] m_ip_total_length_o,
    output logic [15:0] m_frame_length_o,
    output logic        m_udp_checksum_present_o,
    output logic        m_udp_checksum_ok_o,

    output logic [63:0] m_payload_tdata_o,
    output logic [7:0]  m_payload_tkeep_o,
    output logic        m_payload_tvalid_o,
    input  logic        m_payload_tready_i,
    output logic        m_payload_tlast_o,

    output logic        m_error_valid_o,
    input  logic        m_error_ready_i,
    output logic [7:0]  m_error_code_o
);

    localparam int LEN_W = $clog2(MAX_FRAME_BYTES + 1);

    localparam logic [7:0] ERR_BAD_KEEP       = 8'h01;
    localparam logic [7:0] ERR_FRAME_TOO_LONG = 8'h02;
    localparam logic [7:0] ERR_FRAME_TOO_SHORT= 8'h03;
    localparam logic [7:0] ERR_NOT_IPV4       = 8'h04;
    localparam logic [7:0] ERR_IPV4_HEADER    = 8'h05;
    localparam logic [7:0] ERR_FRAGMENTED     = 8'h06;
    localparam logic [7:0] ERR_NOT_UDP        = 8'h07;
    localparam logic [7:0] ERR_LENGTH         = 8'h08;
    localparam logic [7:0] ERR_IPV4_CHECKSUM  = 8'h09;
    localparam logic [7:0] ERR_UDP_CHECKSUM   = 8'h0a;

    typedef enum logic [4:0] {
        ST_CAPTURE,
        ST_ETH,
        ST_IPV4,
        ST_UDP,
        ST_IP_CSUM_ACCUM,
        ST_IP_CSUM_FOLD0,
        ST_IP_CSUM_FOLD1,
        ST_UDP_CSUM_PREP,
        ST_UDP_CSUM_ACCUM,
        ST_UDP_CSUM_FOLD0,
        ST_UDP_CSUM_FOLD1,
        ST_META,
        ST_PAYLOAD,
        ST_ERROR
    } state_t;

    state_t state_reg;

    logic [7:0] frame_mem [0:MAX_FRAME_BYTES-1];
    logic [LEN_W-1:0] capture_length_reg;
    logic [LEN_W-1:0] frame_length_reg;
    logic             capture_drop_reg;
    logic [7:0]       capture_error_reg;

    logic [47:0] dst_mac_reg;
    logic [47:0] src_mac_reg;
    logic [31:0] src_ip_reg;
    logic [31:0] dst_ip_reg;
    logic [15:0] src_port_reg;
    logic [15:0] dst_port_reg;
    logic [15:0] ip_total_length_reg;
    logic [15:0] udp_length_reg;
    logic [15:0] payload_length_reg;
    logic        udp_checksum_present_reg;
    logic        udp_checksum_ok_reg;

    logic [31:0] checksum_sum_reg;
    logic [16:0] checksum_fold_reg;
    logic [15:0] checksum_word_index_reg;
    logic [15:0] checksum_word_total_reg;

    logic [15:0] payload_index_reg;
    logic [7:0]  error_code_reg;

    function automatic logic keep_is_contiguous(input logic [7:0] keep);
        logic seen_zero;
        int i;
        begin
            keep_is_contiguous = (keep != 8'h00);
            seen_zero = 1'b0;
            for (i = 0; i < 8; i++) begin
                if (!keep[i]) begin
                    seen_zero = 1'b1;
                end else if (seen_zero) begin
                    keep_is_contiguous = 1'b0;
                end
            end
        end
    endfunction

    function automatic logic [3:0] keep_count(input logic [7:0] keep);
        logic [3:0] count;
        int i;
        begin
            count = 4'd0;
            for (i = 0; i < 8; i++) begin
                count = count + keep[i];
            end
            return count;
        end
    endfunction

    function automatic logic [15:0] be16(input int unsigned addr);
        begin
            be16 = {frame_mem[addr], frame_mem[addr+1]};
        end
    endfunction

    function automatic logic [31:0] be32(input int unsigned addr);
        begin
            be32 = {
                frame_mem[addr], frame_mem[addr+1],
                frame_mem[addr+2], frame_mem[addr+3]
            };
        end
    endfunction

    function automatic logic [15:0] udp_checksum_word(
        input logic [15:0] index,
        input logic [15:0] udp_length
    );
        int unsigned byte_offset;
        logic [15:0] data_word_index;
        begin
            case (index)
                16'd0: udp_checksum_word = src_ip_reg[31:16];
                16'd1: udp_checksum_word = src_ip_reg[15:0];
                16'd2: udp_checksum_word = dst_ip_reg[31:16];
                16'd3: udp_checksum_word = dst_ip_reg[15:0];
                16'd4: udp_checksum_word = 16'h0011;
                16'd5: udp_checksum_word = udp_length;
                default: begin
                    data_word_index = index - 16'd6;
                    byte_offset = data_word_index * 2;
                    if ((byte_offset + 1) < udp_length) begin
                        udp_checksum_word = {
                            frame_mem[34 + byte_offset],
                            frame_mem[35 + byte_offset]
                        };
                    end else begin
                        udp_checksum_word = {
                            frame_mem[34 + byte_offset], 8'h00
                        };
                    end
                end
            endcase
        end
    endfunction

    logic [3:0] input_byte_count;
    logic [LEN_W:0] input_next_length;
    logic current_keep_bad;
    logic current_too_long;
    logic [16:0] folded_checksum;
    logic [15:0] udp_current_word;
    logic [15:0] payload_remaining;

    always_comb begin
        input_byte_count  = keep_count(s_axis_tkeep_i);
        input_next_length = {1'b0, capture_length_reg} + input_byte_count;
        current_keep_bad  = 1'b0;
        if (!s_axis_tlast_i && (s_axis_tkeep_i != 8'hff)) begin
            current_keep_bad = 1'b1;
        end
        if (s_axis_tlast_i && !keep_is_contiguous(s_axis_tkeep_i)) begin
            current_keep_bad = 1'b1;
        end
        current_too_long = (input_next_length > MAX_FRAME_BYTES);

        folded_checksum = checksum_fold_reg[15:0]
                        + {{16{1'b0}}, checksum_fold_reg[16]};
        udp_current_word = udp_checksum_word(
            checksum_word_index_reg,
            udp_length_reg
        );
        payload_remaining = payload_length_reg - payload_index_reg;
    end

    assign s_axis_tready_o = (state_reg == ST_CAPTURE);

    assign m_meta_valid_o                = (state_reg == ST_META);
    assign m_dst_mac_o                   = dst_mac_reg;
    assign m_src_mac_o                   = src_mac_reg;
    assign m_src_ip_o                    = src_ip_reg;
    assign m_dst_ip_o                    = dst_ip_reg;
    assign m_src_port_o                  = src_port_reg;
    assign m_dst_port_o                  = dst_port_reg;
    assign m_payload_length_o            = payload_length_reg;
    assign m_ip_total_length_o           = ip_total_length_reg;
    assign m_frame_length_o              = frame_length_reg;
    assign m_udp_checksum_present_o      = udp_checksum_present_reg;
    assign m_udp_checksum_ok_o           = udp_checksum_ok_reg;

    assign m_payload_tvalid_o = (state_reg == ST_PAYLOAD);
    assign m_payload_tlast_o  = (state_reg == ST_PAYLOAD)
                              && (payload_remaining <= 16'd8);

    always_comb begin : payload_output_comb
        int lane;
        int unsigned addr;
        m_payload_tdata_o = 64'b0;
        m_payload_tkeep_o = 8'b0;
        for (lane = 0; lane < 8; lane++) begin
            addr = 42 + payload_index_reg + lane;
            if ((state_reg == ST_PAYLOAD)
                    && ((payload_index_reg + lane) < payload_length_reg)) begin
                m_payload_tdata_o[lane*8 +: 8] = frame_mem[addr];
                m_payload_tkeep_o[lane] = 1'b1;
            end
        end
    end

    assign m_error_valid_o = (state_reg == ST_ERROR);
    assign m_error_code_o  = error_code_reg;

    always_ff @(posedge clk_i) begin : rx_fsm
        int lane;
        logic [15:0] flags_fragment;
        logic [15:0] udp_checksum_field;
        logic [31:0] next_sum;

        if (rst_i) begin
            state_reg                  <= ST_CAPTURE;
            capture_length_reg         <= '0;
            frame_length_reg           <= '0;
            capture_drop_reg           <= 1'b0;
            capture_error_reg          <= '0;
            dst_mac_reg                <= '0;
            src_mac_reg                <= '0;
            src_ip_reg                 <= '0;
            dst_ip_reg                 <= '0;
            src_port_reg               <= '0;
            dst_port_reg               <= '0;
            ip_total_length_reg        <= '0;
            udp_length_reg             <= '0;
            payload_length_reg         <= '0;
            udp_checksum_present_reg   <= 1'b0;
            udp_checksum_ok_reg        <= 1'b0;
            checksum_sum_reg           <= '0;
            checksum_fold_reg          <= '0;
            checksum_word_index_reg    <= '0;
            checksum_word_total_reg    <= '0;
            payload_index_reg          <= '0;
            error_code_reg             <= '0;
        end else begin
            case (state_reg)
                ST_CAPTURE: begin
                    if (s_axis_tvalid_i) begin
                        if (!capture_drop_reg && !current_keep_bad && !current_too_long) begin
                            for (lane = 0; lane < 8; lane++) begin
                                if (s_axis_tkeep_i[lane]) begin
                                    frame_mem[capture_length_reg + lane]
                                        <= s_axis_tdata_i[lane*8 +: 8];
                                end
                            end
                            capture_length_reg <= input_next_length[LEN_W-1:0];
                        end

                        if (current_keep_bad) begin
                            capture_drop_reg  <= 1'b1;
                            capture_error_reg <= ERR_BAD_KEEP;
                        end else if (current_too_long) begin
                            capture_drop_reg  <= 1'b1;
                            capture_error_reg <= ERR_FRAME_TOO_LONG;
                        end

                        if (s_axis_tlast_i) begin
                            if (capture_drop_reg || current_keep_bad || current_too_long) begin
                                if (current_keep_bad) begin
                                    error_code_reg <= ERR_BAD_KEEP;
                                end else if (current_too_long) begin
                                    error_code_reg <= ERR_FRAME_TOO_LONG;
                                end else begin
                                    error_code_reg <= capture_error_reg;
                                end
                                state_reg <= ST_ERROR;
                            end else begin
                                frame_length_reg <= input_next_length[LEN_W-1:0];
                                state_reg <= ST_ETH;
                            end
                        end
                    end
                end

                ST_ETH: begin
                    if (frame_length_reg < 42) begin
                        error_code_reg <= ERR_FRAME_TOO_SHORT;
                        state_reg <= ST_ERROR;
                    end else if (be16(12) != 16'h0800) begin
                        error_code_reg <= ERR_NOT_IPV4;
                        state_reg <= ST_ERROR;
                    end else begin
                        dst_mac_reg <= {
                            frame_mem[0], frame_mem[1], frame_mem[2],
                            frame_mem[3], frame_mem[4], frame_mem[5]
                        };
                        src_mac_reg <= {
                            frame_mem[6], frame_mem[7], frame_mem[8],
                            frame_mem[9], frame_mem[10], frame_mem[11]
                        };
                        state_reg <= ST_IPV4;
                    end
                end

                ST_IPV4: begin
                    flags_fragment = be16(20);
                    if (frame_mem[14][7:4] != 4'd4
                            || frame_mem[14][3:0] != 4'd5) begin
                        error_code_reg <= ERR_IPV4_HEADER;
                        state_reg <= ST_ERROR;
                    end else if ((flags_fragment & 16'hbfff) != 16'h0000) begin
                        error_code_reg <= ERR_FRAGMENTED;
                        state_reg <= ST_ERROR;
                    end else if (frame_mem[23] != 8'd17) begin
                        error_code_reg <= ERR_NOT_UDP;
                        state_reg <= ST_ERROR;
                    end else if (be16(16) < 16'd28
                            || ({1'b0, be16(16)} + 17'd14) > frame_length_reg) begin
                        error_code_reg <= ERR_LENGTH;
                        state_reg <= ST_ERROR;
                    end else begin
                        ip_total_length_reg <= be16(16);
                        src_ip_reg <= be32(26);
                        dst_ip_reg <= be32(30);
                        state_reg <= ST_UDP;
                    end
                end

                ST_UDP: begin
                    if (be16(38) < 16'd8
                            || be16(38) != (ip_total_length_reg - 16'd20)) begin
                        error_code_reg <= ERR_LENGTH;
                        state_reg <= ST_ERROR;
                    end else begin
                        src_port_reg <= be16(34);
                        dst_port_reg <= be16(36);
                        udp_length_reg <= be16(38);
                        payload_length_reg <= be16(38) - 16'd8;
                        udp_checksum_field = be16(40);
                        udp_checksum_present_reg <= (udp_checksum_field != 16'h0000);
                        udp_checksum_ok_reg <= (udp_checksum_field == 16'h0000);
                        checksum_sum_reg <= 32'b0;
                        checksum_word_index_reg <= 16'b0;
                        checksum_word_total_reg <= 16'd10;
                        state_reg <= ST_IP_CSUM_ACCUM;
                    end
                end

                ST_IP_CSUM_ACCUM: begin
                    next_sum = checksum_sum_reg + {
                        16'b0,
                        frame_mem[14 + checksum_word_index_reg*2],
                        frame_mem[15 + checksum_word_index_reg*2]
                    };
                    checksum_sum_reg <= next_sum;
                    if ((checksum_word_index_reg + 16'd1) == checksum_word_total_reg) begin
                        state_reg <= ST_IP_CSUM_FOLD0;
                    end else begin
                        checksum_word_index_reg <= checksum_word_index_reg + 16'd1;
                    end
                end

                ST_IP_CSUM_FOLD0: begin
                    checksum_fold_reg <= {1'b0, checksum_sum_reg[15:0]}
                                       + {1'b0, checksum_sum_reg[31:16]};
                    state_reg <= ST_IP_CSUM_FOLD1;
                end

                ST_IP_CSUM_FOLD1: begin
                    if (folded_checksum[15:0] != 16'hffff) begin
                        error_code_reg <= ERR_IPV4_CHECKSUM;
                        state_reg <= ST_ERROR;
                    end else if (!CHECK_UDP_CHECKSUM || !udp_checksum_present_reg) begin
                        udp_checksum_ok_reg <= 1'b1;
                        state_reg <= ST_META;
                    end else begin
                        state_reg <= ST_UDP_CSUM_PREP;
                    end
                end

                ST_UDP_CSUM_PREP: begin
                    checksum_sum_reg <= 32'b0;
                    checksum_word_index_reg <= 16'b0;
                    checksum_word_total_reg <= 16'd6 + ((udp_length_reg + 16'd1) >> 1);
                    state_reg <= ST_UDP_CSUM_ACCUM;
                end

                ST_UDP_CSUM_ACCUM: begin
                    checksum_sum_reg <= checksum_sum_reg + {16'b0, udp_current_word};
                    if ((checksum_word_index_reg + 16'd1) == checksum_word_total_reg) begin
                        state_reg <= ST_UDP_CSUM_FOLD0;
                    end else begin
                        checksum_word_index_reg <= checksum_word_index_reg + 16'd1;
                    end
                end

                ST_UDP_CSUM_FOLD0: begin
                    checksum_fold_reg <= {1'b0, checksum_sum_reg[15:0]}
                                       + {1'b0, checksum_sum_reg[31:16]};
                    state_reg <= ST_UDP_CSUM_FOLD1;
                end

                ST_UDP_CSUM_FOLD1: begin
                    if (folded_checksum[15:0] != 16'hffff) begin
                        error_code_reg <= ERR_UDP_CHECKSUM;
                        state_reg <= ST_ERROR;
                    end else begin
                        udp_checksum_ok_reg <= 1'b1;
                        state_reg <= ST_META;
                    end
                end

                ST_META: begin
                    if (m_meta_ready_i) begin
                        if (payload_length_reg == 16'd0) begin
                            capture_length_reg <= '0;
                            capture_drop_reg <= 1'b0;
                            capture_error_reg <= '0;
                            state_reg <= ST_CAPTURE;
                        end else begin
                            payload_index_reg <= 16'd0;
                            state_reg <= ST_PAYLOAD;
                        end
                    end
                end

                ST_PAYLOAD: begin
                    if (m_payload_tready_i) begin
                        if (payload_remaining <= 16'd8) begin
                            capture_length_reg <= '0;
                            capture_drop_reg <= 1'b0;
                            capture_error_reg <= '0;
                            payload_index_reg <= '0;
                            state_reg <= ST_CAPTURE;
                        end else begin
                            payload_index_reg <= payload_index_reg + 16'd8;
                        end
                    end
                end

                ST_ERROR: begin
                    if (m_error_ready_i) begin
                        capture_length_reg <= '0;
                        frame_length_reg <= '0;
                        capture_drop_reg <= 1'b0;
                        capture_error_reg <= '0;
                        payload_index_reg <= '0;
                        state_reg <= ST_CAPTURE;
                    end
                end

                default: state_reg <= ST_CAPTURE;
            endcase
        end
    end

`ifdef FORMAL
    property p_payload_hold;
        @(posedge clk_i) disable iff (rst_i)
        m_payload_tvalid_o && !m_payload_tready_i
        |=> m_payload_tvalid_o
            && $stable(m_payload_tdata_o)
            && $stable(m_payload_tkeep_o)
            && $stable(m_payload_tlast_o);
    endproperty
    assert property (p_payload_hold);

    property p_meta_hold;
        @(posedge clk_i) disable iff (rst_i)
        m_meta_valid_o && !m_meta_ready_i
        |=> m_meta_valid_o
            && $stable(m_dst_mac_o)
            && $stable(m_src_mac_o)
            && $stable(m_src_ip_o)
            && $stable(m_dst_ip_o)
            && $stable(m_src_port_o)
            && $stable(m_dst_port_o)
            && $stable(m_payload_length_o);
    endproperty
    assert property (p_meta_hold);
`endif

endmodule
