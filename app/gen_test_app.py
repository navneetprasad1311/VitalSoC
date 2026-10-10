#!/usr/bin/env python3
"""
gen_test_app.py  --  Generate test_app.bin for VitalSoC UART-boot testbench
                     (hand-assembled RV32I, no toolchain required)

Tests emitted via UART (PASS/FAIL/INFO/DONE protocol):
  Test 1: GPIO LED write 0xA5A5 and readback
  Test 2: GPIO LED write 0x5A5A and readback
  Test 3: App RAM write/readback at APP_BASE+0xF00
  Test 4: FIR STATUS register == 0 after reset
  Test 5: Unmapped addr 0x4000_0010 returns 0xDEADBEEF

Memory map (VitalSoC Spec §2):
  APP_BASE  = 0x1000_0000   (app runs here after BL jump)
  UART_DATA = 0x2000_0000   (offset 0x00)
  UART_STAT = 0x2000_0004   (offset 0x04, bit0=TX_BUSY, bit1=RX_VALID)
  GPIO_LED  = 0x3000_0000   (offset 0x00)
  FIR_STAT  = 0x5000_0004   (STATUS: bit0=busy, bit1=done)
  UNMAP     = 0x4000_0010   (inside timer window but invalid offset → DEADBEEF)
"""

import struct, os, sys

# ---------------------------------------------------------------------------
# Memory addresses
# ---------------------------------------------------------------------------
APP_BASE  = 0x10000000
UART_DATA = 0x20000000
UART_STAT = 0x20000004
GPIO_LED  = 0x30000000
FIR_STAT  = 0x50000004
UNMAP     = 0x40000010

# ---------------------------------------------------------------------------
# Register file aliases (RISC-V ABI)
# ---------------------------------------------------------------------------
ZERO=0; RA=1; SP=2; GP=3
T0=5; T1=6; T2=7
S0=8; S1=9
A0=10; A1=11; A2=12
S2=18; S3=19; S4=20

# ---------------------------------------------------------------------------
# Instruction encoders (all return 32-bit unsigned int)
# ---------------------------------------------------------------------------
def _u(x): return x & 0xFFFFFFFF

def LUI(rd, imm20):
    return _u(((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37)

def ADDI(rd, rs1, imm12):
    return _u(((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13)

def ANDI(rd, rs1, imm12):
    return _u(((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13)

def LW(rd, rs1, imm12):
    return _u(((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03)

def LBU(rd, rs1, imm12):
    return _u(((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b100 << 12) | (rd << 7) | 0x03)

def SW(rs1, rs2, imm12):
    """SW rs2, imm12(rs1)"""
    imm = imm12 & 0xFFF
    return _u(((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | ((imm & 0x1F) << 7) | 0x23)

def JALR(rd, rs1, imm12):
    return _u(((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67)

def JAL(rd, offset_bytes):
    off = offset_bytes & 0x1FFFFF
    imm20    = (off >> 20) & 1
    imm10_1  = (off >> 1)  & 0x3FF
    imm11    = (off >> 11) & 1
    imm19_12 = (off >> 12) & 0xFF
    return _u((imm20 << 31) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21) | (rd << 7) | 0x6F)

def BEQ(rs1, rs2, offset_bytes):
    off = offset_bytes & 0x1FFF
    return _u(((off>>12)&1)<<31 | ((off>>5)&0x3F)<<25 | (rs2<<20) | (rs1<<15) |
              (0b000<<12) | (((off>>1)&0xF)<<8) | (((off>>11)&1)<<7) | 0x63)

def BNE(rs1, rs2, offset_bytes):
    off = offset_bytes & 0x1FFF
    return _u(((off>>12)&1)<<31 | ((off>>5)&0x3F)<<25 | (rs2<<20) | (rs1<<15) |
              (0b001<<12) | (((off>>1)&0xF)<<8) | (((off>>11)&1)<<7) | 0x63)

def NOP():
    return ADDI(ZERO, ZERO, 0)

# ---------------------------------------------------------------------------
# Assembler context
# ---------------------------------------------------------------------------
class Prog:
    """Two-pass assembler: emit instructions, place labels, patch on finalize."""
    def __init__(self, base):
        self.base   = base          # load address (APP_BASE)
        self.words  = []            # instruction / data words
        self.labels = {}            # label_name -> word index
        self.patches = []           # (word_idx, 'jal_z'|'jal_ra', label)

    # ---- helpers ----
    def _addr(self, idx=None):
        return self.base + (len(self.words) if idx is None else idx) * 4

    def label(self, name):
        self.labels[name] = len(self.words)

    def emit(self, word):
        self.words.append(_u(word))
        return len(self.words) - 1   # return word index

    def placeholder(self, label, rd):
        """Emit NOP placeholder; patch to JAL rd, label on finalize."""
        idx = self.emit(NOP())
        kind = 'jal_ra' if rd == RA else 'jal_z'
        self.patches.append((idx, kind, label))
        return idx

    def li32(self, rd, val):
        """LUI + ADDI to load any 32-bit immediate (sign-extension aware)."""
        val = _u(val)
        hi20 = (val + 0x800) >> 12
        lo12 = val - (hi20 << 12)
        if lo12 > 2047:  lo12 -= 4096
        if lo12 < -2048: lo12 += 4096
        if hi20 == 0:
            self.emit(ADDI(rd, ZERO, lo12))
        else:
            self.emit(LUI(rd, hi20))
            if lo12 != 0:
                self.emit(ADDI(rd, rd, lo12))

    def emit_str(self, s):
        """Append string bytes (NUL-padded to word boundary); return (idx, strlen)."""
        start_idx = len(self.words)
        raw = (s.encode('ascii') + b'\x00')
        while len(raw) % 4: raw += b'\x00'
        for i in range(0, len(raw), 4):
            self.words.append(struct.unpack_from('<I', raw, i)[0])
        return start_idx, len(s)    # idx, byte length (excl NUL)

    def finalize(self):
        for idx, kind, label in self.patches:
            tgt_idx = self.labels[label]
            offset  = (tgt_idx - idx) * 4
            rd = RA if kind == 'jal_ra' else ZERO
            self.words[idx] = JAL(rd, offset)

    def assemble(self):
        self.finalize()
        return b''.join(struct.pack('<I', w) for w in self.words)

# ===========================================================================
# Build program
# ===========================================================================
p = Prog(APP_BASE)

# -- 0: entry: jump over subroutines & string table to main
entry_jmp = p.placeholder('main', ZERO)

# ---------------------------------------------------------------------------
# uart_putc(A0=char)   S0 must hold UART_DATA base address
# Clobbers T0. Preserves RA.
# ---------------------------------------------------------------------------
p.label('uart_putc')
p.label('putc_spin')
p.emit(LW  (T0, S0, 4))              # T0 = UART_STATUS
p.emit(ANDI(T0, T0, 1))              # T0 &= TX_BUSY
p.emit(BNE (T0, ZERO, -8))           # loop while busy (back 2 insns = -8 bytes)
p.emit(SW  (S0, A0, 0))              # UART_DATA = char
p.emit(JALR(ZERO, RA, 0))            # ret

# ---------------------------------------------------------------------------
# uart_puts(A0=ptr, A1=len)   S0 must hold UART_DATA base address
# Sends A1 bytes from A0.  Clobbers T0, T1, A0, A1. Preserves RA.
# uart_putc is inlined here so RA is not clobbered.
# ---------------------------------------------------------------------------
p.label('uart_puts')
p.label('puts_check')
loop_check_idx = len(p.words)
p.emit(BEQ(A1, ZERO, 0))             # placeholder: exit if len==0
puts_exit_bk = len(p.words) - 1
p.emit(LBU(T0, A0,  0))              # T0 = *ptr
p.emit(ADDI(A0, A0,  1))             # ptr++
p.emit(ADDI(A1, A1, -1))             # len--
# inline TX wait + send
p.label('puts_spin')
p.emit(LW  (T1, S0, 4))              # T1 = UART_STATUS
p.emit(ANDI(T1, T1, 1))              # T1 &= TX_BUSY
p.emit(BNE (T1, ZERO, -8))           # loop while busy
p.emit(SW  (S0, T0,  0))             # UART_DATA = char
# loop back
loop_jal_idx = p.placeholder('puts_check', ZERO)
# exit (BEQ target)
p.label('puts_ret')
# patch the exit branch
exit_off = (p.labels['puts_ret'] - puts_exit_bk) * 4
p.words[puts_exit_bk] = BEQ(A1, ZERO, exit_off)
p.emit(JALR(ZERO, RA, 0))            # ret

# ---------------------------------------------------------------------------
# String table (embedded data)
# ---------------------------------------------------------------------------
p.label('str_table')
# Emit each string; record (word_index, byte_length)
si_banner,  ln_banner  = p.emit_str("INFO VitalSoC Test App v1.0\n")
si_t1,      ln_t1      = p.emit_str("INFO Test 1: GPIO LED write/readback\n")
si_t2,      ln_t2      = p.emit_str("INFO Test 2: App RAM write/readback\n")
si_t3,      ln_t3      = p.emit_str("INFO Test 3: FIR STATUS=0 after reset\n")
si_t4,      ln_t4      = p.emit_str("INFO Test 4: Unmapped=0xDEADBEEF\n")
si_pass,    ln_pass    = p.emit_str("PASS\n")
si_fail,    ln_fail    = p.emit_str("FAIL\n")
si_done,    ln_done    = p.emit_str("DONE\n")

# ---------------------------------------------------------------------------
# Helper macros (emit inline code at call site)
# ---------------------------------------------------------------------------
def send_str(str_idx, str_len):
    """Load string address into A0, length into A1, call uart_puts."""
    p.li32(A0, APP_BASE + str_idx * 4)
    p.li32(A1, str_len)
    p.placeholder('uart_puts', RA)

def test_beq(rs1, rs2, str_pass_idx, str_pass_len, str_fail_idx, str_fail_len):
    """
    if rs1==rs2: send PASS string; else: send FAIL string.
    Emit BEQ / branch-over pattern.  Both paths converge at after label.
    """
    beq_idx = p.emit(BEQ(rs1, rs2, 0))  # placeholder → to pass block
    # FAIL path
    send_str(str_fail_idx, str_fail_len)
    skip_idx = p.emit(JAL(ZERO, 0))     # placeholder → skip past PASS
    # PASS path (BEQ target)
    pass_start = len(p.words)
    p.words[beq_idx] = BEQ(rs1, rs2, (pass_start - beq_idx) * 4)
    send_str(str_pass_idx, str_pass_len)
    # Convergence point
    after_idx = len(p.words)
    p.words[skip_idx] = JAL(ZERO, (after_idx - skip_idx) * 4)

# ===========================================================================
# MAIN
# ===========================================================================
p.label('main')

# Initialise S0 = UART_DATA base (used by uart_putc / uart_puts)
p.li32(S0, UART_DATA)

# -- Banner --
send_str(si_banner, ln_banner)

# -------------------------------------------------------------------------
# TEST 1a: GPIO LED write 0xA5A5 → readback
# -------------------------------------------------------------------------
send_str(si_t1, ln_t1)
p.li32(S1, GPIO_LED)
p.li32(T0, 0xA5A5)
p.emit(SW(S1, T0, 0))
p.emit(LW(T1, S1, 0))
test_beq(T1, T0, si_pass, ln_pass, si_fail, ln_fail)

# -------------------------------------------------------------------------
# TEST 1b: GPIO LED write 0x5A5A → readback
# -------------------------------------------------------------------------
p.li32(T0, 0x5A5A)
p.emit(SW(S1, T0, 0))
p.emit(LW(T1, S1, 0))
test_beq(T1, T0, si_pass, ln_pass, si_fail, ln_fail)

# -------------------------------------------------------------------------
# TEST 2: App RAM write/readback at APP_BASE + 0x0F00
# -------------------------------------------------------------------------
send_str(si_t2, ln_t2)
p.li32(S2, APP_BASE + 0x0F00)
p.li32(T0, 0xCAFEBABE)
p.emit(SW(S2, T0, 0))
p.emit(LW(T1, S2, 0))
test_beq(T1, T0, si_pass, ln_pass, si_fail, ln_fail)

# -------------------------------------------------------------------------
# TEST 3: FIR STATUS == 0 after reset (busy=0, done=0)
# -------------------------------------------------------------------------
send_str(si_t3, ln_t3)
p.li32(S3, FIR_STAT)
p.emit(LW(T0, S3, 0))
test_beq(T0, ZERO, si_pass, ln_pass, si_fail, ln_fail)

# -------------------------------------------------------------------------
# TEST 4: Unmapped address 0x4000_0010 returns 0xDEADBEEF
# -------------------------------------------------------------------------
send_str(si_t4, ln_t4)
p.li32(S4, UNMAP)
p.emit(LW(T0, S4, 0))
p.li32(T1, 0xDEADBEEF)
test_beq(T0, T1, si_pass, ln_pass, si_fail, ln_fail)

# -------------------------------------------------------------------------
# DONE + halt
# -------------------------------------------------------------------------
send_str(si_done, ln_done)
p.label('halt')
p.emit(JAL(ZERO, 0))   # infinite self-loop (JAL to self, offset=0 → PC+0 = PC)

# ===========================================================================
# Assemble & write
# ===========================================================================
binary   = p.assemble()
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_app.bin')
with open(out_path, 'wb') as f:
    f.write(binary)

print(f"Generated : {out_path}")
print(f"Size      : {len(binary)} bytes  ({len(p.words)} words)")
print(f"\nLabel map (absolute addresses):")
for name, idx in sorted(p.labels.items(), key=lambda x: x[1]):
    print(f"  {APP_BASE + idx*4:#010x}  {name}")
