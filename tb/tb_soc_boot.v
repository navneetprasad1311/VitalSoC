// ============================================================================
// tb_soc_boot.v  --  VitalSoC Self-Checking Boot + UART Upload Testbench
//
// DESCRIPTION
//   Simulates the complete SoC lifecycle:
//     1. Power-on reset → bootloader runs from Boot ROM
//     2. Host (testbench) injects a .bin file over UART using the bootloader
//        protocol:  4-byte LE length header  +  N raw bytes  +  waits for 'K'
//     3. Bootloader jumps to App RAM; application executes
//     4. Testbench monitors UART TX from the CPU and collects ASCII output
//     5. Self-checking: any line starting with "PASS" increments pass_cnt;
//        any line starting with "FAIL" increments fail_cnt.
//        A "DONE" line (or timeout) terminates the simulation.
//
// USAGE
//   iverilog -g2005-sv -I Top -DAPP_BIN=\"path/to/app.bin\" \
//            -o sim_boot.vvp tb_soc_boot.v                  \
//            Top/top.v Top/gpio.v Top/timer.v               \
//            Top/fir_periph.v Top/fir_core.v               \
//            Top/i2c_wb_bridge.v Top/i2c_master_top.v       \
//            Top/i2c_master_byte_ctrl.v Top/i2c_master_bit_ctrl.v \
//            picorv32_bootloader/picorv32_bootloader/picorv32.v
//   vvp sim_boot.vvp
//
//   Or use the provided run_sim.py wrapper which handles the hex conversion.
//
// SELF-CHECKING PROTOCOL (used by the example test app)
//   The application writes lines over UART (8N1 115200).
//   Lines are terminated with '\n' (0x0A).
//   Reserved keywords the testbench parses:
//     PASS <description>  → test passed
//     FAIL <description>  → test failed
//     INFO <description>  → informational (ignored by checker)
//     DONE                → simulation complete; testbench calls $finish
//
// PARAMETERS (override at compile time with -D or plusargs)
//   +APP_BIN=path/to/app.bin   -- raw binary to upload (default: test_app.bin)
//   +UART_TIMEOUT=N            -- max cycles waiting for UART byte (default: 5_000_000)
//   +UPLOAD_TIMEOUT=N          -- max cycles for full upload (default: 100_000_000)
// ============================================================================

`timescale 1ns/1ps

module tb_soc_boot;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    // Use CLKS_PER_BIT=4 for simulation speed (real HW uses 868 @ 100 MHz).
    // The DUT's top module accepts CLKS_PER_BIT as a parameter and is
    // overridden below.  Testbench tasks use the same value so both sides
    // see identical bit timing.
    localparam integer CLKS_PER_BIT   = 4;      // 4 clk/bit  (sim fast mode)
    // Timeouts scaled to fast-baud world (4 clk/bit x 10 bits x bytes)
    localparam integer DFLT_UART_TMO  =    50_000;   // ~1250 bytes worth of bits
    localparam integer DFLT_UPLOAD_TMO= 5_000_000;   // generous upload window
    localparam integer DFLT_RUN_TMO   =50_000_000;   // post-upload app run budget

    // -----------------------------------------------------------------------
    // DUT Instantiation  (CLKS_PER_BIT overridden for fast simulation)
    // -----------------------------------------------------------------------
    reg  clk     = 0;
    reg  btn_rst = 1;
    wire [15:0] led;
    reg  [15:0] sw  = 16'h0000;
    reg  [4:0]  btn = 5'h00;
    reg         UART_rxd = 1;   // idle-high
    wire        UART_txd;
    wire        i2c_scl;
    wire        i2c_sda;

    pullup(i2c_scl);
    pullup(i2c_sda);

    always #5 clk = ~clk;       // 100 MHz

    top #(
        .CLKS_PER_BIT (CLKS_PER_BIT)   // fast-baud override for simulation
    ) dut (
        .clk      (clk),
        .btn_rst  (btn_rst),
        .led      (led),
        .sw       (sw),
        .btn      (btn[2:0]),
        .UART_rxd (UART_rxd),
        .UART_txd (UART_txd),
        .i2c_scl  (i2c_scl),
        .i2c_sda  (i2c_sda)
    );

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer info_cnt = 0;

    // -----------------------------------------------------------------------
    // UART TX → Host: receive one byte from DUT
    //   Waits for start bit, samples at mid-bit, returns the byte.
    //   Returns 1 in 'valid' if a byte arrived before timeout.
    // -----------------------------------------------------------------------
    task automatic uart_host_recv (
        output reg [7:0] data,
        output reg       valid,
        input  integer   timeout_clks
    );
        integer t;
        integer b;
        reg sampled;
        begin
            valid = 1'b0;
            data  = 8'hxx;
            // Wait for start bit (falling edge on UART_txd)
            t = 0;
            while (UART_txd == 1'b1 && t < timeout_clks) begin
                @(posedge clk);
                t = t + 1;
            end
            if (t >= timeout_clks) begin
                valid = 1'b0;
            end else begin
                // Skip to centre of start bit
                repeat (CLKS_PER_BIT / 2) @(posedge clk);
                // Sample 8 data bits (LSB first)
                for (b = 0; b < 8; b = b + 1) begin
                    repeat (CLKS_PER_BIT) @(posedge clk);
                    data[b] = UART_txd;
                end
                // Consume stop bit
                repeat (CLKS_PER_BIT) @(posedge clk);
                valid = 1'b1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // UART RX → DUT: send one byte to DUT
    //   Drives UART_rxd with 8N1 framing at CLKS_PER_BIT rate.
    // -----------------------------------------------------------------------
    task automatic uart_host_send (input [7:0] data);
        integer b;
        begin
            // Start bit
            UART_rxd = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            // Data bits (LSB first)
            for (b = 0; b < 8; b = b + 1) begin
                UART_rxd = data[b];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            // Stop bit
            UART_rxd = 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
            // Inter-byte gap: give CPU bootloader loop time to read rx_data and store to RAM
            repeat (CLKS_PER_BIT * 8 + 30) @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Upload: send 4-byte LE length + raw bytes from $fread file
    //   Returns 0 on success, 1 on file-open error, 2 on no-ack timeout.
    // -----------------------------------------------------------------------
    // In-memory image storage  (up to 64 KB = max App RAM)
    reg [7:0] app_image [0:65535];
    integer   app_size;

    task automatic upload_app (
        input  [1023:0] bin_path,
        output integer  status
    );
        integer fd;
        integer i;
        reg [7:0] ack;
        reg       ack_valid;
        integer   tmo;
        begin
            status = 0;

            // ---- open and read the binary ----
            // Use $fgetc (returns int; -1 = EOF) which iverilog supports portably.
            fd = $fopen(bin_path, "rb");
            if (fd == 0) begin
                $display("[ERROR] Cannot open bin file: %0s", bin_path);
                status = 1;
            end else begin
                app_size = 0;
                begin : fread_loop
                    integer ch;
                    forever begin
                        ch = $fgetc(fd);
                        if (ch == -1 || app_size >= 65536) disable fread_loop;
                        app_image[app_size] = ch[7:0];
                        app_size = app_size + 1;
                    end
                end
                $fclose(fd);
                $display("[UPLOAD] App binary: %0s  (%0d bytes)", bin_path, app_size);
            end

            if (status != 0) disable upload_app;

            // ---- send 4-byte LE length header ----
            $display("[UPLOAD] Sending length header: 0x%08X", app_size);
            uart_host_send(app_size[7:0]);
            uart_host_send(app_size[15:8]);
            uart_host_send(app_size[23:16]);
            uart_host_send(app_size[31:24]);

            // ---- send payload bytes ----
            $display("[UPLOAD] Sending %0d payload bytes...", app_size);
            for (i = 0; i < app_size; i = i + 1) begin
                uart_host_send(app_image[i]);
                // Progress log every 64 bytes
                if ((i & 6'h3F) == 6'h3F)
                    $display("[UPLOAD]   %0d / %0d bytes sent", i+1, app_size);
            end
            $display("[UPLOAD] Payload complete. Waiting for 'K' acknowledgement...");

            // ---- wait for 'K' ack ----
            tmo = DFLT_UART_TMO * 4;
            uart_host_recv(ack, ack_valid, tmo);
            if (ack_valid && ack == "K") begin
                $display("[UPLOAD] ACK 'K' received. Bootloader jumping to App RAM.");
                status = 0;
            end else if (ack_valid) begin
                $display("[UPLOAD] Unexpected ack byte: 0x%02X (expected 'K')", ack);
                status = 2;
            end else begin
                $display("[UPLOAD] Timeout waiting for 'K' ack.");
                status = 2;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // UART line receiver: collect bytes until '\n', store in line_buf
    // -----------------------------------------------------------------------
    reg [7:0]  line_buf [0:255];
    integer    line_len;

    task automatic recv_line (
        output reg line_ok,     // 1=got '\n'-terminated line, 0=timeout
        input integer per_byte_tmo
    );
        reg [7:0] ch;
        reg       valid;
        begin
            line_len = 0;
            line_ok  = 1'b0;
            begin : recv_loop
                forever begin
                    uart_host_recv(ch, valid, per_byte_tmo);
                    if (!valid) begin
                        line_ok = 1'b0;
                        disable recv_loop;
                    end else if (ch == 8'h0A || ch == 8'h0D) begin
                        // newline terminates the line
                        if (line_len > 0) begin
                            line_ok = 1'b1;
                            disable recv_loop;
                        end
                        // bare CR/LF at start: skip
                    end else begin
                        if (line_len < 255) begin
                            line_buf[line_len] = ch;
                            line_len = line_len + 1;
                        end
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // String comparison helpers
    // -----------------------------------------------------------------------
    // Return 1 if line_buf[0..3] == prefix
    function automatic starts_with_4 (
        input [7:0] b0, b1, b2, b3
    );
        begin
            starts_with_4 = (line_len >= 4) &&
                            (line_buf[0] == b0) &&
                            (line_buf[1] == b1) &&
                            (line_buf[2] == b2) &&
                            (line_buf[3] == b3);
        end
    endfunction

    // Display line_buf as ASCII string
    task automatic print_line (input [63:0] prefix);
        integer k;
        reg [8*256-1:0] s;
        begin
            // Build display string — Verilog has no dynamic string length,
            // so we display character by character via $write.
            $write("%0s", prefix);
            for (k = 0; k < line_len; k = k + 1)
                $write("%c", line_buf[k]);
            $write("\n");
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    integer upload_status;
    reg     line_ok;
    integer run_tmo;
    reg [1023:0] bin_path_str;

    initial begin
        $display("=============================================================");
        $display("   VitalSoC Boot+Upload Testbench  (tb_soc_boot.v)         ");
        $display("   Build:  %0t ns simulation time                           ", $time);
        $display("=============================================================");

        // Determine bin path: plusarg overrides default
        if (!$value$plusargs("APP_BIN=%s", bin_path_str)) begin
            bin_path_str = "app.bin";
        end
        $display("[INIT] Application binary : %0s", bin_path_str);

        // ---- Phase 0: Reset ----
        $display("[INIT] Asserting reset...");
        btn_rst  = 1;
        UART_rxd = 1;
        repeat (30) @(posedge clk);
        btn_rst = 0;
        repeat (100) @(posedge clk);
        $display("[INIT] Reset released. Bootloader running.");

        // ---- Phase 1: Upload ----
        $display("\n[PHASE 1] Uploading application over UART...");
        upload_app(bin_path_str, upload_status);

        if (upload_status != 0) begin
            $display("[FATAL] Upload failed (status=%0d). Aborting.", upload_status);
            $display("=============================================================");
            $display("  RESULT: UPLOAD FAILED");
            $display("=============================================================");
            $finish;
        end

        $display("[PHASE 1] Upload complete. Application running.\n");

        // ---- Phase 2: Monitor UART output from application ----
        $display("[PHASE 2] Monitoring application UART output...");
        $display("-------------------------------------------------------------");

        run_tmo = DFLT_RUN_TMO;

        begin : monitor_loop
            forever begin
                recv_line(line_ok, DFLT_UART_TMO);

                if (!line_ok) begin
                    $display("\n[INFO] UART idle timeout — simulation ending.");
                    disable monitor_loop;
                end

                // ---- PASS ----
                if (starts_with_4("P","A","S","S")) begin
                    pass_cnt = pass_cnt + 1;
                    print_line("[PASS] ");
                end
                // ---- FAIL ----
                else if (starts_with_4("F","A","I","L")) begin
                    fail_cnt = fail_cnt + 1;
                    print_line("[FAIL] ");
                end
                // ---- DONE ----
                else if (line_len >= 4 &&
                         line_buf[0]=="D" && line_buf[1]=="O" &&
                         line_buf[2]=="N" && line_buf[3]=="E") begin
                    print_line("[DONE] ");
                    disable monitor_loop;
                end
                // ---- INFO / other ----
                else begin
                    info_cnt = info_cnt + 1;
                    print_line("[INFO] ");
                end
            end
        end

        // ---- Phase 3: Final report ----
        $display("-------------------------------------------------------------");
        $display("\n=============================================================");
        $display("  SIMULATION COMPLETE");
        $display("  PASS : %0d", pass_cnt);
        $display("  FAIL : %0d", fail_cnt);
        $display("  INFO : %0d", info_cnt);
        if (fail_cnt == 0 && pass_cnt > 0)
            $display("  OVERALL : ** ALL TESTS PASSED **");
        else if (fail_cnt > 0)
            $display("  OVERALL : ** %0d TEST(S) FAILED **", fail_cnt);
        else
            $display("  OVERALL : No PASS/FAIL lines received.");
        $display("=============================================================");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Absolute simulation timeout (catches infinite loops / hangs)
    // -----------------------------------------------------------------------
    initial begin
        #(1s);   // 1 real-second wall-time equivalent (1e9 ns)
        $display("[TIMEOUT] Hard simulation limit reached. Force-finishing.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // LED monitor: print LED changes to help debug
    // -----------------------------------------------------------------------
    reg [15:0] led_prev = 16'hxxxx;
    always @(led) begin
        if (led !== led_prev) begin
            $display("[LED] 0x%04X  at %0t ns", led, $time);
            led_prev = led;
        end
    end

endmodule
