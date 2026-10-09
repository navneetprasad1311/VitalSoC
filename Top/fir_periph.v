// fir_periph.v : PicoRV32 native-memory-interface wrapper for fir_core
// Base 0x5000_0000. Register map (word offsets):
//  0x00 CTRL      W: [0] start (self-clearing)  [1] irq_en  [8+:CH_W] channel
//  0x04 STATUS    R: [0] busy  [1] done (sticky)   W: write 1 to bit 1 clears done
//  0x08 DATA_IN   W: signed 16-bit sample
//  0x0C DATA_OUT  R: last filtered sample (sign-extended)
//  0x10 COEF_ADDR W: {channel, tap}
//  0x14 COEF_DATA W: signed coefficient, the write triggers the store
module fir_periph #(
    parameter NCH = 4, parameter TAPS = 64, parameter COEF_FILE = ""
)(
    input  wire        clk, resetn,
    input  wire        sel,                 // mem_valid && address in range
    input  wire [3:0]  wstrb,
    input  wire [4:0]  addr,                // mem_addr[4:0]
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         ready,
    output wire        irq
);
    localparam CH_W  = (NCH > 1) ? $clog2(NCH) : 1;
    localparam TAP_W = $clog2(TAPS);

    reg                    irq_en, start_p, coef_we;
    reg [CH_W-1:0]         ch_sel;
    reg signed [15:0]      din_r;
    reg [CH_W+TAP_W-1:0]   caddr;
    reg signed [15:0]      cdata;
    reg                    done_s;
    wire                   busy, done_p;
    wire signed [15:0]     dout;

    fir_core #(.NCH(NCH), .TAPS(TAPS), .COEF_FILE(COEF_FILE)) u_fir (
        .clk(clk), .resetn(resetn),
        .coef_we(coef_we), .coef_waddr(caddr), .coef_wdata(cdata),
        .start(start_p), .ch(ch_sel), .din(din_r),
        .busy(busy), .done(done_p), .dout(dout));

    assign irq = done_s & irq_en;

    wire wr = sel & (|wstrb);

    always @(posedge clk) begin
        ready   <= 1'b0;
        start_p <= 1'b0;
        coef_we <= 1'b0;
        if (done_p) done_s <= 1'b1;
        if (!resetn) begin
            irq_en <= 0; ch_sel <= 0; done_s <= 0; din_r <= 0; caddr <= 0; cdata <= 0;
            rdata <= 0;
        end else if (sel && !ready) begin
            ready <= 1'b1;
            rdata <= 32'd0;
            case (addr[4:2])
                3'd0: begin
                    rdata <= {{(24-CH_W){1'b0}}, ch_sel, 6'b0, irq_en, 1'b0};
                    if (wr) begin
                        irq_en <= wdata[1];
                        ch_sel <= wdata[8 +: CH_W];
                        if (wdata[0] && !busy) begin start_p <= 1'b1; done_s <= 1'b0; end
                    end
                end
                3'd1: begin
                    rdata <= {30'd0, done_s, busy};
                    if (wr && wdata[1]) done_s <= 1'b0;
                end
                3'd2: begin
                    rdata <= 32'd0;
                    if (wr) din_r <= wdata[15:0];
                end
                3'd3: begin
                    rdata <= {{16{dout[15]}}, dout};
                end
                3'd4: begin
                    rdata <= 32'd0;
                    if (wr) caddr <= wdata[CH_W+TAP_W-1:0];
                end
                3'd5: begin
                    rdata <= 32'd0;
                    if (wr) begin cdata <= wdata[15:0]; coef_we <= 1'b1; end
                end
                default: begin
                    rdata <= 32'hDEAD_BEEF;
                end
            endcase
        end
    end
endmodule
