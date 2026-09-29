#!/bin/bash
# ChatGPT, and the Codex it runs on, in Islet's island, from each hook's JSON on stdin.
# Two things:
#
# Banners: a reply finished, ChatGPT waiting for permission or asking a question. Only
# while the app it runs in is not in front: a reply you are looking at needs none.
#
# The session's state, for Islet's ChatGPT activity: one JSON file per session (a
# ChatGPT chat or a Codex thread) in
#   ~/Library/Application Support/Islet/ChatGPT/Sessions/<session id>.json
# ($ISLET_CHATGPT_STATE_DIR in its place, for tests), which Islet watches. Each is
# written whole, a new file moved over the old, so Islet never reads half of one; the
# session's end deletes it, and one left by a session that never ended is deleted
# once it is a day old. The end leaves a hidden mark behind it for a day, so a tool
# of that session finishing a moment later does not bring its file back.
#
# Usage: chatgpt-hook.sh <kind>, one kind per hook in ~/.codex/hooks.json:
#   start         SessionStart
#   prompt        UserPromptSubmit
#   tool-start    PreToolUse
#   permission    PermissionRequest
#   tool-end      PostToolUse
#   stop          Stop
#   interrupt     Interrupt
#   agent-start   SubagentStart
#   agent-stop    SubagentStop
#   end           SessionEnd
# ISLET_NOTIFY_DRY=1 prints the banners instead of showing them. Needs jq, which macOS
# has had since 15; before that, Homebrew's, found even when the app was not opened
# from a shell.
#
# A session's file, times in seconds since 1970:
#   version         1
#   sessionId       Codex's thread id, as in the file's name
#   project         the git repository's folder name, or its folder's; "" for a plain
#                   chat, whose folder ChatGPT names after its prompt
#   cwd             the folder the session works in; "" for a plain chat
#   transcriptPath  the thread's rollout file, which Codex writes as it goes: Islet
#                   reads a turn that failed, which fires no hook, from it
#   hostApp         the bundle id of the app Codex runs in (the ChatGPT app, Terminal,
#                   VS Code); "" when unknown
#   pid             Codex's own process: the hook's parent, past any shell it was run
#                   through; null when it could not be found. In the ChatGPT app it is
#                   the app's one Codex server, which every chat shares
#   pidStarted      when that process started, to tell it from a later one given the
#                   same number; null when unknown
#   state           working | needsPermission | waitingForInput | idle
#   since           when it entered that state, or for the two waiting on you, when it
#                   last asked
#   turnId          the latest prompt's turn, which each tool's event names
#   turnStarted     when the latest prompt was sent; null before the first
#   ended           how the latest turn ended: "" while under way, "done" or
#                   "interrupted"
#   updated         the latest event
#   prompt          the latest prompt's first line, plain, at most 120 characters
#   reply           the start of the last reply, plain, at most 160 characters, while
#                   idle; "" otherwise
#   askedBy         who is waiting on you: an agent's id, or "" for the chat itself
#   askId           the call a question or a permission was asked for, as far as known
#   step            the tool under way: {id, kind, name, count, started}, kind being
#                   shell, patch, plan, ask, mcp, spawn, wait, image, goal or other,
#                   and name the program a command runs, the first file a patch
#                   changes (count, how many), an MCP server's name or the tool's own;
#                   null when none is
#   steps           how many tools the turn has used
#   plan            the turn's plan, as its latest update_plan left it:
#                   [{step, status}], status pending, in_progress or completed
#   agents          the agents the session has sent off: [{id, type, name, status
#                   (running or done), firstSeen, ended, step, steps}]
#   pending         agents asked for and not yet started, by the name they were given:
#                   [{name, t}]
#   doneIds         the latest tools to finish, since their events can arrive out of
#                   order
#   endedAgents     the latest agents to stop, so that a tool of theirs finishing after
#                   them does not bring them back
# Never kept: a command (only the program it runs), a patch or a file's folder, what a
# tool was given or gave back, a question, what a permission is asked for, an agent's
# reply, the model, or a plain chat's folder.
#
# It has to be quick, and must never fail the hook: Codex waits for most of them, and
# takes anything printed by some as a decision. So nothing is printed (but a dry run's
# banners), and it always exits 0. PreToolUse and PostToolUse run in the background,
# one for every tool, so their events can arrive late or out of order; the rules below
# keep one from undoing what a later event said.
export LC_ALL=en_US.UTF-8
PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
kind="$1"
input="$(cat)"
[ -z "$ISLET_NOTIFY_DRY" ] && exec >/dev/null
exec 2>/dev/null

# Codex writes the session's id first, so it is read without jq; the match is held to
# the start, where a session_id inside a tool's input can never be.
session=""
if [[ "$input" =~ ^\{\"session_id\":\"([^\"\\]*)\" ]]; then
  session="${BASH_REMATCH[1]}"
else
  session="$(printf '%s' "$input" | jq -r '.session_id // empty | strings' 2>/dev/null)"
fi
[ -z "$session" ] && exit 0
case "$session" in */*|.*) exit 0 ;; esac
dir="${ISLET_CHATGPT_STATE_DIR:-$HOME/Library/Application Support/Islet/ChatGPT/Sessions}"
[ -d "$dir" ] || mkdir -p "$dir" || exit 0
file="$dir/$session.json"
ended="$dir/.$session.ended"
# The last 200 or so events but tools', to see what each carries: lengths in place of
# what was asked and said, and no folders.
log="$dir/.hook-log.jsonl"

case "$kind" in
  # Quick, for Codex gives it a second: the mark goes down first, then the file goes,
  # and the mark keeps anything arriving after it from bringing it back.
  end)
    : > "$ended"
    rm -f "$file"
    # Its time is the mark's.
    [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] && printf '{"event":"end","session_id":"%s"}\n' "$session" >> "$log"
    exit 0 ;;
  # A thread resumed, after its session ended for being idle, starts again.
  start|prompt) rm -f "$ended" ;;
  tool-start|permission|tool-end|stop|interrupt|agent-start|agent-stop) [ -e "$ended" ] && exit 0 ;;
  *) exit 0 ;;
esac

# One event at a time: tools' events come in parallel. A hook holds the lock for a tenth
# of a second or so; one more than two seconds old was left by a hook cut off by its
# timeout, and is taken over, soon enough for Interrupt's three seconds. It is looked at
# every quarter of a second, and after five seconds taken over whatever its age. How
# long it waited, near enough (a try takes about 25 ms), is taken off the event's time,
# which is then when it happened.
lock="$dir/.$session.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  if [ $((waited % 10)) -eq 0 ] && [ -n "$(find "$lock" -maxdepth 0 -mtime +2s 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null
  fi
  waited=$((waited + 1))
  [ "$waited" -ge 200 ] && break
  sleep 0.02
done
trap 'rmdir "$lock" 2>/dev/null' EXIT
# The session may have ended while this waited.
case "$kind" in start|prompt) ;; *) [ -e "$ended" ] && exit 0 ;; esac

previous=""
[ -f "$file" ] && IFS= read -r -d '' previous < "$file"

# The project, when a session starts or is sent a prompt, or has none yet: the git
# repository it works in, or else its folder. A plain chat in the ChatGPT app works in
# a folder named after its prompt (~/Documents/Codex/<date>/<words>), which is neither
# shown nor kept.
known="" project="" cwd=""
if [ "$kind" = start ] || [ "$kind" = prompt ] || [ -z "$previous" ]; then
  # Read without jq where it can be: the first "cwd" of an event without a tool's input
  # is its own, and one with no escapes in it reads as it is.
  if { [ "$kind" = start ] || [ "$kind" = prompt ]; } && [[ "$input" =~ \"cwd\":\"([^\"\\]*)\" ]]; then
    cwd="${BASH_REMATCH[1]}"
  else
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty | strings' 2>/dev/null)"
  fi
  known=1
  case "$cwd" in
    ""|"$HOME"|"$HOME/"|"$HOME/Documents/Codex/"*|"$HOME/.codex/.chatgpt-projects/"*) cwd="" ;;
    *)
      top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
      if [ -z "$top" ] && [[ "$cwd" =~ /[0-9]{4}-[0-9]{2}-[0-9]{2}/[^/]+/?$ ]]; then
        cwd=""
      else
        project="$(basename "${top:-$cwd}")"
      fi ;;
  esac
fi

# Codex's process: the hook's parent, or that shell's parent where Codex ran the hook
# through one. Its number and age (ps's etime, [[dd-]hh:]mm:ss) are looked up when a
# session starts or is sent a prompt, or while its file has none; so is the app it
# runs in, from the environment an app hands what it starts, or else the first app
# above it (not Codex's own).
pid="" age="" host=""
find_codex() {
  local at="$PPID" line parent etime comm d h m s rest a b c app
  for _ in 1 2 3 4 5 6 7 8; do
    line="$(ps -o ppid=,etime=,comm= -p "$at" 2>/dev/null)" || return
    read -r parent etime comm <<< "$line"
    [ -n "$comm" ] || return
    if [ -z "$pid" ]; then
      case "${comm##*/}" in
        sh|bash|zsh|dash|ksh|fish|env|-sh|-bash|-zsh) at="$parent"; continue ;;
      esac
      [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -gt 1 ] || return
      pid="$at"
      if [[ "$etime" =~ ^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$ ]]; then
        d=0 h=0 rest="$etime"
        case "$rest" in *-*) d="${rest%%-*}"; rest="${rest#*-}" ;; esac
        IFS=: read -r a b c <<< "$rest"
        if [ -n "$c" ]; then h="$a" m="$b" s="$c"; else m="$a" s="$b"; fi
        age=$(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
      fi
      [ -n "$host" ] && return
    elif [[ "$comm" == *.app/Contents/MacOS/* && "$comm" != */CodexCLI.app/* ]]; then
      app="${comm%.app/Contents/MacOS/*}.app"
      host="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)"
      return
    fi
    [[ "$parent" =~ ^[0-9]+$ ]] && [ "$parent" -gt 1 ] || return
    at="$parent"
  done
}
case "$kind" in
  tool-start|tool-end) ;;
  *)
    if [ "$kind" = start ] || [ "$kind" = prompt ] || ! [[ "$previous" == *'"pid":'[0-9]* ]] \
       || [[ "$previous" == *'"hostApp":""'* ]]; then
      host="${__CFBundleIdentifier:-}"
      find_codex
    fi ;;
esac

# The new state, a line of banner (or nothing), and a line for the log, from one jq.
program='
  def text: if type == "string" then . else "" end;
  def one: gsub("[\r\n]+"; " ");
  def clip($n): if length <= $n then . else (.[0:$n - 1] | sub(" [^ ]*$"; "")) + "…" end;
  # Only the start of a long text is looked at: jq takes a long time over a long one.
  def plain($n):
    .[0:$n * 4 + 1000] | split("\n") | map(sub("^[[:space:]]*([-*•]|[0-9]+\\.)[[:space:]]+"; "")) | join(" ")
    | gsub("\\*\\*|__|`|^#+ *|\\[|\\]\\([^)]*\\)"; "") | gsub("[[:space:]]+"; " ")
    | sub("^ +"; "") | sub(" +$"; "") | clip($n);
  def base: sub("/+$"; "") | sub("^.*/"; "");
  # The program a command line mostly runs, as a plain word: past any `cd … &&`,
  # variables set and wrappers like sudo or env; for an interpreter, its script. Words
  # that are not plain names are passed over; "" if none is.
  def program:
    def setup: IN("cd", "export", "set", "unset", "source", ".", "true", "false", ":", "pushd", "popd", "local",
                  "shopt", "trap", "umask", "ulimit", "echo", "printf", "sleep", "mkdir", "wait", "read", "declare",
                  "alias");
    def wrapper: IN("sudo", "env", "time", "nohup", "exec", "command", "caffeinate", "xcrun", "timeout", "nice",
                    "if", "while", "until", "then", "else", "do", "!", "{", "(");
    def keyword: IN("for", "case", "select", "done", "fi", "esac", "}", ")", "in");
    def interpreter: IN("bash", "sh", "zsh", "python", "python3", "node", "ruby", "perl", "swift", "osascript");
    def lead($after):
      if length == 0 then .
      elif (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .[1:] | lead($after)
      elif (.[0] | wrapper) then .[1:] | lead(true)
      elif $after and (.[0] | test("^-|^[0-9.]+[sm]?$")) then .[1:] | lead($after)
      else . end;
    def base: sub("^.*/"; "");
    [gsub("&&|\\|\\|"; "\n") | splits("[\n;|]")
     | [splits("[[:space:]]+") | select(length > 0) | gsub("^[\"\u0027`]+|[\"\u0027`]+$"; "")
        | sub("^[({!]+(?=.)"; "")]
     | lead(false) | select(length > 0)
     | (.[0] | gsub("^[\"\u0027`(){}]+|[\"\u0027`(){}]+$"; "")) as $word
     | select($word != "" and ($word | keyword | not))
     | ($word | base) as $name
     | (if ($name | interpreter) then (.[1:] | map(select(startswith("-") | not)) | first // "") else "" end)
     | if test("[./]") then (gsub("[\"\u0027]"; "") | base) else $name end
     | select(test("^[A-Za-z0-9._+@:~-]+$"))] as $names
    | (first($names[] | select(setup | not)) // $names[0] // "")
    | if length > 40 then .[0:39] + "…" else . end;
  # What sort of tool a call is, by its name, which a namespace may lead.
  def toolkind:
    if IN("Bash", "shell", "shell_command", "exec_command", "local_shell", "container.exec") then "shell"
    elif endswith("apply_patch") then "patch"
    elif endswith("update_plan") then "plan"
    elif endswith("request_user_input") or endswith("request_user_input_async") then "ask"
    elif startswith("mcp__") then "mcp"
    elif endswith("spawn_agent") then "spawn"
    elif endswith("wait_agent") or endswith("wait") then "wait"
    elif endswith("view_image") then "image"
    elif IN("create_goal", "update_goal", "get_goal") then "goal"
    else "other" end;
  def given: (try .tool_input catch null) | if type == "string" then (. as $s | (try fromjson catch $s) // $s) else . end;
  # The command line a shell call runs: a string, or an argument list, where a shell
  # running a script with -c or -lc is taken as its script.
  def commandline:
    given | if type == "object" then (.command // .cmd // "") else . end
    | if type == "array" then
        (if length >= 3 and (.[0] | text | base | IN("bash", "sh", "zsh")) and (.[1] | text | test("^-l?c$"))
         then .[2] | text else map(text) | join(" ") end)
      else text end
    | .[0:4000];
  def patchfiles:
    given | if type == "object" then (.command // .input // .patch // "") else . end | text
    | [scan("\\*\\*\\* (?:Add|Update|Delete) File: ([^\n]+)") | .[0] | sub("[[:space:]]+$"; "") | base
       | select(length > 0)];
  # The step a call is, as kept: its kind and a short name, never what it was given.
  def step($id; $t):
    . as $e | (.tool_name | text) as $tool | ($tool | toolkind) as $k
    | {id: $id, kind: $k, name: "", count: 0, started: $t}
    | if $k == "shell" then .name = ($e | commandline | program)
      elif $k == "patch" then ($e | patchfiles) as $files | .name = ($files[0] // "" | clip(60)) | .count = ($files | length)
      elif $k == "mcp" then .name = ($tool | capture("^mcp__(?<s>.+?)__") .s // "" | clip(40))
      elif $k == "other" then .name = ($tool | clip(40))
      else . end;
  # What a permission is asked for, in a few words: "run swift", "edit Store.swift".
  def asked($s):
    if $s.kind == "shell" then (if $s.name == "" then "run a command" else "run " + $s.name end)
    elif $s.kind == "patch" then (if $s.name == "" then "edit files" else "edit " + $s.name end)
    elif $s.kind == "mcp" then "use " + (if $s.name == "cua_repl" then "the computer" else $s.name end)
    elif $s.kind == "other" then "use " + ($s.name | gsub("_"; " "))
    else "go on" end;
  def planned:
    given | (if type == "object" then .plan else null end) // []
    | [.[]? | objects
       | {step: (.step | text | plain(80)),
          status: (.status | text | if IN("pending", "in_progress", "completed") then . else "pending" end)}]
    | .[0:20];
  def list($v): $v | if type == "array" then map(objects) else [] end;

  . as $in
  | if type != "object" then null, "", "" else
  (now - ($waited | tonumber) * 0.025) as $t
  | (if ($prev | type) == "object" then $prev else {} end) as $p
  | ($in.turn_id | text) as $turn
  | ($in.agent_id | text) as $agent
  | ($in.tool_use_id | text) as $use
  | ($in.tool_name | text) as $tool
  | ($p.state // "idle" | text) as $old
  | ($p.turnId // "" | text) as $current
  | ($p.ended // "" | text) as $over
  | (list($p.agents)) as $agents
  | (list($p.pending)) as $pending
  | ($p.doneIds // [] | if type == "array" then map(strings) else [] end) as $done
  | ($p.endedAgents // [] | if type == "array" then map(strings) else [] end) as $gone
  | ($p.since // $t | if type == "number" then . else $t end) as $since
  | ($p.askedBy // "" | text) as $askedBy
  | ($p.askId // "" | text) as $askId
  | ($kind == "tool-start" or $kind == "tool-end") as $isTool
  | (($in.stop_hook_active // false) == true) as $again
  | ($kind == "start" and ($in.source | text) == "compact") as $compacted
  # A tool of the chat itself from a turn that is over, or from before the latest
  # prompt, has nothing to say about now. An agent may go on past the turn it was
  # started in.
  | ($isTool and $agent == ""
     and ($over != "" or ($current != "" and $turn != "" and $turn != $current))) as $late
  | ($isTool and ($tool | toolkind) == "ask") as $question
  | (if $isTool then ($in | step($use; $t)) else null end) as $call
  | ($p.step | if type == "object" then . else null end) as $was
  | if ($kind == "stop" and $again) or $late then null, "", "" else

  # Who is waiting on you, and on what.
  ($agents | map(select(.id == $agent)) | first) as $asker
  | (if $kind == "permission" then
       {state: "needsPermission", since: $t, askedBy: $agent,
        askId: ((if $agent == "" then $was else ($asker.step // null) end)
                | if type == "object" then (.id // "" | text) else "" end)}
     elif $kind == "tool-start" and $question and ($done | index([$use]) | not) then
       {state: "waitingForInput", since: $t, askedBy: $agent, askId: $use}
     elif $kind == "prompt" then {state: "working", since: $t, askedBy: "", askId: ""}
     elif $kind == "stop" or $kind == "interrupt" then
       {state: "idle", since: (if $old == "idle" then $since else $t end), askedBy: "", askId: ""}
     elif $kind == "start" then
       (if $compacted then {state: $old, since: $since, askedBy: $askedBy, askId: $askId}
        else {state: "idle", since: (if $old == "idle" then $since else $t end), askedBy: "", askId: ""} end)
     # Asked for a known call, it goes on when that call finishes or another starts;
     # else when any call starts or finishes a moment after the ask.
     elif $old == "needsPermission" and $isTool and $askedBy == $agent and $t > $since + 1
          and (if $askId != "" then ($kind == "tool-end" and $use == $askId) or ($kind == "tool-start" and $use != $askId)
               else ($kind == "tool-end" or $use != $askId) end) then
       {state: "working", since: $t, askedBy: "", askId: ""}
     elif $old == "waitingForInput" and $kind == "tool-end" and $use == $askId and $use != "" then
       {state: "working", since: $t, askedBy: "", askId: ""}
     elif $isTool and $agent == "" and $old == "idle" and $current == "" then
       {state: "working", since: $t, askedBy: "", askId: ""}
     else {state: $old, since: $since, askedBy: $askedBy, askId: $askId} end) as $w

  # The chat itself: its step, how many it has taken, and its plan.
  | ($isTool and $agent == "") as $mine
  | (if $kind == "prompt" or $kind == "stop" or $kind == "interrupt" or ($kind == "start" and ($compacted | not)) then null
     elif $mine and $kind == "tool-start" and ($done | index([$use]) | not) then $call
     elif $mine and $kind == "tool-end" and ($was.id // null) == $use then null
     else $was end) as $step
  | (if $kind == "prompt" or ($kind == "start" and ($compacted | not)) then 0
     elif $mine and $kind == "tool-start" then ($p.steps // 0 | if type == "number" then . + 1 else 1 end)
     else ($p.steps // 0 | if type == "number" then . else 0 end) end) as $steps
  | (if $kind == "prompt" or ($kind == "start" and ($compacted | not)) then []
     elif $mine and $kind == "tool-end" and $call.kind == "plan" then ($in | planned)
     else list($p.plan) end) as $plan

  # Agents: started, working, stopped; named by the spawn call that asked for them.
  | ($in | given | if type == "object" then .task_name // .name // "" else "" end | text | plain(40)) as $asked
  | (if $kind == "tool-start" and $call.kind == "spawn" and $asked != "" then
       ($agents | map(select(.status == "running" and (.name // "") == "" and (.firstSeen // 0) >= $t))
        | sort_by(.firstSeen) | first) as $unnamed
       | if $unnamed then {agents: ($agents | map(if .id == $unnamed.id then .name = $asked else . end)), pending: $pending}
         else {agents: $agents, pending: ($pending + [{name: $asked, t: $t}] | .[-8:])} end
     elif $kind == "agent-start" and $agent != "" then
       ($pending | to_entries | map(select((.value.t // 0) <= $t)) | first) as $pair
       | ($agents | map(select(.id == $agent)) | first) as $have
       | if $have and (($have.name // "") != "" or $pair == null) then {agents: $agents, pending: $pending}
         elif $have then
           {agents: ($agents | map(if .id == $agent then .name = $pair.value.name else . end)),
            pending: ($pending | del(.[$pair.key]))}
         else {agents: ($agents + [{id: $agent, type: ($in.agent_type | text), name: ($pair.value.name // ""),
                                   status: "running", firstSeen: $t, ended: null, step: null, steps: 0}]),
               pending: (if $pair then ($pending | del(.[$pair.key])) else $pending end)} end
       # One started again after it stopped is running again.
       | .agents |= map(if .id == $agent and .status != "running" then .status = "running" | .ended = null else . end)
     elif $kind == "agent-stop" and $agent != "" then
       (if ($agents | map(.id) | index($agent)) then
          {agents: ($agents | map(if .id == $agent then .status = "done" | .ended = $t | .step = null else . end)),
           pending: $pending}
        else {agents: ($agents + [{id: $agent, type: ($in.agent_type | text), name: "", status: "done",
                                   firstSeen: $t, ended: $t, step: null, steps: 0}]), pending: $pending} end)
     # An agent that has stopped is gone for good, whatever of its own arrives late.
     elif $isTool and $agent != "" and ($gone | index([$agent])) then {agents: $agents, pending: $pending}
     elif $isTool and $agent != "" then
       (if ($agents | map(.id) | index($agent)) then $agents
        else $agents + [{id: $agent, type: ($in.agent_type | text), name: "", status: "running",
                         firstSeen: $t, ended: null, step: null, steps: 0}] end)
       | map(if .id != $agent or .status != "running" then .
             elif $kind == "tool-start" then
               .steps = ((.steps // 0) + 1) | if ($done | index([$use])) then . else .step = $call end
             elif (.step.id // null) == $use then .step = null
             else . end)
       | {agents: ., pending: $pending}
     elif $kind == "start" and ($compacted | not) then {agents: [], pending: []}
     elif $kind == "prompt" then {agents: ($agents | map(select(.status == "running"))), pending: []}
     elif $kind == "stop" or $kind == "interrupt" then
       {agents: ($agents | map(select(.status == "running"))), pending: $pending}
     else {agents: $agents, pending: $pending} end) as $team
  # At most a dozen, those still running kept first.
  | ($team.agents | if length > 12 then (map(select(.status == "running")) + map(select(.status != "running")))[0:12]
                    else . end) as $team_agents

  | ($in.last_assistant_message | text) as $said
  | (if $kind == "prompt" or ($kind == "start" and ($compacted | not)) then ""
     elif $kind == "stop" then "done"
     elif $kind == "interrupt" then "interrupted"
     else $over end) as $ended
  | (if $known == "1" then $project else ($p.project // "" | text) end) as $proj
  | {
      version: 1,
      sessionId: $session,
      project: $proj,
      cwd: (if $known == "1" then $cwd else ($p.cwd // "" | text) end),
      # Events of an agent name its own rollout, which never holds the turn of the chat.
      transcriptPath: (if $agent == "" then ($in.transcript_path | text) else "" end
                       | if . == "" then ($p.transcriptPath // "" | text) else . end),
      hostApp: (if $host == "" then ($p.hostApp // "" | text) else $host end),
      pid: (if $pid != "" then ($pid | tonumber) else ($p.pid // null) end),
      # From when ps looked, after any wait for the lock.
      pidStarted: (if $pid == "" then ($p.pidStarted // null)
                   elif $age != "" then (now - ($age | tonumber) | floor)
                   else null end),
      state: $w.state,
      since: $w.since,
      turnId: (if $kind == "prompt" then $turn
               elif $current == "" and $mine then $turn
               else $current end),
      turnStarted: (if $kind == "prompt" then $t
                    elif ($p.turnStarted | type) == "number" then $p.turnStarted
                    elif $current == "" and $mine then $t
                    else null end),
      ended: $ended,
      updated: $t,
      prompt: (if $kind == "prompt"
               then ($in.prompt | text | .[0:20000] | split("\n") | map(select(test("\\S"))) | (first // "") | plain(120))
               else ($p.prompt // "" | text) end),
      reply: (if $w.state != "idle" then ""
              elif $kind == "stop" then ($said | plain(160))
              elif $kind == "start" and ($compacted | not) then ""
              else ($p.reply // "" | text) end),
      askedBy: $w.askedBy,
      askId: $w.askId,
      step: $step,
      steps: $steps,
      plan: $plan,
      agents: $team_agents,
      pending: $team.pending,
      doneIds: (if $kind == "prompt" then []
                elif $kind == "tool-end" and $use != "" then ($done + [$use] | .[-16:])
                else $done end),
      endedAgents: (if $kind == "agent-stop" and $agent != "" then ($gone - [$agent] + [$agent] | .[-16:])
                    elif $kind == "agent-start" and $agent != "" then $gone - [$agent]
                    elif $kind == "start" and ($compacted | not) then []
                    else $gone end)
    } as $state

  # A banner, for the three that want you: its words, and the same as a URL query.
  | (if $proj == "" then "" else " · " + $proj end) as $at
  | (if $kind == "stop" then
       {title: ("ChatGPT replied" + $at), subtitle: ($said | plain(120)),
        symbol: "checkmark.circle.fill", tint: "green", style: "card"}
     elif $kind == "permission" then
       ($in | step(""; $t)) as $s
       | {title: "ChatGPT needs permission",
          subtitle: ((if $proj == "" then "" else $proj + " · " end) + asked($s)),
          symbol: "hand.raised.fill", tint: "orange", style: "compact"}
     elif $kind == "tool-start" and $question and $w.askId == $use then
       ($in | given | if type == "object" then (.questions // []) else [] end | .[0]? // {}
        | if type == "object" then (.question // .header // "") else "" end | text | plain(90)) as $q
       | {title: "ChatGPT has a question", subtitle: (if $q == "" then $proj else $q end),
          symbol: "questionmark.bubble.fill", tint: "orange", style: "card"}
     else null end) as $banner

  | $state,
    (if $banner == null then "" else
       ($banner | map_values(text | one)) as $b
       | @sh "title=\($b.title) subtitle=\($b.subtitle) symbol=\($b.symbol) tint=\($b.tint) style=\($b.style) host=\($state.hostApp | one) query=\("title=\($b.title | @uri)&subtitle=\($b.subtitle | @uri)&symbol=\($b.symbol)&tint=\($b.tint)&style=\($b.style)&activity=chatGPT")"
     end),
    (if $isTool then "" else
       {t: ($t | floor), event: $kind, session_id: $session, turn_id: $turn}
       + (if $kind == "start" then {source: ($in.source | text)} else {} end)
       + (if $kind == "permission" then {tool_name: $tool} else {} end)
       + (if $kind == "prompt" then {prompt_chars: ($in.prompt | text | length)} else {} end)
       + (if $kind == "stop" or $kind == "agent-stop" then {reply_chars: ($said | length)} else {} end)
       + (if $kind == "agent-start" or $kind == "agent-stop" then {agent_type: ($in.agent_type | text)} else {} end)
       | tojson
     end)
  end end'
update() { # previous
  printf '%s' "$input" | jq -rc --argjson prev "${1:-null}" --arg kind "$kind" --arg session "$session" \
    --arg known "$known" --arg project "$project" --arg cwd "$cwd" --arg host "$host" \
    --arg pid "$pid" --arg age "$age" --arg waited "$waited" "$program" 2>/dev/null
}
out="$(update "$previous")"
# A file that is not JSON (edited by hand, say) is started afresh.
[ -z "$out" ] && [ -n "$previous" ] && out="$(update null)"
[ -z "$out" ] && exit 0
state="${out%%$'\n'*}"
rest="${out#*$'\n'}"
[ "$rest" = "$out" ] && rest=""
banner="${rest%%$'\n'*}"
logline="${rest#*$'\n'}"
[ "$logline" = "$rest" ] && logline=""

if [ -n "$state" ] && [ "$state" != null ]; then
  tmp="$dir/.$session.$$.tmp"
  { printf '%s\n' "$state" > "$tmp" && mv -f "$tmp" "$file"; } || rm -f "$tmp"
  # The session ended while this wrote: it stays gone.
  [ -e "$ended" ] && rm -f "$file"
fi
# Every session's hooks share the log, so it is cut back to its last 200 lines only once
# it passes 400, by one hook at a time, through a file of its own; a line another chat
# adds in the moment it is cut can be lost, which for a log is no matter.
if [ -n "$logline" ]; then
  printf '%s\n' "$logline" >> "$log"
  if [ "$(wc -l < "$log")" -gt 400 ] && mkdir "$dir/.log.lock" 2>/dev/null; then
    tail -n 200 "$log" > "$log.$$.tmp" && mv -f "$log.$$.tmp" "$log"
    rm -f "$log.$$.tmp"
    rmdir "$dir/.log.lock"
  fi
fi
if [ "$kind" = start ]; then
  find "$dir" -maxdepth 1 \( \( -name '*.json' -o -name '.*.ended' -o -name '.*.tmp' \) -mmin +1440 \
    -o -name '.*.lock' -type d -mmin +1 \) -delete
fi

[ -z "$banner" ] && exit 0
title="" subtitle="" symbol="" tint="" style="" host="" query=""
eval "$banner"
# Not while the app it runs in is in front: you are looking at it already.
if [ -n "$host" ]; then
  front="$(lsappinfo info -only bundleid "$(lsappinfo front)")"
  [[ "$front" =~ (bundleID|CFBundleIdentifier)\"?=\"([^\"]*)\" ]] && [ "${BASH_REMATCH[2]}" = "$host" ] && exit 0
fi
if [ -n "$ISLET_NOTIFY_DRY" ]; then
  echo "banner: $title | $subtitle | $symbol | $tint | $style"
else
  open -g "islet://banner?$query"
fi
exit 0
