# SHAKE128/256 (Keccak) Implementation in Verilog

This repository contains a Verilog implementation of the SHAKE128 and SHAKE256 extendable-output functions (XOF), based on the Keccak-f[1600] permutation.

##  Features
* **Dual Mode Support**: Toggle between SHAKE128 (rate = 168B) and SHAKE256 (rate = 136B) using the `shake_sel` signal.
* **Customizable Output (XOF)**: Specify the desired output length via the `out_len_bytes` parameter.
* **Handshake Protocol**: Utilizes a `valid/ready` mechanism to manage data flow for both input and output.
* **Automatic Padding**: Handles Domain Padding and buffer bytes (`0x1F`, `0x9F`, `0x80`) according to the SHAKE standard .

##  Module Structure

### 1. Permutation Core
* **`f_permutation.v`**: Manages the 24-round Keccak permutation process and controls the computation state .
* **`round.v`**: Implements the Keccak round transformations: Theta, Rho, Pi, Chi, and Iota .
* **`rconst.v`**: Provides the specific Round Constants required for the Iota step in each iteration .

### 2. Padding Unit
* **`padder_shake.v`**: Accepts message data byte-by-byte, packages them into blocks, and applies padding once the `is_last` signal is received.

### 3. Control Unit
* **`shake_control.v`**: A Finite State Machine (FSM) that coordinates the two primary phases:
    * **Absorb**: XORs the padded blocks into the internal state .
    * **Squeeze**: Extracts the output data based on the requested byte count .

### 4. Top Level
* **`shake128.v`**: The `shake_top` module integrates all components and performs byte reordering for both input and output data to ensure algorithmic correctness.

##  Interface Description

### Primary Signals
| Signal | Direction | Description |
| :--- | :--- | :--- |
| `clk`, `rst_n` | Input | System clock and active-low reset. |
| `start` | Input | 1-cycle pulse to initialize a new job and clear internal state. |
| `shake_sel` | Input | Mode selection: `0` for SHAKE128, `1` for SHAKE256. |
| `in_byte` [7:0] | Input | Input message data stream (byte-by-byte). |
| `is_last` | Input | Indicates the final byte of the input message. |
| `out_block` | Output | 1344-bit container for the generated output blocks. |

---
