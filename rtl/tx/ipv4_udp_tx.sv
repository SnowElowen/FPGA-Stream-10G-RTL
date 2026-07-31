`timescale 1ns / 1ps

// Store-and-forward Ethernet II / IPv4 / UDP transmitter.
//
// Descriptor and payload are captured first. Checksums are calculated over
// bounded, multi-cycle state machines. The complete Ethernet frame is then
// emitted on a 64-bit MAC-facing stream without preamble or FCS.
module ipv4_udp_tx #(
    parameter int MAX_FRAME_BYTES = 2048
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        s_desc_valid_i,
    output logic        s_desc_ready_o,
    input  logic [47:0] s_dst_mac_i,
    input  logic [47:0] s_src_mac_i,
    input  logic [31:0] s_src_ip_i,
    input  logic [31:0] s_dst_ip_i,
    input  logic [15:0] s_src_port_i,
    input  logic [15:0] s_dst_port_i,
    input  logic [15:0] s_payload_length_i,
    input  logic [15:0] s_ip_identification_i,
    input  logic [7:0]  s_ip_ttl_i,
    input  logic        s_udp_checksum_enable_i,

    input  logic [63:0] s_payload_tdata_i,
    input  logic [7:0]  s_payload_tkeep_i,
    input  logic        s_payload_tvalid_i,
    output logic        s_payload_tready_o,
    input  logic        s_payload_tlast_i,

    output logic [63:0] m_axis_tdata_o,
    output logic [7:0]  m_axis_tkeep_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,

    output logic        m_error_valid_o,
    input  logic        m_error_ready_i,
    output logic [7:0]  m_error_code_o
);

    localparam int LEN_W = $clog2(MAX_FRAME_BYTES + 1);

    localparam logic [7:0] ERR_FRAME_TOO_LONG = 8'h01;
    localparam logic [7:0] ERR_BAD_KEEP       = 8'h02;
    localparam logic [7:0] ERR_PAYLOAD_LENGTH = 8'h03;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_CAPTURE_PAYLOAD,
        ST_IP_CSUM_PREP,
        ST_IP_CSUM_ACCUM,
        ST_IP_CSUM_FOLD0,
        ST_IP_CSUM_FOLD1,
        ST_UDP_CSUM_PREP,
        ST_UDP_CSUM_ACCUM,
        ST_UDP_CSUM_FOLD0,
        ST_UDP_CSUM_FOLD1,
        ST_BUILD_HEADER,
        ST_OUTPUT,
        ST_ERROR
    } state_t;

    state_t state_reg;

    logic [7:0] frame_mem [0:MAX_FRAME_BYTES-1];

    logic [47:0] dst_mac_reg;
    logic [47:0] src_mac_reg;
    logic [31:0] src_ip_reg;
    logic [31:0] dst_ip_reg;
    logic [15:0] src_port_reg;
    logic [15:0] dst_port_reg;
    logic [15:0] payload_length_reg;
    logic [15:0] ip_identification_reg;
    logic [7:0]  ip_ttl_reg;
    logic        udp_checksum_enable_reg;

    logic [15:0] ip_total_length_reg;
    logic [15:0] udp_length_reg;
    logic [LEN_W-1:0] frame_length_reg;
    logic [15:0] ip_checksum_reg;
    logic [15:0] udp_checksum_reg;

    logic [15:0] payload_capture_index_reg;
    logic        payload_drop_reg;
    logic [7:0]  payload_error_reg;

    logic [31:0] checksum_sum_reg;
    logic [16:0] checksum_fold_reg;
    logic [15:0] checksum_word_index_reg;
    logic [15:0] checksum_word_total_reg;

    logic [5:0] header_index_reg;
    logic [LEN_W-1:0] output_index_reg;
    logic [7:0] error_code_reg;

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

    function automatic logic [15:0] ipv4_header_word(input logic [3:0] index);
        begin
            case (index)
                4'd0: ipv4_header_word = 16'h4500;
                4'd1: ipv4_header_word = ip_total_length_reg;
                4'd2: ipv4_header_word = ip_identification_reg;
                4'd3: ipv4_header_word = 16'h4000;
                4'd4: ipv4_header_word = {ip_ttl_reg, 8'h11};
                4'd5: ipv4_header_word = 16'h0000;
                4'd6: ipv4_header_word = src_ip_reg[31:16];
                4'd7: ipv4_header_word = src_ip_reg[15:0];
                4'd8: ipv4_header_word = dst_ip_reg[31:16];
                4'd9: ipv4_header_word = dst_ip_reg[15:0];
                default: ipv4_header_word = 16'h0000;
            endcase
        end
    endfunction

    function automatic logic [15:0] udp_checksum_word(input logic [15:0] index);
        logic [15:0] payload_word_index;
        int unsigned byte_offset;
        begin
            case (index)
                16'd0: udp_checksum_word = src_ip_reg[31:16];
                16'd1: udp_checksum_word = src_ip_reg[15:0];
                16'd2: udp_checksum_word = dst_ip_reg[31:16];
                16'd3: udp_checksum_word = dst_ip_reg[15:0];
                16'd4: udp_checksum_word = 16'h0011;
                16'd5: udp_checksum_word = udp_length_reg;
                16'd6: udp_checksum_word = src_port_reg;
                16'd7: udp_checksum_word = dst_port_reg;
                16'd8: udp_checksum_word = udp_length_reg;
                16'd9: udp_checksum_word = 16'h0000;
                default: begin
                    payload_word_index = index - 16'd10;
                    byte_offset = payload_word_index * 2;
                    if ((byte_offset + 1) < payload_length_reg) begin
                        udp_checksum_word = {
                            frame_mem[42 + byte_offset],
                            frame_mem[43 + byte_offset]
                        };
                    end else begin
                        udp_checksum_word = {
                            frame_mem[42 + byte_offset], 8'h00
                        };
                    end
                end
            endcase
        end
    endfunction

    function automatic logic [7:0] header_byte(input logic [5:0] index);
        begin
            case (index)
                6'd0:  header_byte = dst_mac_reg[47:40];
                6'd1:  header_byte = dst_mac_reg[39:32];
                6'd2:  header_byte = dst_mac_reg[31:24];
                6'd3:  header_byte = dst_mac_reg[23:16];
                6'd4:  header_byte = dst_mac_reg[15:8];
                6'd5:  header_byte = dst_mac_reg[7:0];
                6'd6:  header_byte = src_mac_reg[47:40];
                6'd7:  header_byte = src_mac_reg[39:32];
                6'd8:  header_byte = src_mac_reg[31:24];
                6'd9:  header_byte = src_mac_reg[23:16];
                6'd10: header_byte = src_mac_reg[15:8];
                6'd11: header_byte = src_mac_reg[7:0];
                6'd12: header_byte = 8'h08;
                6'd13: header_byte = 8'h00;
                6'd14: header_byte = 8'h45;
                6'd15: header_byte = 8'h00;
                6'd16: header_byte = ip_total_length_reg[15:8];
                6'd17: header_byte = ip_total_length_reg[7:0];
                6'd18: header_byte = ip_identification_reg[15:8];
                6'd19: header_byte = ip_identification_reg[7:0];
                6'd20: header_byte = 8'h40;
                6'd21: header_byte = 8'h00;
                6'd22: header_byte = ip_ttl_reg;
                6'd23: header_byte = 8'h11;
                6'd24: header_byte = ip_checksum_reg[15:8];
                6'd25: header_byte = ip_checksum_reg[7:0];
                6'd26: header_byte = src_ip_reg[31:24];
                6'd27: header_byte = src_ip_reg[23:16];
                6'd28: header_byte = src_ip_reg[15:8];
                6'd29: header_byte = src_ip_reg[7:0];
                6'd30: header_byte = dst_ip_reg[31:24];
                6'd31: header_byte = dst_ip_reg[23:16];
                6'd32: header_byte = dst_ip_reg[15:8];
                6'd33: header_byte = dst_ip_reg[7:0];
                6'd34: header_byte = src_port_reg[15:8];
                6'd35: header_byte = src_port_reg[7:0];
                6'd36: header_byte = dst_port_reg[15:8];
                6'd37: header_byte = dst_port_reg[7:0];
                6'd38: header_byte = udp_length_reg[15:8];
                6'd39: header_byte = udp_length_reg[7:0];
                6'd40: header_byte = udp_checksum_reg[15:8];
                6'd41: header_byte = udp_checksum_reg[7:0];
                default: header_byte = 8'h00;
            endcase
        end
    endfunction

    logic [3:0] payload_input_bytes;
    logic [16:0] payload_next_count;
    logic payload_keep_bad;
    logic payload_length_bad;
    logic [16:0] folded_checksum;
    logic [15:0] checksum_current_word;
    logic [LEN_W:0] output_remaining;

    always_comb begin
        payload_input_bytes = keep_count(s_payload_tkeep_i);
        payload_next_count = {1'b0, payload_capture_index_reg}
                           + payload_input_bytes;

        payload_keep_bad = 1'b0;
        if (!s_payload_tlast_i && (s_payload_tkeep_i != 8'hff)) begin
            payload_keep_bad = 1'b1;
        end
        if (s_payload_tlast_i && !keep_is_contiguous(s_payload_tkeep_i)) begin
            payload_keep_bad = 1'b1;
        end

        payload_length_bad = (payload_next_count > payload_length_reg)
                          || (s_payload_tlast_i
                              && (payload_next_count != payload_length_reg))
                          || (!s_payload_tlast_i
                              && (payload_next_count == payload_length_reg));

        folded_checksum = checksum_fold_reg[15:0]
                        + {{16{1'b0}}, checksum_fold_reg[16]};

        if (state_reg == ST_IP_CSUM_ACCUM) begin
            checksum_current_word = ipv4_header_word(checksum_word_index_reg[3:0]);
        end else begin
            checksum_current_word = udp_checksum_word(checksum_word_index_reg);
        end

        output_remaining = {1'b0, frame_length_reg}
                         - {1'b0, output_index_reg};
    end

    assign s_desc_ready_o = (state_reg == ST_IDLE);
    assign s_payload_tready_o = (state_reg == ST_CAPTURE_PAYLOAD);

    assign m_axis_tvalid_o = (state_reg == ST_OUTPUT);
    assign m_axis_tlast_o  = (state_reg == ST_OUTPUT)
                           && (output_remaining <= 8);

    always_comb begin : output_pack
        int lane;
        int unsigned addr;
        m_axis_tdata_o = 64'b0;
        m_axis_tkeep_o = 8'b0;
        for (lane = 0; lane < 8; lane++) begin
            addr = output_index_reg + lane;
            if ((state_reg == ST_OUTPUT) && (addr < frame_length_reg)) begin
                m_axis_tdata_o[lane*8 +: 8] = frame_mem[addr];
                m_axis_tkeep_o[lane] = 1'b1;
            end
        end
    end

    assign m_error_valid_o = (state_reg == ST_ERROR);
    assign m_error_code_o  = error_code_reg;

    always_ff @(posedge clk_i) begin : tx_fsm
        int lane;
        logic [31:0] next_sum;
        logic [15:0] raw_udp_checksum;

        if (rst_i) begin
            state_reg                 <= ST_IDLE;
            dst_mac_reg               <= '0;
            src_mac_reg               <= '0;
            src_ip_reg                <= '0;
            dst_ip_reg                <= '0;
            src_port_reg              <= '0;
            dst_port_reg              <= '0;
            payload_length_reg        <= '0;
            ip_identification_reg     <= '0;
            ip_ttl_reg                <= 8'd64;
            udp_checksum_enable_reg   <= 1'b0;
            ip_total_length_reg       <= '0;
            udp_length_reg            <= '0;
            frame_length_reg          <= '0;
            ip_checksum_reg           <= '0;
            udp_checksum_reg          <= '0;
            payload_capture_index_reg <= '0;
            payload_drop_reg          <= 1'b0;
            payload_error_reg         <= '0;
            checksum_sum_reg          <= '0;
            checksum_fold_reg         <= '0;
            checksum_word_index_reg   <= '0;
            checksum_word_total_reg   <= '0;
            header_index_reg          <= '0;
            output_index_reg          <= '0;
            error_code_reg            <= '0;
        end else begin
            case (state_reg)
                ST_IDLE: begin
                    if (s_desc_valid_i) begin
                        if ((17'd42 + s_payload_length_i) > MAX_FRAME_BYTES) begin
                            error_code_reg <= ERR_FRAME_TOO_LONG;
                            state_reg <= ST_ERROR;
                        end else begin
                            dst_mac_reg <= s_dst_mac_i;
                            src_mac_reg <= s_src_mac_i;
                            src_ip_reg <= s_src_ip_i;
                            dst_ip_reg <= s_dst_ip_i;
                            src_port_reg <= s_src_port_i;
                            dst_port_reg <= s_dst_port_i;
                            payload_length_reg <= s_payload_length_i;
                            ip_identification_reg <= s_ip_identification_i;
                            ip_ttl_reg <= s_ip_ttl_i;
                            udp_checksum_enable_reg <= s_udp_checksum_enable_i;
                            ip_total_length_reg <= 16'd28 + s_payload_length_i;
                            udp_length_reg <= 16'd8 + s_payload_length_i;
                            frame_length_reg <= 42 + s_payload_length_i;
                            payload_capture_index_reg <= 16'd0;
                            payload_drop_reg <= 1'b0;
                            payload_error_reg <= '0;
                            if (s_payload_length_i == 16'd0) begin
                                state_reg <= ST_IP_CSUM_PREP;
                            end else begin
                                state_reg <= ST_CAPTURE_PAYLOAD;
                            end
                        end
                    end
                end

                ST_CAPTURE_PAYLOAD: begin
                    if (s_payload_tvalid_i) begin
                        if (!payload_drop_reg && !payload_keep_bad && !payload_length_bad) begin
                            for (lane = 0; lane < 8; lane++) begin
                                if (s_payload_tkeep_i[lane]) begin
                                    frame_mem[42 + payload_capture_index_reg + lane]
                                        <= s_payload_tdata_i[lane*8 +: 8];
                                end
                            end
                            payload_capture_index_reg <= payload_next_count[15:0];
                        end

                        if (payload_keep_bad) begin
                            payload_drop_reg <= 1'b1;
                            payload_error_reg <= ERR_BAD_KEEP;
                        end else if (payload_length_bad) begin
                            payload_drop_reg <= 1'b1;
                            payload_error_reg <= ERR_PAYLOAD_LENGTH;
                        end

                        if (s_payload_tlast_i
                                || payload_length_bad
                                || payload_keep_bad) begin
                            if (payload_drop_reg || payload_keep_bad || payload_length_bad) begin
                                if (payload_keep_bad) begin
                                    error_code_reg <= ERR_BAD_KEEP;
                                end else if (payload_length_bad) begin
                                    error_code_reg <= ERR_PAYLOAD_LENGTH;
                                end else begin
                                    error_code_reg <= payload_error_reg;
                                end
                                state_reg <= ST_ERROR;
                            end else begin
                                state_reg <= ST_IP_CSUM_PREP;
                            end
                        end
                    end
                end

                ST_IP_CSUM_PREP: begin
                    checksum_sum_reg <= 32'b0;
                    checksum_word_index_reg <= 16'd0;
                    checksum_word_total_reg <= 16'd10;
                    state_reg <= ST_IP_CSUM_ACCUM;
                end

                ST_IP_CSUM_ACCUM: begin
                    next_sum = checksum_sum_reg + {16'b0, checksum_current_word};
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
                    ip_checksum_reg <= ~folded_checksum[15:0];
                    if (udp_checksum_enable_reg) begin
                        state_reg <= ST_UDP_CSUM_PREP;
                    end else begin
                        udp_checksum_reg <= 16'h0000;
                        header_index_reg <= 6'd0;
                        state_reg <= ST_BUILD_HEADER;
                    end
                end

                ST_UDP_CSUM_PREP: begin
                    checksum_sum_reg <= 32'b0;
                    checksum_word_index_reg <= 16'd0;
                    checksum_word_total_reg <= 16'd10
                                             + ((payload_length_reg + 16'd1) >> 1);
                    state_reg <= ST_UDP_CSUM_ACCUM;
                end

                ST_UDP_CSUM_ACCUM: begin
                    checksum_sum_reg <= checksum_sum_reg + {16'b0, checksum_current_word};
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
                    raw_udp_checksum = ~folded_checksum[15:0];
                    udp_checksum_reg <= (raw_udp_checksum == 16'h0000)
                                      ? 16'hffff : raw_udp_checksum;
                    header_index_reg <= 6'd0;
                    state_reg <= ST_BUILD_HEADER;
                end

                ST_BUILD_HEADER: begin
                    frame_mem[header_index_reg] <= header_byte(header_index_reg);
                    if (header_index_reg == 6'd41) begin
                        output_index_reg <= '0;
                        state_reg <= ST_OUTPUT;
                    end else begin
                        header_index_reg <= header_index_reg + 6'd1;
                    end
                end

                ST_OUTPUT: begin
                    if (m_axis_tready_i) begin
                        if (output_remaining <= 8) begin
                            output_index_reg <= '0;
                            payload_capture_index_reg <= '0;
                            state_reg <= ST_IDLE;
                        end else begin
                            output_index_reg <= output_index_reg + 8;
                        end
                    end
                end

                ST_ERROR: begin
                    if (m_error_ready_i) begin
                        payload_capture_index_reg <= '0;
                        payload_drop_reg <= 1'b0;
                        payload_error_reg <= '0;
                        state_reg <= ST_IDLE;
                    end
                end

                default: state_reg <= ST_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    property p_output_hold;
        @(posedge clk_i) disable iff (rst_i)
        m_axis_tvalid_o && !m_axis_tready_i
        |=> m_axis_tvalid_o
            && $stable(m_axis_tdata_o)
            && $stable(m_axis_tkeep_o)
            && $stable(m_axis_tlast_o);
    endproperty
    assert property (p_output_hold);
`endif

endmodule
