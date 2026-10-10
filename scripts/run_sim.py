#!/usr/bin/env python3
"""
run_sim.py  --  VitalSoC UART-Boot Simulation Launcher
=======================================================
Generates test_app.bin (if --gen-app is set or file missing),
then invokes iverilog + vvp to compile and run tb_soc_boot.v
with the specified (or default) application binary.

Usage:
    python run_sim.py                          # uses test_app.bin (auto-generated)
    python run_sim.py path/to/your_app.bin     # embed engineer's binary
    python run_sim.py --gen-app                # regenerate test_app.bin, then simulate

Options:
    --gen-app            Force-regenerate test_app.bin before simulating
    --no-sim             Only generate test_app.bin, do not run simulation
    --iverilog PATH      Path to iverilog executable (default: auto-detect)
    --vvp      PATH      Path to vvp executable      (default: auto-detect)
    --timeout  N         Hard simulation timeout in ns (default: 2000000000)

Directory layout assumed (same as MAKEATHON workspace):
    tb_soc_boot.v          Top testbench
    gen_test_app.py        Test-app generator
    Top/                   RTL sources (fixed, with all I-INT-1 / A-1 / I-4 fixes)
    picorv32_bootloader/   PicoRV32 CPU source
"""

import argparse, os, subprocess, sys, shutil

WORKSPACE = os.path.dirname(os.path.abspath(__file__))

# ---- Default paths ----
DEFAULT_IVERILOG = r"C:\iverilog\bin\iverilog.exe"
DEFAULT_VVP      = r"C:\iverilog\bin\vvp.exe"

RTL_SOURCES = [
    "Top/top.v",
    "Top/gpio.v",
    "Top/timer.v",
    "Top/fir_periph.v",
    "Top/fir_core.v",
    "Top/i2c_wb_bridge.v",
    "Top/i2c_master_top.v",
    "Top/i2c_master_byte_ctrl.v",
    "Top/i2c_master_bit_ctrl.v",
    "picorv32_bootloader/picorv32_bootloader/picorv32.v",
]

TESTBENCH = "tb_soc_boot.v"
OUTPUT_VVP = os.path.join(WORKSPACE, "sim_boot.vvp")

# ---------------------------------------------------------------------------
def find_tool(name, override, default):
    if override:
        return override
    if os.path.isfile(default):
        return default
    found = shutil.which(name)
    if found:
        return found
    return None

# ---------------------------------------------------------------------------
def generate_test_app():
    gen = os.path.join(WORKSPACE, "gen_test_app.py")
    print(f"[SIM] Generating test_app.bin via {gen} ...")
    result = subprocess.run([sys.executable, gen], cwd=WORKSPACE,
                            capture_output=False)
    if result.returncode != 0:
        print("[ERROR] gen_test_app.py failed.")
        sys.exit(1)

# ---------------------------------------------------------------------------
def compile_sim(iverilog, bin_path, timeout_ns):
    abs_bin = os.path.abspath(bin_path)
    # Escape backslashes for Verilog define string
    escaped = abs_bin.replace("\\", "\\\\")

    cmd = [
        iverilog,
        "-g2005-sv",
        "-I", "Top",
        f'-DTIMEOUT_NS={timeout_ns}',
        "-o", OUTPUT_VVP,
        TESTBENCH,
    ] + RTL_SOURCES

    print("[SIM] Compiling:")
    print("  " + " ".join(cmd))
    result = subprocess.run(cmd, cwd=WORKSPACE)
    if result.returncode != 0:
        print("[ERROR] Compilation failed.")
        sys.exit(1)
    print("[SIM] Compilation OK.")

# ---------------------------------------------------------------------------
def run_sim(vvp, bin_path):
    abs_bin = os.path.abspath(bin_path)
    cmd = [vvp, OUTPUT_VVP, f"+APP_BIN={abs_bin}"]
    print(f"\n[SIM] Running: {' '.join(cmd)}\n")
    result = subprocess.run(cmd, cwd=WORKSPACE)
    return result.returncode

# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="VitalSoC UART-Boot Simulation Launcher")
    parser.add_argument("bin_path",    nargs="?", default=None,
                        help="Path to application .bin (default: test_app.bin)")
    parser.add_argument("--gen-app",   action="store_true",
                        help="Force-regenerate test_app.bin")
    parser.add_argument("--no-sim",    action="store_true",
                        help="Only generate the .bin, do not simulate")
    parser.add_argument("--iverilog",  default=None)
    parser.add_argument("--vvp",       default=None)
    parser.add_argument("--timeout",   default=2_000_000_000, type=int,
                        help="Simulation timeout in ns (default 2e9 = 2 s simtime)")
    args = parser.parse_args()

    iverilog = find_tool("iverilog", args.iverilog, DEFAULT_IVERILOG)
    vvp      = find_tool("vvp",      args.vvp,      DEFAULT_VVP)

    if not iverilog or not os.path.isfile(iverilog):
        print(f"[ERROR] iverilog not found. Install Icarus Verilog or pass --iverilog <path>.")
        sys.exit(1)
    if not vvp or not os.path.isfile(vvp):
        print(f"[ERROR] vvp not found. Install Icarus Verilog or pass --vvp <path>.")
        sys.exit(1)

    # ---- Determine .bin file ----
    if args.bin_path:
        bin_path = args.bin_path
        if not os.path.isfile(bin_path):
            print(f"[ERROR] Binary not found: {bin_path}")
            sys.exit(1)
        print(f"[SIM] Using provided binary: {bin_path}")
    else:
        bin_path = os.path.join(WORKSPACE, "test_app.bin")
        if args.gen_app or not os.path.isfile(bin_path):
            generate_test_app()
        else:
            print(f"[SIM] Using existing: {bin_path}")

    if args.no_sim:
        print("[SIM] --no-sim: skipping simulation.")
        return

    # ---- Compile & run ----
    compile_sim(iverilog, bin_path, args.timeout)
    rc = run_sim(vvp, bin_path)
    sys.exit(rc)

if __name__ == "__main__":
    main()
