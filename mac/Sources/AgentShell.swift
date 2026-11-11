import Foundation

/// Terminal integration: a marked block in ~/.zshrc sources ~/.phonecast/agents/shell.zsh, which makes
/// interactive `claude` / `codex` open in a PhoneCast-managed tmux pane (same TUI on the Mac and the
/// phone). Pure zsh + tmux: no helper process. `pa` = pick a running session and attach,
/// `pa notify "title" "body"` = a phone notification from inside a session.
/// Bypass once with `PHONECAST_AGENTS_OFF=1 claude …` or `command claude …`.
enum AgentShell {
    static let begin = "# >>> phonecast agents >>>"
    static let end = "# <<< phonecast agents <<<"
    static let oldBegin = "# >>> agent-deck shell integration >>>"
    static let oldEnd = "# <<< agent-deck shell integration <<<"
    static var zshrc: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc") }
    static var script: URL { AgentTmux.home.appendingPathComponent("shell.zsh") }

    static var block: String {
        """
        \(begin)
        # Added by PhoneCast (Agents). `claude`/`codex` run in a managed tmux pane PhoneCast can show on the phone.
        # Remove from PhoneCast → Agents, or delete this block. Bypass once: PHONECAST_AGENTS_OFF=1 claude
        [[ -o interactive && -r "$HOME/.phonecast/agents/shell.zsh" ]] && source "$HOME/.phonecast/agents/shell.zsh"
        \(end)
        """
    }

    static func installed() -> Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(begin)
    }

    static func legacyInstalled() -> Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(oldBegin)
    }

    /// Writes shell.zsh and puts the block into ~/.zshrc (replacing Agent Deck's block, backed up first).
    static func install() throws {
        try writeScript()
        var rc = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        let backup = zshrc.deletingLastPathComponent().appendingPathComponent(".zshrc.pre-phonecast-agents")
        if !FileManager.default.fileExists(atPath: backup.path) { try? rc.write(to: backup, atomically: true, encoding: .utf8) }
        rc = remove(rc, oldBegin, oldEnd)
        rc = remove(rc, begin, end)
        if !rc.hasSuffix("\n") && !rc.isEmpty { rc += "\n" }
        rc += "\n" + block + "\n"
        try rc.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        let rc = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        try remove(rc, begin, end).write(to: zshrc, atomically: true, encoding: .utf8)
    }

    private static func remove(_ s: String, _ b: String, _ e: String) -> String {
        guard let r1 = s.range(of: b), let r2 = s.range(of: e, range: r1.upperBound..<s.endIndex) else { return s }
        var end = r2.upperBound
        if end < s.endIndex, s[end] == "\n" { end = s.index(after: end) }
        var start = r1.lowerBound
        if start > s.startIndex, s[s.index(before: start)] == "\n", start > s.index(after: s.startIndex), s[s.index(before: s.index(before: start))] == "\n" { start = s.index(before: start) }
        return String(s[..<start]) + String(s[end...])
    }

    /// Keeps shell.zsh current (called at every launch, so app updates update the script too).
    static func writeScript() throws {
        try FileManager.default.createDirectory(at: AgentTmux.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? String(contentsOf: script, encoding: .utf8)) != source {
            try source.write(to: script, atomically: true, encoding: .utf8)
        }
    }

    static let source = #"""
    # PhoneCast agents — managed claude/codex terminals (written by PhoneCast.app; edits are overwritten)
    _pc_dir="$HOME/.phonecast/agents"
    _pc_sock="$_pc_dir/tmux.sock"
    _pc_conf="$_pc_dir/tmux.conf"
    _pc_tmux_bin=${commands[tmux]:-/opt/homebrew/bin/tmux}
    _pc_t() { TMUX= "$_pc_tmux_bin" -S "$_pc_sock" -f "$_pc_conf" "$@"; }
    _pc_uuid='[0-9a-fA-F](#c8)-[0-9a-fA-F](#c4)-[0-9a-fA-F](#c4)-[0-9a-fA-F](#c4)-[0-9a-fA-F](#c12)'

    _pc_native() {  # real binary, skipping these functions
      local p; p=$(whence -p "$1") && { print -r -- "$p"; return; }
      [[ -x "$HOME/.local/bin/$1" ]] && print -r -- "$HOME/.local/bin/$1"
    }

    _pc_interactive() {  # agent args...: is this the TUI (not -p, --version, a subcommand)?
      setopt localoptions extendedglob
      local agent=$1; shift
      local a first=""
      for a in "$@"; do [[ $a != -* ]] && { first=$a; break; }; done
      if [[ $agent == claude ]]; then
        for a in "$@"; do [[ $a == (-p|--print|--print=*|-v|--version|-h|--help) ]] && return 1; done
        [[ -n $first && $first == $1 && $first == (agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade|config|migrate-installer) ]] && return 1
        return 0
      fi
      for a in "$@"; do [[ $a == (-h|--help|-V|--version) ]] && return 1; done
      [[ -z $first || $first == (resume|fork) ]] && return 0
      [[ $first == (exec|e|review|login|logout|mcp|mcp-server|plugin|app-server|remote-control|app|completion|update|doctor|sandbox|debug|apply|a|queue|archive|delete|migrate-rollouts|unarchive|cloud|exec-server|features|help|agents) ]] && return 1
      return 0
    }

    _pc_run() {
      setopt localoptions extendedglob
      local agent=$1; shift
      local bin; bin=$(_pc_native $agent) || { print -u2 "phonecast: $agent not found"; return 127; }
      if [[ -n $PHONECAST_AGENTS_OFF || -n $PHONECAST_AGENT_ID || -n $AGENTDECK_SESSION_ID || ! -t 0 || ! -t 1 || ! -x $_pc_tmux_bin ]] || ! _pc_interactive $agent "$@"; then
        "$bin" "$@"; return
      fi
      # resuming a chat that already runs in a managed pane: just show that pane
      local target="" i
      if [[ $agent == claude ]]; then
        for (( i = 1; i <= $#; i++ )); do
          [[ ${@[i]} == (--resume|-r) && ${@[i+1]} == ${~_pc_uuid} ]] && target=${@[i+1]}
          [[ ${@[i]} == --resume=${~_pc_uuid} ]] && target=${@[i]#--resume=}
        done
      elif [[ $1 == resume ]]; then
        for i in "${@:2}"; do [[ $i == ${~_pc_uuid} ]] && target=$i; done
      fi
      if [[ -n $target && -S $_pc_sock ]]; then
        local s; s=$(_pc_t list-sessions -F '#{@pc_native} #{session_name}' 2>/dev/null | awk -v t=$target '$1==t{print $2; exit}')
        [[ -n $s ]] && { _pc_t attach-session -t "$s"; return; }
      fi
      mkdir -p "$_pc_dir" && chmod 700 "$_pc_dir"
      local id; id=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 12)
      local -a extra; local native=""
      if [[ $agent == claude && -z ${(M)@:#(--resume|-r|--resume=*|--continue|-c|--session-id|--session-id=*|--fork-session)} ]]; then
        native=$(uuidgen | tr 'A-Z' 'a-z'); extra=(--session-id $native)
      fi
      [[ -n $target ]] && native=$target
      local -a envs; local kv
      for kv in ${(0)"$(env -0)"}; do [[ $kv == (TMUX|TMUX_PANE|CLAUDECODE|AGENTDECK_SESSION_ID)=* ]] || envs+=(-e "$kv"); done
      _pc_t new-session -d -s "pc-$id" -x ${COLUMNS:-160} -y ${LINES:-48} -c "$PWD" "${envs[@]}" -e "PHONECAST_AGENT_ID=$id" -- "$bin" "${extra[@]}" "$@" || { "$bin" "$@"; return; }
      _pc_t set-option -t "pc-$id" @pc_id "$id"
      _pc_t set-option -t "pc-$id" @pc_agent "$agent"
      [[ -n $native ]] && _pc_t set-option -t "pc-$id" @pc_native "$native"
      _pc_t attach-session -t "pc-$id"
    }

    claude() { _pc_run claude "$@"; }
    codex() { _pc_run codex "$@"; }

    pa() {
      if [[ $1 == notify ]]; then
        shift
        [[ -z $PHONECAST_AGENT_ID ]] && { print -u2 "pa notify: only inside a PhoneCast agent session"; return 2; }
        mkdir -p "$_pc_dir/notify"
        local f="$_pc_dir/notify/$(date +%s)-$$-$RANDOM.json"
        python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"title":sys.argv[2],"body":sys.argv[3]}))' "$PHONECAST_AGENT_ID" "${1:-Agent}" "${2:-}" >"$f.tmp" && mv "$f.tmp" "$f"
        return
      fi
      local -a socks=("$_pc_sock" "$HOME/.agent-deck/terminal/tmux.sock")
      local -a rows; local s line
      for s in $socks; do
        [[ -S $s ]] || continue
        for line in ${(f)"$(TMUX= "$_pc_tmux_bin" -S "$s" list-sessions -F "$s	#{session_name}	#{?session_attached,attached,}	#{pane_current_path}	#{pane_current_command}" 2>/dev/null)"}; do rows+=("$line"); done
      done
      (( $#rows )) || { print "No running agent sessions."; return 1; }
      local n=1 r
      for r in $rows; do
        local -a f=("${(@s:	:)r}")
        printf '%2d. %-8s %-9s %s\n' $n "${f[5]}" "${f[3]}" "${f[4]/#$HOME/~}"; (( n++ ))
      done
      local pick; read "pick?Attach to (1-$#rows, Enter = 1): "
      [[ -z $pick ]] && pick=1
      [[ $pick == <-> && $pick -ge 1 && $pick -le $#rows ]] || return 1
      local -a f=("${(@s:	:)rows[pick]}")
      TMUX= "$_pc_tmux_bin" -S "${f[1]}" attach-session -t "${f[2]}"
    }
    """#
}
