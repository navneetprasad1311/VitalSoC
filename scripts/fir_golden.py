"""Golden model + coefficient/vector generator for fir_core (bit-exact).
Run:  python3 fir_golden.py   -> writes coeffs.mem, stim.mem, exp.mem
"""
import numpy as np

NCH, TAPS, FRAC = 4, 64, 15

def lp(fc, fs, n):
    return 2 * fc / fs * np.sinc(2 * fc / fs * n)

def design(kind, fs, f1, f2=None, taps=TAPS):
    n = np.arange(taps) - (taps - 1) / 2
    h = lp(f1, fs, n) if kind == "lp" else lp(f2, fs, n) - lp(f1, fs, n)
    h = h * np.hamming(taps)
    fc = 0.0 if kind == "lp" else (f1 + f2) / 2           # unity gain at reference freq
    g = abs(np.sum(h * np.exp(-2j * np.pi * fc / fs * np.arange(taps))))
    return h / g

def quant(h):
    return np.clip(np.round(h * (1 << FRAC)), -32768, 32767).astype(int)

BANKS = [                                # edit freely: this is the "configurable" part
    quant(design("bp", 250, 5, 25)),     # ch0 ECG QRS band-pass @250 Hz
    quant(design("lp", 100, 4)),         # ch1 PPG red low-pass @100 Hz
    quant(design("lp", 100, 4)),         # ch2 PPG IR low-pass @100 Hz
    quant(design("lp", 250, 40)),        # ch3 ECG low-pass 40 Hz @250 Hz
]

def sat16(v):
    return max(-32768, min(32767, v))

def fir_ref(x, coef):
    """acc = sum c[k]*x[n-k];  y = sat16(acc >> FRAC)  (arithmetic shift, same as RTL)."""
    hist = [0] * len(coef)
    y = []
    for s in x:
        hist = [int(s)] + hist[:-1]
        acc = sum(int(c) * int(h) for c, h in zip(coef, hist))
        y.append(sat16(acc >> FRAC))
    return y

def synth_ecg(n=1000, fs=250, bpm=75, seed=1):
    rng = np.random.default_rng(seed)
    t = np.arange(n) / fs
    sig = np.zeros(n)
    for b in np.arange(0.3, n / fs, 60 / bpm):
        sig += 6000 * np.exp(-((t - b) ** 2) / (2 * 0.012 ** 2))        # QRS-like spike
        sig += 1200 * np.exp(-((t - b - 0.25) ** 2) / (2 * 0.04 ** 2))  # T wave
    sig += 1500 * np.sin(2 * np.pi * 0.3 * t)                            # baseline wander
    sig += 300 * np.sin(2 * np.pi * 50 * t)                              # mains
    sig += rng.normal(0, 80, n)
    return np.clip(np.round(sig), -32768, 32767).astype(int)

def hex16(v):
    return f"{int(v) & 0xFFFF:04x}"

if __name__ == "__main__":
    with open("coeffs.mem", "w") as f:
        for bank in BANKS:
            for c in bank:
                f.write(hex16(c) + "\n")
    x = synth_ecg()
    y = fir_ref(x, BANKS[0])
    open("stim.mem", "w").write("\n".join(hex16(v) for v in x) + "\n")
    open("exp.mem", "w").write("\n".join(hex16(v) for v in y) + "\n")
    print(f"wrote coeffs.mem ({NCH*TAPS} lines), stim.mem/exp.mem ({len(x)} samples, ch0)")
    for i, b in enumerate(BANKS):
        print(f"ch{i}: sum(coef)={b.sum()/(1<<FRAC):.3f}  max|coef|={abs(b).max()}")
