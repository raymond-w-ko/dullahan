# Single-Parser Matrix

Repeatable local/CI command:

```bash
./scripts/run-single-parser-matrix.sh
```

Direct runner form:

```bash
./server/zig-out/bin/dullahan test single-parser-matrix
```

What it covers:

- fish-style DA1 detection
- lipgloss OSC 11 background queries with BEL and ST terminators
- vim-style DA2 and DSR probes
- OSC 52 clipboard set/get routing
- OSC 0/2 title updates
- OSC 9 and OSC 777 notifications
- OSC 9;4 progress updates
- XTGETTCAP
- XTVERSION
- DECRQM
- kitty keyboard query
- OSC 7 PWD reporting
- XTWINOPS size reports

Artifacts:

- `manifest.json`
- per-case `*-request.bin`
- per-case `*-response.bin`
- `server.log`
- `pty-traffic.jsonl`

The runner prints the artifact directory on success. Keep that directory when diagnosing failures locally or in CI.
