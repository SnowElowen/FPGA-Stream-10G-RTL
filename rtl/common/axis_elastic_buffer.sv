`timescale 1ns / 1ps

// One-entry AXI-stream-style elastic register.
// The output transaction is held stable while m_axis_tvalid && !m_axis_tready.
module axis_elastic_buffer #(
    parameter int DATA_WIDTH = 64,
    parameter int KEEP_WIDTH = DATA_WIDTH / 8,
    parameter int USER_WIDTH = 1
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
    input  logic [KEEP_WIDTH-1:0] s_axis_tkeep_i,
    input  logic                  s_axis_tvalid_i,
    output logic                  s_axis_tready_o,
    input  logic                  s_axis_tlast_i,
    input  logic [USER_WIDTH-1:0] s_axis_tuser_i,

    output logic [DATA_WIDTH-1:0] m_axis_tdata_o,
    output logic [KEEP_WIDTH-1:0] m_axis_tkeep_o,
    output logic                  m_axis_tvalid_o,
    input  logic                  m_axis_tready_i,
    output logic                  m_axis_tlast_o,
    output logic [USER_WIDTH-1:0] m_axis_tuser_o
);

    logic [DATA_WIDTH-1:0] data_reg;
    logic [KEEP_WIDTH-1:0] keep_reg;
    logic                  valid_reg;
    logic                  last_reg;
    logic [USER_WIDTH-1:0] user_reg;

    assign s_axis_tready_o = !valid_reg || m_axis_tready_i;

    assign m_axis_tdata_o  = data_reg;
    assign m_axis_tkeep_o  = keep_reg;
    assign m_axis_tvalid_o = valid_reg;
    assign m_axis_tlast_o  = last_reg;
    assign m_axis_tuser_o  = user_reg;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            data_reg  <= '0;
            keep_reg  <= '0;
            valid_reg <= 1'b0;
            last_reg  <= 1'b0;
            user_reg  <= '0;
        end else if (s_axis_tready_o) begin
            valid_reg <= s_axis_tvalid_i;
            if (s_axis_tvalid_i) begin
                data_reg <= s_axis_tdata_i;
                keep_reg <= s_axis_tkeep_i;
                last_reg <= s_axis_tlast_i;
                user_reg <= s_axis_tuser_i;
            end
        end
    end

`ifdef FORMAL
    property p_hold_while_stalled;
        @(posedge clk_i) disable iff (rst_i)
        m_axis_tvalid_o && !m_axis_tready_i
        |=> m_axis_tvalid_o
            && $stable(m_axis_tdata_o)
            && $stable(m_axis_tkeep_o)
            && $stable(m_axis_tlast_o)
            && $stable(m_axis_tuser_o);
    endproperty
    assert property (p_hold_while_stalled);
`endif

endmodule
