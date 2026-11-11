# Agents tests (Mac)

Command-line checks for the Agents code; build each with `swiftc -import-objc-header Tests/disco/shim.h`
plus the `Sources/Agent*.swift` files it needs (see the first line of each `main.swift`).

- `screentest/` – the terminal screen parser against real Claude Code / Codex captures in `screens/`
  (`expected.json` holds the results of the original parser). Run: `screentest Tests/screens`.
- `disco/` – live discovery of the chats on this Mac, with timings.
- `ctl/` – starts a throwaway Claude chat (haiku) in a scratch folder: trust question, send, and with a
  second argument an interrupting send while it works. Uses a few tokens.
- `hub/` – drives AgentHub with the same JSON the phone sends and prints what the phone would receive.
