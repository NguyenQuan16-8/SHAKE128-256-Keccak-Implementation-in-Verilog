`timescale 1ns/1ps

module tb_shake_top_upgrade;

  // ---------------- clock/reset ----------------
  logic clk = 0;
  always #5 clk = ~clk; // 100MHz

  logic rst_n;

  // ---------------- DUT I/O ----------------
  logic         start;
  logic         shake_sel;      // 0=SHAKE128, 1=SHAKE256
  logic [31:0]  out_len_bytes;

  logic [7:0]   in_byte;
  logic         in_valid;
  logic         is_last;
  wire          in_ready;

  wire          out_valid;
  logic         out_ready;
  wire [1343:0] out_block;
  wire [7:0]    out_nbytes;
  wire          out_last;

  // ---------------- instantiate DUT ----------------
  shake_top dut (
    .clk(clk),
    .rst_n(rst_n),

    .start(start),
    .shake_sel(shake_sel),
    .out_len_bytes(out_len_bytes),

    .in_byte(in_byte),
    .in_valid(in_valid),
    .is_last(is_last),
    .in_ready(in_ready),

    .out_valid(out_valid),
    .out_ready(out_ready),
    .out_block(out_block),
    .out_nbytes(out_nbytes),
    .out_last(out_last)
  );

  // ============================================================
  // Helpers
  // ============================================================

  function automatic int rate_bytes(input bit sel);
    rate_bytes = sel ? 136 : 168;
  endfunction

  // ============================================================
  // One-line INPUT/OUTPUT buffers
  // ============================================================
  string in_hex_line;
  string out_hex_line;

  task automatic hex_reset();
    in_hex_line  = "";
    out_hex_line = "";
  endtask

  task automatic in_hex_push(input byte b);
    in_hex_line = {in_hex_line, $sformatf("%02x", b)};
  endtask

  task automatic out_hex_push(input byte b);
    out_hex_line = {out_hex_line, $sformatf("%02x", b)};
  endtask

  // ============================================================
  // 1-cycle pulse sender (retry until accepted)
  // Logs IN only when accepted (in_valid && in_ready)
  // ============================================================
  task automatic send_byte_1cycle(input byte b, input bit last);
    bit accepted;
    begin
      accepted = 0;
      while (!accepted) begin
        in_byte  <= b;
        in_valid <= 1'b1;
        is_last  <= last;

        @(posedge clk);

        accepted = in_ready;

        // log only on fire
        if (accepted) in_hex_push(b);

        // drop for next cycle
        in_valid <= 1'b0;
        is_last  <= 1'b0;
        in_byte  <= 8'h00;
      end
    end
  endtask

  // Send LEN bytes: pattern = 0x00,0x01,...
  task automatic send_message_len(input int unsigned LEN);
    int i;
    begin
      for (i = 0; i < LEN; i++) begin
        send_byte_1cycle(byte'(i[7:0]), (i == LEN-1));
      end
    end
  endtask


  task automatic append_out_block_rate_msb(
      input logic [1343:0] blk,
      input int unsigned    nbytes,   // out_nbytes
      input int unsigned    rbytes    // rate_bytes(shake_sel)
  );
    int i;
    int base;
    int idx;
    byte ob;
    begin
      base = 168 - rbytes; // SHAKE128->0, SHAKE256->32

      for (i = 0; i < nbytes; i++) begin
        idx = 167 - i;
        if (idx < base) ob = 8'h00;
        else            ob = blk[idx*8 +: 8];
        out_hex_push(ob);
      end
    end
  endtask

  // Collect output until out_last, but PRINT ONLY ONCE
  task automatic collect_output_until_last_1line(input int unsigned rbytes);
    begin
      out_ready <= 1'b1;

      // wait for first handshake
      while (!(out_valid && out_ready)) @(posedge clk);

      forever begin
        if (out_valid && out_ready) begin
          append_out_block_rate_msb(out_block, out_nbytes, rbytes);
          if (out_last) break;
        end
        @(posedge clk);
      end
    end
  endtask

  // ============================================================
  // Run one case (prints IN/OUT each one line)
  // ============================================================
  task automatic run_case(
      input bit sel,                  // 0/1
      input int unsigned msg_len,
      input int unsigned out_len
  );
    int r;
    begin
      r = rate_bytes(sel);

      $display("\n============================================================");
      $display("[CASE] SHAKE_%0d  rate=%0d  msg_len=%0d  out_len=%0d",
               sel ? 256 : 128, r, msg_len, out_len);

      // reset DUT between cases
      rst_n      <= 1'b0;
      start      <= 1'b0;
      in_valid   <= 1'b0;
      is_last    <= 1'b0;
      in_byte    <= 8'h00;
      out_ready  <= 1'b1;

      hex_reset();

      repeat (5) @(posedge clk);
      rst_n <= 1'b1;
      repeat (2) @(posedge clk);

      // config
      shake_sel     <= sel;
      out_len_bytes <= out_len;

      // start pulse (1 cycle)
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;

      // send message
      if (msg_len != 0) begin
        send_message_len(msg_len);
      end

      // collect output
      collect_output_until_last_1line(r);

      // print 1-line IN/OUT
      $display("IN  SHAKE_%0d msg_len=%0d : %s",
               sel ? 256 : 128, msg_len, (msg_len==0) ? "<empty>" : in_hex_line);

      $display("OUT SHAKE_%0d out_len=%0d : %s",
               sel ? 256 : 128, out_len, out_hex_line);

      repeat (5) @(posedge clk);
    end
  endtask

  // ============================================================
  // Main
  // ============================================================
  initial begin
    int r128, r256;

    // init defaults
    rst_n         = 1'b0;
    start         = 1'b0;
    shake_sel     = 1'b1;
    out_len_bytes = 32;

    in_byte       = 8'h00;
    in_valid      = 1'b0;
    is_last       = 1'b0;

    out_ready     = 1'b1;

    r128 = rate_bytes(1'b0); // 168
    r256 = rate_bytes(1'b1); // 136

    // --- SHAKE128 cases ---
    run_case(1'b0, r128-20, 32);
    run_case(1'b0, r128-20, r128+20);
    run_case(1'b0, r128,    32);
    run_case(1'b0, r128,    r128+20);
    run_case(1'b0, r128-1,  32);
    run_case(1'b0, r128+10, 32);
    run_case(1'b0, r128+10, r128+20);

    // --- SHAKE256 cases ---
    run_case(1'b1, r256-20, 32);
    run_case(1'b1, r256-20, r256+20);
    run_case(1'b1, r256,    32);
    run_case(1'b1, r256,    r256+20);
    run_case(1'b1, r256-1,  32);
    run_case(1'b1, r256+10, 32);
    run_case(1'b1, r256+10, r256+20);

    $display("\nALL CASES DONE.");
    $finish;
  end

endmodule
