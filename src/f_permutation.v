module f_permute (
    input               clk,
    input               rst_n,

    /* input handshake */
    input               in_valid,
    output              in_ready,
    input      [1599:0] state_in,

    /* output handshake */
    output reg          out_valid,
    input               out_ready,
    output reg [1599:0] state_out
);

    reg  [22:0]   i;        // one-hot round counter
    reg           calc;

    wire [1599:0] round_in, round_out;
    wire [63:0]   rc;

    wire can_accept;
    wire accept;
    wire update;

    assign can_accept = ~calc & (~out_valid | out_ready);  
    assign in_ready   = can_accept;
    assign accept     = in_valid & in_ready;

    assign update     = accept | calc;

    /* round counter */
    always @(posedge clk or negedge rst_n)
      if (!rst_n)
        i <= 23'b0;
      else if (accept)
        i <= 23'b1;                 // start round 1 (round 0 được encode bằng 'accept')
      else if (calc)
        i <= {i[21:0], 1'b0};
      else
        i <= 23'b0;

    /* calc flag  */
    always @(posedge clk or negedge rst_n)
      if (!rst_n)
        calc <= 1'b0;
      else
        calc <= (calc & ~i[22]) | accept;

    /* out_valid  */
    always @(posedge clk or negedge rst_n)
      if (!rst_n)
        out_valid <= 1'b0;
      else if (accept)
        out_valid <= 1'b0;          // bắt đầu job mới -> chưa có output valid
      else if (i[22])
        out_valid <= 1'b1;          // kết thúc round cuối -> output valid
      else if (out_valid & out_ready)
        out_valid <= 1'b0;          // output đã consume

    /* datapath  */
    assign round_in = accept ? state_in : state_out;

    rconst rconst_ (
        // round_sel[0]=accept (round0), round_sel[1..23]=i[0..22] (round1..23)
        .i({i, accept}),
        .rc(rc)
    );

    round round_ (
        .in(round_in),
        .round_const(rc),
        .out(round_out)
    );

    /* state register */
    always @(posedge clk or negedge rst_n)
      if (!rst_n)
        state_out <= 1600'b0;
      else if (update)
        state_out <= round_out;

endmodule
