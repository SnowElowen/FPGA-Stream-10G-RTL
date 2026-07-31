`timescale 1ns / 1ps

// Vendor-neutral 10G-class UDP streaming core.
//
// Connect rx_axis_* to the receive side of a 64-bit Ethernet MAC and tx_axis_*
// to the transmit side. Preamble, SFD, FCS, PHY, PCS, PMA, transceiver reset,
// and clock generation remain the integrator's responsibility.
module fpga_stream10g_core #(
    parameter int MAX_FRAME_BYTES = 2048,
    parameter bit CHECK_UDP_CHECKSUM = 1'b1
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [63:0] rx_axis_tdata_i,
    input  logic [7:0]  rx_axis_tkeep_i,
    input  logic        rx_axis_tvalid_i,
    output logic        rx_axis_tready_o,
    input  logic        rx_axis_tlast_i,

    output logic        rx_udp_meta_valid_o,
    input  logic        rx_udp_meta_ready_i,
    output logic [47:0] rx_dst_mac_o,
    output logic [47:0] rx_src_mac_o,
    output logic [31:0] rx_src_ip_o,
    output logic [31:0] rx_dst_ip_o,
    output logic [15:0] rx_src_port_o,
    output logic [15:0] rx_dst_port_o,
    output logic [15:0] rx_payload_length_o,
    output logic [15:0] rx_ip_total_length_o,
    output logic [15:0] rx_frame_length_o,
    output logic        rx_udp_checksum_present_o,
    output logic        rx_udp_checksum_ok_o,

    output logic [63:0] rx_payload_tdata_o,
    output logic [7:0]  rx_payload_tkeep_o,
    output logic        rx_payload_tvalid_o,
    input  logic        rx_payload_tready_i,
    output logic        rx_payload_tlast_o,

    output logic        rx_error_valid_o,
    input  logic        rx_error_ready_i,
    output logic [7:0]  rx_error_code_o,

    input  logic        tx_desc_valid_i,
    output logic        tx_desc_ready_o,
    input  logic [47:0] tx_dst_mac_i,
    input  logic [47:0] tx_src_mac_i,
    input  logic [31:0] tx_src_ip_i,
    input  logic [31:0] tx_dst_ip_i,
    input  logic [15:0] tx_src_port_i,
    input  logic [15:0] tx_dst_port_i,
    input  logic [15:0] tx_payload_length_i,
    input  logic [15:0] tx_ip_identification_i,
    input  logic [7:0]  tx_ip_ttl_i,
    input  logic        tx_udp_checksum_enable_i,

    input  logic [63:0] tx_payload_tdata_i,
    input  logic [7:0]  tx_payload_tkeep_i,
    input  logic        tx_payload_tvalid_i,
    output logic        tx_payload_tready_o,
    input  logic        tx_payload_tlast_i,

    output logic [63:0] tx_axis_tdata_o,
    output logic [7:0]  tx_axis_tkeep_o,
    output logic        tx_axis_tvalid_o,
    input  logic        tx_axis_tready_i,
    output logic        tx_axis_tlast_o,

    output logic        tx_error_valid_o,
    input  logic        tx_error_ready_i,
    output logic [7:0]  tx_error_code_o
);

    ipv4_udp_rx #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .CHECK_UDP_CHECKSUM(CHECK_UDP_CHECKSUM)
    ) u_ipv4_udp_rx (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .s_axis_tdata_i(rx_axis_tdata_i),
        .s_axis_tkeep_i(rx_axis_tkeep_i),
        .s_axis_tvalid_i(rx_axis_tvalid_i),
        .s_axis_tready_o(rx_axis_tready_o),
        .s_axis_tlast_i(rx_axis_tlast_i),
        .m_meta_valid_o(rx_udp_meta_valid_o),
        .m_meta_ready_i(rx_udp_meta_ready_i),
        .m_dst_mac_o(rx_dst_mac_o),
        .m_src_mac_o(rx_src_mac_o),
        .m_src_ip_o(rx_src_ip_o),
        .m_dst_ip_o(rx_dst_ip_o),
        .m_src_port_o(rx_src_port_o),
        .m_dst_port_o(rx_dst_port_o),
        .m_payload_length_o(rx_payload_length_o),
        .m_ip_total_length_o(rx_ip_total_length_o),
        .m_frame_length_o(rx_frame_length_o),
        .m_udp_checksum_present_o(rx_udp_checksum_present_o),
        .m_udp_checksum_ok_o(rx_udp_checksum_ok_o),
        .m_payload_tdata_o(rx_payload_tdata_o),
        .m_payload_tkeep_o(rx_payload_tkeep_o),
        .m_payload_tvalid_o(rx_payload_tvalid_o),
        .m_payload_tready_i(rx_payload_tready_i),
        .m_payload_tlast_o(rx_payload_tlast_o),
        .m_error_valid_o(rx_error_valid_o),
        .m_error_ready_i(rx_error_ready_i),
        .m_error_code_o(rx_error_code_o)
    );

    ipv4_udp_tx #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
    ) u_ipv4_udp_tx (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .s_desc_valid_i(tx_desc_valid_i),
        .s_desc_ready_o(tx_desc_ready_o),
        .s_dst_mac_i(tx_dst_mac_i),
        .s_src_mac_i(tx_src_mac_i),
        .s_src_ip_i(tx_src_ip_i),
        .s_dst_ip_i(tx_dst_ip_i),
        .s_src_port_i(tx_src_port_i),
        .s_dst_port_i(tx_dst_port_i),
        .s_payload_length_i(tx_payload_length_i),
        .s_ip_identification_i(tx_ip_identification_i),
        .s_ip_ttl_i(tx_ip_ttl_i),
        .s_udp_checksum_enable_i(tx_udp_checksum_enable_i),
        .s_payload_tdata_i(tx_payload_tdata_i),
        .s_payload_tkeep_i(tx_payload_tkeep_i),
        .s_payload_tvalid_i(tx_payload_tvalid_i),
        .s_payload_tready_o(tx_payload_tready_o),
        .s_payload_tlast_i(tx_payload_tlast_i),
        .m_axis_tdata_o(tx_axis_tdata_o),
        .m_axis_tkeep_o(tx_axis_tkeep_o),
        .m_axis_tvalid_o(tx_axis_tvalid_o),
        .m_axis_tready_i(tx_axis_tready_i),
        .m_axis_tlast_o(tx_axis_tlast_o),
        .m_error_valid_o(tx_error_valid_o),
        .m_error_ready_i(tx_error_ready_i),
        .m_error_code_o(tx_error_code_o)
    );

endmodule
