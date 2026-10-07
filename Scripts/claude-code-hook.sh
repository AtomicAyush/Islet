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
#   hostSession     in the Claude app, the app's own id for the session (local_ and a
#                   UUID), which it hands its hooks as CLAUDE_CODE_HOST_SESSION_ID and
#                   which its link to the session takes; "" elsewhere
#   tty             the terminal Claude Code's process runs in, as ttys003, looked up
#                   with its process: Terminal and iTerm find the tab by it; "" when it
#                   has none
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
# Approving from the island: once a permission asked is noted, and while Islet is
# running and willing, the request is offered to Islet, which shows it in the island
# with Allow, Deny and Answer in the app. The hook waits for Islet's answer, checks it
# is signed with the approvals key whose public half sits beside this script
# (islet-approvals.pub, written by Islet only when you click for it) and was given for
# exactly this request, and hands Claude Code the decision. Anything else, including no
# answer in time, prints nothing, and Claude Code asks in the app as it always has.
# Under the Claude app both ask at once and the first answer wins; elsewhere the hook
# waits only briefly, and not at all while you are away or busy elsewhere.
# `permission --timeout N` names the hook line's timeout, 10 seconds where it is not
# given. The command itself is written only into the request, for Islet to show, and
# the request is deleted as the hook ends.
#
# It has to be quick, and must never fail the hook: Claude Code waits for it before
# sending a prompt, and adds anything it prints then to the prompt. So nothing is
# printed (but a dry run's banners), except the permission kind's answer, and it always
# exits 0; a PermissionRequest hook that prints nothing leaves the asking to Claude
# Code. A tool's use comes after every tool call of every agent, so for a session with
# nothing asked it ends at once.
export LC_ALL=en_US.UTF-8
# The tools from fixed places, not from whatever PATH Claude Code was started with.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
kind="$1"
input="$(cat)"
# Only the permission kind may answer, on what was stdout; nothing else reaches it.
if [ "$kind" = permission ]; then exec 3>&1; trap 'exit 0' TERM INT HUP; else exec 3>&-; fi
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
# compact one, and may still be up beside the notch once it closes. Each names its
# session, so a click on it opens the session where Islet knows how; the Done card
# says it is one (event=done), for Islet to leave down while the session is on screen.
banner_session=""
[[ "$session" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] && banner_session="$session"
show() { # title subtitle symbol tint [style] [event]
  if [ -n "$ISLET_NOTIFY_DRY" ]; then echo "banner: $1 | $2 | $3 | $4 | ${5:-compact} | claudeCode"; return; fi
  open -g "islet://banner?title=$(enc "$1")&subtitle=$(enc "$2")&symbol=$3&tint=$4&style=${5:-compact}&activity=claudeCode${banner_session:+&session=$banner_session}${6:+&event=$6}" 2>/dev/null
}

# The agent this script speaks for, to the approval block below.
approval_agent=claude
# --- islet approval: begin ---
# Offering a permission asked to Islet, as the header says. Islet's folder,
#   ~/Library/Application Support/Islet/Approvals   (0700, made by Islet only)
#     presence.json      Islet is running, and what it will be asked
#     Requests/<id>.json written here, never rewritten, deleted as the hook ends
#     Answers/<id>.json  written by Islet, signed, never overwritten
#     Passed/<session>/  ChatGPT's requests left to the app, each by the first 16 hex
#                        digits of its digest and nothing more
# The same in both of Islet's hook scripts. The script sets approval_agent (claude or
# chatgpt), and session, project and approval_pending (the fingerprint the session's
# file notes the request by, or "") before asking. The home folder comes from the
# directory service and the tools from fixed places, not from the environment the
# agent hands the hook. Only the harness's copy of this script reads the test settings
# below.
approval_test_overrides=0
approval_allow='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
approval_deny='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Islet by the person using this Mac. Don'"'"'t retry it or find another way to do it; ask them how to go on."}}}'
# Hosts whose own prompt runs alongside the hook and is withdrawn by its answer.
approval_listed_hosts=" com.anthropic.claudefordesktop "
approval_jq=""
for approval_tool in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do
  [ -x "$approval_tool" ] && { approval_jq="$approval_tool"; break; }
done
approval_overridden() { [ "$approval_test_overrides" = 1 ] && [ -n "$1" ]; }
approval_home() {
  if approval_overridden "$ISLET_APPROVAL_HOME"; then printf '%s' "$ISLET_APPROVAL_HOME"; return; fi
  local line
  line="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null)" || return 1
  line="${line#NFSHomeDirectory: }"
  [ "${line:0:1}" = / ] && printf '%s' "$line"
}
# A process number as a file may give one: decimal, 2 to 99999.
approval_int() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -ge 2 ]; }
# When process $1 started, in seconds since 1970.
approval_started() {
  local s
  s="$(LC_ALL=C /bin/ps -o lstart= -p "$1" 2>/dev/null)" || return 1
  s="${s%"${s##*[![:space:]]}"}"
  LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$s" +%s 2>/dev/null
}
# The bytes of file $1, if it is a regular file of yours, not a link, at most $2 bytes,
# with none of the mode bits $3 set (077 unless given). Opened without following a link
# or waiting on a pipe, and checked on what was opened.
approval_read() {
  /usr/bin/perl -e '
    use Fcntl; my ($path, $most, $mask) = @ARGV;
    sysopen(my $f, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
    my @s = stat($f);
    exit 1 unless @s && -f _ && $s[4] == $< && ($s[2] & oct($mask)) == 0 && $s[7] <= $most;
    local $/; my $d = <$f> // ""; exit 1 if length($d) > $most; print $d;' "$1" "$2" "${3:-077}" 2>/dev/null
}
# A folder of yours, not a link, that only you can use.
approval_dir_ok() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null)" = "$(/usr/bin/id -u) 700" ]
}
# The approvals key, as PEM, from islet-approvals.pub beside this script: found from the
# script's own path, and used only when it and its folder are yours and no one else can
# write to them, since whoever can change it could change this script too.
approval_key() {
  local here key
  here="$(CDPATH='' cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
  [ -f "$here/islet-approvals.pub" ] && [ ! -L "$here/islet-approvals.pub" ] || return 1
  [ "$(/usr/bin/stat -f '%u' "$here" 2>/dev/null)" = "$(/usr/bin/id -u)" ] || return 1
  (( (8#$(/usr/bin/stat -f '%Lp' "$here") & 8#022) == 0 )) || return 1
  key="$(approval_read "$here/islet-approvals.pub" 200 022)" || return 1
  key="${key%$'\n'}"
  # A P-256 public key, DER SubjectPublicKeyInfo: 91 bytes, 124 base64 characters.
  [[ "$key" =~ ^MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE[A-Za-z0-9+/]{86}==$ ]] || return 1
  printf -- '-----BEGIN PUBLIC KEY-----\n%s\n%s\n-----END PUBLIC KEY-----\n' "${key:0:64}" "${key:64}"
}
# Islet's presence, if it is valid: a file of yours naming a running process that
# started when it says. Sets approval_presence and approval_islet.
approval_presence_ok() {
  local text pid started start
  text="$(approval_read "$approval_dir/presence.json" 4096)" || return 1
  read -r pid started <<< "$(printf '%s' "$text" | "$approval_jq" -r '
    [(.pid | if type == "number" and . == floor then tostring else "-" end),
     (.started | if type == "number" then floor | tostring else "-" end)] | join(" ")' 2>/dev/null)"
  approval_int "$pid" && [[ "$started" =~ ^[0-9]{1,12}$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  start="$(approval_started "$pid")" || return 1
  (( start - started <= 2 && started - start <= 2 )) || return 1
  approval_presence="$text" approval_islet="$pid"
}
# Seconds since the keyboard, pointer or trackpad was last used.
approval_idle_seconds() {
  if approval_overridden "$ISLET_APPROVAL_IDLE"; then printf '%s' "$ISLET_APPROVAL_IDLE"; return; fi
  /usr/sbin/ioreg -c IOHIDSystem -d 4 2>/dev/null | /usr/bin/awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'
}
# The agent's process (the hook's parent past any shell), whether it was started to
# ask through its host (--permission-prompt-tool stdio), and the app it runs in, past
# Claude Code's own processes and the Claude app's disclaimer helper. Sets
# approval_agent_pid, approval_stdio, approval_host_id and approval_host_name.
approval_host() {
  local at="$PPID" line parent comm args app _
  approval_agent_pid="" approval_stdio=0 approval_host_id="" approval_host_name=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    approval_int "$at" || return 0
    line="$(LC_ALL=C /bin/ps -o ppid=,comm= -p "$at" 2>/dev/null)" || return 0
    read -r parent comm <<< "$line"
    case "${comm##*/}" in
      sh|bash|zsh|dash|ksh|fish|env|login|-sh|-bash|-zsh) at="$parent"; continue ;;
    esac
    if [ -z "$approval_agent_pid" ]; then
      approval_agent_pid="$at"
      args="$(LC_ALL=C /bin/ps -ww -o args= -p "$at" 2>/dev/null)"
      case " $args " in *" --permission-prompt-tool stdio "*|*" --permission-prompt-tool=stdio "*) approval_stdio=1 ;; esac
    else
      case "$comm" in
        */claude-code/*|*/disclaimer) ;;
        /*.app/Contents/*)
          app="${comm%%.app/Contents/*}.app"
          approval_host_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)"
          approval_host_name="${app##*/}"; approval_host_name="${approval_host_name%.app}"
          return 0 ;;
      esac
    fi
    at="$parent"
  done
}
# Whether a card is up for session $1: a request of its whose hook is still running.
# The Notification that permission is needed then puts up no banner.
approval_live() {
  local home dir file text sid pid
  [ -n "$approval_jq" ] && home="$(approval_home)" || return 1
  dir="$home/Library/Application Support/Islet/Approvals/Requests"
  for file in "$dir"/*.json; do
    [[ "${file##*/}" =~ ^[0-9a-f]{32}\.json$ ]] || continue
    text="$(approval_read "$file" 300000)" || continue
    read -r sid pid <<< "$(printf '%s' "$text" | "$approval_jq" -r '
      [(.sessionId | strings), (.hookPid | numbers | tostring)] | join(" ")' 2>/dev/null)"
    [ -n "$sid" ] && [ "$sid" = "$1" ] && approval_int "$pid" && kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}
# Removes this hook's request and answer, whatever ends it.
approval_files=()
approval_cleanup() { [ "${#approval_files[@]}" -gt 0 ] && /bin/rm -f "${approval_files[@]}" 2>/dev/null; }
# Islet's answer in $1, if it is one this hook can take: its own, for exactly what was
# shown, in time, and signed with the approvals key. Sets approval_decision to allow or
# deny; anything else leaves it pass.
approval_verify() {
  local text id digest decision answered sig pem now
  text="$(approval_read "$1" 1024)" || return 0
  IFS=$'\t' read -r id digest decision answered sig <<< "$(printf '%s' "$text" | "$approval_jq" -r '
    def plain: if type == "string" and (test("[\t\n\r]") | not) and . != "" then . else "-" end;
    [(.id | plain), (.digest | plain), (.decision | plain),
     (.answered | if type == "number" and . == floor then tostring else "-" end), (.sig | plain)]
    | join("\t")' 2>/dev/null)"
  [ "$id" = "$approval_id" ] && [ "$digest" = "$approval_digest" ] || return 0
  case "$decision" in allow|deny) ;; *) return 0 ;; esac
  [[ "$answered" =~ ^[0-9]{1,12}$ ]] || return 0
  now="$(/bin/date +%s)"
  (( approval_created <= answered && answered <= approval_deadline && now <= approval_deadline )) || return 0
  [[ "$sig" =~ ^[A-Za-z0-9+/]{6,96}={0,2}$ ]] && [ "${#sig}" -ge 8 ] && [ "${#sig}" -le 96 ] || return 0
  pem="$(approval_key)" || return 0
  printf '%s' "v1|$id|$digest|$decision|$answered" | /usr/bin/openssl dgst -sha256 -verify <(printf '%s\n' "$pem") \
    -signature <(printf '%s' "$sig" | /usr/bin/base64 -D 2>/dev/null) >/dev/null 2>&1 || return 0
  approval_decision="$decision"
}
# Whether file $1 has Codex answer what it asks with its own reviewer: an
# approvals_reviewer in it other than "user".
approval_reviewer_set() {
  [ -f "$1" ] && /usr/bin/grep -E '^[[:space:]]*approvals_reviewer[[:space:]]*=' "$1" 2>/dev/null \
    | /usr/bin/grep -Evq '=[[:space:]]*"user"[[:space:]]*(#.*)?$'
}
# Whether Codex's reviewer, not the person, answers what it asks, so that no card goes
# ahead of it: by Codex's settings, or a project's from the agent's folder up to the
# home folder ($1), the agent's folder being $2.
approval_reviewed() {
  local codex="$CODEX_HOME" at="$2"
  [ "${codex:0:1}" = / ] || codex="$1/.codex"
  approval_reviewer_set "$codex/config.toml" && return 0
  while [ -n "$at" ] && [ "$at" != / ] && [ "$at" != "$1" ]; do
    approval_reviewer_set "$at/.codex/config.toml" && return 0
    at="${at%/*}"
  done
  return 1
}
# The policy, and how long to wait, from the host found by ancestry and the hook's
# arguments ($2 --timeout, $3 the hook line's timeout, 10 where not given). A blocking
# wait, or one on a line that gives its timeout, ends two seconds before that timeout,
# counted from the hook's start (approval_ends, in $SECONDS).
approval_policy_of() {
  local limit=10
  [ "$2" = --timeout ] && [[ "$3" =~ ^[1-9][0-9]{0,3}$ ]] && limit="$3"
  approval_host
  if [ "$approval_agent" = claude ] && [ "$approval_stdio" = 1 ]; then
    approval_policy=concurrent approval_wait=540 approval_ends=99999
    [ "$2" = --timeout ] && approval_ends=$((limit - 2))
    case "$approval_listed_hosts" in *" $approval_host_id "*) approval_allows=true ;; *) approval_allows=false ;; esac
  else
    approval_policy=blocking approval_allows=true approval_wait=540 approval_ends=$((limit - 2))
  fi
  (( approval_ends - SECONDS < approval_wait )) && approval_wait=$((approval_ends - SECONDS))
}
# Whether to offer the permission asked to Islet, by every gate the header names, the
# cheap ones first; returns 1 to leave it to the app. Sets the tool, the call and its
# digest, the policy, how long to wait and where Islet's folder is; for ChatGPT, also
# approval_mark, the Passed mark to leave should the app be left to ask.
approval_offer() {
  # Nothing from the environment reaches the tools that check a request or an answer:
  # not a library jq would load from $HOME, nor a Perl or OpenSSL setting.
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty
  unset PERL5OPT PERL5LIB PERLLIB PERL5DB OPENSSL_CONF CDPATH
  approval_mark=""
  [ -n "$approval_jq" ] || return 1
  local home tool call bytes
  read -r tool <<< "$(printf '%s' "$input" | "$approval_jq" -r '.tool_name | strings' 2>/dev/null)"
  case "$approval_agent:$tool" in
    claude:Bash|claude:Write|claude:Edit|claude:MultiEdit|claude:NotebookEdit|claude:WebFetch|claude:WebSearch) ;;
    chatgpt:Bash|chatgpt:apply_patch|chatgpt:Edit|chatgpt:Write) ;;
    claude:mcp__*|chatgpt:mcp__*) ;;
    *) return 1 ;;
  esac
  approval_tool="$tool"
  # A dry run says what would be offered, and goes no further.
  if [ -n "$ISLET_NOTIFY_DRY" ]; then
    approval_policy_of "$@"
    echo "approval: $approval_policy $tool wait=$approval_wait" >&2
    return 1
  fi
  [ -n "$session" ] && home="$(approval_home)" || return 1
  approval_dir="$home/Library/Application Support/Islet/Approvals"
  approval_dir_ok "$approval_dir" && approval_dir_ok "$approval_dir/Requests" \
    && approval_dir_ok "$approval_dir/Answers" || return 1
  approval_policy_of "$@"
  call="$(printf '%s' "$input" | "$approval_jq" -cS '{input: .tool_input, tool: .tool_name}' 2>/dev/null)"
  bytes="$(LC_ALL=C; printf '%s' "${#call}")"
  [ -n "$call" ] && (( bytes <= 262144 )) || return 1
  approval_call="$call"
  approval_digest="$(printf '%s' "$call" | /usr/bin/openssl dgst -sha256 -r 2>/dev/null)"
  approval_digest="${approval_digest:0:64}"
  [[ "$approval_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  # ChatGPT checks what was approved for the session only after this hook: a request
  # left to it before goes to it again at once.
  if [ "$approval_agent" = chatgpt ] && [[ "$session" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
    && approval_dir_ok "$approval_dir/Passed"; then
    approval_mark="$approval_dir/Passed/$session/${approval_digest:0:16}"
    [ -e "$approval_mark" ] && return 1
  fi
  # Not for an agent working in your home folder, or in or around Islet's.
  local cwd here
  read -r cwd <<< "$(printf '%s' "$input" | "$approval_jq" -r '.cwd | strings' 2>/dev/null)"
  [ -n "$cwd" ] && here="$(CDPATH='' cd -- "$cwd" 2>/dev/null && pwd -P)" || return 1
  case "${here%/}/" in "${home%/}/"|"$approval_dir/"*) return 1 ;; esac
  case "$approval_dir/" in "${here%/}/"*) return 1 ;; esac
  approval_here="$here"
  approval_presence_ok || return 1
  approval_key >/dev/null || return 1
  local accepting locked presenting captured visible frontmost waits
  IFS=$'\t' read -r accepting locked presenting captured visible frontmost waits <<< "$(printf '%s' "$approval_presence" \
    | "$approval_jq" -r --arg agent "$approval_agent" '
      def flag: if . == true then "1" else "0" end;
      [(.accepting[$agent] | flag), (.locked | flag), (.presenting | flag), (.captured | flag), (.visible | flag),
       (.frontmost | if type == "string" and (test("[\t\n]") | not) and . != "" then . else "-" end),
       (.wait[if $agent == "chatgpt" then "chatgpt" else "terminal" end]
        | if type == "number" and . >= 1 and . <= 600 then floor | tostring else "30" end)] | join("\t")' 2>/dev/null)"
  [ "$accepting" = 1 ] || return 1
  if [ "$approval_policy" = blocking ]; then
    # Only while you are here to answer, and not already in the app that would ask.
    [ "$locked$presenting$captured$visible" = 0001 ] || return 1
    [ -n "$approval_host_id" ] && [ "$frontmost" = "$approval_host_id" ] && return 1
    [ "$(approval_idle_seconds)" -lt 120 ] 2>/dev/null || return 1
    (( waits < approval_wait )) && approval_wait="$waits"
  fi
  [ "$approval_agent" = chatgpt ] && approval_reviewed "$home" "$here" && return 1
  (( approval_wait >= 1 )) || return 1
  return 0
}
# Offers the request approval_offer allowed to Islet and waits for its answer, setting
# approval_decision, and approval_answered when Islet answered at all. Run in the
# hook's own shell, with fd 3 closed, so a stop ends it at once and nothing it starts
# can answer.
approval_ask() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty
  approval_decision=pass approval_answered=0
  local now hook_started
  approval_id="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
  [[ "$approval_id" =~ ^[0-9a-f]{32}$ ]] || return 0
  hook_started="$(approval_started $$)" || return 0
  # Whatever recording took since comes off the wait.
  local wait="$approval_wait"
  (( approval_ends - SECONDS < wait )) && wait=$((approval_ends - SECONDS))
  (( wait >= 1 )) || return 0
  now="$(/bin/date +%s)"
  approval_created="$now" approval_deadline=$((now + wait))
  local request="$approval_dir/Requests/$approval_id.json" temp="$approval_dir/Requests/.$approval_id.tmp"
  approval_files=("$temp" "$request" "$approval_dir/Answers/$approval_id.json")
  trap approval_cleanup EXIT
  trap 'exit 0' TERM INT HUP
  ( umask 077; set -C
    printf '%s' "$input" | "$approval_jq" -c \
      --arg id "$approval_id" --arg agent "$approval_agent" --arg policy "$approval_policy" \
      --argjson offer "$approval_allows" --arg cwd "$approval_here" --arg project "$project" \
      --arg hostApp "$approval_host_id" --arg hostName "$approval_host_name" \
      --arg hookPid "$$" --arg hookStarted "$hook_started" --arg agentPid "${approval_agent_pid:-0}" \
      --arg created "$now" --arg deadline "$approval_deadline" --arg call "$approval_call" \
      --arg digest "$approval_digest" --arg pendingInput "$approval_pending" '
      def text: if type == "string" then . else "" end;
      {version: 1, id: $id, agent: $agent, policy: $policy, allowOffered: $offer,
       sessionId: (.session_id | text), agentId: (.agent_id | text), agentType: (.agent_type | text),
       promptId: (.prompt_id | text), turnId: (.turn_id | text), cwd: $cwd, project: $project,
       hostApp: $hostApp, hostName: $hostName, transcriptPath: (.transcript_path | text),
       permissionMode: (.permission_mode | text), hookPid: ($hookPid | tonumber),
       hookStarted: ($hookStarted | tonumber), agentPid: ($agentPid | tonumber), created: ($created | tonumber),
       deadline: ($deadline | tonumber), tool: (.tool_name | text), call: $call, digest: $digest,
       pendingInput: $pendingInput}' > "$temp" ) 2>/dev/null || return 0
  /bin/mv -n "$temp" "$request" 2>/dev/null && [ ! -e "$temp" ] || return 0
  # Every quarter of a second, Islet's answer; every two, whether Islet is still there.
  local answer="$approval_dir/Answers/$approval_id.json" ticks=0 until=$((SECONDS + wait))
  while :; do
    if [ -e "$answer" ] || [ -L "$answer" ]; then
      approval_answered=1
      approval_verify "$answer"
      return 0
    fi
    (( SECONDS >= until )) && return 0
    ticks=$((ticks + 1))
    if (( ticks % 8 == 0 )); then
      kill -0 "$approval_islet" 2>/dev/null || return 0
      (( $(/bin/date +%s) >= approval_deadline )) && return 0
    fi
    /bin/sleep 0.25
  done
}
# Leaves ChatGPT's mark that this request went to the app, in a folder of the
# session's made here, only you able to use either.
approval_leave() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin
  [ -n "$approval_mark" ] || return 0
  local folder="${approval_mark%/*}"
  [ -d "$folder" ] || /bin/mkdir -m 700 "$folder" 2>/dev/null
  approval_dir_ok "$folder" || return 0
  ( umask 077; set -C; : > "$approval_mark" ) 2>/dev/null
  return 0
}
# --- islet approval: end ---

case "$kind" in
  stop)
    [ "$stop_active" = "true" ] && exit 0
    if [ -z "$message" ] && [ -f "$transcript" ]; then
      message="$(tail -n 400 "$transcript" | jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' 2>/dev/null)"
    fi
    # A card, with room for the start of the reply: what was done, not just that it was.
    show "$(titled Done)" "$(plain "$message" 120)" checkmark.circle.fill green card done
    ;;
  notification)
    message="$(plain "$said")"
    # Beside the notch there is room for a few words a side: the project and what
    # is wanted, "use Bash" rather than "Claude needs your permission to use Bash".
    wanted="$(printf '%s' "$message" | sed -E 's/^Claude needs your permission to //; s/^Claude //')"
    case "$wants" in
      # Not while a card in the island already asks.
      permission_prompt) approval_live "$session" || show "Needs permission" "${project:+$project · }$wanted" hand.raised.fill orange ;;
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
pid="" age="" tty=""
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
    tty="$(ps -o tty= -p "$at" 2>/dev/null)"
    tty="${tty//[[:space:]]/}"
    [[ "$tty" =~ ^ttys[0-9]{1,4}$ ]] || tty=""
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
      hostSession: (if $hostSession == "" then ($p.hostSession // "") else $hostSession end),
      # Looked up with the process, and as it is then: a session resumed in the Claude
      # app has none.
      tty: (if $pid == "" then ($p.tty // "") else $tty end),
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
# The Claude app's id for the session, in the one shape its link takes.
host_session=""
[[ "${CLAUDE_CODE_HOST_SESSION_ID:-}" =~ ^local_[A-Za-z0-9-]{1,64}$ ]] && host_session="$CLAUDE_CODE_HOST_SESSION_ID"
update() { # previous
  printf '%s' "$input" | jq -c --argjson prev "${1:-null}" --arg kind "$kind" --arg session "$session" \
    --arg project "$project" --arg cwd "$cwd" --arg host "${__CFBundleIdentifier:-}" \
    --arg hostSession "$host_session" --arg tty "$tty" \
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
# A permission asked waits for Islet's answer below, the session's file free meanwhile.
[ "$kind" = permission ] && { rmdir "$lock" 2>/dev/null; trap - EXIT; }
[ "$kind" = start ] && forget_old


count=0
[ "${finished:-[]}" = "[]" ] || count="$(printf '%s' "$finished" | jq 'length' 2>/dev/null)"
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
if [ "$kind" = permission ]; then
  approval_pending="$given" approval_decision=pass
  approval_offer "$@" 3>&- && approval_ask "$@" 3>&-
  # The one answer this script ever prints.
  case "$approval_decision" in allow) approval_out="$approval_allow" ;; deny) approval_out="$approval_deny" ;; *) approval_out="" ;; esac
  [ -n "$approval_out" ] && printf '%s\n' "$approval_out" >&3
fi
exit 0
