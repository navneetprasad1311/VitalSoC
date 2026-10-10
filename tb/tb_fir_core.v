// ============================================================================
// tb_fir_core.v : Bit-exact verification against Python golden model
// ============================================================================

`timescale 1ns/1ps

module tb_fir_core;

    parameter NCH       = 4;
    parameter TAPS      = 64;
    parameter DATA_W    = 16;
    parameter COEF_W    = 16;
    parameter ACC_W     = 40;
    parameter COEF_FRAC = 15;

    reg clk = 0;
    always #5 clk = ~clk; // 100 MHz clock

    reg resetn = 0;
    reg coef_we = 0;
    reg [7:0] coef_waddr = 0;
    reg signed [15:0] coef_wdata = 0;

    reg start = 0;
    reg [1:0] ch = 0;
    reg signed [15:0] din = 0;
    wire busy;
    wire done;
    wire signed [15:0] dout;

    fir_core #(
        .NCH(NCH),
        .TAPS(TAPS),
        .DATA_W(DATA_W),
        .COEF_W(COEF_W),
        .ACC_W(ACC_W),
        .COEF_FRAC(COEF_FRAC)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .coef_we(coef_we),
        .coef_waddr(coef_waddr),
        .coef_wdata(coef_wdata),
        .start(start),
        .ch(ch),
        .din(din),
        .busy(busy),
        .done(done),
        .dout(dout)
    );

    reg [15:0] coeffs_mem [0:255];
    reg [15:0] stim_mem   [0:999];
    reg [15:0] exp_mem    [0:999];

    integer i, k, errors;

    initial begin
        $readmemh("coeffs.mem", coeffs_mem);
        $readmemh("stim.mem", stim_mem);
        $readmemh("exp.mem", exp_mem);

        errors = 0;
        resetn = 0;
        repeat (10) @(posedge clk);
        resetn = 1;
        repeat (5) @(posedge clk);

        // Check reset value of dout is 0 (F-2 check)
        if (dout !== 16'd0) begin
            $display("[FAIL] dout is not 0 after reset: %h", dout);
            errors = errors + 1;
        end else begin
            $display("[PASS] dout is 0 after reset");
        end

        // Load coefficients for all 4 channels
        $display("[INFO] Loading coefficients...");
        for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            coef_we <= 1'b1;
            coef_waddr <= i[7:0];
            coef_wdata <= coeffs_mem[i];
        end
        @(posedge clk);
        coef_we <= 1'b0;

        // Run ch0 through 1000 stimulus samples and check against exp.mem
        $display("[INFO] Running 1000 samples on Channel 0...");
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk);
            while (busy) @(posedge clk);
            ch <= 2'd0;
            din <= stim_mem[i];
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            @(posedge done);
            if (dout !== $signed(exp_mem[i])) begin
                $display("[FAIL] Sample %0d: expected %h (%0d), got %h (%0d)",
                         i, exp_mem[i], $signed(exp_mem[i]), dout, dout);
                errors = errors + 1;
                if (errors > 10) begin
                    $display("[FATAL] Too many errors, stopping simulation.");
                    $finish;
                end
            end
        end

        if (errors == 0) begin
            $display("=================================================");
            $display("  ALL 1000 FIR SAMPLES MATCHED GOLDEN MODEL!     ");
            $display("=================================================");
        end else begin
            $display("[FAIL] Total errors: %0d", errors);
        end
        $finish;
    end

endmodule
