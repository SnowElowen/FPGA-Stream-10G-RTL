`timescale 1ns / 1ps

// Store-and-forward Ethernet/IPv4 ARP parser.
module arp_rx #(
    parameter int MAX_FRAME_BYTES = 256
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [63:0] s_axis_tdata_i,
    input  logic [7:0]  s_axis_tkeep_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,

    output logic        m_arp_valid_o,
    input  logic        m_arp_ready_i,
    output logic [47:0] m_eth_dst_mac_o,
    output logic [47:0] m_eth_src_mac_o,
    output logic [15:0] m_opcode_o,
    output logic [47:0] m_sender_mac_o,
    output logic [31:0] m_sender_ip_o,
    output logic [47:0] m_target_mac_o,
    output logic [31:0] m_target_ip_o,

    output logic        m_error_valid_o,
    input  logic        m_error_ready_i,
    output logic [7:0]  m_error_code_o
);

    localparam int LEN_W = $clog2(MAX_FRAME_BYTES + 1);
    localparam logic [7:0] ERR_BAD_KEEP   = 8'h01;
    localparam logic [7:0] ERR_TOO_LONG   = 8'h02;
    localparam logic [7:0] ERR_TOO_SHORT  = 8'h03;
    localparam logic [7:0] ERR_NOT_ARP    = 8'h04;
    localparam logic [7:0] ERR_BAD_FORMAT = 8'h05;

    typedef enum logic [1:0] {
        ST_CAPTURE,
        ST_VALIDATE,
        ST_OUTPUT,
        ST_ERROR
    } state_t;

    state_t state_reg;
    logic [7:0] frame_mem [0:MAX_FRAME_BYTES-1];
    logic [LEN_W-1:0] length_reg;
    logic drop_reg;
    logic [7:0] drop_error_reg;
    logic [7:0] error_code_reg;

    logic [47:0] eth_dst_mac_reg;
    logic [47:0] eth_src_mac_reg;
    logic [15:0] opcode_reg;
    logic [47:0] sender_mac_reg;
    logic [31:0] sender_ip_reg;
    logic [47:0] target_mac_reg;
    logic [31:0] target_ip_reg;

    function automatic logic keep_is_contiguous(input logic [7:0] keep);
        logic seen_zero;
        int i;
        begin
            keep_is_contiguous = (keep != 8'h00);
            seen_zero = 1'b0;
            for (i = 0; i < 8; i++) begin
                if (!keep[i]) seen_zero = 1'b1;
                else if (seen_zero) keep_is_contiguous = 1'b0;
            end
        end
    endfunction

    function automatic logic [3:0] keep_count(input logic [7:0] keep);
        logic [3:0] count;
        int i;
        begin
            count = 4'd0;
            for (i = 0; i < 8; i++) count = count + keep[i];
            return count;
        end
    endfunction

    function automatic logic [15:0] be16(input int unsigned addr);
        be16 = {frame_mem[addr], frame_mem[addr+1]};
    endfunction

    logic [3:0] input_count;
    logic [LEN_W:0] next_length;
    logic keep_bad;
    logic too_long;

    always_comb begin
        input_count = keep_count(s_axis_tkeep_i);
        next_length = {1'b0, length_reg} + input_count;
        keep_bad = (!s_axis_tlast_i && s_axis_tkeep_i != 8'hff)
                || (s_axis_tlast_i && !keep_is_contiguous(s_axis_tkeep_i));
        too_long = (next_length > MAX_FRAME_BYTES);
    end

    assign s_axis_tready_o = (state_reg == ST_CAPTURE);
    assign m_arp_valid_o = (state_reg == ST_OUTPUT);
    assign m_error_valid_o = (state_reg == ST_ERROR);

    assign m_eth_dst_mac_o = eth_dst_mac_reg;
    assign m_eth_src_mac_o = eth_src_mac_reg;
    assign m_opcode_o      = opcode_reg;
    assign m_sender_mac_o  = sender_mac_reg;
    assign m_sender_ip_o   = sender_ip_reg;
    assign m_target_mac_o  = target_mac_reg;
    assign m_target_ip_o   = target_ip_reg;
    assign m_error_code_o  = error_code_reg;

    always_ff @(posedge clk_i) begin : arp_rx_fsm
        int lane;
        if (rst_i) begin
            state_reg <= ST_CAPTURE;
            length_reg <= '0;
            drop_reg <= 1'b0;
            drop_error_reg <= '0;
            error_code_reg <= '0;
            eth_dst_mac_reg <= '0;
            eth_src_mac_reg <= '0;
            opcode_reg <= '0;
            sender_mac_reg <= '0;
            sender_ip_reg <= '0;
            target_mac_reg <= '0;
            target_ip_reg <= '0;
        end else begin
            case (state_reg)
                ST_CAPTURE: begin
                    if (s_axis_tvalid_i) begin
                        if (!drop_reg && !keep_bad && !too_long) begin
                            for (lane = 0; lane < 8; lane++) begin
                                if (s_axis_tkeep_i[lane]) begin
                                    frame_mem[length_reg + lane]
                                        <= s_axis_tdata_i[lane*8 +: 8];
                                end
                            end
                            length_reg <= next_length[LEN_W-1:0];
                        end
                        if (keep_bad) begin
                            drop_reg <= 1'b1;
                            drop_error_reg <= ERR_BAD_KEEP;
                        end else if (too_long) begin
                            drop_reg <= 1'b1;
                            drop_error_reg <= ERR_TOO_LONG;
                        end
                        if (s_axis_tlast_i) begin
                            if (drop_reg || keep_bad || too_long) begin
                                if (keep_bad) error_code_reg <= ERR_BAD_KEEP;
                                else if (too_long) error_code_reg <= ERR_TOO_LONG;
                                else error_code_reg <= drop_error_reg;
                                state_reg <= ST_ERROR;
                            end else begin
                                state_reg <= ST_VALIDATE;
                            end
                        end
                    end
                end

                ST_VALIDATE: begin
                    if (length_reg < 42) begin
                        error_code_reg <= ERR_TOO_SHORT;
                        state_reg <= ST_ERROR;
                    end else if (be16(12) != 16'h0806) begin
                        error_code_reg <= ERR_NOT_ARP;
                        state_reg <= ST_ERROR;
                    end else if (be16(14) != 16'h0001
                            || be16(16) != 16'h0800
                            || frame_mem[18] != 8'd6
                            || frame_mem[19] != 8'd4
                            || (be16(20) != 16'h0001 && be16(20) != 16'h0002)) begin
                        error_code_reg <= ERR_BAD_FORMAT;
                        state_reg <= ST_ERROR;
                    end else begin
                        eth_dst_mac_reg <= {
                            frame_mem[0], frame_mem[1], frame_mem[2],
                            frame_mem[3], frame_mem[4], frame_mem[5]
                        };
                        eth_src_mac_reg <= {
                            frame_mem[6], frame_mem[7], frame_mem[8],
                            frame_mem[9], frame_mem[10], frame_mem[11]
                        };
                        opcode_reg <= be16(20);
                        sender_mac_reg <= {
                            frame_mem[22], frame_mem[23], frame_mem[24],
                            frame_mem[25], frame_mem[26], frame_mem[27]
                        };
                        sender_ip_reg <= {
                            frame_mem[28], frame_mem[29], frame_mem[30], frame_mem[31]
                        };
                        target_mac_reg <= {
                            frame_mem[32], frame_mem[33], frame_mem[34],
                            frame_mem[35], frame_mem[36], frame_mem[37]
                        };
                        target_ip_reg <= {
                            frame_mem[38], frame_mem[39], frame_mem[40], frame_mem[41]
                        };
                        state_reg <= ST_OUTPUT;
                    end
                end

                ST_OUTPUT: begin
                    if (m_arp_ready_i) begin
                        length_reg <= '0;
                        drop_reg <= 1'b0;
                        drop_error_reg <= '0;
                        state_reg <= ST_CAPTURE;
                    end
                end

                ST_ERROR: begin
                    if (m_error_ready_i) begin
                        length_reg <= '0;
                        drop_reg <= 1'b0;
                        drop_error_reg <= '0;
                        state_reg <= ST_CAPTURE;
                    end
                end

                default: state_reg <= ST_CAPTURE;
            endcase
        end
    end

endmodule
