<div align="center">
    <img src="./docs/img/coconut.png" alt="coconut-logo" height="260"/>
    <h2>Cashu wallet and mint in Zig</h2>

<a href="https://github.com/AbdelStark/coconut/actions/workflows/check.yml"><img alt="GitHub Workflow Status" src="https://img.shields.io/github/actions/workflow/status/AbdelStark/coconut/check.yml?style=for-the-badge" height=30></a>
<a href="https://ziglang.org/"> <img alt="Zig" src="https://img.shields.io/badge/zig-%23000000.svg?style=for-the-badge&logo=zig&logoColor=white" height=30></a>
<a href="https://bitcoin.org/"> <img alt="Bitcoin" src="https://img.shields.io/badge/Bitcoin-000?style=for-the-badge&logo=bitcoin&logoColor=white" height=30></a>
<a href="https://lightning.network/"><img src="https://img.shields.io/badge/Ligthning Network-000.svg?&style=for-the-badge&logo=data:image/svg%2bxml;base64%2CPD94bWwgdmVyc2lvbj0iMS4wIiBzdGFuZGFsb25lPSJubyI%2FPg0KPCEtLSBHZW5lcmF0b3I6IEFkb2JlIEZpcmV3b3JrcyAxMCwgRXhwb3J0IFNWRyBFeHRlbnNpb24gYnkgQWFyb24gQmVhbGwgKGh0dHA6Ly9maXJld29ya3MuYWJlYWxsLmNvbSkgLiBWZXJzaW9uOiAwLjYuMSAgLS0%2BDQo8IURPQ1RZUEUgc3ZnIFBVQkxJQyAiLS8vVzNDLy9EVEQgU1ZHIDEuMS8vRU4iICJodHRwOi8vd3d3LnczLm9yZy9HcmFwaGljcy9TVkcvMS4xL0RURC9zdmcxMS5kdGQiPg0KPHN2ZyBpZD0iYml0Y29pbl9saWdodG5pbmdfaWNvbi5mdy1QYWdlJTIwMSIgdmlld0JveD0iMCAwIDI4MCAyODAiIHN0eWxlPSJiYWNrZ3JvdW5kLWNvbG9yOiNmZmZmZmYwMCIgdmVyc2lvbj0iMS4xIg0KCXhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgeG1sbnM6eGxpbms9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiIHhtbDpzcGFjZT0icHJlc2VydmUiDQoJeD0iMHB4IiB5PSIwcHgiIHdpZHRoPSIyODBweCIgaGVpZ2h0PSIyODBweCINCj4NCgk8cGF0aCBpZD0iRWxsaXBzZSIgZD0iTSA3IDE0MC41IEMgNyA2Ni43NjkgNjYuNzY5IDcgMTQwLjUgNyBDIDIxNC4yMzEgNyAyNzQgNjYuNzY5IDI3NCAxNDAuNSBDIDI3NCAyMTQuMjMxIDIxNC4yMzEgMjc0IDE0MC41IDI3NCBDIDY2Ljc2OSAyNzQgNyAyMTQuMjMxIDcgMTQwLjUgWiIgZmlsbD0iI2Y3OTMxYSIvPg0KCTxwYXRoIGQ9Ik0gMTYxLjE5NDMgNTEuNSBDIDE1My4yMzQ5IDcyLjE2MDcgMTQ1LjI3NTYgOTQuNDEwNyAxMzUuNzI0NCAxMTYuNjYwNyBDIDEzNS43MjQ0IDExNi42NjA3IDEzNS43MjQ0IDExOS44MzkzIDEzOC45MDgxIDExOS44MzkzIEwgMjA0LjE3NDcgMTE5LjgzOTMgQyAyMDQuMTc0NyAxMTkuODM5MyAyMDQuMTc0NyAxMjEuNDI4NiAyMDUuNzY2NyAxMjMuMDE3OSBMIDExMC4yNTQ1IDIyOS41IEMgMTA4LjY2MjYgMjI3LjkxMDcgMTA4LjY2MjYgMjI2LjMyMTQgMTA4LjY2MjYgMjI0LjczMjEgTCAxNDIuMDkxOSAxNTMuMjE0MyBMIDE0Mi4wOTE5IDE0Ni44NTcxIEwgNzUuMjMzMyAxNDYuODU3MSBMIDc1LjIzMzMgMTQwLjUgTCAxNTYuNDE4NyA1MS41IEwgMTYxLjE5NDMgNTEuNSBaIiBmaWxsPSIjZmZmZmZmIi8%2BDQo8L3N2Zz4%3D" alt="Bitcoin Lightning" height="30"></a>

</div>

# About

Coconut 🥥 is a Cashu Wallet and Mint implementation in Zig.

## Build

```sh
zig build -Doptimize=ReleaseFast
```

## CLI Usage

The Coconut wallet provides a command-line interface for various operations. Here's how to use it:

### General Help

To see the general help and available commands, run:

```text
$ coconut --help
Version: 0.1.0
Author: Coconut Contributors
USAGE:
  coconut [OPTIONS]
COMMANDS:
  info   Display information about the Coconut wallet
OPTIONS:
  -h, --help            Show this help output.
      --color <VALUE>   When to use colors (*auto*, never, always).
```

### Info Command

The `info` command displays information about the Coconut wallet. Here's its specific help:

```text
$ coconut info --help
USAGE:
  coconut info [OPTIONS]
OPTIONS:
  -m, --mint       Fetch mint information
  -n, --mnemonic   Show your mnemonic
  -h, --help       Show this help output.
```

### Example Usage

Here's an example of using the `info` command with the `--mnemonic` option:

```text
$ coconut info --mnemonic

Version: 0.1.0
Wallet: coconut
Cashu dir: /Users/abdel/Library/Application Support/coconut
Mints:
    - URL: https://example.com:3338
        - Keysets:
            - ID: example_id  unit: sat  active: True   fee (ppk): 0
Mnemonic:
 - example word1 word2 word3 ...
Nostr:
    - Public key: npub1example...
    - Relays: wss://example1.com, wss://example2.com
```

This command displays general information about the wallet, including the version, wallet name, Cashu directory, mint information, and Nostr details. The `--mnemonic` option additionally displays the wallet's mnemonic phrase.

Note: Be cautious when using the `--mnemonic` option, as it displays sensitive information. Make sure you're in a secure environment when viewing your mnemonic.

## Benchmarks

This project includes performance benchmarks for each step of the BDHKE process, as well as the end-to-end flow.

### Running Benchmarks Locally

To run the benchmarks on your local machine:

```sh
zig build bench -Doptimize=ReleaseFast
```

The benchmarks will be compiled with the ReleaseFast optimization level.

### Benchmark Results

Current results:

| Operation   | Time us    | Time ns      |
| ----------- | ---------- | ------------ |
| hashToCurve | 7.182 us   | 7181.94 ns   |
| step1Alice  | 23.608 us  | 23608.43 ns  |
| step2Bob    | 28.003 us  | 28002.82 ns  |
| step3Alice  | 25.102 us  | 25101.80 ns  |
| verify      | 29.020 us  | 29020.39 ns  |
| e2e         | 112.626 us | 112626.12 ns |

This run was performed on a MacBook Pro with an M1 chip.

```bash
Machine Info:
  Model: MacBook Pro
  CPU: Apple M1 Max
  Cores: 10 (Physical), 10 (Logical)
  Memory: 64 GB
  macOS Version: 14.5
  Zig Version: 0.14.0-dev.850+ddcb7b1c1
```

## Resources

- [Cashu documentation](https://docs.cashu.space/)
- [Cashu slides by Gandalf](https://lconf.gandlaf.com/)
- [Nutshell reference implementation](https://github.com/cashubtc/nutshell)
