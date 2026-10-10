// fir_core.v : configurable multi-channel sequential FIR (one MAC shared by all channels)
// NCH and TAPS must be powers of two. One output sample costs about TAPS+3 clock cycles.
// y[n] = sat( (sum_k coef[ch][k] * x[ch][n-k]) >>> COEF_FRAC )
module fir_core #(
    parameter NCH       = 4,
    parameter TAPS      = 64,
    parameter DATA_W    = 16,
    parameter COEF_W    = 16,
    parameter ACC_W     = 40,
    parameter COEF_FRAC = 15,
    parameter COEF_FILE = "",                         // optional $readmemh init, channel-major
    parameter CH_W      = (NCH > 1) ? $clog2(NCH) : 1, // derived, do not override
    parameter TAP_W     = $clog2(TAPS)                 // derived, do not override
)(
    input  wire                      clk,
    input  wire                      resetn,
    // coefficient write port, address = {channel, tap}
    input  wire                      coef_we,
    input  wire [CH_W+TAP_W-1:0]     coef_waddr,
    input  wire signed [COEF_W-1:0]  coef_wdata,
    // sample port
    input  wire                      start,
    input  wire [CH_W-1:0]           ch,
    input  wire signed [DATA_W-1:0]  din,
    output reg                       busy,
    output reg                       done,            // 1-cycle pulse
    output reg  signed [DATA_W-1:0]  dout
);
    reg signed [COEF_W-1:0] coef [0:NCH*TAPS-1];
    reg signed [DATA_W-1:0] dly  [0:NCH*TAPS-1];
    reg [TAP_W-1:0]         head [0:NCH-1];

    integer i;
    initial begin
        dout = 0;
        for (i = 0; i < NCH*TAPS; i = i + 1) begin coef[i] = 0; dly[i] = 0; end
        for (i = 0; i < NCH; i = i + 1) head[i] = 0;
        if (COEF_FILE != "") $readmemh(COEF_FILE, coef);
    end

    always @(posedge clk) if (coef_we) coef[coef_waddr] <= coef_wdata;

    reg [CH_W-1:0]   ch_r;
    reg [TAP_W-1:0]  head_r;
    reg [TAP_W:0]    k;                 // issue counter
    reg              issuing;

    // pipeline: issue -> read regs -> multiply -> accumulate
    reg signed [DATA_W-1:0]        xr;
    reg signed [COEF_W-1:0]        cr;
    reg signed [DATA_W+COEF_W-1:0] p;
    reg signed [ACC_W-1:0]         acc;
    reg v0, v1, v2;

    wire [TAP_W-1:0] tap_idx  = k[TAP_W-1:0];
    wire [TAP_W-1:0] samp_idx = head_r - tap_idx;

    localparam signed [ACC_W-1:0] MAXV = (1 <<< (DATA_W-1)) - 1;
    localparam signed [ACC_W-1:0] MINV = -(1 <<< (DATA_W-1));
    wire signed [ACC_W-1:0] shifted = acc >>> COEF_FRAC;

    always @(posedge clk) begin
        done <= 1'b0;
        if (!resetn) begin
            busy <= 1'b0; issuing <= 1'b0;
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0;
            acc <= 0; k <= 0;
            dout <= 0;
        end else begin
            xr <= dly [{ch_r, samp_idx}];
            cr <= coef[{ch_r, tap_idx}];
            v0 <= issuing;
            p  <= xr * cr;
            v1 <= v0;
            if (v1) acc <= acc + p;
            v2 <= v1;

            if (start && !busy) begin
                busy    <= 1'b1;
                ch_r    <= ch;
                head_r  <= head[ch];
                dly[{ch, head[ch]}] <= din;     // newest sample x[n]
                acc     <= 0;
                k       <= 0;
                issuing <= 1'b1;
            end else if (issuing) begin
                k <= k + 1'b1;
                if (k == TAPS-1) issuing <= 1'b0;
            end

            if (v2 && !v1) begin                // last product accumulated
                dout <= (shifted > MAXV) ? {1'b0, {(DATA_W-1){1'b1}}} :
                        (shifted < MINV) ? {1'b1, {(DATA_W-1){1'b0}}} : shifted[DATA_W-1:0];
                head[ch_r] <= head[ch_r] + 1'b1;
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
