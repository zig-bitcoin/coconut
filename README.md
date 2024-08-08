<div align="center">
    <h1>Coconut</h1>
    <h2>Cashu protocol implementation in Zig.</h2>

<a href="https://github.com/AbdelStark/coconut/actions/workflows/check.yml"><img alt="GitHub Workflow Status" src="https://img.shields.io/github/actions/workflow/status/AbdelStark/coconut/check.yml?style=for-the-badge" height=30></a>
<a href="https://ziglang.org/"> <img alt="Zig" src="https://img.shields.io/badge/zig-%23000000.svg?style=for-the-badge&logo=zig&logoColor=white" height=30></a>
<a href="https://bitcoin.org/"> <img alt="Bitcoin" src="https://img.shields.io/badge/Bitcoin-000?style=for-the-badge&logo=bitcoin&logoColor=white" height=30></a>
<a href="https://lightning.network/"><img src="https://img.shields.io/badge/Ligthning Network-000.svg?&style=for-the-badge&logo=data:image/svg%2bxml;base64%2CPD94bWwgdmVyc2lvbj0iMS4wIiBzdGFuZGFsb25lPSJubyI%2FPg0KPCEtLSBHZW5lcmF0b3I6IEFkb2JlIEZpcmV3b3JrcyAxMCwgRXhwb3J0IFNWRyBFeHRlbnNpb24gYnkgQWFyb24gQmVhbGwgKGh0dHA6Ly9maXJld29ya3MuYWJlYWxsLmNvbSkgLiBWZXJzaW9uOiAwLjYuMSAgLS0%2BDQo8IURPQ1RZUEUgc3ZnIFBVQkxJQyAiLS8vVzNDLy9EVEQgU1ZHIDEuMS8vRU4iICJodHRwOi8vd3d3LnczLm9yZy9HcmFwaGljcy9TVkcvMS4xL0RURC9zdmcxMS5kdGQiPg0KPHN2ZyBpZD0iYml0Y29pbl9saWdodG5pbmdfaWNvbi5mdy1QYWdlJTIwMSIgdmlld0JveD0iMCAwIDI4MCAyODAiIHN0eWxlPSJiYWNrZ3JvdW5kLWNvbG9yOiNmZmZmZmYwMCIgdmVyc2lvbj0iMS4xIg0KCXhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgeG1sbnM6eGxpbms9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiIHhtbDpzcGFjZT0icHJlc2VydmUiDQoJeD0iMHB4IiB5PSIwcHgiIHdpZHRoPSIyODBweCIgaGVpZ2h0PSIyODBweCINCj4NCgk8cGF0aCBpZD0iRWxsaXBzZSIgZD0iTSA3IDE0MC41IEMgNyA2Ni43NjkgNjYuNzY5IDcgMTQwLjUgNyBDIDIxNC4yMzEgNyAyNzQgNjYuNzY5IDI3NCAxNDAuNSBDIDI3NCAyMTQuMjMxIDIxNC4yMzEgMjc0IDE0MC41IDI3NCBDIDY2Ljc2OSAyNzQgNyAyMTQuMjMxIDcgMTQwLjUgWiIgZmlsbD0iI2Y3OTMxYSIvPg0KCTxwYXRoIGQ9Ik0gMTYxLjE5NDMgNTEuNSBDIDE1My4yMzQ5IDcyLjE2MDcgMTQ1LjI3NTYgOTQuNDEwNyAxMzUuNzI0NCAxMTYuNjYwNyBDIDEzNS43MjQ0IDExNi42NjA3IDEzNS43MjQ0IDExOS44MzkzIDEzOC45MDgxIDExOS44MzkzIEwgMjA0LjE3NDcgMTE5LjgzOTMgQyAyMDQuMTc0NyAxMTkuODM5MyAyMDQuMTc0NyAxMjEuNDI4NiAyMDUuNzY2NyAxMjMuMDE3OSBMIDExMC4yNTQ1IDIyOS41IEMgMTA4LjY2MjYgMjI3LjkxMDcgMTA4LjY2MjYgMjI2LjMyMTQgMTA4LjY2MjYgMjI0LjczMjEgTCAxNDIuMDkxOSAxNTMuMjE0MyBMIDE0Mi4wOTE5IDE0Ni44NTcxIEwgNzUuMjMzMyAxNDYuODU3MSBMIDc1LjIzMzMgMTQwLjUgTCAxNTYuNDE4NyA1MS41IEwgMTYxLjE5NDMgNTEuNSBaIiBmaWxsPSIjZmZmZmZmIi8%2BDQo8L3N2Zz4%3D" alt="Bitcoin Lightning" height="30"></a>

</div>

# About

Cashu protocol implementation in Zig.

For now it contains only the BDHKE implementation.

## Usage

### Running

```bash
zig build run
```

Example output:

```text
Starting BDHKE test
Secret message: test_message
Alice's private key (a): 0000000000000000000000000000000000000000000000000000000000000001
Alice's public key (A): 0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
r private key: 0000000000000000000000000000000000000000000000000000000000000001
Blinding factor (r): 0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
Blinded message (B_): 025cc16fe33b953e2ace39653efb3e7a7049711ae1d8a2f7a9108753f1cdea742b
Step 1 complete: Message blinded
Blinded signature (C_): 025cc16fe33b953e2ace39653efb3e7a7049711ae1d8a2f7a9108753f1cdea742b
DLEQ proof - e: e87bf88896743cd89e8f8316811553a15d74538f205c9cff1f72ff23e624cc1f
DLEQ proof - s: 9f546cb383df3d8c0d36c925045287c113df293c3429083d2c5728cfdbddd925
Step 2 complete: Blinded message signed
Alice's DLEQ verification successful
Unblinded signature (C): 0215fdc277c704590f3c3bcc08cf9a8f748f46619b96268cece86442b6c3ac461b
Step 3 complete: Signature unblinded
Carol's DLEQ verification successful
Final verification successful
BDHKE test completed successfully
```

## Resources

- [Cashu documentation](https://docs.cashu.space/)
- [Cashu slides by Gandalf](https://lconf.gandlaf.com/)
- [Nutshell reference implementation](https://github.com/cashubtc/nutshell)
