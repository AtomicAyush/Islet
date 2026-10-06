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
#                   (running or done), firstSeen, ended, step, steps, planDone,
#                   planTotal, seen}], planDone and planTotal how far its own plan has
#                   got, once it has one, and seen when it last started or used a tool;
#                   those done are kept till the next prompt
#   pending         agents asked for and not yet started, by the name they were given,
#                   and where a spawn's end said which it started, its id: [{name, t, id}]
#   doneIds         the latest tools to finish, since their events can arrive out of
#                   order
#   endedAgents     the latest agents to stop, so that a tool of theirs finishing after
#                   them does not bring them back
#   codexHome       the folder Codex keeps its own files in ($CODEX_HOME, or ~/.codex),
#                   where Islet reads the thread's goal and queued prompts, read-only;
#                   "" when not a full path
#   history         the turn's steps so far, oldest first, a run of the same one counted
#                   once: [{kind, name, count, n}], as a step's, at most 12
#   shells          the chat's commands left running, after another tool started or the
#                   turn stopped: [{id, name, started, since, asked}], name the program,
#                   since when it was left, and asked whether permission was asked for it,
#                   for one declined never ran (Islet lists it only once the rollout says
#                   it is running); at most 8, those asked for let go first. A turn's end
#                   leaves them running; their own end, an interrupt or a new session ends
#                   them
#   turns           the latest turns seen, so that a tool from one Codex started itself
#                   (carrying on towards a goal, with no prompt) is told from a late one
# A field is only ever added: the version goes up only if one comes to mean something
# else.
# Never kept: a command (only the program it runs), a patch or a file's folder, what a
# tool was given or gave back, what was typed into a command left running, a question,
# what a permission is asked for, an agent's message or reply, its plan's steps, the
# model, or a plain chat's folder.
#
# Approving from the island: while Islet is running and willing, and you are at the
# Mac and not in the app that would ask, a permission asked is offered to Islet, which
# shows it in the island with Allow, Deny and Answer in ChatGPT. Codex asks in the app
# only once this hook is done, so the hook waits only briefly: Islet's setting, but
# never past two seconds before the hook line's timeout, which `permission --timeout N`
# names (10 seconds where it is not given, as on the line Settings copies). Islet's
# answer counts only when it is signed with the approvals key whose public half sits
# beside this script (islet-approvals.pub, written by Islet only when you click for it)
# and was given for exactly this request; anything else, or no answer in time, prints
# nothing, and Codex asks in the app as it always has. Meanwhile the banner waits: it
# shows only if the wait runs out. A request left to the app is marked, by its digest
# alone, so that the same one in that session goes straight to the app, where Codex may
# have approved it for the session. Nothing is offered while Codex's own reviewer
# (approvals_reviewer) answers in your place. The command itself is written only into
# the request, for Islet to show, and the request is deleted as the hook ends.
#
# It has to be quick, and must never fail the hook: Codex waits for most of them, and
# takes anything printed by some as a decision. So nothing is printed (but a dry run's
# banners), except the permission kind's answer, and it always exits 0. PreToolUse and
# PostToolUse run in the background, one for every tool, so their events can arrive
# late or out of order; the rules below keep one from undoing what a later event said.
export LC_ALL=en_US.UTF-8
# The tools from fixed places, not from whatever PATH Codex was started with.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
kind="$1"
input="$(cat)"
# Only the permission kind may answer, on what was stdout; nothing else reaches it.
if [ "$kind" = permission ]; then exec 3>&1; trap 'exit 0' TERM INT HUP; else exec 3>&-; fi
[ -z "$ISLET_NOTIFY_DRY" ] && exec >/dev/null
# A dry run says on stderr what the island would be offered.
[ -z "$ISLET_NOTIFY_DRY" ] && exec 2>/dev/null

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

# The agent this script speaks for, to the approval block below.
approval_agent=chatgpt
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

# A permission asked: whether the island will ask it, decided before anything is
# recorded, so that the banner can wait while it does.
approval_offered=0 approval_decision=pass approval_answered=0 approval_mark=""
if [ "$kind" = permission ]; then
  approval_pending=""
  approval_offer "$@" 3>&- && approval_offered=1
fi

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
  # A v1 agent starting comes as a prompt carrying its id: it is the agent starting, not
  # a prompt of the chat, and is taken as SubagentStart is.
  | ($kind == "prompt" and $agent != "") as $agentPrompt
  | (if $agentPrompt then "agent-start" else $kind end) as $kind
  # A tool or a stop of the chat from a turn never seen is from one Codex started itself,
  # carrying on towards a goal with no prompt: a new turn, where one from a turn seen
  # before is late.
  | ($p.turns // [] | if type == "array" then map(strings) else [] end) as $turns
  | ($agent == "" and ($isTool or $kind == "stop") and $over != "" and $turn != "" and $turn != $current
     and ($turns | index([$turn]) | not)) as $selfStart
  # A prompt into the turn under way steers it: the turn goes on.
  | ($kind == "prompt" and $turn != "" and $turn == $current and $over == "") as $steer
  | (($kind == "prompt" and ($steer | not)) or $selfStart) as $fresh
  # A command left running may end in a later turn, or after the last.
  | ($p.shells // [] | if type == "array" then map(objects) else [] end) as $shells
  | ($late and ($selfStart | not) and (($kind == "tool-end" and ($shells | map(.id) | index($use))) | not)) as $late
  | (if $selfStart then "" else $current end) as $current
  | (if $selfStart then "" else $over end) as $over
  # Where Codex keeps its own files: only a full path.
  | ($ENV.CODEX_HOME // "" | if . == "" and ($ENV.HOME // "") != "" then $ENV.HOME + "/.codex" else . end
     | if startswith("/") then sub("(?<=.)/+$"; "") else "" end) as $codexHome
  | ($isTool and ($tool | toolkind) == "ask") as $question
  | (if $isTool then ($in | step($use; $t)) else null end) as $call
  | ($p.step | if type == "object" then . else null end) as $was
  | if ($kind == "stop" and $again) or $late then null, "", "" else

  # Who is waiting on you, and on what.
  # The step under way is the call asked for only if it started a moment before: the ask
  # can land before the start of its call, with a command left under way since earlier.
  ($agents | map(select(.id == $agent)) | first) as $asker
  | (if $kind == "permission" then
       {state: "needsPermission", since: $t, askedBy: $agent,
        askId: ((if $agent == "" then
                   ($was | if type == "object" and (.started | type) == "number" and .started >= $t - 1 then . else null end)
                 else ($asker.step // null) end)
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
  | (if ($fresh and ($isTool | not)) or $kind == "stop" or $kind == "interrupt" or ($kind == "start" and ($compacted | not)) then null
     elif $mine and $kind == "tool-start" and ($done | index([$use]) | not) then $call
     elif $mine and $kind == "tool-end" and ($was.id // null) == $use then null
     else $was end) as $step
  | ((if $fresh or ($kind == "start" and ($compacted | not)) then 0
      else ($p.steps // 0 | if type == "number" then . else 0 end) end)
     + (if $mine and $kind == "tool-start" then 1 else 0 end)) as $steps
  | (if $mine and $kind == "tool-end" and $call.kind == "plan" then ($in | planned)
     elif $fresh or ($kind == "start" and ($compacted | not)) then []
     else list($p.plan) end) as $plan
  # The steps of the turn so far, a run of the same one counted once.
  | (if $fresh or ($kind == "start" and ($compacted | not)) then [] else list($p.history) end
     | if $mine and $kind == "tool-start" then
         (.[-1] // {}) as $last
         | if ($last.kind // "") == $call.kind and ($last.name // "") == $call.name
           then .[-1].n = (($last.n // 1) + 1) | .[-1].count = $call.count
           else . + [{kind: $call.kind, name: $call.name, count: $call.count, n: 1}] end
       else . end
     | .[-12:]) as $history
  # Its commands left running: the one under way once another tool starts, or the turn
  # stops, before its own end has come. Codex stops them at an interrupt. One the chat
  # was still waiting for permission for may have been declined, which no hook says;
  # where the call asked for is not known, one started well before the ask was not it.
  | ($was | if type == "object" and .kind == "shell" and (.id // "" | text) != "" then . else null end) as $left
  | ($shells
     | if $left != null and (($mine and $kind == "tool-start" and $use != $left.id) or $kind == "stop")
          and ($done | index([$left.id]) | not) and (map(.id) | index($left.id) | not)
       then . + [{id: $left.id, name: ($left.name // "" | text), started: ($left.started // $t), since: $t,
                  asked: ($old == "needsPermission" and $askedBy == ""
                          and (if $askId == "" then ($left.started // $t | if type == "number" then . else $t end) >= $since - 1
                               else $askId == $left.id end))}]
       else . end
     | if $kind == "tool-end" and $use != "" then map(select(.id != $use)) else . end
     | if $kind == "interrupt" or ($kind == "start" and ($compacted | not)) then [] else . end
     | if length > 8 then (map(select(.asked == true)) + map(select(.asked != true))) else . end
     | .[-8:]) as $shells

  # Agents: started, working, stopped; named by the spawn call that asked for them.
  | ($in | given | if type == "object" then .task_name // .name // "" else "" end | text | plain(40)) as $asked
  # The end of a v1 spawn says which agent it started, and the nickname Codex gave it.
  | (if $kind == "tool-end" and $agent == "" and $call.kind == "spawn" then
       ($in.tool_response | if type == "string" then (try fromjson catch null) else . end
        | if type == "object" then {id: (.agent_id | text), name: (.nickname | text | plain(40))} else null end)
     else null end // {id: "", name: ""}) as $spawned
  | (if $spawned.id != "" and $spawned.name != "" then
       (if ($agents | map(.id) | index($spawned.id)) then
          {agents: ($agents | map(if .id == $spawned.id and (.name // "") == "" then .name = $spawned.name else . end)),
           pending: $pending}
        else {agents: $agents, pending: ($pending + [{name: $spawned.name, t: $t, id: $spawned.id}] | .[-8:])} end)
     elif $kind == "tool-start" and $call.kind == "spawn" and $asked != "" then
       ($agents | map(select(.status == "running" and (.name // "") == "" and (.firstSeen // 0) >= $t))
        | sort_by(.firstSeen) | first) as $unnamed
       | if $unnamed then {agents: ($agents | map(if .id == $unnamed.id then .name = $asked else . end)), pending: $pending}
         else {agents: $agents, pending: ($pending + [{name: $asked, t: $t}] | .[-8:])} end
     elif $kind == "agent-start" and $agent != "" then
       (($pending | to_entries | map(select((.value.id // "") == $agent)) | first)
        // ($pending | to_entries | map(select((.value.id // "") == "" and (.value.t // 0) <= $t)) | first)) as $pair
       | ($agents | map(select(.id == $agent)) | first) as $have
       | if $have and (($have.name // "") != "" or $pair == null) then {agents: $agents, pending: $pending}
         elif $have then
           {agents: ($agents | map(if .id == $agent then .name = $pair.value.name else . end)),
            pending: ($pending | del(.[$pair.key]))}
         else {agents: ($agents + [{id: $agent, type: ($in.agent_type | text), name: ($pair.value.name // ""),
                                   status: "running", firstSeen: $t, ended: null, step: null, steps: 0}]),
               pending: (if $pair then ($pending | del(.[$pair.key])) else $pending end)} end
       # One started again after it stopped is running again.
       | .agents |= map(if .id == $agent then (if .status != "running" then .status = "running" | .ended = null
                                               else . end) | .seen = $t
                        else . end)
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
             else
               # Its own plan, as how many of its steps are done; never their words.
               (if $call.kind == "plan" then ($in | planned) as $own
                  | .planDone = ($own | map(select(.status == "completed")) | length) | .planTotal = ($own | length)
                else . end)
               | if (.step.id // null) == $use then .step = null else . end end)
       # Heard from: between its tools it has no step to say it is busy.
       | map(if .id == $agent and .status == "running" then .seen = $t else . end)
       | {agents: ., pending: $pending}
     elif $kind == "start" and ($compacted | not) then {agents: [], pending: []}
     # Those done are let go at the next turn: kept till then, past the end of this one,
     # they say how many of its agents are done.
     elif $fresh then {agents: ($agents | map(select(.status == "running"))), pending: []}
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
      turnId: (if $kind == "prompt" or $selfStart then $turn
               elif $current == "" and $mine then $turn
               else $current end),
      turnStarted: (if $fresh then $t
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
      doneIds: (if $kind == "tool-end" and $use != "" then ((if $fresh then [] else $done end) + [$use] | .[-16:])
                elif $fresh then []
                else $done end),
      endedAgents: (if $kind == "agent-stop" and $agent != "" then ($gone - [$agent] + [$agent] | .[-16:])
                    elif $kind == "agent-start" and $agent != "" then $gone - [$agent]
                    elif $kind == "start" and ($compacted | not) then []
                    else $gone end),
      codexHome: $codexHome,
      history: $history,
      shells: $shells,
      turns: (if $turn != "" and ($kind == "prompt" or $selfStart or $agentPrompt) then ($turns - [$turn] + [$turn] | .[-8:])
              else $turns end)
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

if [ "$kind" = permission ]; then
  # The island asks first, the session's file free meanwhile.
  rmdir "$lock" 2>/dev/null
  trap - EXIT
  if [ "$approval_offered" = 1 ]; then
    [[ "$state" =~ \"project\":\"([^\"\\]*)\" ]] && project="${BASH_REMATCH[1]}"
    approval_ask "$@" 3>&-
    case "$approval_decision" in allow) approval_out="$approval_allow" ;; deny) approval_out="$approval_deny" ;; *) approval_out="" ;; esac
    if [ -n "$approval_out" ]; then
      # The one answer this script ever prints.
      printf '%s\n' "$approval_out" >&3
      [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] \
        && printf '{"t":%s,"event":"island","session_id":"%s","decision":"%s"}\n' "$(date +%s)" "$session" "$approval_decision" >> "$log"
      exit 0
    fi
    # Left to the app by Islet, which needs no banner to say so; by the wait running
    # out, the banner held back.
    [ "$approval_answered" = 1 ] && banner=""
  fi
  approval_leave
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
