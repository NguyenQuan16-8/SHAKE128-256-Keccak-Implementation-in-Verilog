module padder_shake_byte (
    input               clk,
    input               rst_n,

    // upstream (message source)
    input      [7:0]    in_byte,
    input               in_valid,
    input               is_last,     // chỉ có ý nghĩa khi byte đó được accept
    output              in_ready,

    // config
    input               shake_sel,   // 0 = SHAKE128 (168B), 1 = SHAKE256 (136B)

    // downstream (Keccak-f)
    output              out_valid,   // block valid
    input               out_ready,   // block consumed

    // block output
    output reg [1343:0] out
);

    /* ================= rate ================= */
    wire [7:0] rate_bytes = shake_sel ? 8'd136 : 8'd168;
    wire [7:0] rate_last  = rate_bytes - 8'd1;

    /* ================= FSM ================= */
    localparam S_ABSORB     = 2'd0;
    localparam S_PAD_DOMAIN = 2'd1;  // 0x1F hoặc 0x9F nếu rơi đúng byte cuối
    localparam S_PAD_FILL   = 2'd2;  // 0x00 ... và byte cuối 0x80
    localparam S_DONE       = 2'd3;  // out_valid=1, chờ out_ready

    reg [1:0] state, next_state;

    /* ================= handshake ================= */
    assign out_valid = (state == S_DONE);
    wire f_ack  = out_valid & out_ready;

    reg  [7:0] cnt_byte;                 // số byte đã ghi trong block hiện tại
    assign in_ready = (state == S_ABSORB) && (cnt_byte < rate_bytes);
    wire accept = in_valid & in_ready;  // accept byte

    /* ================= write control ================= */
    reg        wr_en;
    reg [7:0]  wr_byte;

    /* ================= need_extra =================
       Set khi accept byte cuối của message và nó làm đầy block (cnt==rate_last).
       Clear ngay khi consume block đó (f_ack).
    */
    reg need_extra;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            need_extra <= 1'b0;
        end
        else begin
            // clear khi consume block "boundary-last"
            if (f_ack && need_extra)
                need_extra <= 1'b0;
            // set khi accept last byte và nó làm đầy block
            else if (accept && is_last && (cnt_byte == rate_last))
                need_extra <= 1'b1;
        end
    end

    /* ================= output shift register =================
       GIỮ nguyên packing như code gốc: {old[1335:0], new_byte}
    */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= {1344{1'b0}};
        else if (f_ack)
            out <= {1344{1'b0}};
        else if (wr_en)
            out <= {out[1335:0], wr_byte};
    end

    /* ================= byte counter ================= */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt_byte <= 8'd0;
        else if (f_ack)
            cnt_byte <= 8'd0;
        else if (wr_en)
            cnt_byte <= cnt_byte + 8'd1;
    end

    /* ================= state register ================= */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_ABSORB;
        else
            state <= next_state;
    end

    /* ================= FSM + ASMD ================= */
    always @(*) begin
        next_state = state;
        wr_en      = 1'b0;
        wr_byte    = 8'h00;

        case (state)

            // ABSORB MESSAGE BYTES
            S_ABSORB: begin
                if (accept) begin
                    wr_en   = 1'b1;
                    wr_byte = in_byte;

                    // ưu tiên full-block trước
                    if (cnt_byte == rate_last)
                        next_state = S_DONE;
                    else if (is_last)
                        next_state = S_PAD_DOMAIN;
                end
            end

            // PAD DOMAIN: 0x1F (hoặc 0x9F nếu rơi đúng byte cuối)
            S_PAD_DOMAIN: begin
                wr_en = 1'b1;
                if (cnt_byte == rate_last) begin
                    wr_byte    = 8'h9F;   // 0x1F | 0x80
                    next_state = S_DONE;
                end
                else begin
                    wr_byte    = 8'h1F;
                    next_state = S_PAD_FILL;
                end
            end

            // PAD FILL: 0x00 ... và byte cuối 0x80
            S_PAD_FILL: begin
                wr_en = 1'b1;
                if (cnt_byte == rate_last) begin
                    wr_byte    = 8'h80;
                    next_state = S_DONE;
                end
                else begin
                    wr_byte    = 8'h00;
                    next_state = S_PAD_FILL;
                end
            end

            // DONE – chờ consume
            S_DONE: begin
                if (out_ready) begin
                    next_state = need_extra ? S_PAD_DOMAIN : S_ABSORB;
                end
            end

            default: begin
                next_state = S_ABSORB;
            end
        endcase
    end

endmodule
