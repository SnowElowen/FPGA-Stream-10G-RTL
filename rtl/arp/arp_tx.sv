`timescale 1ns / 1ps

// Ethernet/IPv4 ARP frame generator. Emits a 42-byte frame without preamble/FCS.
module arp_tx (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        s_desc_valid_i,
    output logic        s_desc_ready_o,
    input  logic [47:0] s_eth_dst_mac_i,
    input  logic [47:0] s_eth_src_mac_i,
    input  logic [15:0] s_opcode_i,
    input  logic [47:0] s_sender_mac_i,
    input  logic [31:0] s_sender_ip_i,
    input  logic [47:0] s_target_mac_i,
    input  logic [31:0] s_target_ip_i,

    output logic [63:0] m_axis_tdata_o,
    output logic [7:0]  m_axis_tkeep_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_BUILD,
        ST_OUTPUT
    } state_t;

    state_t state_reg;
    logic [7:0] frame_mem [0:41];
    logic [5:0] build_index_reg;
    logic [5:0] output_index_reg;

    logic [47:0] eth_dst_mac_reg;
    logic [47:0] eth_src_mac_reg;
    logic [15:0] opcode_reg;
    logic [47:0] sender_mac_reg;
    logic [31:0] sender_ip_reg;
    logic [47:0] target_mac_reg;
    logic [31:0] target_ip_reg;

    function automatic logic [7:0] frame_byte(input logic [5:0] index);
        begin
            case (index)
                6'd0:  frame_byte = eth_dst_mac_reg[47:40];
                6'd1:  frame_byte = eth_dst_mac_reg[39:32];
                6'd2:  frame_byte = eth_dst_mac_reg[31:24];
                6'd3:  frame_byte = eth_dst_mac_reg[23:16];
                6'd4:  frame_byte = eth_dst_mac_reg[15:8];
                6'd5:  frame_byte = eth_dst_mac_reg[7:0];
                6'd6:  frame_byte = eth_src_mac_reg[47:40];
                6'd7:  frame_byte = eth_src_mac_reg[39:32];
                6'd8:  frame_byte = eth_src_mac_reg[31:24];
                6'd9:  frame_byte = eth_src_mac_reg[23:16];
                6'd10: frame_byte = eth_src_mac_reg[15:8];
                6'd11: frame_byte = eth_src_mac_reg[7:0];
                6'd12: frame_byte = 8'h08;
                6'd13: frame_byte = 8'h06;
                6'd14: frame_byte = 8'h00;
                6'd15: frame_byte = 8'h01;
                6'd16: frame_byte = 8'h08;
                6'd17: frame_byte = 8'h00;
                6'd18: frame_byte = 8'h06;
                6'd19: frame_byte = 8'h04;
                6'd20: frame_byte = opcode_reg[15:8];
                6'd21: frame_byte = opcode_reg[7:0];
                6'd22: frame_byte = sender_mac_reg[47:40];
                6'd23: frame_byte = sender_mac_reg[39:32];
                6'd24: frame_byte = sender_mac_reg[31:24];
                6'd25: frame_byte = sender_mac_reg[23:16];
                6'd26: frame_byte = sender_mac_reg[15:8];
                6'd27: frame_byte = sender_mac_reg[7:0];
                6'd28: frame_byte = sender_ip_reg[31:24];
                6'd29: frame_byte = sender_ip_reg[23:16];
                6'd30: frame_byte = sender_ip_reg[15:8];
                6'd31: frame_byte = sender_ip_reg[7:0];
                6'd32: frame_byte = target_mac_reg[47:40];
                6'd33: frame_byte = target_mac_reg[39:32];
                6'd34: frame_byte = target_mac_reg[31:24];
                6'd35: frame_byte = target_mac_reg[23:16];
                6'd36: frame_byte = target_mac_reg[15:8];
                6'd37: frame_byte = target_mac_reg[7:0];
                6'd38: frame_byte = target_ip_reg[31:24];
                6'd39: frame_byte = target_ip_reg[23:16];
                6'd40: frame_byte = target_ip_reg[15:8];
                6'd41: frame_byte = target_ip_reg[7:0];
                default: frame_byte = 8'h00;
            endcase
        end
    endfunction

    assign s_desc_ready_o = (state_reg == ST_IDLE);
    assign m_axis_tvalid_o = (state_reg == ST_OUTPUT);
    assign m_axis_tlast_o = (state_reg == ST_OUTPUT) && (output_index_reg >= 6'd40);

    always_comb begin : arp_output_pack
        int lane;
        int unsigned addr;
        m_axis_tdata_o = 64'b0;
        m_axis_tkeep_o = 8'b0;
        for (lane = 0; lane < 8; lane++) begin
            addr = output_index_reg + lane;
            if ((state_reg == ST_OUTPUT) && (addr < 42)) begin
                m_axis_tdata_o[lane*8 +: 8] = frame_mem[addr];
                m_axis_tkeep_o[lane] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_reg <= ST_IDLE;
            build_index_reg <= '0;
            output_index_reg <= '0;
            eth_dst_mac_reg <= '0;
            eth_src_mac_reg <= '0;
            opcode_reg <= '0;
            sender_mac_reg <= '0;
            sender_ip_reg <= '0;
            target_mac_reg <= '0;
            target_ip_reg <= '0;
        end else begin
            case (state_reg)
                ST_IDLE: begin
                    if (s_desc_valid_i) begin
                        eth_dst_mac_reg <= s_eth_dst_mac_i;
                        eth_src_mac_reg <= s_eth_src_mac_i;
                        opcode_reg <= s_opcode_i;
                        sender_mac_reg <= s_sender_mac_i;
                        sender_ip_reg <= s_sender_ip_i;
                        target_mac_reg <= s_target_mac_i;
                        target_ip_reg <= s_target_ip_i;
                        build_index_reg <= 6'd0;
                        state_reg <= ST_BUILD;
                    end
                end

                ST_BUILD: begin
                    frame_mem[build_index_reg] <= frame_byte(build_index_reg);
                    if (build_index_reg == 6'd41) begin
                        output_index_reg <= 6'd0;
                        state_reg <= ST_OUTPUT;
                    end else begin
                        build_index_reg <= build_index_reg + 6'd1;
                    end
                end

                ST_OUTPUT: begin
                    if (m_axis_tready_i) begin
                        if (output_index_reg >= 6'd40) begin
                            output_index_reg <= '0;
                            state_reg <= ST_IDLE;
                        end else begin
                            output_index_reg <= output_index_reg + 6'd8;
                        end
                    end
                end

                default: state_reg <= ST_IDLE;
            endcase
        end
    end

endmodule
