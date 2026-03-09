`define low_pos(w,b)      ((w)*64 + (b)*8)
`define low_pos2(w,b)     `low_pos(w,7-b)
`define high_pos(w,b)     (`low_pos(w,b) + 7)
`define high_pos2(w,b)    (`low_pos2(w,b) + 7)

module shake_top (
    input               clk,
    input               rst_n,

    /* job control */
    input               start,          // 1-cycle pulse: start new SHAKE job
    input               shake_sel,      // 0=SHAKE128, 1=SHAKE256
    input      [31:0]   out_len_bytes,  // requested XOF length (bytes)

    /* message input (byte stream) */
    input      [7:0]    in_byte,
    input               in_valid,
    input               is_last,
    output              in_ready,

    /* output (block stream, 1344-bit container) */
    output              out_valid,
    input               out_ready,
    output     [1343:0] out_block,      
    output     [7:0]    out_nbytes,     
    output              out_last        
);


    wire         pad_in_ready;
    wire         pad_out_valid;
    wire         pad_out_ready;
    wire [1343:0] pad_block_raw;

    padder_shake_byte u_padder (
        .clk(clk),
        .rst_n(rst_n),

        .in_byte(in_byte),
        .in_valid(in_valid),
        .is_last(is_last),
        .in_ready(pad_in_ready),

        .shake_sel(shake_sel),

        .out_valid(pad_out_valid),
        .out_ready(pad_out_ready),

        .out(pad_block_raw)
    );

    assign in_ready = pad_in_ready;


    reg msg_last_seen;
    wire byte_accept = in_valid & in_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            msg_last_seen <= 1'b0;
        else if (start)
            msg_last_seen <= 1'b0;
        else if (byte_accept && is_last)
            msg_last_seen <= 1'b1;
    end


    wire [1343:0] pad_block_reo;

    genvar w_in, b_in;
    generate
        for (w_in = 0; w_in < 21; w_in = w_in + 1) begin : REO_IN_W
            for (b_in = 0; b_in < 8; b_in = b_in + 1) begin : REO_IN_B
                assign pad_block_reo[`high_pos(w_in,b_in):`low_pos(w_in,b_in)] =
                       pad_block_raw[`high_pos2(w_in,b_in):`low_pos2(w_in,b_in)];
            end
        end
    endgenerate


    wire         perm_in_valid;
    wire         perm_in_ready;
    wire [1599:0] perm_state_in;

    wire         perm_out_valid;
    wire         perm_out_ready;
    wire [1599:0] perm_state_out;

    f_permute u_perm (
        .clk(clk),
        .rst_n(rst_n),

        .in_valid(perm_in_valid),
        .in_ready(perm_in_ready),
        .state_in(perm_state_in),

        .out_valid(perm_out_valid),
        .out_ready(perm_out_ready),
        .state_out(perm_state_out)
    );


    wire         sq_valid;
    wire         sq_ready;
    wire [1343:0] sq_block_raw;
    wire [7:0]   sq_nbytes;
    wire         sq_last;

    wire [1599:0] state_dbg;
    wire          busy_dbg;
    wire          done_dbg;

    shake_control_mid u_ctrl (
        .clk(clk),
        .rst_n(rst_n),

        .start(start),
        .done(done_dbg),
        .busy(busy_dbg),

        .shake_sel(shake_sel),
        .out_len_bytes(out_len_bytes),

        .msg_last_seen(msg_last_seen),
        .pad_in_ready(pad_in_ready),

        .pad_valid(pad_out_valid),
        .pad_ready(pad_out_ready),
        .pad_block(pad_block_reo),            // <==== reordered before XOR in control

        .perm_in_valid(perm_in_valid),
        .perm_in_ready(perm_in_ready),
        .perm_state_in(perm_state_in),

        .perm_out_valid(perm_out_valid),
        .perm_out_ready(perm_out_ready),
        .perm_state_out(perm_state_out),

        .sq_valid(sq_valid),
        .sq_ready(sq_ready),
        .sq_block(sq_block_raw),
        .sq_nbytes(sq_nbytes),
        .sq_last(sq_last),

        .state_reg(state_dbg)
    );


    wire [1343:0] sq_block_reo;

    genvar w_out, b_out;
    generate
        for (w_out = 0; w_out < 21; w_out = w_out + 1) begin : REO_OUT_W
            for (b_out = 0; b_out < 8; b_out = b_out + 1) begin : REO_OUT_B
                assign sq_block_reo[`high_pos(w_out,b_out):`low_pos(w_out,b_out)] =
                       sq_block_raw[`high_pos2(w_out,b_out):`low_pos2(w_out,b_out)];
            end
        end
    endgenerate


    assign out_valid  = sq_valid;
    assign sq_ready   = out_ready;

    assign out_block  = sq_block_reo;
    assign out_nbytes = sq_nbytes;
    assign out_last   = sq_last;

endmodule

`undef low_pos
`undef low_pos2
`undef high_pos
`undef high_pos2
