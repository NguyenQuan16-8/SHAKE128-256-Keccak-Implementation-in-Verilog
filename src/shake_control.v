module shake_control_mid (
    input               clk,
    input               rst_n,              // active-low reset

    /* ===== job control ===== */
    input               start,           // 1-cycle pulse: start new job (clear state/counters)
    output              done,            // high when finished squeezing requested bytes
    output reg          busy,

    /* ===== config ===== */
    input               shake_sel,       // 0=SHAKE128(rate=168B), 1=SHAKE256(rate=136B)
    input      [31:0]   out_len_bytes,   // requested XOF bytes (can be 0)

    /* ===== status from padder input side (provided by TOP) ===== */
    input               msg_last_seen,   // sticky: last message byte has been accepted into padder
    input               pad_in_ready,    // padder.in_ready (padder back in absorb state)

    /* ===== from padder block interface ===== */
    input               pad_valid,       // padder.out_valid
    output reg          pad_ready,       // padder.out_ready
    input      [1343:0] pad_block,       // padder.out (1344-bit container)

    /* ===== to/from permute ===== */
    output reg          perm_in_valid,
    input               perm_in_ready,
    output reg [1599:0] perm_state_in,

    input               perm_out_valid,
    output reg          perm_out_ready,
    input      [1599:0] perm_state_out,

    output reg          sq_valid,
    input               sq_ready,
    output reg [1343:0] sq_block,
    output reg  [7:0]   sq_nbytes,
    output reg          sq_last,

    /* debug */
    output reg [1599:0] state_reg
);

    /* ===== rate ===== */
    wire [7:0] rate_bytes = shake_sel ? 8'd136 : 8'd168;

    /* ===== internal ===== */
    reg [31:0] bytes_left;

    wire sq_fire = sq_valid & sq_ready;
    wire perm_fire_in  = perm_in_valid  & perm_in_ready;
    wire perm_fire_out = perm_out_valid & perm_out_ready;

    /* ===== XOR absorb (MSB-side like your reference) ===== */
    reg [1599:0] state_xor_block;
    always @(*) begin
        state_xor_block = state_reg;

        if (!shake_sel) begin
            // SHAKE128: rate=1344b -> state[1599:256]
            state_xor_block[1599 -: 1344] =
                state_reg[1599 -: 1344] ^ pad_block[1343:0];
        end else begin
            // SHAKE256: rate=1088b -> state[1599:512]
            state_xor_block[1599 -: 1088] =
                state_reg[1599 -: 1088] ^ pad_block[1087:0];
        end
    end

    /* ===== build squeeze container block from state ===== */
    reg [1343:0] squeeze_block;
    always @(*) begin
        if (!shake_sel) begin
            squeeze_block = state_reg[1599 -: 1344];
        end else begin
            squeeze_block = { state_reg[1599 -: 1088], 256'b0 };
        end
    end

    /* ===== this_nbytes = min(rate_bytes, bytes_left) ===== */
    reg [7:0] this_nbytes;
    always @(*) begin
        if (bytes_left[31:8] != 24'd0)
            this_nbytes = rate_bytes;
        else if (bytes_left[7:0] >= rate_bytes)
            this_nbytes = rate_bytes;
        else
            this_nbytes = bytes_left[7:0];
    end

    /* ===== FSM ===== */
    localparam ST_ABS_WAIT   = 3'd0; // wait pad_valid
    localparam ST_ABS_LAUNCH = 3'd1; // ack pad + launch permute(state^block)
    localparam ST_ABS_WAITP  = 3'd2; // wait permute output (latch)
    localparam ST_SQ_OUT     = 3'd3; // present squeeze block
    localparam ST_SQ_LAUNCH  = 3'd4; // launch permute(state) between squeeze blocks
    localparam ST_SQ_WAITP   = 3'd5; // wait permute output (latch)
    localparam ST_DONE       = 3'd6; // finished, wait start

    reg [2:0] state, next_state;
    assign done = (state == ST_DONE);

    /* ===== combinational control ===== */
    always @(*) begin
        next_state = state;

        // defaults
        busy          = (state != ST_ABS_WAIT);

        pad_ready     = 1'b0;

        perm_in_valid = 1'b0;
        perm_state_in = state_reg;

        perm_out_ready= 1'b0;

        sq_valid      = 1'b0;
        sq_block      = squeeze_block;
        sq_nbytes     = 8'd0;
        sq_last       = 1'b0;

        case (state)
            /* -------- ABSORB: wait for a padded block -------- */
            ST_ABS_WAIT: begin
                busy = 1'b0;
                if (pad_valid)
                    next_state = ST_ABS_LAUNCH;
            end

            /* -------- ABSORB: atomically consume pad block + start permute -------- */
            ST_ABS_LAUNCH: begin
                // Only when permute can accept, we consume padder block
                if (pad_valid && perm_in_ready) begin
                    pad_ready     = 1'b1;
                    perm_in_valid = 1'b1;
                    perm_state_in = state_xor_block;
                    next_state          = ST_ABS_WAITP;
                end
            end

            /* -------- wait permute result after absorption block -------- */
            ST_ABS_WAITP: begin
                // always latch permute output as soon as it becomes valid
                perm_out_ready = 1'b1;

                if (perm_fire_out) begin
                    // If message ended AND padder has no more pending block -> enter squeeze
                    if (msg_last_seen && pad_in_ready && !pad_valid) begin
                        next_state = ST_SQ_OUT;
                    end else begin
                        // more blocks to absorb (message continues or padder still generating padding blocks)
                        if (pad_valid) next_state = ST_ABS_LAUNCH;
                        else           next_state = ST_ABS_WAIT;
                    end
                end
            end

            /* -------- SQUEEZE: output one block (up to rate_bytes) -------- */
            ST_SQ_OUT: begin
                if (bytes_left == 32'd0) begin
                    next_state = ST_DONE;
                end else begin
                    sq_valid  = 1'b1;
                    sq_block  = squeeze_block;
                    sq_nbytes = this_nbytes;
                    sq_last   = (bytes_left <= rate_bytes);

                    if (sq_fire) begin
                        if (bytes_left > rate_bytes)
                            next_state = ST_SQ_LAUNCH;  // need more output -> permute between blocks
                        else
                            next_state = ST_DONE;       // finished in this block
                    end
                end
            end

            /* -------- launch permute between squeeze blocks (no XOR) -------- */
            ST_SQ_LAUNCH: begin
                if (perm_in_ready) begin
                    perm_in_valid = 1'b1;
                    perm_state_in = state_reg;
                    next_state          = ST_SQ_WAITP;
                end
            end

            /* -------- wait permute result for next squeeze block -------- */
            ST_SQ_WAITP: begin
                perm_out_ready = 1'b1;
                if (perm_fire_out) begin
                    next_state = ST_SQ_OUT;
                end
            end

            /* -------- DONE: wait for next start -------- */
            ST_DONE: begin
                busy = 1'b1;
                if (start)
                    next_state = ST_ABS_WAIT;
            end

            default: next_state = ST_ABS_WAIT;
        endcase
    end

    /* ===== sequential updates ===== */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_ABS_WAIT;
            state_reg  <= 1600'b0;
            bytes_left <= 32'd0;
        end else if (start) begin
            state         <= ST_ABS_WAIT;
            state_reg  <= 1600'b0;
            bytes_left <= out_len_bytes;   // latch requested length at start
        end else begin
            state <= next_state;

            // latch permute output into state_reg whenever consumed
            if (perm_fire_out)
                state_reg <= perm_state_out;

            // decrement bytes_left when TOP accepts a squeeze block
            if (state == ST_SQ_OUT && sq_fire)
                bytes_left <= bytes_left - {24'd0, this_nbytes};
        end
    end

endmodule
