`timescale 1ns/1ps

module timer(
    input  wire        clk,
    input  wire        resetn,

    input  wire        sel,
    input  wire [3:0]  wstrb,
    input  wire [1:0]  addr,
    input  wire [31:0] wdata,

    output reg  [31:0] rdata,
    output reg         ready,
    output wire        irq
);

    reg        en;
    reg        irq_en;
    reg        pending;

    reg [31:0] period;
    reg [31:0] cnt;
    reg [31:0] ticks;

    wire xfer = sel && !ready;
    wire wr   = |wstrb;

    assign irq = pending & irq_en;

    always @(posedge clk) begin
        if (!resetn) begin

            ready   <= 1'b0;

            en      <= 1'b0;
            irq_en  <= 1'b0;
            pending <= 1'b0;

            period  <= 32'd99999;
            cnt     <= 32'd0;
            ticks   <= 32'd0;

        end else begin

            ready <= xfer;

            /*
             * ----------------------------------------
             * REGISTER WRITE
             * ----------------------------------------
             */
            if (xfer && wr) begin

                case (addr)

                    // TIMER_CTRL
                    2'd0: begin
                        if (wstrb[0]) begin
                            en     <= wdata[0];
                            irq_en <= wdata[1];
                        end
                    end

                    // TIMER_PERIOD
                    2'd1: begin

                        if (wstrb[0])
                            period[7:0] <= wdata[7:0];

                        if (wstrb[1])
                            period[15:8] <= wdata[15:8];

                        if (wstrb[2])
                            period[23:16] <= wdata[23:16];

                        if (wstrb[3])
                            period[31:24] <= wdata[31:24];

                    end

                    // TIMER_FLAG
                    2'd2: begin
                        // Write 1 clears sticky flag
                        if (wstrb[0] && wdata[0])
                            pending <= 1'b0;
                    end

                    // TIMER_TICKS is READ ONLY
                    2'd3: begin
                        // Ignore writes
                    end

                endcase

            end


            /*
             * ----------------------------------------
             * TIMER COUNTING
             * ----------------------------------------
             */
            if (en) begin

                if (cnt >= period) begin

                    cnt   <= 32'd0;
                    ticks <= ticks + 32'd1;

                    /*
                     * A new timer tick sets the sticky flag.
                     * Per Spec §6.4: if hardware sets TICK in the same cycle as a clear,
                     * the hardware set wins. Since register write occurred earlier in this
                     * clock edge, setting pending <= 1'b1 unconditionally here ensures set wins.
                     */
                    pending <= 1'b1;

                end else begin

                    cnt <= cnt + 32'd1;

                end

            end else begin

                // Timer disabled -> counter held at zero
                cnt <= 32'd0;

            end

        end
    end


    /*
     * ----------------------------------------
     * READ DATA
     * ----------------------------------------
     */
    always @(posedge clk) begin

        case (addr)

            // TIMER_CTRL
            2'd0:
                rdata <= {30'h0, irq_en, en};

            // TIMER_PERIOD
            2'd1:
                rdata <= period;

            // TIMER_FLAG
            2'd2:
                rdata <= {31'h0, pending};

            // TIMER_TICKS
            2'd3:
                rdata <= ticks;

        endcase

    end

endmodule