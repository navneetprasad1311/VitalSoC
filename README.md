# VitalSoC
VitalSoC is a small computer built inside an FPGA, designed around cardiac signals.

<img width="639" height="425" alt="image" src="https://github.com/user-attachments/assets/a191aa2b-fddc-4a80-bb83-6135182d4d32" />

# VitalSoC — RISC-V SoC for Biomedical Signal Processing

VitalSoC is a RISC-V-based System-on-Chip (SoC) designed for real-time biomedical signal processing. It integrates a PicoRV32 processor with a dedicated Finite Impulse Response (FIR) hardware accelerator to support efficient filtering of sampled physiological signals such as ECG and PPG.

The project explores hardware/software co-design by combining a lightweight processor for system control and higher-level algorithms with a dedicated DSP datapath for computationally repetitive signal-processing operations.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [System Architecture](#system-architecture)
- [FIR Accelerator](#fir-accelerator)
- [Fixed-Point Arithmetic](#fixed-point-arithmetic)
- [Memory-Mapped Interface](#memory-mapped-interface)
- [Repository Structure](#repository-structure)
- [Design Specifications](#design-specifications)
- [Verification and Evaluation](#verification-and-evaluation)
- [Applications](#applications)
- [Future Work](#future-work)
- [References](#references)

## Overview

Biomedical signals are often affected by noise, baseline drift, and interference. Digital filtering is an important preprocessing step before performing operations such as peak detection, heart-rate estimation, and physiological parameter analysis.

Executing repetitive filtering operations entirely in software can consume processor cycles that could otherwise be used for system control and higher-level algorithms.

VitalSoC addresses this design challenge through a hardware/software co-design approach:

- **PicoRV32 processor:** Executes firmware, controls peripherals, and performs system-level processing.
- **FIR accelerator:** Performs multiply-accumulate operations for digital filtering.
- **Memory-mapped interface:** Allows firmware to configure the accelerator and exchange data.
- **Interrupt support:** Provides a mechanism for notifying the processor when processing is complete, subject to the implemented control logic.

## Key Features

- PicoRV32-based RISC-V processor integration.
- Dedicated FIR accelerator for digital signal processing.
- Four independently addressed signal channels.
- 64-tap FIR filtering per channel.
- Signed 16-bit input samples and coefficients.
- Q1.15 fixed-point coefficient representation.
- 40-bit accumulation datapath.
- Output scaling and saturation logic.
- Circular-buffer-based sample history.
- Runtime-accessible coefficient memory.
- Memory-mapped control and data registers.
- Hardware/software partitioning for efficient resource utilization.

## System Architecture

VitalSoC separates system-level control from computationally intensive filtering operations.

```text
                  Biomedical Sensors
                          |
                          v
                    Signal Acquisition
                          |
                          v
                       ADC Data
                          |
                          v
                 +-------------------+
                 |     PicoRV32      |
                 |   RISC-V Core     |
                 +---------+---------+
                           |
                     System Bus
                           |
                 +---------v---------+
                 |   FIR Peripheral  |
                 |   fir_periph.v    |
                 +---------+---------+
                           |
                 +---------v---------+
                 |     FIR Core      |
                 |   fir_core.v      |
                 |                   |
                 |  Sample Buffer    |
                 |  Coefficient RAM  |
                 |  Multiplier       |
                 |  Accumulator      |
                 |  Saturation       |
                 +---------+---------+
                           |
                           v
                    Filtered Samples
                           |
                           v
                 Higher-Level Processing
```

### Processor responsibilities

The PicoRV32 processor is responsible for:

- Initializing and configuring the FIR peripheral.
- Supplying input samples.
- Selecting the signal channel.
- Managing processing completion.
- Executing higher-level biomedical algorithms.
- Handling communication and system control.

### Accelerator responsibilities

The FIR hardware performs:

- Sample-history management.
- Coefficient retrieval.
- Multiply-accumulate operations.
- Fixed-point scaling.
- Output saturation.
- Processing-status and completion signalling.

## FIR Accelerator

The FIR accelerator implements a 64-tap finite impulse response filter. For each output sample, it calculates the weighted sum of the current input and 63 previous samples.

The discrete-time filtering equation is:

\[
y[n]=\sum_{k=0}^{63}c_kx[n-k]
\]

where:

- \(x[n-k]\) is the input sample at tap \(k\).
- \(c_k\) is the corresponding filter coefficient.
- \(y[n]\) is the filtered output.

### Time-multiplexed multiply-accumulate datapath

Rather than implementing a separate multiplier for every tap, the design reuses a multiplier across successive processing cycles.

```text
 Sample History             Coefficient Memory
       |                            |
       v                            v
 +-------------+              +-------------+
 | Sample Read |              | Coefficient |
 |   Address   |              |    Read     |
 +------+------+              +------+------+
        |                            |
        +-------------+--------------+
                      |
                      v
               +-------------+
               | Multiplier  |
               |   16 x 16   |
               +------+------+
                      |
                      v
               +-------------+
               | 40-bit      |
               | Accumulator|
               +------+------+
                      |
                      v
               +-------------+
               | Scaling and |
               | Saturation  |
               +------+------+
                      |
                      v
                 16-bit Output
```

For every output sample, the accelerator performs 64 multiplications and accumulates the resulting products.

This architecture trades parallel processing resources for additional processing cycles. It is suitable for applications where the sample arrival rate is low relative to the available FPGA clock frequency.

### Circular sample buffer

The accelerator maintains sample history using a circular buffer.

For four channels with 64 samples per channel, the logical sample storage requirement is:

\[
4\times64=256\text{ samples}
\]

A channel-specific head pointer identifies the most recently stored sample. Earlier samples are accessed through tap-index arithmetic, avoiding the need to shift the entire sample history whenever a new sample arrives.

### Coefficient storage

The coefficient memory provides storage for the filter coefficients associated with each channel.

The logical coefficient storage requirement is:

\[
4\times64=256\text{ coefficients}
\]

The memory-mapped interface may be used to update coefficients at runtime, according to the implemented peripheral functionality.

## Fixed-Point Arithmetic

The accelerator uses signed 16-bit samples and signed 16-bit coefficients. Coefficients are represented in Q1.15 fixed-point format.

The coefficient value is interpreted as:

\[
c_{\text{real}}=\frac{c_{\text{integer}}}{2^{15}}
\]

For example, an integer coefficient of 16384 represents 0.5.

### Multiplication and accumulation

Multiplying two signed 16-bit values produces a signed 32-bit product:

\[
16\text{-bit}\times16\text{-bit}
\rightarrow32\text{-bit}
\]

The products are accumulated in a 40-bit datapath to provide additional headroom during summation.

### Output scaling

After accumulation, the result is shifted right by 15 bits to account for the coefficient's fractional scaling.

\[
y_{\text{scaled}}=acc\mathbin{\text{>>>}}15
\]

The arithmetic right shift preserves the sign of the accumulated result.

### Saturation

The final result is limited to the signed 16-bit range:

\[
-32768\leq y[n]\leq32767
\]

Values above the positive limit are clipped to 32767, while values below the negative limit are clipped to -32768. Results within the valid range are retained.

Saturation prevents out-of-range results from wrapping around when converted to a 16-bit output.

## Memory-Mapped Interface

The FIR peripheral provides a register-based interface between the processor and the accelerator.

The following offsets describe the interface documented for the current design; confirm the exact register widths, access rules, and status-bit definitions against `fir_periph.v`.

| Register | Offset | Purpose |
|---|---:|---|
| `FIR_CTRL` | `0x00` | Start processing and select channel |
| `FIR_DATA_IN` | `0x08` | Input sample |
| `FIR_DATA_OUT` | `0x0C` | Filtered output |
| `FIR_STATUS` | Verify RTL | Processing status and completion |

### Typical software transaction

1. Write an input sample to `FIR_DATA_IN`.
2. Select the channel and initiate processing through `FIR_CTRL`.
3. Wait for the completion status or an interrupt, if supported and enabled.
4. Read the filtered output from `FIR_DATA_OUT`.
5. Clear the completion status according to the implemented register semantics.

Conceptual pseudocode:

```c
write_reg(FIR_DATA_IN, sample);
write_reg(FIR_CTRL, (channel << 8) | 1);

while (!(read_reg(FIR_STATUS) & DONE_MASK)) {
    // Wait for processing completion.
}

result = read_reg(FIR_DATA_OUT);
```

The register addresses, `DONE_MASK`, and status-clearing operation must match the actual peripheral implementation. The code above is illustrative rather than a drop-in firmware driver.

## Repository Structure

```text
VitalSoC/
├── DSP/
│   └── vitalsoc_fir/
│       ├── fir_core.v
│       ├── fir_periph.v
│       └── model/
├── README.md
└── ...
```

The tree above highlights the FIR-related files currently identified. Additional directories and files should be documented as the repository develops.

| File or directory | Description |
|---|---|
| `DSP/vitalsoc_fir/fir_core.v` | FIR computation datapath and control logic |
| `DSP/vitalsoc_fir/fir_periph.v` | Peripheral register and processor-interface logic |
| `DSP/vitalsoc_fir/model/` | Model-related files; exact contents should be documented from the repository |

## Design Specifications

| Parameter | Specification |
|---|---|
| Processor | PicoRV32 |
| Accelerator | Finite Impulse Response (FIR) filter |
| Number of channels | 4 |
| Taps per channel | 64 |
| Input width | 16 bits, signed |
| Coefficient width | 16 bits, signed |
| Coefficient format | Q1.15 |
| Product width | 32 bits |
| Accumulator width | 40 bits |
| Output width | 16 bits |
| Sample-history capacity | 256 logical samples |
| Coefficient capacity | 256 logical coefficients |
| Processing architecture | Time-multiplexed MAC |

The exact clock frequency, measured latency, FPGA resource usage, and achieved timing should be reported from simulation and synthesis results rather than inferred from the architecture alone.

## Verification and Evaluation

The following tests are recommended for validating the FIR core and its integration.

### Functional verification

- Reset and initialization.
- Impulse response.
- Constant input and DC gain.
- Positive and negative input samples.
- Channel isolation.
- Circular-buffer wraparound.
- Coefficient read/write behaviour.
- Output scaling and saturation.
- Completion status and interrupt behaviour.
- Back-to-back processing requests.
- Comparison against a software reference model.

### Performance evaluation

Evaluate the design using:

- LUT and flip-flop utilization.
- DSP block utilization.
- Memory resource utilization.
- Maximum achievable clock frequency.
- Processing latency per output sample.
- Maximum sustainable sample rate.
- Power consumption, if measured.

For a 100 MHz implementation, one clock cycle is 10 ns. A 67-cycle operation would correspond to 670 ns, or 0.67 µs. This is a theoretical calculation based on that assumed cycle count and clock frequency; the actual latency must be measured from the implemented RTL.

## Applications

Potential applications include:

- ECG signal preprocessing.
- PPG signal filtering.
- Wearable health-monitoring systems.
- Biomedical instrumentation.
- Low-cost real-time DSP systems.
- FPGA-based hardware/software co-design experiments.

VitalSoC is a development and research platform, not a clinically validated medical device. Its filtered outputs should not be used for diagnosis or treatment without appropriate validation.

## Future Work

Potential development directions include:

- Complete PicoRV32 SoC integration and system-level verification.
- Automated regression testing with a software reference model.
- Integration with real ADC and sensor interfaces.
- Configurable FIR coefficients and filter profiles.
- Benchmarking against a software-only FIR implementation.
- FPGA synthesis and timing analysis.
- Power and area comparison across alternative architectures.
- Integration of downstream ECG/PPG analysis algorithms.

## References

- [PicoRV32 RISC-V CPU](https://github.com/YosysHQ/picorv32)
- [GitHub README documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

## License

Add a `LICENSE` file specifying the project's chosen license before distributing the source code as an open-source project.

## Acknowledgements

VitalSoC builds on the PicoRV32 open-source RISC-V processor and explores dedicated hardware acceleration for biomedical signal processing.
