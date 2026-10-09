#!/bin/bash
# Gemini, as Google Antigravity's agents run it, in Islet's island, from each hook's JSON
# on stdin. It only tells: it never changes what Antigravity does. Two things:
#
# Banners: an agent finished, stopped to ask you something, ran out of quota, stopped on
# an error or at its step limit. Each names its conversation, so a click on it brings
# Antigravity forward (Antigravity can't be asked from outside for a conversation). A
# finish goes to Islet either way, which leaves it down while that conversation is the
# one on screen; a question only while Antigravity is not in front. A run you stopped
# yourself gets none. A subagent's run, one a conversation sent off, gets a banner only
# for an error or its quota, and names the conversation that sent it.
#
# The conversation's state, for Islet's Gemini activity: one JSON file per conversation in
#   ~/Library/Application Support/Islet/Gemini/Sessions/<conversation id>.json
# ($ISLET_GEMINI_STATE_DIR in its place, for tests), which Islet watches. Each is written
# whole, a new file moved over the old, so Islet never reads half of one. Antigravity
# says nothing when a conversation is closed, so one is deleted once it is a day old.
#
# Usage: antigravity-hook.sh <kind>, one kind per event in ~/.gemini/config/hooks.json:
#   invocation    PreInvocation   the model is about to be called
#   tool          PostToolUse     a tool has finished
#   stop          Stop            the agent's loop has ended
#   tool-start    PreToolUse      a tool is about to run (not in Islet's own entry)
# ISLET_NOTIFY_DRY=1 writes the banners to stderr instead of showing them. Needs jq, which
# macOS has had since 15; before that, Homebrew's.
#
# What it answers. Antigravity reads a hook's stdout as its answer, so this script prints
# exactly the answer that leaves Antigravity's own course alone, and nothing else ever
# reaches stdout. By Antigravity's hooks documentation:
#   PostToolUse     "Expects an empty JSON object {}": it prints {}.
#   PreInvocation   injectSteps is optional: {} injects nothing.
#   Stop            only "continue" keeps the agent going ("Any other value allows the
#                   agent to stop"): {} lets it stop, as it would have.
#   PreToolUse      every decision the documentation gives (allow, deny, ask, force_ask)
#                   overrules Antigravity's own, and it gives none that leaves it be, so
#                   Islet's entry has no PreToolUse hook. Should one run this script
#                   anyway, it prints nothing at all.
# Each prints its answer before reading anything, so whatever happens after, the answer
# has been given; it then exits 0 within three seconds at most, a watchdog ending it
# should anything hang, well inside the hook line's five.
#
# A conversation's file, times in seconds since 1970:
#   version         1
#   sessionId       Antigravity's conversation id, as in the file's name
#   project         the git repository's folder name, or the workspace's; "" for none, the
#                   home folder or Antigravity's own folders
#   workspace       the conversation's first workspace folder, a full path; "" for none
#   model           the model Antigravity names, at most 40 characters
#   transcriptPath  where Antigravity says it writes the conversation, as given
#   artifactDir     where Antigravity keeps the conversation's own files (its task list,
#                   task.md, among them), as given; Islet reads only task.md there, and
#                   only inside ~/.gemini
#   state           working | needsInput | idle | error
#   since           when it entered that state
#   turnStarted     when the agent's latest run began; null before the first
#   updated         the latest event
#   ended           how the latest run ended: "" while under way, done, needsInput,
#                   background (stopped with background tasks still going), maxSteps,
#                   cancelled (stopped by you), error or quota
#   error           the start of the error that stopped it, plain, at most 120
#                   characters; "" otherwise
#   asked           whether the agent's latest tool asked you something (notify_user
#                   waiting on you, or ask_question about to run): a stop then is a
#                   question, not Done. An ask_question that has finished was answered.
#   step            the tool under way, where PreToolUse says so: {kind, name, count,
#                   started}; null otherwise
#   lastStep        the latest tool to finish: {kind, name, count, at}; null before one
#   steps           how many tools the run has used
#   history         the run's tools so far, oldest first, a run of the same one counted
#                   once: [{kind, name, count, n}], at most 12
#   parent          for a subagent's conversation, the id of the conversation that sent it
#                   off; "" otherwise
#   agent           a subagent's name as Antigravity gives it, at most 40 characters; ""
#                   otherwise
# A tool's kind is shell, edit, read, search, browser, web, ask, notify, task, mcp, image
# or other; its name the program a command runs, the file an edit or a read is of (its
# name alone), an MCP server's name or the tool's own.
# A field is only ever added: the version goes up only if one comes to mean something
# else.
# Never kept: a command (only the program it runs), a file's folder, what a tool was
# given or gave back, a question, a message, a prompt or a reply.
export LC_ALL=en_US.UTF-8
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
kind="$1"

# The answer, first, and then stdout goes: nothing else can reach it.
case "$kind" in
  invocation|tool|stop) printf '{}' ;;
esac
exec 1>/dev/null
[ -z "$ISLET_NOTIFY_DRY" ] && exec 2>/dev/null

# Ends the hook, at 0, should anything below hang: an event whose input never ends, say.
# Bash keeps a signal until what it waits on ends, so everything the hook has started is
# ended too, the watchdog apart. It holds none of the hook's pipes, so Antigravity is not
# kept waiting on it, and goes as the hook ends.
/usr/bin/perl -e '
  sleep 3; $SIG{TERM} = "IGNORE"; my $top = shift; kill "TERM", $top;
  my %kids; for (`/bin/ps -A -o pid= -o ppid=`) { my ($p, $pp) = split; push @{$kids{$pp}}, $p if $pp }
  my @todo = ($top); my @tree;
  while (@todo) { for (@{$kids{shift @todo} || []}) { push @tree, $_; push @todo, $_ } }
  kill "TERM", grep { $_ != $$ } @tree;' "$$" </dev/null >/dev/null 2>&1 &
watchdog=$!
trap 'exit 0' TERM INT HUP
trap 'kill "$watchdog" 2>/dev/null' EXIT

# A kind this script does not know (a typo in hooks.json, or another event): the event
# is read to its end, under the watchdog like any other, and left alone.
case "$kind" in
  invocation|tool|stop|tool-start) ;;
  *) cat >/dev/null; exit 0 ;;
esac

# At most a megabyte of the event is kept: a tool's arguments can hold a whole file.
# The rest is read and let go, so Antigravity is never left writing into a closed pipe.
input="$(head -c 1048576; cat >/dev/null)"

[[ "$HOME" == /* ]] || exit 0
if ! session="$(printf '%s' "$input" | jq -r '.conversationId // empty | strings' 2>/dev/null)"; then
  # An event cut short is not JSON: its id, and a tool's name, are looked for as text,
  # and stand in for it. Only where nothing before them opens an object of its own, so
  # a key of the same name inside a tool's arguments is never taken for the event's;
  # an id that comes after the arguments is lost with the rest, and the step with it.
  session="" tool=""
  if [[ "$input" =~ \"conversationId\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then
    found="${BASH_REMATCH[1]}" before="${input%%\"conversationId\"*}"
    opens="${before//[^\{]/}"
    [ "${#opens}" -le 1 ] && session="$found"
  fi
  if [[ "$input" =~ \"toolCall\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_.:-]{1,80})\" ]]; then
    found="${BASH_REMATCH[1]}" before="${input%%\"toolCall\"*}"
    opens="${before//[^\{]/}"
    [ "${#opens}" -le 1 ] && tool="$found"
  fi
  input="$(jq -nc --arg id "$session" --arg tool "$tool" \
    '{conversationId: $id} + (if $tool == "" then {} else {toolCall: {name: $tool}} end)' 2>/dev/null)"
fi
[[ "$session" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || exit 0
dir="${ISLET_GEMINI_STATE_DIR:-$HOME/Library/Application Support/Islet/Gemini/Sessions}"
[ -d "$dir" ] || mkdir -p "$dir" || exit 0
file="$dir/$session.json"
log="$dir/.hook-log.jsonl"

# One event of a conversation at a time: tools run side by side can finish together.
# The lock is a file made only if there is none, holding the process id of the hook
# that made it. One whose maker has gone (ended outright, which no trap sees), or more
# than two seconds old, is taken over; after about a second the event goes ahead
# anyway. A lock that can't be made while there is none (a folder that can't be
# written) is not waited for: the event goes ahead, and its writes fail as they will.
# A hook removes only its own lock.
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

# The workspace: the first full path given, without a step up in it; and the project,
# the git repository it is in, found by looking for .git rather than by running git, or
# else the folder itself.
workspace="$(printf '%s' "$input" | jq -r '
  [.workspacePaths // [] | if type == "array" then .[] else empty end | strings
   | select(startswith("/") and (test("[[:cntrl:]]") | not) and (test("(^|/)\\.\\.(/|$)") | not))
   | sub("(?<=.)/+$"; "")] | first // empty' 2>/dev/null)"
[ "${#workspace}" -le 1024 ] || workspace=""
project=""
case "$workspace" in
  ""|/|"$HOME"|"$HOME/"|"$HOME/.gemini"|"$HOME/.gemini/"*) ;;
  *)
    at="$workspace" top=""
    # The home folder and above are never taken for the repository: a home folder that
    # is one would name every workspace outside a repository of its own after it.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
      [ -z "$at" ] || [ "$at" = / ] || [ "$at" = "$HOME" ] && break
      [ -e "$at/.git" ] && { top="$at"; break; }
      at="${at%/*}"
    done
    project="${top:-$workspace}"
    project="${project##*/}" ;;
esac

# The conversation's title, for a banner, from Antigravity's own list of conversations,
# read-only.
title=""
if [ "$kind" = stop ] || { [ "$kind" = tool-start ] && [[ "$input" == *ask_question* ]]; }; then
  db="${ISLET_GEMINI_DB:-$HOME/.gemini/antigravity/conversation_summaries.db}"
  if [ -f "$db" ]; then
    title="$(sqlite3 -readonly -cmd '.timeout 300' "$db" \
      "SELECT title FROM conversation_summaries WHERE conversation_id = '$session' LIMIT 1" 2>/dev/null | head -c 4000)"
  fi
fi

# The new state, a banner (or nothing), and a line for the log, from one jq.
program='
  def text: if type == "string" then . else "" end;
  def one: gsub("[\r\n\t]+"; " ");
  def clip($n): if length <= $n then . else (.[0:$n - 1] | sub(" [^ ]*$"; "")) + "…" end;
  def plain($n):
    .[0:$n * 4 + 1000] | gsub("[[:cntrl:]]+"; " ") | gsub("\\*\\*|__|`"; "")
    | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "") | clip($n);
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
  # What sort of tool a call is, by the name Antigravity gives it: its step type in
  # lower case.
  def toolkind:
    if . == "run_command" or . == "send_command_input" or . == "command_status" then "shell"
    elif IN("write_to_file", "replace_file_content", "multi_replace_file_content", "code_action", "file_change",
            "edit_file", "propose_code", "delete_file") then "edit"
    elif IN("view_file", "view_file_outline", "view_content_chunk", "view_code_item", "list_dir", "read_file") then "read"
    elif IN("grep_search", "find_by_name", "codebase_search", "trajectory_search", "search") then "search"
    elif test("browser") then "browser"
    elif IN("search_web", "read_url_content") then "web"
    elif . == "ask_question" then "ask"
    elif . == "notify_user" then "notify"
    elif . == "task_boundary" then "task"
    elif . == "mcp_tool" or startswith("mcp_") then "mcp"
    elif . == "generate_image" then "image"
    else "other" end;
  def args: (.toolCall.args // .toolCall.arguments // null)
    | if type == "string" then (. as $s | (try fromjson catch $s)) else . end
    | if type == "object" then . else {} end;
  def toolname: (.toolCall.name // .toolName // .tool.name // "") | text | ascii_downcase
    | if test("^[a-z0-9_.:-]{1,80}$") then . else "" end;
  def filename: [.TargetFile, .AbsolutePath, .File, .FilePath, .Path, .file_path, .path, .DirectoryPath]
    | map(strings | select(length > 0)) | first // "" | base | plain(60);
  # The step a call is, as kept: its kind and a short name, never what it was given.
  def step($t):
    . as $e | toolname as $tool | ($tool | toolkind) as $k | ($e | args) as $a
    | {kind: $k, name: "", count: 0, started: $t}
    | if $k == "shell" and $tool == "run_command" then .name = ($a | (.CommandLine // .command // .Command // "") | text | program)
      elif $k == "edit" or $k == "read" then .name = ($a | filename) | .count = (if .name == "" then 0 else 1 end)
      elif $k == "mcp" then .name = ($a | (.ServerName // .serverName // .server // "") | text | plain(40))
      elif $k == "other" then .name = ($tool | clip(40))
      else . end;
  # Whether a call asks the person something and waits on them: a question about to be
  # put (an ask_question that has finished has had its answer), or a message that says
  # it waits.
  def asking:
    (toolname) as $tool | args as $a
    | ($tool == "ask_question" and $kind == "tool-start")
      or ($tool == "notify_user"
          and ([$a.IsBlocking, $a.isBlocking, $a.BlockedOnUser, $a.blockedOnUser, $a.AskForUserFeedback,
                $a.askForUserFeedback] | any(. == true)));
  def list($v): $v | if type == "array" then map(objects) else [] end;

  . as $in
  | if type != "object" then null, "", "" else
  now as $t
  | (if ($prev | type) == "object" then $prev else {} end) as $p
  | ($p.state // "idle" | text) as $old
  | ($p.ended // "" | text) as $over
  # A run begins with the model called after the last one ended, or after none was
  # seen; one stopped with background tasks going carries on.
  | ($kind == "invocation" and ($old != "working" or ($over != "" and $over != "background"))) as $fresh
  | ($kind == "tool" or $kind == "tool-start") as $isTool
  | (($isTool and $old != "working" and $old != "needsInput") or ($isTool and $over != "" and $over != "background")) as $joined
  | ($fresh or $joined) as $new
  | (if $isTool then ($in | step($t)) else null end) as $call
  | ($isTool and ($in | asking)) as $asks
  # How a run stopped, in the words of the documentation ("model_stop",
  # "max_steps_exceeded", "error") or by the name Antigravity gives the reason itself
  # (EXECUTOR_TERMINATION_REASON_…), whichever it sends.
  | ($in.terminationReason // "" | text | .[0:200] | ascii_downcase
     | sub("^(executor_)?termination_reason_"; "")) as $reason
  | ($in.error // "" | if type == "string" then . elif type == "object" then (.message // tojson | text) else "" end) as $err
  | ($err | plain(120)) as $errText
  | ($err + " " + $reason
     | test("resource_exhausted|resource exhausted|(?<!disk )quota|rate[ _-]?limit|too many requests|\\b(status|code|http|error)[^0-9a-z]{0,3}429\\b|\\b429 too many|out of credits|usage limit"; "i")) as $quota
  | ($in.fullyIdle | if type == "boolean" then . else true end) as $idle
  | (if $new then false else ($p.asked // false) == true end) as $askedBefore
  | (($in.parentConversationId | strings | select(test("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$") and . != $session))
     // ($p.parent // "" | text)) as $parent
  | (if $kind == "stop" then
       (if $quota then "quota"
        elif $reason | test("cancel") then "cancelled"
        elif ($reason | test("error")) or $errText != "" then "error"
        elif $reason | test("^max_|steps_exceeded|token_budget") then "maxSteps"
        elif $askedBefore then "needsInput"
        elif ($idle | not) then "background"
        else "done" end)
     elif $new then ""
     elif $kind == "invocation" then ""
     else $over end) as $ended
  | (if $kind == "stop" then
       (if $ended == "quota" or $ended == "error" then "error"
        elif $ended == "needsInput" then "needsInput"
        elif $ended == "background" then "working"
        else "idle" end)
     elif $kind == "tool-start" and $asks then "needsInput"
     else "working" end) as $state
  | (if $state == $old and ($new | not) and ($p.since | type) == "number" then $p.since else $t end) as $since
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
  | {
      version: 1,
      sessionId: $session,
      project: (if $workspace != "" then $project else ($p.project // "" | text) end),
      workspace: (if $workspace != "" then $workspace else ($p.workspace // "" | text) end),
      model: ($in.modelName // "" | text | plain(40) | if . == "" then ($p.model // "" | text) else . end),
      transcriptPath: ($in.transcriptPath // "" | text | select(startswith("/")) // ($p.transcriptPath // "" | text)
                       | .[0:1024]),
      artifactDir: ($in.artifactDirectoryPath // "" | text | select(startswith("/")) // ($p.artifactDir // "" | text)
                    | .[0:1024]),
      state: $state,
      since: $since,
      turnStarted: (if $new then $t elif ($p.turnStarted | type) == "number" then $p.turnStarted else null end),
      updated: $t,
      ended: $ended,
      error: (if $kind == "stop" and ($ended == "error" or $ended == "quota") then $errText
              elif $new then "" else ($p.error // "" | text) end),
      asked: (if $kind == "invocation" or $kind == "stop" then false
              elif $kind == "tool" then $asks
              elif $asks then true
              else $askedBefore end),
      step: (if $kind == "tool-start" then $call else null end),
      lastStep: (if $kind == "tool" then ($call | del(.started) | .at = $t)
                 elif $new then null else ($p.lastStep // null | if type == "object" then . else null end) end),
      steps: $steps,
      history: $history,
      parent: $parent,
      agent: ($in.agentName // "" | text | plain(40) | if . == "" and $parent != "" then ($p.agent // "" | text) else . end
              | if $parent == "" then "" else . end)
    } as $state
  # A banner, for what wants you: its words, and the same as a URL query.
  | ($state.project | if . == "" then "" else " · " + . end) as $at
  | ($title | plain(100)) as $named
  # A subagent finishing, asking or reaching its step limit is for the conversation that
  # sent it off to take up, which goes on; an error or its quota is told, naming that
  # conversation.
  | ($parent != "") as $sub
  | (if $sub and ($ended == "done" or $ended == "needsInput" or $ended == "maxSteps" or $kind == "tool-start") then null
     elif $kind == "stop" and $ended == "done" then
       {title: ("Gemini finished" + $at), subtitle: $named,
        symbol: "checkmark.circle.fill", tint: "green", style: "card"}
     elif ($kind == "stop" and $ended == "needsInput") or ($kind == "tool-start" and $asks and $old != "needsInput") then
       {title: ("Gemini needs your input" + $at), subtitle: (if $named == "" then "Antigravity is waiting for your answer" else $named end),
        symbol: "questionmark.bubble.fill", tint: "orange", style: "card"}
     elif $kind == "stop" and $ended == "quota" then
       {title: ("Gemini quota reached" + $at),
        subtitle: (if $errText == "" then "Antigravity stopped until the quota resets" else $errText end),
        symbol: "gauge.with.dots.needle.100percent", tint: "orange", style: "card"}
     elif $kind == "stop" and $ended == "error" then
       {title: ("Gemini stopped" + $at), subtitle: (if $errText == "" then "Antigravity stopped on an error" else $errText end),
        symbol: "exclamationmark.triangle.fill", tint: "red", style: "card"}
     elif $kind == "stop" and $ended == "maxSteps" then
       {title: ("Gemini reached its step limit" + $at), subtitle: (if $named == "" then "Antigravity stopped the agent" else $named end),
        symbol: "pause.circle.fill", tint: "orange", style: "card"}
     else null end) as $banner
  | $state,
    (if $banner == null then "" else
       ($banner | map_values(text | one)) as $b
       | (if $kind == "stop" and $ended == "done" then "&event=done" else "" end) as $event
       | ($ended | if . == "" then "needsInput" else . end) as $what
       | (if $sub then $parent else $session end) as $about
       | @sh "what=\($what) query=\("title=\($b.title | @uri)&subtitle=\($b.subtitle | @uri)&symbol=\($b.symbol)&tint=\($b.tint)&style=\($b.style)&activity=gemini&session=\($about)" + $event)"
     end),
    ({t: ($t | floor), event: $kind, conversationId: $session, keys: ($in | keys_unsorted | map(.[0:40]) | .[0:24])}
     + {subagent: ($parent != "")}
     + (if $isTool then {tool: ($in | toolname),
                         toolCallKeys: ($in.toolCall | if type == "object" then keys_unsorted | map(.[0:40]) | .[0:8] else [] end),
                         argKeys: ($in | args | keys_unsorted | map(.[0:40]) | .[0:12])} else {} end)
     + (if $kind == "stop" then {reason: ($reason | .[0:60]),
                                 fullyIdle: ($in.fullyIdle | if type == "boolean" then . else type end),
                                 errorChars: ($err | length), ended: $ended} else {} end)
     | tojson)
  end'
update() { # previous
  printf '%s' "$input" | jq -rc --argjson prev "${1:-null}" --arg kind "$kind" --arg session "$session" \
    --arg workspace "$workspace" --arg project "$project" --arg title "$title" "$program" 2>/dev/null
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
fi
# Every conversation's hooks share the log, cut back to its last 200 lines once it
# passes 400. It keeps what each event carries by its keys alone, never their values
# but a tool's name and how a run stopped.
if [ -n "$logline" ]; then
  printf '%s\n' "$logline" >> "$log"
  if [ "$(wc -l < "$log")" -gt 400 ] && mkdir "$dir/.log.lock" 2>/dev/null; then
    tail -n 200 "$log" > "$log.$$.tmp" && mv -f "$log.$$.tmp" "$log"
    rm -f "$log.$$.tmp"
    rmdir "$dir/.log.lock"
  fi
fi
if [ "$kind" = stop ]; then
  find "$dir" -maxdepth 1 \( \( -name '*.json' -o -name '.*.tmp' \) -mmin +1440 -o -name '.*.lock' -mmin +1 \) -delete
fi

[ -z "$banner" ] && exit 0
what="" query=""
eval "$banner"
# A question only while Antigravity is not in front, where you would see it already. A
# finish goes to Islet, which tells whether its conversation is the one on screen.
if [ "$what" = needsInput ]; then
  front="$(lsappinfo info -only bundleid "$(lsappinfo front)")"
  [[ "$front" =~ (bundleID|CFBundleIdentifier)\"?=\"([^\"]*)\" ]] && [ "${BASH_REMATCH[2]}" = com.google.antigravity ] && exit 0
fi
if [ -n "$ISLET_NOTIFY_DRY" ]; then
  echo "banner: islet://banner?$query" >&2
else
  open -g "islet://banner?$query" </dev/null >/dev/null 2>&1
fi
exit 0
