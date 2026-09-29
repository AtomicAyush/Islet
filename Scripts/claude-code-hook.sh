#!/bin/bash
# Claude Code in Islet's island, from each hook's JSON on stdin. Two things:
#
# Banners: a reply finished, Claude waiting for permission or input, a workflow
# finished.
#
# The session's state, for Islet's Claude Code activity: one JSON file per session in
#   ~/Library/Application Support/Islet/Claude Code/Sessions/<session id>.json
# ($ISLET_CLAUDE_STATE_DIR in its place, for tests), which Islet watches. Each is
# written whole, a new file moved over the old, so Islet never reads half of one; the
# session's end deletes it, and one left by a session that never ended is deleted
# once it is a day old. The end leaves a hidden mark behind it for a day, so an agent
# of that session stopping a moment later does not bring its file back.
#
# Usage: claude-code-hook.sh <kind>, one kind per hook in ~/.claude/settings.json:
#   start         SessionStart
#   prompt        UserPromptSubmit
#   notification  Notification
#   stop          Stop
#   subagent      SubagentStop
#   task          TaskCompleted
#   end           SessionEnd
#   permission    PermissionRequest
#   tool          PostToolUse
#   tool          PostToolUseFailure
# ISLET_NOTIFY_DRY=1 prints the banners instead of showing them, the activity they are
# news of last.
#
# A session's file, times in seconds since 1970:
#   version         1
#   sessionId       Claude Code's session id, as in the file's name
#   project         the git repository's folder name, or its folder's; "" for Claude's
#                   scratch folders, the home folder and "/", which have no name worth
#                   showing
#   cwd             the folder the session is working in, as of its latest event
#   transcriptPath  the session's transcript, which Claude Code writes as it goes:
#                   Islet reads a session gone quiet on it as over
#   hostApp         the bundle id of the app Claude Code runs in (Terminal, iTerm, VS
#                   Code, the Claude app), which it hands its hooks as
#                   __CFBundleIdentifier; "" when unknown
#   pid             Claude Code's own process: the hook's parent, past any shell it was
#                   run through; null when it could not be found. Islet takes a session
#                   whose process has gone as over, whatever its state says
#   pidStarted      when that process started, to tell it from a later one given the
#                   same number; null when unknown
#   state           working | needsPermission | waitingForInput | idle
#   since           when it entered that state, or for the two waiting on you, when it
#                   last asked: a second question in the same turn starts the wait again
#   turnStarted     when the latest prompt was sent; null before the first
#   updated         the latest event
#   prompt          the latest prompt's first line, plain, at most 120 characters
#   turnEnded       when the latest turn ended (Stop); null while it is under way
#   reply           the start of the last reply, plain, at most 160 characters, once
#                   the turn is over; "" while it is under way
#   workflows       the background workflows the latest event listed, with when each
#                   was first seen: [{id, name, description, status, firstSeen}]
#   tasks           the session's other background tasks the latest event listed, the
#                   same way: [{id, type, description, status, firstSeen}], type being
#                   Claude Code's word for each: subagent (an agent sent off in the
#                   background, the id its agent's), shell (a command left running),
#                   monitor, and so on. The command itself is never kept: where Claude
#                   Code describes a task by its command alone, the description is ""
#                   and a program field names the program it runs. A session started
#                   afresh or resumed, not compacted, starts with none. Islet reads how
#                   far the workflows and agents have got from the files Claude Code
#                   keeps for them
#   pending         the permissions asked and not yet seen answered, oldest first:
#                   [{toolUseId, agentId, tool, at, input, command}]. agentId is the
#                   agent that asked, "" for the session's own; toolUseId is "" where
#                   Claude Code does not say (it does not yet); input is a fingerprint
#                   of what the tool was asked to do, and command, for Bash, one of the
#                   command alone: the first 16 hex digits of its SHA-256, never the
#                   command itself, which lets Islet see it running
#   answered        when a permission asked was last seen answered; null before
#
# A permission asked is noted when asked, and the session marked as needing it only
# by the Notification Claude Code sends a few seconds later if it is still unanswered,
# so one answered at once never shows. Claude Code says nothing when it is answered;
# the first of these does: the tool's use, allowed, ending or failing; its agent
# stopping, or for the session's own, the turn ending or a prompt sent; or the agent
# carrying on with a tool started after the asking, which is all a denial leaves. Once
# none is left the session is working again, or idle if its turn has ended. Without the
# PermissionRequest hook nothing is noted, and the Notification's mark lasts the turn.
#
# It has to be quick, and must never fail the hook: Claude Code waits for it before
# sending a prompt, and adds anything it prints then to the prompt. So nothing is
# printed (but a dry run's banners), and it always exits 0; a PermissionRequest hook
# that prints nothing leaves the asking to Claude Code. A tool's use comes after every
# tool call of every agent, so for a session with nothing asked it ends at once.
export LC_ALL=en_US.UTF-8
kind="$1"
input="$(cat)"
[ -z "$ISLET_NOTIFY_DRY" ] && exec >/dev/null
dir="${ISLET_CLAUDE_STATE_DIR:-$HOME/Library/Application Support/Islet/Claude Code/Sessions}"
# A tool's use in a session with nothing asked ends here: its file's one line says so.
if [ "$kind" = tool ]; then
  [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"/]+)\" ]] || exit 0
  IFS= read -r line < "$dir/${BASH_REMATCH[1]}.json" 2>/dev/null
  [[ "$line" == *'"pending":[{'* ]] || exit 0
fi

# Every field used below, read in one go, each as `jq -r` would print it.
session="" cwd="" transcript="" stop_active="" message="" wants="" said="" task_name=""
logged="" agent="" tool="" tool_use="" duration="" given="" command="" clock=""
eval "$(printf '%s' "$input" | jq -r '
  def text: (if type == "string" then . else tojson end) | sub("\n+$"; "");
  def field(f): (try (f // "") catch "") | text;
  # When the hook ran, before it waits its turn for the session file below.
  @sh "clock=\(now)",
  @sh "session=\(field(.session_id))",
  @sh "cwd=\(field(.cwd))",
  @sh "transcript=\(field(.transcript_path))",
  @sh "stop_active=\(field(.stop_hook_active // false))",
  @sh "message=\(field(.last_assistant_message))",
  @sh "wants=\(field(.notification_type // .type))",
  @sh "said=\(field(.message // .title))",
  @sh "task_name=\(field(.task_subject // .task_description // .description // .name))",
  @sh "agent=\(field(.agent_id))",
  @sh "tool=\(field(.tool_name))",
  @sh "tool_use=\(field(.tool_use_id))",
  @sh "duration=\(try (.duration_ms | numbers | floor | tostring) catch "")",
  # What a tool was asked to do, keys in order, and a Bash command as it is: the two
  # fingerprints of a permission asked, and of a tool used to match it by.
  (if .tool_input != null then
     @sh "given=\(try (.tool_input | walk(if type == "object" then to_entries | sort_by(.key) | from_entries
                                          else . end) | tojson) catch "")",
     @sh "command=\(try (if .tool_name == "Bash" then .tool_input.command | strings else "" end) catch "")"
   else empty end),
  @sh "logged=\((try (. as $in | del(.background_tasks, .prompt, .tool_input, .tool_response, .permission_suggestions)
    + (if $in | has("prompt") then {prompt_chars: ($in.prompt | tostring | length)} else {} end)
    | tojson) catch "") | text)"
' 2>/dev/null)"

# Keeps the last 200 events other than agents stopping and tools used (one per agent
# inside a workflow, or per tool call, too many to be useful), to see what each event
# carries. A prompt is kept by its length alone: what you ask may hold things not meant
# for a log.
log="$HOME/.claude/hooks/islet-hook-log.jsonl"
note() { # kind json
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$2" >> "$log"
  tail -n 200 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
}
[ "$kind" != subagent ] && [ "$kind" != tool ] && note "$kind" "$logged"
# The first 16 hex digits of the SHA-256 of $1, or "" for "".
fingerprint() {
  [ -z "$1" ] && return
  local sum
  sum="$(printf '%s' "$1" | /usr/bin/openssl dgst -sha256 -r 2>/dev/null || printf '%s' "$1" | shasum -a 256)"
  printf '%s' "${sum:0:16}"
}
given="$(fingerprint "$given")"
command="$(fingerprint "$command")"

enc() { printf '%s' "$1" | jq -sRr @uri; }
# One line of plain text: list markers, markdown marks, extra spaces and newlines
# removed, cut at a word to at most $2 characters (90 unless said).
plain() {
  local text limit="${2:-90}"
  text="$(printf '%s' "$1" | sed -E 's/^[[:space:]]*([-*•]|[0-9]+\.)[[:space:]]+//' | tr '\n' ' ' \
    | sed -E 's/\*\*|__|`|^#+ *|\[|\]\([^)]*\)//g; s/  +/ /g; s/^ +//; s/ +$//')"
  if [ "${#text}" -le "$limit" ]; then printf '%s' "$text"; return; fi
  text="${text:0:$((limit - 1))}"
  printf '%s…' "${text% *}"
}
# The project: the git repository the session works in, or else its folder. The
# event's own folder, not CLAUDE_PROJECT_DIR, which is wherever the session was
# first started. Claude's scratch folders have no project name worth showing, nor
# have the home folder and "/", nor a repository of either (of settings, say).
[ -z "$cwd" ] && cwd="$CLAUDE_PROJECT_DIR"
project=""
case "${cwd%/}" in
  ""|"${HOME%/}"|*"/Library/Application Support/Claude/"*|/private/tmp/claude-*|/tmp/claude-*) ;;
  *) top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
     case "${top%/}" in ""|"${HOME%/}"|"$(cd "$HOME" 2>/dev/null && pwd -P)") top="$cwd" ;; esac
     project="$(basename "$top")" ;;
esac
# "Title · Islet", or the title alone where there is no project.
titled() { printf '%s' "$1${project:+ · $project}"; }
# Every banner here is news of the Claude Code activity, which shows each session: while
# it holds the island, a banner beside the notch takes its place rather than going in a
# row under it, where "Needs permission" would sit under its own raised hand. A card
# takes the island anyway, but one that comes while the island is open goes up as a
# compact one, and may still be up beside the notch once it closes.
show() { # title subtitle symbol tint [style]
  if [ -n "$ISLET_NOTIFY_DRY" ]; then echo "banner: $1 | $2 | $3 | $4 | ${5:-compact} | claudeCode"; return; fi
  open -g "islet://banner?title=$(enc "$1")&subtitle=$(enc "$2")&symbol=$3&tint=$4&style=${5:-compact}&activity=claudeCode" 2>/dev/null
}

case "$kind" in
  stop)
    [ "$stop_active" = "true" ] && exit 0
    if [ -z "$message" ] && [ -f "$transcript" ]; then
      message="$(tail -n 400 "$transcript" | jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' 2>/dev/null)"
    fi
    # A card, with room for the start of the reply: what was done, not just that it was.
    show "$(titled Done)" "$(plain "$message" 120)" checkmark.circle.fill green card
    ;;
  notification)
    message="$(plain "$said")"
    # Beside the notch there is room for a few words a side: the project and what
    # is wanted, "use Bash" rather than "Claude needs your permission to use Bash".
    wanted="$(printf '%s' "$message" | sed -E 's/^Claude needs your permission to //; s/^Claude //')"
    case "$wants" in
      permission_prompt) show "Needs permission" "${project:+$project · }$wanted" hand.raised.fill orange ;;
      idle_prompt)       show "Waiting for you" "${project:-Claude}" ellipsis.bubble.fill blue ;;
      agent_needs_input|elicitation_dialog|elicitation_url_dialog)
                         show "$(titled "Needs input")" "$message" questionmark.bubble.fill orange card ;;
      agent_completed)   show "$(titled "Agent finished")" "$message" checkmark.seal.fill purple card ;;
      auth_success|elicitation_complete|elicitation_response|quota_*) ;;
      *)                 show "$(titled Claude)" "$message" bell.fill blue card ;;
    esac
    ;;
  task)
    # TaskCompleted: an item on the task list marked done (not a background
    # workflow; those are caught below).
    name="$(plain "$task_name")"
    show "Task done" "${name:-$project}" checkmark.circle.fill purple
    ;;
esac


# The session's file. Agents stop in parallel, so one event at a time here: each
# reads what the last one wrote.
[ -z "$session" ] && exit 0
case "$session" in */*|.*) exit 0 ;; esac
[ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || exit 0
file="$dir/$session.json"
lock="$dir/.$session.lock"
ended="$dir/.$session.ended"
# Up to five seconds; a lock still there by then was left by a hook cut off by its
# timeout, and is taken over.
tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -ge 250 ] && break
  sleep 0.02
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

# The earlier script kept each session's workflows in a folder of its own. A session
# still running is moved over at its next event, so a workflow that finished while the
# scripts were swapped still gets its banner; the rest go once they are a day old.
legacy="$HOME/.claude/hooks/islet-workflows"
forget_old() {
  find "$dir" -maxdepth 1 \( -name '*.json' -o -name '.*.ended' -o -name '.*.tmp' \) -mmin +1440 \
    -delete 2>/dev/null
  if [ -d "$legacy" ]; then
    find "$legacy" -maxdepth 1 -name '*.json' -mmin +1440 -delete 2>/dev/null
    rmdir "$legacy" 2>/dev/null
  fi
}
case "$kind" in
  end)
    rm -f "$file" "$legacy/$session.json"
    : > "$ended" 2>/dev/null
    forget_old
    exit 0 ;;
  # A session resumed under the same id starts again.
  start|prompt) rm -f "$ended" 2>/dev/null ;;
  *) [ -e "$ended" ] && exit 0 ;;
esac

previous="$(cat "$file" 2>/dev/null)"
if [ -z "$previous" ] && [ -f "$legacy/$session.json" ]; then
  previous="$(jq -c 'if type == "array" then {workflows: .} else empty end' "$legacy/$session.json" 2>/dev/null)"
  rm -f "$legacy/$session.json"
  rmdir "$legacy" 2>/dev/null
fi

# Claude Code's process: the hook's parent, or that shell's parent where Claude Code ran
# the hook through one. Its number and age (ps's etime, [[dd-]hh:]mm:ss) are looked up
# when a session starts or is sent a prompt, or while its file has none.
pid="" age=""
find_claude() {
  local at="$PPID" line parent etime comm d h m s rest a b c
  for _ in 1 2 3 4; do
    line="$(ps -o ppid=,etime=,comm= -p "$at" 2>/dev/null)" || return
    read -r parent etime comm <<< "$line"
    case "${comm##*/}" in
      sh|bash|zsh|dash|ksh|fish|env|-sh|-bash|-zsh) at="$parent"; continue ;;
    esac
    [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -gt 1 ] || return
    pid="$at"
    [[ "$etime" =~ ^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$ ]] || return
    d=0 h=0 rest="$etime"
    case "$rest" in *-*) d="${rest%%-*}"; rest="${rest#*-}" ;; esac
    IFS=: read -r a b c <<< "$rest"
    if [ -n "$c" ]; then h="$a" m="$b" s="$c"; else m="$a" s="$b"; fi
    age=$(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
    return
  done
}
if [ "$kind" = start ] || [ "$kind" = prompt ] || ! [[ "$previous" == *'"pid":'[0-9]* ]]; then
  find_claude
fi

# Workflows. No hook fires when one finishes, but every event carries the session's
# background tasks, so one that was running last time and isn't now has finished.
# Noticed at the session's next event: one of the other workflows' agents
# stopping, or Claude finishing the turn the finish woke it for.
#
# The state. A question or a permission asked starts the wait afresh, even while the
# session is already waiting: Islet takes a message in the transcript after the asking
# as the answer, so the asking has to be the latest, not the turn's first. Claude Code
# tells a session's hooks it has sat waiting for a prompt (idle_prompt) only once its
# turn is over, so a session still marked working a minute into its turn, left so by
# an interruption that sent no Stop, is marked done.
#
# The permissions asked, as the header says, each timed by when its hook ran, not when
# it got the file, as is a tool's start: a hook kept waiting behind others must not
# make a tool used before an asking look started after it. A tool used matches the
# latest request with its id, or failing that, the same agent's asking for the same tool
# to do the same thing, and clears that agent's requests asked more than a second before
# it: those asked alongside it come within moments, and one asked earlier had been
# answered by the time it was asked, denied or answered at once and noted after its
# tool was used. A tool that matches none, started a couple of seconds or more after an
# asking, clears that agent's requests the same way, a denial leaving nothing else.
# A Notification that permission is needed, with nothing left asked and a request
# answered moments before, came for that one, late. The end of a turn clears the
# session's own requests; if the Notification that asked was for an agent's request,
# still there (asked a few seconds before it), the session still needs permission.
program='
  def clip($n): if length <= $n then . else (.[0:$n - 1] | sub(" [^ ]*$"; "")) + "…" end;
  def plain($n):
    split("\n") | map(sub("^[[:space:]]*([-*•]|[0-9]+\\.)[[:space:]]+"; "")) | join(" ")
    | gsub("\\*\\*|__|`|^#+ *|\\[|\\]\\([^)]*\\)"; "") | gsub("  +"; " ")
    | sub("^ +"; "") | sub(" +$"; "") | clip($n);
  def text: if type == "string" then . else "" end;
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
  . as $in
  | now as $now
  | (if ($prev | type) == "object" then $prev else {} end) as $p
  | ($p.workflows // [] | if type == "array" then . else [] end) as $was
  | (try ($in | has("background_tasks")) catch false) as $listed
  | (if $listed then [$in.background_tasks[]? | objects | select(.type == "workflow") | {id, name, description, status}]
     else null end) as $current
  | ($p.tasks // [] | if type == "array" then map(objects) else [] end) as $wasTasks
  | (if $listed then
       [$in.background_tasks[]? | objects | select(.type != "workflow" and (.id | type) == "string")
        | (.command // "" | text | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $command
        | (.description // "" | text) as $description
        | ($description | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $said
        | ($command != "" and ($said == "" or $said == $command)) as $bare
        | {id, type: (.type // "" | text), description: (if $bare then "" else $description | .[0:300] end),
           status: (.status // "" | text)}
          + (if $bare then {program: ($command | program)} else {} end)
        | . as $t | ($wasTasks | map(select(.id == $t.id)) | first) as $o
        | $t + {firstSeen: ($o.firstSeen // $now)}]
     elif $kind == "start" and (try $in.source catch null) != "compact" then []
     else $wasTasks end) as $tasks
  | (if $current == null then [] else
       [$was[] | select(.status == "running") | . as $w
        | ($current | map(select(.id == $w.id)) | first) as $n
        | select($n == null or $n.status != "running")
        | {id, name, description, status} + {status: ($n.status // "completed")}]
     end) as $finished
  | (if $current == null then $was else
       [$current[] | . as $t | ($was | map(select(.id == $t.id)) | first) as $o
        | $t + {firstSeen: ($o.firstSeen // $now)}]
     end) as $workflows
  | ($p.state // "idle") as $old
  | ($p.pending // [] | if type == "array" then map(objects) else [] end) as $wasPending
  | (try ($clock | tonumber) catch $now) as $ran
  # When a request was asked.
  | def asked: .at // $now | if type == "number" then . else $now end;
    (if $duration == "" then null else $ran - ($duration | tonumber) / 1000 end) as $toolStarted
  | (if $kind == "permission" then
       $wasPending + [{toolUseId: $toolUse, agentId: $agent, tool: $tool, at: $ran, input: $given,
                       command: $command}] | .[-20:]
     elif $kind == "tool" then
       ($wasPending | map((.toolUseId // "") as $id
          | if $id != "" then $id == $toolUse
            else (.agentId // "") == $agent and .tool == $tool
                 and ((.input // "") != "" and .input == $given or (.command // "") != "" and .command == $command)
            end) | rindex(true)) as $used
       | (if $used != null then ($wasPending[$used] | asked) - 1
          elif $toolStarted != null then $toolStarted - 2
          else null end) as $before
       | [$wasPending | to_entries[]
          | select(.key != $used)
          | .value
          | select((.agentId // "") != $agent or $before == null or asked >= $before)]
     elif $kind == "subagent" then
       (if $agent == "" then $wasPending else [$wasPending[] | select((.agentId // "") != $agent)] end)
     elif $kind == "stop" or $kind == "prompt" then [$wasPending[] | select((.agentId // "") != "")]
     elif $kind == "start" and (try $in.source catch null) != "compact" then []
     else $wasPending end) as $pending
  | ($kind != "permission" and ($pending | length) < ($wasPending | length)) as $answered
  | (if $kind == "stop" then $now elif $kind == "prompt" then null
     elif $kind == "start" and (try $in.source catch null) != "compact" then null
     else $p.turnEnded end) as $turnEnded
  | ($kind == "stop" and $old == "needsPermission"
     and any($pending[]; asked <= ($p.since // 0 | if type == "number" then . else 0 end) - 3)) as $stillAsking
  | ((try $in.notification_type catch null) // (try $in.type catch null) // "") as $wants
  | ($kind == "notification" and $wants == "permission_prompt" and ($pending | length) == 0
     and $now - ($p.answered // 0 | if type == "number" then . else 0 end) < 10) as $late
  | ($kind == "notification" and ($wants == "permission_prompt" or $wants == "agent_needs_input"
      or $wants == "elicitation_dialog" or $wants == "elicitation_url_dialog") and ($late | not)) as $asks
  | (if $kind == "prompt" then "working"
     elif $kind == "stop" then (if $stillAsking then $old else "idle" end)
     elif $kind == "start" then (if (try $in.source catch null) == "compact" then $old else "idle" end)
     elif ($kind == "tool" or $kind == "subagent") and $answered and ($pending | length) == 0
          and $old == "needsPermission" then (if $turnEnded == null then "working" else "idle" end)
     elif $kind == "notification" then
       (if $late then $old
        elif $wants == "permission_prompt" then "needsPermission"
        elif $asks then "waitingForInput"
        elif ($wants == "elicitation_complete" or $wants == "elicitation_response")
              and $old == "waitingForInput" then "working"
        elif $wants == "idle_prompt" and $old == "working"
              and $now - ($p.since // $now | if type == "number" then . else $now end) > 60 then "idle"
        else $old end)
     else $old end) as $state
  | {
      version: 1,
      sessionId: $session,
      project: $project,
      cwd: $cwd,
      transcriptPath: ((try $in.transcript_path catch null) | text
                       | if . == "" then ($p.transcriptPath // "") else . end),
      hostApp: (if $host == "" then ($p.hostApp // "") else $host end),
      pid: (if $pid != "" then ($pid | tonumber) else ($p.pid // null) end),
      pidStarted: (if $pid == "" then ($p.pidStarted // null)
                   elif $age != "" then ($now - ($age | tonumber) | floor)
                   else null end),
      state: $state,
      # Past the reply just ended, which answers nothing an agent asked.
      since: (if $asks or $kind == "prompt" or $state != $old or $p.since == null or $stillAsking then $now
              else $p.since end),
      turnStarted: (if $kind == "prompt" then $now else $p.turnStarted end),
      turnEnded: $turnEnded,
      updated: $now,
      # Past any tags Claude Code or a host put before what the person wrote
      # (<system-reminder>…</system-reminder>, say: their names have a - or _, which
      # HTML tags lack), and any line such a tag alone. A prompt of tags alone was not
      # written by the person (Claude Code sends a <task-notification> when a background
      # agent finishes), and leaves theirs.
      prompt: (if $kind == "prompt"
               then ((try $in.prompt catch null) | text
                     | sub("^(\\s*<(?<t>[A-Za-z]\\w*[-_][\\w-]*)(\\s[^>]*)?>(?s:.*?)</\\k<t>>)+"; "")
                     | split("\n")
                     | map(select(test("\\S") and (test("^\\s*</?[A-Za-z]\\w*[-_][\\w-]*(\\s[^>]*)?/?>\\s*$") | not)))
                     | (first // "") | plain(120)
                     | if . == "" then ($p.prompt // "") else . end)
               else ($p.prompt // "") end),
      reply: (if $kind == "stop" then ($reply | plain(160))
              elif $state != "idle" and $turnEnded == null then ""
              else ($p.reply // "") end),
      workflows: $workflows,
      tasks: $tasks,
      pending: $pending,
      answered: (if $answered then $now else ($p.answered // null) end)
    },
    $finished'
[ "$kind" = stop ] || message=""
update() { # previous
  printf '%s' "$input" | jq -c --argjson prev "${1:-null}" --arg kind "$kind" --arg session "$session" \
    --arg project "$project" --arg cwd "$cwd" --arg host "${__CFBundleIdentifier:-}" \
    --arg pid "$pid" --arg age "$age" --arg reply "$message" --arg agent "$agent" --arg tool "$tool" \
    --arg toolUse "$tool_use" --arg duration "$duration" --arg given "$given" --arg command "$command" \
    --arg clock "$clock" \
    "$program" 2>/dev/null
}
out="$(update "$previous")"
# A file that is not JSON (edited by hand, say) is started afresh.
[ -z "$out" ] && [ -n "$previous" ] && out="$(update null)"
state="${out%%$'\n'*}"
finished="${out#*$'\n'}"
[ "$finished" = "$out" ] && finished="[]"
if [ -n "$state" ]; then
  tmp="$dir/.$session.$$.tmp"
  { printf '%s\n' "$state" > "$tmp" && mv -f "$tmp" "$file"; } 2>/dev/null || rm -f "$tmp"
fi
[ "$kind" = start ] && forget_old


[ "${finished:-[]}" = "[]" ] && exit 0
count="$(printf '%s' "$finished" | jq 'length' 2>/dev/null)"
if [ "${count:-0}" -gt 0 ]; then
  note workflow "$finished"
  failed="$(printf '%s' "$finished" | jq '[.[] | select(.status | test("fail|error|kill|stop"))] | length')"
  if [ "$count" -eq 1 ]; then
    name="$(printf '%s' "$finished" | jq -r '.[0].name // "workflow"')"
    what="$(printf '%s' "$finished" | jq -r '.[0].description // ""')"
    subtitle="$(plain "$name${what:+ — $what}" 120)"
    if [ "$failed" -gt 0 ]; then
      show "$(titled "Workflow failed")" "$subtitle" xmark.octagon.fill red card
    else
      show "$(titled "Workflow finished")" "$subtitle" checkmark.seal.fill purple card
    fi
  else
    names="$(printf '%s' "$finished" | jq -r '[.[].name] | join(", ")')"
    if [ "$failed" -gt 0 ]; then
      show "$(titled "$count workflows ended, $failed failed")" "$(plain "$names" 120)" xmark.octagon.fill red card
    else
      show "$(titled "$count workflows finished")" "$(plain "$names" 120)" checkmark.seal.fill purple card
    fi
  fi
fi
exit 0
