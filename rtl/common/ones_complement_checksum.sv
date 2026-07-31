`timescale 1ns / 1ps

// Multi-cycle 16-bit one's-complement checksum engine.
// Words are supplied in network byte order. The returned value is the checksum
// to place in a protocol header, i.e. the one's complement of the folded sum.
module ones_complement_checksum (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        start_i,
    output logic        start_ready_o,

    input  logic [15:0] word_i,
    input  logic        word_valid_i,
    output logic        word_ready_o,
    input  logic        word_last_i,

    output logic [15:0] checksum_o,
    output logic        checksum_valid_o,
    input  logic        checksum_ready_i,
    output logic        busy_o
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_ACCUM,
        ST_FOLD0,
        ST_FOLD1,
        ST_RESULT
    } state_t;

    state_t      state_reg;
    logic [31:0] sum_reg;
    logic [16:0] fold_reg;
    logic [15:0] checksum_reg;

    assign start_ready_o    = (state_reg == ST_IDLE);
    assign word_ready_o     = (state_reg == ST_ACCUM);
    assign checksum_valid_o = (state_reg == ST_RESULT);
    assign checksum_o       = checksum_reg;
    assign busy_o           = (state_reg != ST_IDLE);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_reg    <= ST_IDLE;
            sum_reg      <= '0;
            fold_reg     <= '0;
            checksum_reg <= '0;
        end else begin
            case (state_reg)
                ST_IDLE: begin
                    if (start_i) begin
                        sum_reg   <= '0;
                        state_reg <= ST_ACCUM;
                    end
                end

                ST_ACCUM: begin
                    if (word_valid_i) begin
                        sum_reg <= sum_reg + {16'b0, word_i};
                        if (word_last_i) begin
                            state_reg <= ST_FOLD0;
                        end
                    end
                end

                ST_FOLD0: begin
                    fold_reg <= {1'b0, sum_reg[15:0]} + {1'b0, sum_reg[31:16]};
                    state_reg <= ST_FOLD1;
                end

                ST_FOLD1: begin
                    checksum_reg <= ~(
                        fold_reg[15:0] + {{15{1'b0}}, fold_reg[16]}
                    );
                    state_reg <= ST_RESULT;
                end

                ST_RESULT: begin
                    if (checksum_ready_i) begin
                        state_reg <= ST_IDLE;
                    end
                end

                default: state_reg <= ST_IDLE;
            endcase
        end
    end

endmodule
