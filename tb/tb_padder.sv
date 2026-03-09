`timescale 1ns/1ps

module tb_padder_shake_byte;

  // clock/reset
  reg clk;
  reg rst_n;

  // upstream
  reg  [7:0] in_byte;
  reg        in_valid;
  reg        is_last;
  wire       in_ready;

  // config
  reg        shake_sel; // 0=SHAKE128(168), 1=SHAKE256(136)

  // downstream
  wire       out_valid;
  reg        out_ready;

  // output block
  wire [1343:0] out;

  // DUT
  padder_shake_byte dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_byte(in_byte),
    .in_valid(in_valid),
    .is_last(is_last),
    .in_ready(in_ready),
    .shake_sel(shake_sel),
    .out_valid(out_valid),
    .out_ready(out_ready),
    .out(out)
  );

  // clock gen: 100MHz
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // rate helper
  function automatic int rate_bytes();
    rate_bytes = (shake_sel) ? 136 : 168;
  endfunction

  // print a block as bytes in absorb order (first written .. last written)
  task automatic print_block_bytes(input [1343:0] blk, input int rbytes);
    int j;
    begin
      $write("  OUT bytes (MSB..LSB absorb order) = ");
      // byte at position (rbytes-1) is the first absorbed (for a full rate block)
      for (j = rbytes-1; j >= 0; j--) begin
        $write("%02x ", blk[8*j +: 8]);
      end
      $write("\n");
      $display("  OUT hex (full 1344b) = %h", blk);
    end
  endtask

  // send message of length LEN bytes: byte values = 0,1,2,... (mod 256)
  task automatic send_message(input int LEN, input string casename);
    int i;
    begin
      // idle
      in_valid = 1'b0;
      is_last  = 1'b0;
      in_byte  = 8'h00;

      // small gap
      repeat(2) @(posedge clk);

      $display("\n============================================================");
      $display("[CASE %s] SEND message len = %0d bytes, rate = %0d bytes", casename, LEN, rate_bytes());
      $write("[CASE %s] IN  bytes = ", casename);
      for (i = 0; i < LEN; i++) begin
        $write("%02x ", (i & 8'hFF));
      end
      $write("\n");

      // drive stream: keep in_valid high until each byte is accepted
      for (i = 0; i < LEN; i++) begin
        in_byte  = (i & 8'hFF);
        in_valid = 1'b1;
        is_last  = (i == (LEN-1));

        // wait until DUT ready, then acceptance happens on a posedge where in_ready=1
        do @(posedge clk); while (!in_ready);

        // after this posedge, that byte has been accepted by DUT
      end

      // deassert
      @(posedge clk);
      in_valid = 1'b0;
      is_last  = 1'b0;
      in_byte  = 8'h00;

      $display("[CASE %s] DONE sending input stream.", casename);
    end
  endtask

  // consume N blocks: wait out_valid, print, then pulse out_ready 1 cycle
  task automatic consume_blocks(input int N, input string casename);
    int b;
    int rbytes;
    begin
      rbytes = rate_bytes();
      out_ready = 1'b0;

      for (b = 1; b <= N; b++) begin
        // wait for out_valid
        do @(posedge clk); while (!out_valid);

        $display("[CASE %s] >>> GOT out_valid: Block #%0d at t=%0t", casename, b, $time);
        print_block_bytes(out, rbytes);

        // consume exactly 1 cycle
        out_ready = 1'b1;
        @(posedge clk);
        out_ready = 1'b0;

        $display("[CASE %s] <<< CONSUMED Block #%0d\n", casename, b);
      end
    end
  endtask


  function automatic int expected_blocks(input int LEN);
    int r, full, rem;
    begin
      r = rate_bytes();
      if (LEN == 0) expected_blocks = 1;
      else begin
        full = LEN / r;
        rem  = LEN % r;
        if (rem == 0) expected_blocks = full + 1; // boundary-last => extra block
        else          expected_blocks = full + 1; // last partial includes padding
      end
    end
  endfunction

  task automatic run_case(input string casename, input int LEN);
    int r, rem, exp;
    begin
      r   = rate_bytes();
      rem = (LEN % r);
      exp = expected_blocks(LEN);

      if ((LEN != 0) && (rem == 0)) begin
        $display("[CASE %s] NOTE: Message ends exactly at block boundary => EXTRA PADDING BLOCK expected!", casename);
      end

      fork
        send_message(LEN, casename);
        consume_blocks(exp, casename);
      join

      // small gap
      repeat(5) @(posedge clk);
    end
  endtask

  // main
  initial begin
    // init
    rst_n    = 1'b0;
    shake_sel= 1'b0;  // SHAKE128 default
    in_byte  = 8'h00;
    in_valid = 1'b0;
    is_last  = 1'b0;
    out_ready= 1'b0;

    // reset
    repeat(5) @(posedge clk);
    rst_n = 1'b1;
    repeat(3) @(posedge clk);

    // 4 requested cases (based on current rate)
    run_case("data_lt_rate",     rate_bytes() - 20);  // data < rate
    run_case("data_gt_rate",     rate_bytes() + 10);  // data > rate
    run_case("data_eq_rate",     rate_bytes()     );  // data = rate  (EXTRA padding block)
    run_case("data_eq_rate_m1",  rate_bytes() - 1 );  // data = rate-1

    $display("\nALL CASES DONE.");
    $finish;
  end

endmodule
