#!/bin/bash
# Gemini CLI in Islet's island, from each hook's JSON on stdin. It only tells: it never
# changes what Gemini CLI does. Two things:
#
# Banners: Gemini finished a reply, asks your permission for a tool, has a question or a
# plan for you, ran out of quota, or stopped on an error. Each names its session, so a
# click on it brings the terminal forward at the session's tab where Islet can (Terminal
# and iTerm). A finish goes to Islet either way, which leaves it down while that tab is
# the one in front; a turn you stop yourself (Escape, or a tool you turn down) gets none.
#
# The session's state, for Islet's Gemini activity: one JSON file per session in
#   ~/Library/Application Support/Islet/Gemini/Sessions/<session id>.json
# ($ISLET_GEMINI_STATE_DIR in its place, for tests), beside Antigravity's conversations
# and marked as the CLI's ("source": "cli"), which Islet watches. Each is written whole, a
# new file moved over the old, so Islet never reads half of one. The session's end
# deletes it; one left by a session that never said so is deleted once it is a day old.
#
# Usage: gemini-cli-hook.sh <kind>, one kind per event in ~/.gemini/settings.json:
#   start         SessionStart    a session began, or was resumed or cleared
#   end           SessionEnd      it ended, or /clear ended it
#   prompt        BeforeAgent     a prompt was sent
#   stop          AfterAgent      the agent's turn is over
#   tool-start    BeforeTool      a tool is about to run (before Gemini asks you about it)
#   tool          AfterTool       a tool has finished, or was stopped
#   notification  Notification    Gemini asks you about a tool (ToolPermission)
# ISLET_NOTIFY_DRY=1 writes the banners to stderr instead of showing them. Needs jq, which
# macOS has had since 15; before that, Homebrew's.
#
# What it answers. Gemini CLI reads a hook's stdout (or, where that is empty, its stderr)
# as its answer, and takes any other exit status than 0 as a failure or a refusal. Its
# hooks documentation gives `{}` with exit 0 as the answer that does nothing ("Return
# success (exit 0) with empty JSON"): no decision, nothing added to the prompt, the turn
# not stopped. So this script prints exactly `{}` for every event, before it reads
# anything, and nothing else ever reaches stdout or stderr; it then exits 0 within three
# seconds at most, a watchdog ending it should anything hang, well inside the hook line's
# five. Gemini CLI gives a hook no way to allow a tool, only to refuse one, and this
# script refuses nothing: nothing is approved or denied from the island.
#
# A session's file, times in seconds since 1970:
#   version         1
#   source          "cli": a Gemini CLI session (Antigravity's conversations have none)
#   sessionId       Gemini CLI's session id, as in the file's name
#   project         the git repository's folder name, or the folder's; "" for the home
#                   folder, "/" and Gemini's own folders
#   branch          the git branch the folder is on, as of the latest event, or for a
#                   detached HEAD its commit's first seven digits; "" for none
#   workspace       the folder the session works in, a full path
#   model           the model that last answered, as the session's own file names it, at
#                   most 40 characters; "" before it has
#   transcriptPath  the session's own file, as Gemini names it, only inside ~/.gemini/tmp
#   hostApp         the bundle id of the app Gemini CLI runs in (Terminal, iTerm, an
#                   editor), as macOS hands it to the terminal's shell; "" when unknown
#   tty             the terminal Gemini CLI's process runs in, as ttys003: Terminal and
#                   iTerm find the tab by it; "" when it has none
#   itermSession    in iTerm, the session's own id (ITERM_SESSION_ID's UUID); "" elsewhere
#   pid             Gemini CLI's own process: the hook's parent, past any shell it was run
#                   through; null when it could not be found. Islet takes a session whose
#                   process has gone as over, whatever its state says
#   pidStarted      when that process started, to tell it from a later one given the same
#                   number; null when unknown
#   state           working | needsInput | idle | error
#   since           when it entered that state, or for one waiting on you, when Gemini
#                   last asked
#   turnStarted     when the latest prompt was sent; null before the first
#   updated         the latest event
#   ended           how the latest turn ended: "" while under way, done, cancelled (you
#                   stopped it, a command as it ran too, or turned a tool down), error or
#                   quota
#   error           the start of the error that stopped it, plain, at most 120 characters;
#                   "" otherwise
#   waiting         what Gemini asks you, while it does: permission (to run a command,
#                   edit a file, use an MCP server's tool or fetch from the web), question
#                   (its ask_user tool) or plan (a plan to approve); "" otherwise
#   asking          what a permission is for: {kind, name}, as a step's; null otherwise
#   step            the tool under way: {kind, name, count, started}; null otherwise
#   lastStep        the latest tool to finish: {kind, name, count, at}; null before one
#   steps           how many tools the turn has used
#   history         the turn's tools so far, oldest first, a run of the same one counted
#                   once: [{kind, name, count, n}], at most 12
#   prompt          the latest prompt's first line, plain, at most 120 characters
#   todos           the agent's to-do list, as its write_todos tool last gave it: [{text,
#                   status}], status pending, inProgress or completed, at most 20 items of
#                   80 characters, cancelled ones left out
# A tool's kind is shell, edit, read, search, web, ask, task, mcp or other; its name the
# program a command runs, the file an edit or a read is of (its name alone), an MCP
# server's name or the tool's own.
# A field is only ever added: the version goes up only if one comes to mean something
# else.
# Never kept: a command (only the program it runs), a file's folder, what a tool was given
# or gave back, a question, a plan or a reply. The reply's start goes only into the Done
# banner. Of the session's own file only two things are read, from its last 256 KB: the
# kind of its last message (whether the turn ended on Gemini's reply) and the model named
# last. Where a turn ends without a reply, the newest report of a turn's error Gemini wrote
# in the ten seconds before (gemini-client-error-Turn.run-sendMessageStream-*.json in
# $TMPDIR) gives the error's message, read from its first 8 KB and nothing else of it.
export LC_ALL=en_US.UTF-8
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
kind="$1"

# The answer, first, and then stdout goes: nothing else can reach it. Stderr goes too,
# since Gemini reads it where stdout is empty, but for a dry run's banners.
printf '{}'
exec 1>/dev/null
[ -z "$ISLET_NOTIFY_DRY" ] && exec 2>/dev/null

# Ends the hook, at 0, should anything below hang: an event whose input never ends, say.
# Bash keeps a signal until what it waits on ends, so everything the hook has started is
# ended too, the watchdog apart. It holds none of the hook's pipes, so Gemini is not kept
# waiting on it, and goes as the hook ends.
/usr/bin/perl -e '
  sleep 3; $SIG{TERM} = "IGNORE"; my $top = shift; kill "TERM", $top;
  my %kids; for (`/bin/ps -A -o pid= -o ppid=`) { my ($p, $pp) = split; push @{$kids{$pp}}, $p if $pp }
  my @todo = ($top); my @tree;
  while (@todo) { for (@{$kids{shift @todo} || []}) { push @tree, $_; push @todo, $_ } }
  kill "TERM", grep { $_ != $$ } @tree;' "$$" </dev/null >/dev/null 2>&1 &
watchdog=$!
trap 'exit 0' TERM INT HUP
trap 'kill "$watchdog" 2>/dev/null' EXIT

# A kind this script does not know (a typo in settings.json, or another event): the event
# is read to its end, under the watchdog like any other, and left alone.
case "$kind" in
  start|end|prompt|stop|tool-start|tool|notification) ;;
  *) cat >/dev/null; exit 0 ;;
esac

# At most a megabyte of the event is kept: an edit's permission carries the whole file.
# The rest is read and let go, so Gemini is never left writing into a closed pipe.
input="$(head -c 1048576; cat >/dev/null)"

[[ "$HOME" == /* ]] || exit 0
# The fields a cut-short event still has, looked for as text where it is not JSON: Gemini
# puts the session's own fields first, so only its first 64 KB are looked in (bash takes
# far longer than the watchdog allows to cut up a megabyte this way). Only where nothing
# before them opens an object of its own, so a key of the same name inside a tool's input
# is never taken for the event's.
top_level() { # key, pattern of its value
  [[ "$start" =~ \"$1\"[[:space:]]*:[[:space:]]*\"($2)\" ]] || return 1
  local found="${BASH_REMATCH[1]}" before="${start%%\"$1\"*}"
  [ "${#found}" -le 1024 ] || return 1
  local opens="${before//[^\{]/}"
  [ "${#opens}" -le 1 ] || return 1
  printf '%s' "$found"
}
if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
  start="$(printf '%s' "$input" | head -c 65536)"
  details=""
  [[ "$start" =~ \"details\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"type\"[[:space:]]*:[[:space:]]*\"([a-z_]{1,40})\" ]] \
    && details="${BASH_REMATCH[1]}"
  input="$(jq -nc --arg id "$(top_level session_id '[A-Za-z0-9._-]{1,128}')" \
    --arg cwd "$(top_level cwd '/[^"\\]*')" \
    --arg transcript "$(top_level transcript_path '/[^"\\]*')" \
    --arg tool "$(top_level tool_name '[A-Za-z0-9_.:-]{1,80}')" --arg details "$details" \
    '{session_id: $id, cwd: $cwd, transcript_path: $transcript}
     + (if $tool == "" then {} else {tool_name: $tool} end)
     + (if $details == "" then {} else {notification_type: "ToolPermission", details: {type: $details}} end)' 2>/dev/null)"
  unset start
fi

# Every field read below, in one go.
session="" cwd="" transcript="" response=""
eval "$(printf '%s' "$input" | jq -r '
  def text: if type == "string" then . else "" end;
  @sh "session=\(.session_id | text)",
  @sh "cwd=\(.cwd | text | .[0:4096])",
  @sh "transcript=\(.transcript_path | text | .[0:4096])",
  @sh "response=\(.prompt_response | text | .[0:2000])"' 2>/dev/null)"
[ -z "$session" ] && session="${GEMINI_SESSION_ID:-}"
[[ "$session" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || exit 0
dir="${ISLET_GEMINI_STATE_DIR:-$HOME/Library/Application Support/Islet/Gemini/Sessions}"
[ -d "$dir" ] || mkdir -p "$dir" || exit 0
file="$dir/$session.json"
log="$dir/.cli-hook-log.jsonl"

# One event of a session at a time: an event can come while the last is still running.
# The lock is a file made only if there is none, holding the process id of the hook that
# made it. One whose maker has gone (ended outright, which no trap sees), or more than two
# seconds old, is taken over; after about a second the event goes ahead anyway. A lock
# that can't be made while there is none (a folder that can't be written) is not waited
# for. A hook removes only its own lock.
lock="$dir/.$session.lock"
waited=0
while :; do
  ( set -C; printf '%s' "$$" > "$lock" ) 2>/dev/null && break
  [ -e "$lock" ] || break
  holder="$(head -c 16 "$lock" 2>/dev/null)"
  if { [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; } \
     || { [ $((waited % 10)) -eq 0 ] && [ -n "$(find "$lock" -maxdepth 0 -mtime +2s 2>/dev/null)" ]; }; then
    [ -f "$lock" ] && [ "$(head -c 16 "$lock" 2>/dev/null)" = "$holder" ] && rm -f "$lock"
  fi
  waited=$((waited + 1))
  [ "$waited" -ge 30 ] && break
  sleep 0.02
done
trap '[ "$(head -c 16 "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"; kill "$watchdog" 2>/dev/null' EXIT

previous=""
[ -f "$file" ] && [ ! -L "$file" ] && IFS= read -r -d '' previous < <(head -c 262144 "$file")
# Antigravity's conversation of the same name, should there ever be one, is not this
# script's to change.
[ -n "$previous" ] && [[ "$previous" != *'"source":"cli"'* ]] && exit 0

# The session's end: its file goes.
if [ "$kind" = end ]; then
  rm -f "$file"
  printf '%s\n' "{\"t\":$(date +%s),\"event\":\"end\"}" >> "$log"
  exit 0
fi

# The git branch folder $1 is on, read from the repository's own files rather than by
# running git, exactly as the other hooks read it: the nearest .git at or above the folder
# (a folder, or a file naming one, as a worktree's or a submodule's is), never the home
# folder's or one above it, and the HEAD it holds. A branch checked out gives its name, a
# detached HEAD its commit's first seven digits, and anything else none. At most 64
# folders are looked at and two files read, a line of each. Sets branch to one line of
# plain text, cut in the middle to at most 80 characters, and branch_short to the same cut
# to 20 for a banner; both "" for none.
git_branch() {
  branch="" branch_short=""
  local at="$1" git="" line n=0
  local commit='^[0-9a-f]{40}([0-9a-f]{24})?$'
  local ascii='^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+@#,=-]+$'
  [ "${at:0:1}" = / ] && [ "${#at}" -le 4096 ] && [ -d "$at" ] || return 0
  case "$at/" in */./*|*/../*) return 0 ;; esac
  while [[ "$at" == *//* ]]; do at="${at//\/\///}"; done
  while [ "$n" -lt 64 ]; do
    at="${at%/}"
    { [ -z "$at" ] || [ "$at" = "${HOME%/}" ]; } && return 0
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then git="$at/.git"; break; fi
    at="${at%/*}" n=$((n + 1))
  done
  [ -n "$git" ] || return 0
  if [ -f "$git" ]; then
    { IFS= read -r -n 1024 line < "$git"; } 2>/dev/null
    line="${line%$'\r'}"
    [[ "$line" == "gitdir: "?* ]] || return 0
    git="${line#gitdir: }"
    [ "${git:0:1}" = / ] || git="$at/$git"
  fi
  [ -f "$git/HEAD" ] || return 0
  line=""
  { IFS= read -r -n 512 line < "$git/HEAD"; } 2>/dev/null
  line="${line%$'\r'}"
  if [[ "$line" == "ref: refs/heads/"?* ]]; then
    branch="${line#ref: refs/heads/}"
    [[ "/$branch" == */.* ]] && { branch=""; return 0; }
  elif [[ "$line" =~ $commit ]]; then
    branch="${line:0:7}"
  else
    return 0
  fi
  if ! [[ "$branch" =~ $ascii ]]; then
    branch="$(jq -rn --arg b "$branch" '$b
      | gsub("[\\p{Cc}\\p{Cf}\\p{Co}\\p{Cs}\\p{Zl}\\p{Zp}\\p{Default_Ignorable_Code_Point}\\x{2800}\u034f\u115f\u1160\u17b4\u17b5\u3164\uffa0\ufffd]"; "")
      | gsub("\\p{Zs}+"; " ") | sub("^ +"; "") | sub(" +$"; "")' 2>/dev/null)"
  fi
  [ "${#branch}" -gt 80 ] && branch="${branch:0:40}…${branch: -39}"
  branch_short="$branch"
  [ "${#branch}" -gt 20 ] && branch_short="${branch:0:10}…${branch: -9}"
  return 0
}
# The folder, a full path without a step up in it, and the project: the git repository it
# is in, found by looking for .git rather than by running git, or else the folder itself.
workspace=""
if [[ "$cwd" == /* ]] && ! [[ "$cwd" =~ [[:cntrl:]] ]]; then
  case "/$cwd/" in */../*) ;; *) workspace="${cwd%/}"; [ -z "$workspace" ] && workspace=/ ;; esac
fi
[ "${#workspace}" -le 1024 ] || workspace=""
[ -z "$workspace" ] && [[ "$previous" =~ \"workspace\":\"([^\"\\]*)\" ]] && workspace="${BASH_REMATCH[1]}"
project="" branch="" branch_short=""
case "$workspace" in
  ""|/|"$HOME"|"$HOME/"|"$HOME/.gemini"|"$HOME/.gemini/"*) ;;
  *)
    at="$workspace" top=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
      [ -z "$at" ] || [ "$at" = / ] || [ "$at" = "$HOME" ] && break
      [ -e "$at/.git" ] && { top="$at"; break; }
      at="${at%/*}"
    done
    project="${top:-$workspace}"
    project="${project##*/}"
    git_branch "$workspace" ;;
esac

# The session's own file, only where Gemini keeps them, never through a link.
case "$transcript" in
  "$HOME/.gemini/tmp/"*.jsonl) case "$transcript" in */../*|*/./*) transcript="" ;; esac ;;
  *) transcript="" ;;
esac
[ -n "$transcript" ] && { [ -L "$transcript" ] || [ ! -f "$transcript" ]; } && transcript=""
# Of its last 256 KB, the kind of its last message (its lines start with an id, a time and
# a type) and the model named last; nothing else.
last_type="" model=""
if [ -n "$transcript" ] && { [ "$kind" = stop ] || [ "$kind" = tool ] || [ "$kind" = prompt ]; }; then
  tail_text="$(tail -c 262144 "$transcript" 2>/dev/null)"
  line="$(printf '%s\n' "$tail_text" | grep -aoE '^\{"id":"[^"]{1,80}","timestamp":"[^"]{1,40}","type":"[a-z_]{1,20}"' | tail -n 1)"
  [[ "$line" =~ \"type\":\"([a-z_]+)\"$ ]] && last_type="${BASH_REMATCH[1]}"
  line="$(printf '%s\n' "$tail_text" | grep -aoE '"model":"[A-Za-z0-9._:/-]{1,80}"' | tail -n 1)"
  [[ "$line" =~ :\"([^\"]+)\"$ ]] && model="${BASH_REMATCH[1]:0:40}"
  unset tail_text
fi

# How a turn ended, at its stop: on Gemini's reply (done); without one, on an error, if
# Gemini wrote a report of the turn's error just before (error, or quota where the error
# says so), else stopped by you (cancelled). Where the session's file can't be read, a
# reply says it was done.
ending="" error_text=""
if [ "$kind" = stop ]; then
  started=""
  [[ "$previous" =~ \"turnStarted\":([0-9]+) ]] && started="${BASH_REMATCH[1]}"
  if [ "$last_type" = gemini ]; then
    ending=done
  elif [ -z "$transcript" ] && [ -n "$response" ] && [ "$response" != "[no response text]" ]; then
    ending=done
  else
    ending=cancelled
    # The newest report of a turn's error, written in the turn and in the last ten seconds:
    # Gemini writes it just before the turn ends. Every Gemini CLI session shares the
    # folder, and other reports there (a helper call failing, which goes on) end no turn.
    # One find and one stat, however many reports there are.
    since_s=$(($(date +%s) - 10))
    [ -n "$started" ] && [ "$started" -gt "$since_s" ] && since_s="$started"
    report=""
    line="$(find "${TMPDIR:-/tmp}/" -maxdepth 1 -type f -name 'gemini-client-error-Turn.run-sendMessageStream-*.json' \
      -mmin -1 -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -n 1)"
    if [[ "$line" =~ ^([0-9]+)\ (.+)$ ]] && [ "${BASH_REMATCH[1]}" -ge $((since_s - 1)) ]; then
      report="${BASH_REMATCH[2]}"
    fi
    if [ -n "$report" ]; then
      head_text="$(head -c 8192 "$report" 2>/dev/null)"
      # Regular expressions here repeat at most 255 times: the message is cut after.
      pattern='"message"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
      if [[ "$head_text" =~ $pattern ]]; then
        error_text="$(jq -rn --arg s "${BASH_REMATCH[1]:0:2000}" '"\"" + $s + "\"" | (try fromjson catch $s)' 2>/dev/null)"
      fi
      [ -z "$error_text" ] && error_text="Gemini CLI stopped on an error"
      ending=error
      shopt -s nocasematch
      [[ "$error_text" =~ (resource_exhausted|resource\ exhausted|quota|rate[\ _-]?limit|too\ many\ requests|429|exhausted\ your) ]] \
        && ending=quota
      shopt -u nocasematch
    fi
  fi
fi

# Gemini CLI's process: the hook's parent, or that shell's parent where Gemini ran the hook
# through one. Its number, terminal and age (ps's etime, [[dd-]hh:]mm:ss) are looked up when
# a session starts or is sent a prompt, or while its file has none.
pid="" age="" tty=""
find_gemini() {
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
  find_gemini
fi
# The app the terminal is: as macOS hands it to the shell, or as the terminal names itself.
host="${__CFBundleIdentifier:-}"
if [ -z "$host" ]; then
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) host=com.apple.Terminal ;;
    iTerm.app) host=com.googlecode.iterm2 ;;
  esac
fi
[[ "$host" =~ ^[A-Za-z0-9.-]{1,128}$ ]] || host=""
iterm=""
[[ "${ITERM_SESSION_ID:-}" =~ :([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$ ]] \
  && iterm="${BASH_REMATCH[1]}"

# The new state, a banner (or nothing), and a line for the log, from one jq.
program='
  def text: if type == "string" then . else "" end;
  def one: gsub("[\r\n\t]+"; " ");
  def clip($n): if length <= $n then . else (.[0:$n - 1] | sub(" [^ ]*$"; "")) + "…" end;
  def plain($n):
    .[0:$n * 4 + 1000] | gsub("[[:cntrl:]]+"; " ") | gsub("\\*\\*|__|`|^#+ *"; "")
    | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "") | clip($n);
  def firstline: split("\n") | map(select(test("[^[:space:]]"))) | first // "";
  def base: sub("/+$"; "") | sub("^.*/"; "");
  # The program a command line mostly runs, as a plain word, as in chatgpt-hook.sh.
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
    [.[0:4000] | gsub("&&|\\|\\|"; "\n") | splits("[\n;|]")
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
  # What sort of tool a call is, by the name Gemini CLI gives it.
  def toolkind:
    if . == "run_shell_command" then "shell"
    elif IN("replace", "write_file", "edit") then "edit"
    elif IN("read_file", "read_many_files", "list_directory", "get_internal_docs", "read_mcp_resource",
            "list_mcp_resources") then "read"
    elif IN("glob", "grep_search", "search_file_content") then "search"
    elif IN("google_web_search", "web_fetch") then "web"
    elif . == "ask_user" then "ask"
    elif . == "write_todos" or startswith("tracker_") then "task"
    elif startswith("mcp_") then "mcp"
    else "other" end;
  def toolname: (.tool_name // "") | text
    | if test("^[A-Za-z0-9_.:-]{1,80}$") then ascii_downcase else "" end;
  def args: (.tool_input // {}) | if type == "object" then . else {} end;
  def filename: [.file_path, .absolute_path, .dir_path, .path]
    | map(strings | select(length > 0)) | first // "" | base | plain(60);
  # The step a call is, as kept: its kind and a short name, never what it was given.
  def step($t):
    . as $e | toolname as $tool | ($tool | toolkind) as $k | ($e | args) as $a
    | {kind: $k, name: "", count: 0, started: $t}
    | if $k == "shell" then .name = ($a | (.command // "") | text | program)
      elif $k == "edit" or $k == "read" then .name = ($a | filename) | .count = (if .name == "" then 0 else 1 end)
      elif $k == "mcp" then .name = (($e.mcp_context | objects | .server_name) // "" | text | plain(40)
                                     | if . == "" then ($tool | sub("^mcp_"; "") | sub("_.*$"; "")) else . end)
      elif $k == "other" then .name = ($tool | clip(40))
      else . end;
  # What a permission asked is for, from the event details: as a step.
  def asked:
    (.details | objects) // {} | . as $d
    | ($d.type // "" | text) as $type
    | if $type == "exec" then
        {kind: "shell", name: (($d.rootCommand // "" | text | program) as $root
                               | if $root != "" then $root else ($d.command // "" | text | program) end)}
      elif $type == "edit" then {kind: "edit", name: ([$d.fileName, $d.filePath] | map(strings) | first // "" | base | plain(60))}
      elif $type == "mcp" then {kind: "mcp", name: ($d.serverName // "" | text | plain(40))}
      elif $type == "info" then {kind: "web", name: ""}
      elif $type == "ask_user" then {kind: "ask", name: ""}
      elif $type == "exit_plan_mode" then {kind: "task", name: ""}
      else {kind: "other", name: ($d.title // "" | text | plain(40))} end;
  def waitingfor:
    ((.details | objects | .type) // "" | text) as $type
    | if $type == "ask_user" then "question" elif $type == "exit_plan_mode" then "plan" else "permission" end;
  def todos:
    ((.tool_input | objects | .todos) // [] | if type == "array" then . else [] end)
    | map(objects | {text: (.description // "" | text | firstline | plain(80)), status: (.status // "" | text)}
          | select(.text != "" and .status != "cancelled")
          | .status |= (if . == "completed" then "completed" elif . == "in_progress" then "inProgress" else "pending" end))
    | .[0:20];
  def list($v): $v | if type == "array" then map(objects) else [] end;
  # A command stopped with Escape as it ran: Gemini CLI ends the turn there and says
  # nothing more, no AfterAgent.
  def halted:
    (.tool_response | objects | .llmContent) // ""
    | if type == "array" then map(objects | .text // "" | text) | join("") else text end
    | startswith("Command was cancelled by user");

  . as $in
  | if type != "object" then null, "", "" else
  now as $t
  | (if ($prev | type) == "object" then $prev else {} end) as $p
  | ($p.state // "idle" | text) as $old
  | ($p.ended // "" | text) as $over
  | ($kind == "tool" or $kind == "tool-start") as $isTool
  | ($kind == "tool" and ($in | halted)) as $halted
  # A turn begins with a prompt; or with a tool used after the last one ended, or none was
  # seen (the hook added mid-turn).
  | ($kind == "prompt" or ($isTool and ($old == "idle" or $old == "error"))) as $new
  | (if $isTool then ($in | step($t)) else null end) as $call
  | (if $kind == "notification" then ($in | asked) else null end) as $asking
  | ($in.notification_type // "" | text) as $ntype
  | ($kind == "notification" and $ntype == "ToolPermission") as $asks
  | (if $kind == "stop" then (if $ending == "error" or $ending == "quota" then "error" else "idle" end)
     elif $kind == "start" then "idle"
     elif $kind == "notification" then (if $asks then "needsInput" else $old end)
     elif $halted then "idle"
     else "working" end) as $state
  | (if $kind == "notification" and $asks then $t
     elif $state == $old and ($new | not) and ($p.since | type) == "number" then $p.since else $t end) as $since
  | (if $new then 0 else ($p.steps // 0 | if type == "number" then . else 0 end) end
     + (if $kind == "tool" then 1 else 0 end)) as $steps
  | (if $new then [] else list($p.history) end
     | if $kind == "tool" then
         (.[-1] // {}) as $last
         | if ($last.kind // "") == $call.kind and ($last.name // "") == $call.name
           then .[-1].n = (($last.n // 1) + 1)
           else . + [{kind: $call.kind, name: $call.name, count: $call.count, n: 1}] end
       else . end
     | .[-12:]) as $history
  | (list($p.todos) | map(select((.text | type) == "string"))) as $oldTodos
  | (if $kind == "tool" and ($in | toolname) == "write_todos" then ($in | todos)
     elif $kind == "prompt" and ($oldTodos | all(.status == "completed")) then []
     else $oldTodos end) as $todos
  | ($pid | if test("^[0-9]+$") then tonumber else null end) as $found
  | ($in.prompt // "" | text | firstline | plain(120)) as $promptText
  | {
      version: 1,
      source: "cli",
      sessionId: $session,
      project: (if $workspace != "" then $project else ($p.project // "" | text) end),
      branch: $branch,
      workspace: (if $workspace != "" then $workspace else ($p.workspace // "" | text) end),
      model: (if $model != "" then $model else ($p.model // "" | text) end),
      transcriptPath: (if $transcript != "" then $transcript else ($p.transcriptPath // "" | text) end),
      hostApp: (if $host != "" then $host else ($p.hostApp // "" | text) end),
      tty: (if $found == null then ($p.tty // "" | text) else $tty end),
      itermSession: (if $iterm != "" then $iterm else ($p.itermSession // "" | text) end),
      pid: (if $found == null then ($p.pid // null) else $found end),
      pidStarted: (if $found == null then ($p.pidStarted // null)
                   elif ($age | test("^[0-9]+$")) then (($t - ($age | tonumber)) | floor) else null end),
      state: $state,
      since: $since,
      turnStarted: (if $new then $t elif ($p.turnStarted | type) == "number" then $p.turnStarted else null end),
      updated: $t,
      ended: (if $kind == "stop" then $ending elif $halted then "cancelled" elif $new then ""
              elif $kind == "start" then $over
              elif $isTool or $asks then "" else $over end),
      error: (if $kind == "stop" and ($ending == "error" or $ending == "quota")
              then ($errText | if startswith("[API Error: ") then .[12:] | sub("\\]$"; "") else . end | plain(120))
              elif $kind == "stop" or $new or $halted then "" else ($p.error // "" | text) end),
      waiting: (if $asks then ($in | waitingfor) elif $kind == "notification" then ($p.waiting // "" | text) else "" end),
      asking: (if $asks then $asking elif $kind == "notification" then ($p.asking // null) else null end),
      step: (if $kind == "tool-start" then $call else null end),
      lastStep: (if $kind == "tool" then ($call | del(.started) | .at = $t)
                 elif $new then null else ($p.lastStep // null | if type == "object" then . else null end) end),
      steps: $steps,
      history: $history,
      prompt: (if $kind == "prompt" then $promptText else ($p.prompt // "" | text) end),
      todos: $todos
    } as $out
  # A banner, for what wants you: its words, and the same as a URL query. Where the
  # session is: the project, and the branch beside it, cut in the middle to as much as a
  # banner has room for.
  | ($branch | if length > 20 then .[0:10] + "…" + .[-9:] else . end) as $branchShort
  | ($out.project | if . == "" then "" elif $branchShort == "" then " · " + . else " · " + . + " · " + $branchShort end) as $at
  | ($out.prompt | plain(100)) as $asked
  | ($out.asking // {}) as $what
  | (($what.name // "") | text) as $whatName
  | (if $kind == "stop" and $ending == "done" then
       {title: ("Gemini finished" + $at),
        subtitle: ($reply | firstline | plain(120) | if . == "" or . == "[no response text]" then $asked else . end),
        symbol: "checkmark.circle.fill", tint: "green", style: "card"}
     elif $asks and $out.waiting == "question" then
       {title: ("Gemini has a question" + $at),
        subtitle: (if $asked == "" then "Gemini CLI is waiting for your answer" else $asked end),
        symbol: "questionmark.bubble.fill", tint: "orange", style: "card"}
     elif $asks and $out.waiting == "plan" then
       {title: ("Gemini has a plan for you" + $at),
        subtitle: (if $asked == "" then "Gemini CLI is waiting for you to approve it" else $asked end),
        symbol: "checklist", tint: "orange", style: "card"}
     elif $asks then
       {title: ("Gemini needs permission" + $at),
        subtitle: (if $what.kind == "shell" then (if $whatName == "" then "To run a command" else "To run " + $whatName end)
                   elif $what.kind == "edit" then (if $whatName == "" then "To change a file" else "To change " + $whatName end)
                   elif $what.kind == "mcp" then (if $whatName == "" then "To use a tool" else "To use " + $whatName end)
                   elif $what.kind == "web" then "To fetch from the web"
                   elif $whatName != "" then "For " + $whatName
                   else "Gemini CLI is waiting for you" end),
        symbol: "hand.raised.fill", tint: "orange", style: "card"}
     elif $kind == "stop" and $ending == "quota" then
       {title: ("Gemini quota reached" + $at),
        subtitle: ($out.error | if . == "" then "Gemini CLI stopped until the quota resets" else . end),
        symbol: "gauge.with.dots.needle.100percent", tint: "orange", style: "card"}
     elif $kind == "stop" and $ending == "error" then
       {title: ("Gemini stopped" + $at),
        subtitle: ($out.error | if . == "" then "Gemini CLI stopped on an error" else . end),
        symbol: "exclamationmark.triangle.fill", tint: "red", style: "card"}
     else null end) as $banner
  | $out,
    (if $banner == null then "" else
       ($banner | map_values(text | one)) as $b
       | (if $kind == "stop" and $ending == "done" then "&event=done" else "" end) as $event
       | (if $branchShort != "" and ($b.title + "\n" + $b.subtitle | contains(" · " + ($branchShort | one)))
          then "&branch=" + ($branchShort | one | @uri) else "" end) as $branchQuery
       | "title=\($b.title | @uri)&subtitle=\($b.subtitle | @uri)&symbol=\($b.symbol)&tint=\($b.tint)&style=\($b.style)&activity=gemini&session=\($session)" + $event + $branchQuery
     end),
    ({t: ($t | floor), event: $kind, keys: ($in | keys_unsorted | map(.[0:40]) | .[0:24])}
     + (if $isTool then {tool: ($in | toolname), inputKeys: ($in | args | keys_unsorted | map(.[0:40]) | .[0:12])} else {} end)
     + (if $kind == "notification" then {type: ($ntype | .[0:40]), details: (($in.details | objects | .type) // "" | text | .[0:40])} else {} end)
     + (if $kind == "stop" then {ended: $ending, replyChars: ($reply | length), errorChars: ($errText | length)} else {} end)
     + (if $halted then {ended: "cancelled"} else {} end)
     | tojson)
  end'
update() { # previous
  printf '%s' "$input" | jq -rc --argjson prev "${1:-null}" --arg kind "$kind" --arg session "$session" \
    --arg workspace "$workspace" --arg project "$project" --arg branch "$branch" --arg model "$model" \
    --arg transcript "$transcript" --arg host "$host" --arg tty "$tty" --arg iterm "$iterm" --arg pid "$pid" \
    --arg age "$age" --arg ending "$ending" --arg errText "$error_text" --arg reply "$response" \
    "$program" 2>/dev/null
}
out="$(update "$previous")"
# A file that is not JSON (edited by hand, say) is started afresh.
[ -z "$out" ] && [ -n "$previous" ] && out="$(update null)"
[ -z "$out" ] && exit 0
state="${out%%$'\n'*}"
rest="${out#*$'\n'}"
[ "$rest" = "$out" ] && rest=""
query="${rest%%$'\n'*}"
logline="${rest#*$'\n'}"
[ "$logline" = "$rest" ] && logline=""

if [ -n "$state" ] && [ "$state" != null ]; then
  tmp="$dir/.$session.$$.tmp"
  { printf '%s\n' "$state" > "$tmp" && mv -f "$tmp" "$file"; } || rm -f "$tmp"
fi
# Every session's hooks share the log, cut back to its last 200 lines once it passes 400.
# It keeps what each event carries by its keys alone, never their values but a tool's
# name, the kind of a notification and how a turn ended.
if [ -n "$logline" ]; then
  printf '%s\n' "$logline" >> "$log"
  if [ "$(wc -l < "$log")" -gt 400 ] && mkdir "$dir/.cli-log.lock" 2>/dev/null; then
    tail -n 200 "$log" > "$log.$$.tmp" && mv -f "$log.$$.tmp" "$log"
    rm -f "$log.$$.tmp"
    rmdir "$dir/.cli-log.lock"
  fi
fi
if [ "$kind" = stop ] || [ "$kind" = start ]; then
  find "$dir" -maxdepth 1 \( \( -name '*.json' -o -name '.*.tmp' \) -mmin +1440 -o -name '.*.lock' -mmin +1 \) -delete
fi

[ -z "$query" ] && exit 0
if [ -n "$ISLET_NOTIFY_DRY" ]; then
  echo "banner: islet://banner?$query" >&2
else
  open -g "islet://banner?$query" </dev/null >/dev/null 2>&1
fi
exit 0
