// ============================================================================
// top.v -- VitalSoC Top-Level System-on-Chip (PicoRV32 RV32IMC)
// Real Digital Boolean Board / Vivado FPGA Implementation
//
// Integrated Peripherals & Memory Map (VitalSoC Specification Rev 0.1):
//   0x0000_0000 - 0x0000_07FF : Boot ROM (2 KB, resident bootloader, read-only)
//   0x1000_0000 - 0x1000_FFFF : App RAM (64 KB Block RAM)
//   0x2000_0000 - 0x2000_0FFF : UART (115200 baud @ 100 MHz, DATA=0x00, STATUS=0x04)
//   0x3000_0000 - 0x3000_0FFF : GPIO (LED=0x00, SW=0x04, BTN=0x08)
//   0x4000_0000 - 0x4000_0FFF : System Timer (CTRL=0x00, PERIOD=0x04, FLAG=0x08, TICKS=0x0C -> irq[3])
//   0x5000_0000 - 0x5000_0FFF : FIR Accelerator (0x00..0x14 -> irq[4])
//   0x6000_0000 - 0x6000_0FFF : I2C Controller (0x00..0x10 -> irq[5])
//   0x7000_0000 - 0x7000_0FFF : MI Modem (Future stretch -> irq[6])
//
// Aliasing Rule (A-1 Resolved):
//   Strict non-aliasing: any access to unmapped offsets inside or outside the
//   4 KB windows completes with 0xDEADBEEF and ignores writes.
// ============================================================================

`timescale 1ns/1ps

module top (
    input  wire        clk,        // 100 MHz oscillator (Pin F14)
    input  wire        btn_rst,    // Push-button reset, active-high (Pin J2)
    output wire [15:0] led,        // 16 on-board LEDs
    input  wire [15:0] sw,         // 16 slide switches
    input  wire [4:0]  btn,        // Push buttons
    input  wire        UART_rxd,   // Host PC -> FPGA RX
    output wire        UART_txd,   // FPGA -> Host PC TX
    inout  wire        i2c_scl,    // I2C SCL (open-drain with external pullup)
    inout  wire        i2c_sda     // I2C SDA (open-drain with external pullup)
);

    // ------------------------------------------------------------------
    // Reset synchronizer (btn_rst active-high -> resetn active-low)
    // ------------------------------------------------------------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], btn_rst};
    end
    wire resetn = ~rst_sync[1];

    // ------------------------------------------------------------------
    // PicoRV32 Native Memory Interface & IRQ Collector
    // ------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    wire timer_irq;   // irq[3]
    wire fir_irq;     // irq[4]
    wire i2c_irq;     // irq[5]

    // IRQ Collector per Spec §2.2
    wire [31:0] cpu_irq = {
        25'b0,
        1'b0,         // irq[6]: MI modem (future/stretch)
        i2c_irq,      // irq[5]: I2C Controller
        fir_irq,      // irq[4]: FIR Accelerator
        timer_irq,    // irq[3]: System Timer
        3'b000        // irq[2:0]: Reserved
    };

    // CPU configured per Spec §2 / §9: RV32IMC, rdcycle, interrupts enabled
    picorv32 #(
        .ENABLE_COUNTERS (1),
        .ENABLE_MUL      (1),
        .ENABLE_DIV      (1),
        .BARREL_SHIFTER  (1),
        .COMPRESSED_ISA  (1),
        .ENABLE_IRQ      (1),
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET  (32'h0000_0000),
        .PROGADDR_IRQ    (32'h1000_0010)
    ) cpu (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .irq       (cpu_irq)
    );

    // ------------------------------------------------------------------
    // Address Decoder with Strict Non-Aliasing (A-1 & I-INT-1 Resolved)
    // ------------------------------------------------------------------
    // 4 KB Region base matching
    wire rom_win   = (mem_addr[31:11] == 21'h0);        // 0x0000_0000 (2 KB)
    wire app_win   = (mem_addr[31:16] == 16'h1000);     // 0x1000_0000 (64 KB)
    wire uart_win  = (mem_addr[31:12] == 20'h20000);    // 0x2000_0000 (4 KB)
    wire gpio_win  = (mem_addr[31:12] == 20'h30000);    // 0x3000_0000 (4 KB)
    wire timer_win = (mem_addr[31:12] == 20'h40000);    // 0x4000_0000 (4 KB)
    wire fir_win   = (mem_addr[31:12] == 20'h50000);    // 0x5000_0000 (4 KB)
    wire i2c_win   = (mem_addr[31:12] == 20'h60000);    // 0x6000_0000 (4 KB)

    // Valid register offset qualification inside 4 KB window (prevents aliasing)
    wire uart_valid_off  = (mem_addr[11:3] == 9'h0);                             // 0x00 (DATA), 0x04 (STATUS)
    wire gpio_valid_off  = (mem_addr[11:4] == 8'h0) && (mem_addr[3:2] <= 2'd2);  // 0x00, 0x04, 0x08
    wire timer_valid_off = (mem_addr[11:4] == 8'h0);                             // 0x00, 0x04, 0x08, 0x0C
    wire fir_valid_off   = (mem_addr[11:5] == 7'h0) && (mem_addr[4:2] <= 3'd5);  // 0x00..0x14
    wire i2c_valid_off   = (mem_addr[11:5] == 7'h0) && (mem_addr[4:2] <= 3'd4);  // 0x00..0x10

    wire rom_sel_raw   = rom_win;
    wire app_sel_raw   = app_win;
    wire uart_sel_raw  = uart_win  && uart_valid_off;
    wire gpio_sel_raw  = gpio_win  && gpio_valid_off;
    wire timer_sel_raw = timer_win && timer_valid_off;
    wire fir_sel_raw   = fir_win   && fir_valid_off;
    wire i2c_sel_raw   = i2c_win   && i2c_valid_off;

    // Peripheral selects gated by mem_valid (I-INT-1)
    wire rom_sel       = mem_valid && rom_sel_raw;
    wire app_sel       = mem_valid && app_sel_raw;
    wire uart_sel      = mem_valid && uart_sel_raw;
    wire gpio_sel      = mem_valid && gpio_sel_raw;
    wire timer_sel     = mem_valid && timer_sel_raw;
    wire fir_sel       = mem_valid && fir_sel_raw;
    wire i2c_sel       = mem_valid && i2c_sel_raw;

    // Unmapped: anything outside valid register ranges (both outside & inside 4 KB windows)
    wire unmapped_sel  = mem_valid && !(rom_sel_raw | app_sel_raw | uart_sel_raw |
                                        gpio_sel_raw | timer_sel_raw | fir_sel_raw | i2c_sel_raw);

    // ------------------------------------------------------------------
    // Boot ROM: 512 x 32-bit = 2 KB, READ-ONLY (Spec §2.1)
    // ------------------------------------------------------------------
    localparam ROM_WORDS = 512;
    (* rom_style = "block" *) reg [31:0] bootrom [0:ROM_WORDS-1];
    reg [31:0] rom_rdata;
    reg        rom_ready;

    initial begin
        $readmemh("bootloader.hex", bootrom);
    end

    always @(posedge clk) begin
        if (!resetn) begin
            rom_ready <= 1'b0;
            rom_rdata <= 32'd0;
        end else begin
            rom_ready <= rom_sel && !rom_ready;
            rom_rdata <= bootrom[mem_addr[10:2]];
        end
    end

    // ------------------------------------------------------------------
    // Application RAM: 16384 x 32-bit = 64 KB (Spec §2.1)
    // ------------------------------------------------------------------
    localparam APP_WORDS = 16384;
    (* ram_style = "block" *) reg [31:0] appram [0:APP_WORDS-1];
    reg [31:0] app_rdata;
    reg        app_ready;

    wire app_en = app_sel && !app_ready;

    always @(posedge clk) begin
        if (!resetn) begin
            app_ready <= 1'b0;
            app_rdata <= 32'd0;
        end else begin
            app_ready <= app_en;
            if (app_en) begin
                if (mem_wstrb[0]) appram[mem_addr[15:2]][7:0]   <= mem_wdata[7:0];
                if (mem_wstrb[1]) appram[mem_addr[15:2]][15:8]  <= mem_wdata[15:8];
                if (mem_wstrb[2]) appram[mem_addr[15:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) appram[mem_addr[15:2]][31:24] <= mem_wdata[31:24];
            end
            app_rdata <= appram[mem_addr[15:2]];
        end
    end

    // ------------------------------------------------------------------
    // UART peripheral: 115200 baud @ 100 MHz, 8N1 (Spec §4)
    // ------------------------------------------------------------------
    localparam integer CLKS_PER_BIT = 868;
    wire [9:0] reg_off = mem_addr[11:2];
    wire uart_data_sel = uart_sel && (reg_off == 10'd0);
    reg        uart_ready;
    wire uart_access   = uart_sel && !uart_ready;

    reg        tx_busy = 1'b0;
    reg [15:0] tx_clkcnt;
    reg [3:0]  tx_bitidx;
    reg [9:0]  tx_shiftreg;
    reg        uart_txd_reg = 1'b1;
    assign UART_txd = uart_txd_reg;

    wire tx_start = uart_access && uart_data_sel && (|mem_wstrb) && !tx_busy;

    always @(posedge clk) begin
        if (!resetn) begin
            tx_busy      <= 1'b0;
            uart_txd_reg <= 1'b1;
        end else if (tx_start) begin
            tx_shiftreg  <= {1'b1, mem_wdata[7:0], 1'b0};
            tx_bitidx    <= 4'd0;
            tx_clkcnt    <= 16'd0;
            tx_busy      <= 1'b1;
            uart_txd_reg <= 1'b0;
        end else if (tx_busy) begin
            if (tx_clkcnt == CLKS_PER_BIT - 1) begin
                tx_clkcnt <= 16'd0;
                if (tx_bitidx == 4'd9) begin
                    tx_busy <= 1'b0;
                end else begin
                    tx_bitidx    <= tx_bitidx + 4'd1;
                    tx_shiftreg  <= {1'b1, tx_shiftreg[9:1]};
                    uart_txd_reg <= tx_shiftreg[1];
                end
            end else begin
                tx_clkcnt <= tx_clkcnt + 16'd1;
            end
        end
    end

    // ---- Receive ----
    reg [1:0] rxd_sync = 2'b11;
    always @(posedge clk) rxd_sync <= {rxd_sync[0], UART_rxd};
    wire rxd = rxd_sync[1];

    reg        rx_busy    = 1'b0;
    reg        rx_aligned = 1'b0;
    reg [15:0] rx_clkcnt;
    reg [3:0]  rx_bitidx;
    reg [7:0]  rx_shiftreg;
    reg        rx_valid = 1'b0;
    reg [7:0]  rx_data  = 8'h00;

    wire rx_read_ack = uart_access && uart_data_sel && (mem_wstrb == 4'b0000);

    always @(posedge clk) begin
        if (!resetn) begin
            rx_busy  <= 1'b0;
            rx_valid <= 1'b0;
            rx_data  <= 8'h00;
        end else begin
            if (rx_valid && rx_read_ack) rx_valid <= 1'b0;

            if (!rx_busy) begin
                if (!rxd) begin
                    rx_busy    <= 1'b1;
                    rx_aligned <= 1'b0;
                    rx_clkcnt  <= CLKS_PER_BIT / 2;
                    rx_bitidx  <= 4'd0;
                end
            end else begin
                if (rx_clkcnt == CLKS_PER_BIT - 1) begin
                    rx_clkcnt <= 16'd0;
                    if (!rx_aligned) begin
                        rx_aligned <= 1'b1;
                    end else if (rx_bitidx == 4'd8) begin
                        rx_busy  <= 1'b0;
                        rx_data  <= rx_shiftreg;
                        rx_valid <= 1'b1;
                    end else begin
                        rx_shiftreg <= {rxd, rx_shiftreg[7:1]};
                        rx_bitidx   <= rx_bitidx + 4'd1;
                    end
                end else begin
                    rx_clkcnt <= rx_clkcnt + 16'd1;
                end
            end
        end
    end

    reg [31:0] uart_rdata;
    always @(posedge clk) begin
        if (!resetn) begin
            uart_ready <= 1'b0;
            uart_rdata <= 32'd0;
        end else begin
            uart_ready <= uart_access;
            if (uart_access) begin
                if (reg_off == 10'd0)
                    uart_rdata <= {24'h0, rx_data};
                else if (reg_off == 10'd1)
                    uart_rdata <= {30'h0, rx_valid, tx_busy};
                else
                    uart_rdata <= 32'hDEAD_BEEF;
            end
        end
    end

    // ------------------------------------------------------------------
    // GPIO Peripheral (Base 0x3000_0000, Spec §5)
    // ------------------------------------------------------------------
    wire [31:0] gpio_rdata;
    wire        gpio_ready;

    gpio u_gpio (
        .clk    (clk),
        .resetn (resetn),
        .sel    (gpio_sel),       // Gated by mem_valid & valid offset
        .wstrb  (mem_wstrb),
        .addr   (mem_addr[4:2]),
        .wdata  (mem_wdata),
        .rdata  (gpio_rdata),
        .ready  (gpio_ready),
        .led    (led),
        .sw     (sw),
        .btn    (btn)
    );

    // ------------------------------------------------------------------
    // System Timer (Base 0x4000_0000, Spec §6)
    // ------------------------------------------------------------------
    wire [31:0] timer_rdata;
    wire        timer_ready;

    timer u_timer (
        .clk    (clk),
        .resetn (resetn),
        .sel    (timer_sel),      // Gated by mem_valid & valid offset
        .wstrb  (mem_wstrb),
        .addr   (mem_addr[3:2]),
        .wdata  (mem_wdata),
        .rdata  (timer_rdata),
        .ready  (timer_ready),
        .irq    (timer_irq)
    );

    // ------------------------------------------------------------------
    // FIR Accelerator (Base 0x5000_0000, Spec §7)
    // ------------------------------------------------------------------
    wire [31:0] fir_rdata;
    wire        fir_ready;

    fir_periph u_fir (
        .clk    (clk),
        .resetn (resetn),
        .sel    (fir_sel),        // Gated by mem_valid & valid offset
        .wstrb  (mem_wstrb),
        .addr   (mem_addr[4:0]),
        .wdata  (mem_wdata),
        .rdata  (fir_rdata),
        .ready  (fir_ready),
        .irq    (fir_irq)
    );

    // ------------------------------------------------------------------
    // I2C Controller & Open-Drain IO Pads (Base 0x6000_0000, Spec §8)
    // ------------------------------------------------------------------
    wire [31:0] i2c_rdata;
    wire        i2c_ready;
    wire        scl_drive_low;
    wire        sda_drive_low;

    // Open-drain tri-state pads for I2C
    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;
    wire scl_i = i2c_scl;
    wire sda_i = i2c_sda;

    i2c_wb_bridge u_i2c (
        .clk           (clk),
        .resetn        (resetn),
        .sel           (i2c_sel),        // Gated by mem_valid & valid offset
        .wstrb         (mem_wstrb),
        .addr          (mem_addr[4:2]),
        .wdata         (mem_wdata),
        .rdata         (i2c_rdata),
        .ready         (i2c_ready),
        .scl_i         (scl_i),
        .scl_drive_low (scl_drive_low),
        .sda_i         (sda_i),
        .sda_drive_low (sda_drive_low),
        .irq           (i2c_irq)
    );

    // ------------------------------------------------------------------
    // Unmapped Address Handler (Spec §1)
    // ------------------------------------------------------------------
    reg unmapped_ready;
    always @(posedge clk) begin
        if (!resetn) begin
            unmapped_ready <= 1'b0;
        end else begin
            unmapped_ready <= unmapped_sel && !unmapped_ready;
        end
    end

    // ------------------------------------------------------------------
    // Bus Interconnect: mem_ready & mem_rdata Multiplexers
    // ------------------------------------------------------------------
    assign mem_ready = rom_ready      |
                       app_ready      |
                       uart_ready     |
                       gpio_ready     |
                       timer_ready    |
                       fir_ready      |
                       i2c_ready      |
                       unmapped_ready;

    assign mem_rdata = rom_sel_raw    ? rom_rdata   :
                       app_sel_raw    ? app_rdata   :
                       uart_sel_raw   ? uart_rdata  :
                       gpio_sel_raw   ? gpio_rdata  :
                       timer_sel_raw  ? timer_rdata :
                       fir_sel_raw    ? fir_rdata   :
                       i2c_sel_raw    ? i2c_rdata   :
                       32'hDEAD_BEEF;

endmodule
