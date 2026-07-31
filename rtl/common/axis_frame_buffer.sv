`timescale 1ns / 1ps

// Single-frame store-and-forward buffer.
// - Non-final beats must have all keep bits asserted.
// - Final keep must be non-zero and contiguous from lane 0.
// - Malformed or oversized frames are consumed and reported, never partially
//   exposed on the output.
module axis_frame_buffer #(
    parameter int DATA_WIDTH      = 64,
    parameter int KEEP_WIDTH      = DATA_WIDTH / 8,
    parameter int MAX_FRAME_BYTES = 2048
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
    input  logic [KEEP_WIDTH-1:0] s_axis_tkeep_i,
    input  logic                  s_axis_tvalid_i,
    output logic                  s_axis_tready_o,
    input  logic                  s_axis_tlast_i,

    output logic [DATA_WIDTH-1:0] m_axis_tdata_o,
    output logic [KEEP_WIDTH-1:0] m_axis_tkeep_o,
    output logic                  m_axis_tvalid_o,
    input  logic                  m_axis_tready_i,
    output logic                  m_axis_tlast_o,

    output logic [$clog2(MAX_FRAME_BYTES+1)-1:0] frame_length_o,
    output logic                  frame_error_valid_o,
    input  logic                  frame_error_ready_i
);

    localparam int MAX_BEATS = (MAX_FRAME_BYTES + KEEP_WIDTH - 1) / KEEP_WIDTH;
    localparam int BEAT_W    = (MAX_BEATS <= 1) ? 1 : $clog2(MAX_BEATS);
    localparam int LEN_W     = $clog2(MAX_FRAME_BYTES + 1);

    typedef enum logic [1:0] {
        ST_CAPTURE,
        ST_REPLAY,
        ST_ERROR
    } state_t;

    logic [DATA_WIDTH-1:0] mem_data [0:MAX_BEATS-1];
    logic [KEEP_WIDTH-1:0] mem_keep [0:MAX_BEATS-1];
    logic                  mem_last [0:MAX_BEATS-1];

    state_t state_reg;
    logic [BEAT_W-1:0] write_index_reg;
    logic [BEAT_W-1:0] read_index_reg;
    logic [LEN_W-1:0]  length_reg;
    logic               drop_reg;

    function automatic logic keep_is_contiguous(input logic [KEEP_WIDTH-1:0] keep);
        logic seen_zero;
        int i;
        begin
            keep_is_contiguous = (keep != '0);
            seen_zero = 1'b0;
            for (i = 0; i < KEEP_WIDTH; i++) begin
                if (!keep[i]) begin
                    seen_zero = 1'b1;
                end else if (seen_zero) begin
                    keep_is_contiguous = 1'b0;
                end
            end
        end
    endfunction

    function automatic int unsigned keep_count(input logic [KEEP_WIDTH-1:0] keep);
        int unsigned count;
        int i;
        begin
            count = 0;
            for (i = 0; i < KEEP_WIDTH; i++) begin
                count += keep[i];
            end
            return count;
        end
    endfunction

    logic beat_bad;
    logic [LEN_W:0] next_length;

    always_comb begin
        beat_bad = 1'b0;
        if (!s_axis_tlast_i && (s_axis_tkeep_i != {KEEP_WIDTH{1'b1}})) begin
            beat_bad = 1'b1;
        end
        if (s_axis_tlast_i && !keep_is_contiguous(s_axis_tkeep_i)) begin
            beat_bad = 1'b1;
        end
        next_length = {1'b0, length_reg} + keep_count(s_axis_tkeep_i);
        if (next_length > MAX_FRAME_BYTES) begin
            beat_bad = 1'b1;
        end
    end

    assign s_axis_tready_o = (state_reg == ST_CAPTURE);

    assign m_axis_tvalid_o = (state_reg == ST_REPLAY);
    assign m_axis_tdata_o  = mem_data[read_index_reg];
    assign m_axis_tkeep_o  = mem_keep[read_index_reg];
    assign m_axis_tlast_o  = mem_last[read_index_reg];

    assign frame_length_o      = length_reg;
    assign frame_error_valid_o = (state_reg == ST_ERROR);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_reg       <= ST_CAPTURE;
            write_index_reg <= '0;
            read_index_reg  <= '0;
            length_reg      <= '0;
            drop_reg        <= 1'b0;
        end else begin
            case (state_reg)
                ST_CAPTURE: begin
                    if (s_axis_tvalid_i) begin
                        if (!drop_reg && !beat_bad) begin
                            mem_data[write_index_reg] <= s_axis_tdata_i;
                            mem_keep[write_index_reg] <= s_axis_tkeep_i;
                            mem_last[write_index_reg] <= s_axis_tlast_i;
                            write_index_reg <= write_index_reg + 1'b1;
                            length_reg <= next_length[LEN_W-1:0];
                        end

                        if (beat_bad) begin
                            drop_reg <= 1'b1;
                        end

                        if (s_axis_tlast_i) begin
                            if (drop_reg || beat_bad) begin
                                state_reg <= ST_ERROR;
                            end else begin
                                read_index_reg <= '0;
                                state_reg <= ST_REPLAY;
                            end
                        end
                    end
                end

                ST_REPLAY: begin
                    if (m_axis_tready_i) begin
                        if (mem_last[read_index_reg]) begin
                            state_reg       <= ST_CAPTURE;
                            write_index_reg <= '0;
                            read_index_reg  <= '0;
                            length_reg      <= '0;
                            drop_reg        <= 1'b0;
                        end else begin
                            read_index_reg <= read_index_reg + 1'b1;
                        end
                    end
                end

                ST_ERROR: begin
                    if (frame_error_ready_i) begin
                        state_reg       <= ST_CAPTURE;
                        write_index_reg <= '0;
                        read_index_reg  <= '0;
                        length_reg      <= '0;
                        drop_reg        <= 1'b0;
                    end
                end

                default: state_reg <= ST_CAPTURE;
            endcase
        end
    end

endmodule
