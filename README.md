# LLPTP - Low Latency PassThrough Player

LLPTP is a high-performance macOS command-line tool written in zero-dependency Swift that routes audio from an input device directly to the default output device with minimal latency. 

It is designed for real-time monitoring of external audio sources (like instruments, microphones, or game consoles connected via Capture Cards/USB interfaces) through your Mac's default speakers or headphones, bypassing the significant latencies introduced by software like QuickTime, OBS, or standard DAWs.

## Key Features
* **Ultra-Low Latency**: Utilizes Apple's low-level Core Audio HAL (`kAudioUnitSubType_HALOutput`) and a lock-free SPSC (Single Producer, Single Consumer) ring buffer synchronized with hardware memory barriers.
* **Format Agnostic**: Detects and natively handles hardware audio formats (16-bit, 24-bit, 32-bit `Int` or `Float`) directly from USB sources, avoiding OS-level resampling artifacts.
* **Latency Management**: Actively fights clock drift between input and output devices. If the buffer drifts beyond a safe limit, it corrects itself automatically. User-configurable target latency (default 10ms).
* **Multi-Source Support**: Seamlessly select sub-sources on composite hardware devices (e.g. choosing between Microphone, Line-In, or SPDIF on a USB Sound Device).
* **Live Level Meter**: Displays visual volume meters and live latency calculations.

## Installation / Building

LLPTP is written in Swift and requires only the standard macOS SDK to build.

```bash
# Clone the repository
git clone https://github.com/Havelock-Vetinari/Low-Latency-PassThru-Player.git
cd Low-Latency-PassThru-Player

# Build the executable
./build.sh

# The binary will be compiled to `build/llptp`
```

## Usage

### Interactive Mode
Run the tool without arguments to enter an interactive step-by-step wizard to select your device and source:
```bash
./build/llptp
```

### CLI Mode
You can script or automate the monitoring by passing arguments directly:

```bash
# 1. List all available devices and their IDs
./build/llptp --list

# 2. List all available internal sources for a specific device (e.g., Device 2)
./build/llptp --sources 2

# 3. Start passthrough from Device 2 (Source 1) with default latency (10ms)
./build/llptp --device 2 --source 1

# 4. Start passthrough with aggressive Target Latency (e.g., 5ms)
./build/llptp --device 2 --source 1 --latency 5

# 5. Quiet mode (disables the Live Level Meter to save CPU cycles)
./build/llptp --device 2 --source 1 --quiet
```

### Options Overview

| Flag | Description |
|------|-------------|
| `--list` | List available audio input devices and their channels |
| `--device <N>` | Start monitoring from the specified device index |
| `--sources <N>` | List sub-sources (Mic, Line, SPDIF) for the specified device |
| `--source <N>` | Select a specific hardware sub-source index |
| `--buffer <frames>` | Internal CoreAudio buffer size (default: 128 frames) |
| `--latency <ms>` | Target latency in milliseconds (default: 10 ms). The ring buffer will try to maintain exactly this latency. |
| `--quiet`, `-q` | Suppress the CLI volume meter and live latency tracking |
| `--help` | Show the help message |

## Architecture Notes
LLPTP uses a two-stage asynchronous audio pipeline:
1. An `AudioDeviceIOProc` callback eagerly pulls raw audio from the hardware device, doing format-conversion (e.g., `Int16` -> `Float32`) and dumping samples into an SPSC lock-free ring buffer.
2. An `AUHAL` output unit render callback consumes from the opposite end of the ring buffer and pushes to the system's default output.
3. Apple Silicon memory reordering issues are sidestepped via `os_unfair_lock` barriers on the ring buffer indices, guaranteeing glitch-free audio without heavy mutex overhead.

## License
MIT License
