#!/usr/bin/env bash
#
# summarize-work.sh - turn git history into a plain-English list of completed work.
#
# Reads commits, merges (pull requests / merge requests) and release tags for a
# date range and rewrites them as short past-tense sentences, grouped by kind:
#
#   ### New features
#   - Added CSV export to the reports page (#142).
#   ### Bug fixes
#   - Auth: Fixed token refresh failing after sleep (PROJ-88).
#
# Everything is rule-based (conventional-commit prefixes, verb tense rules,
# branch-name prefixes). This script is explicitly designed
# to work without network calls or LLMs. Works with the stock macOS
# bash 3.2 / BSD tools as well as Linux / GNU tools.
#
# Usage: summarize-work.sh [options] [START [END]]
#        Run with --help for all options.

set -eo pipefail

PROG=$(basename "$0")
US=$(printf '\037')   # field separator used internally
RSC=$(printf '\036')  # record separator for multi-line git output
MONTHS=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

usage() {
  cat <<EOF
Usage: $PROG [options] [START [END]]

Summarize git commits, merges and release tags as human-readable bullet points.

Dates may be YYYY-MM-DD, MM/DD/YYYY, MM/DD/YY, "today" or "yesterday".
One date means that single day. With no dates, the current week (Monday
through today) is used.

Date shortcuts:
  --today              Just today
  --yesterday          Just yesterday
  --this-week          Monday of this week through today (default)
  --last-week          Monday through Sunday of last week
  --days N             The last N days, including today

What to look at:
  -r, --repo PATH      Repository to summarize (repeatable). Defaults to the
                       repository containing the current directory.
  -s, --scan DIR       Summarize every git repository found under DIR
                       (up to 3 levels deep). Repos with no activity are skipped.
  -b, --branch REF     Only follow this branch/ref (repeatable). Default is all
                       local and remote-tracking branches.
  -a, --author TEXT    Only include work whose author name/email matches TEXT
                       (repeatable; any match counts).
  -m, --me             Only include your own work (uses git config user.email).
  -f, --fetch          Run 'git fetch --all --tags' in each repo first.
      --no-tags        Leave release tags out.
      --all-commits    Also list the individual commits that came in through a
                       merged pull request (normally the PR stands in for them).

Output:
  -o, --output FILE    Write the summary to FILE instead of stdout.
      --format FMT     markdown (default), text, or slack.
      --dates          Add the date to each bullet.
      --no-totals      Leave out the closing totals line.
  -h, --help           Show this help.

Examples:
  $PROG 10/20/2026 10/24/2026
  $PROG --me --last-week -o ~/reports/last-week.md
  $PROG --scan ~/code --today --format slack

Cron (every Friday at 5pm, saved to a dated file):
  0 17 * * 5  $PWD/$PROG --me --scan ~/code -o ~/reports/week-\$(date +\\%F).md
EOF
}

die()  { echo "$PROG: $*" >&2; exit 1; }
warn() { echo "$PROG: $*" >&2; }

# ---------------------------------------------------------------- dates

if date -v-1d +%Y >/dev/null 2>&1; then
  days_ago() { date -v-"$1"d +%Y-%m-%d; }          # BSD / macOS
else
  days_ago() { date -d "$1 days ago" +%Y-%m-%d; }  # GNU / Linux
fi

RE_ISO='^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$'
RE_US='^([0-9]{1,2})/([0-9]{1,2})/([0-9]{2}|[0-9]{4})$'

normalize_date() {
  local d=$1 y m dd
  case "$d" in
    today)     days_ago 0; return ;;
    yesterday) days_ago 1; return ;;
  esac
  if [[ $d =~ $RE_ISO ]]; then
    y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; dd=${BASH_REMATCH[3]}
  elif [[ $d =~ $RE_US ]]; then
    m=${BASH_REMATCH[1]}; dd=${BASH_REMATCH[2]}; y=${BASH_REMATCH[3]}
    [ ${#y} -eq 2 ] && y="20$y"
  else
    return 1
  fi
  m=$((10#$m)); dd=$((10#$dd))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ] || return 1
  printf '%04d-%02d-%02d\n' "$((10#$y))" "$m" "$dd"
}

pretty_date() {  # 2026-10-20 -> Oct 20
  local m=${1#*-} d
  d=${m#*-}; m=${m%-*}
  echo "${MONTHS[$((10#$m - 1))]} $((10#$d))"
}

range_label() {
  local y1=${SINCE%%-*} y2=${UNTIL%%-*}
  if [ "$SINCE" = "$UNTIL" ]; then
    echo "$(pretty_date "$SINCE"), $y1"
  elif [ "$y1" = "$y2" ]; then
    echo "$(pretty_date "$SINCE") – $(pretty_date "$UNTIL"), $y1"
  else
    echo "$(pretty_date "$SINCE"), $y1 – $(pretty_date "$UNTIL"), $y2"
  fi
}

# ---------------------------------------------------------------- options

SINCE=""; UNTIL=""; PRESET=""
REPOS=(); SCAN_DIRS=(); BRANCHES=(); AUTHORS=()
ME=""; FETCH=""; NO_TAGS=""; ALL_COMMITS=""
OUTPUT=""; FORMAT="markdown"; SHOW_DATES=0; SHOW_TOTALS=1
POSITIONAL=()

need_arg() { [ -n "$2" ] || die "option $1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --today|--yesterday|--this-week|--last-week) PRESET=${1#--} ;;
    --days)          need_arg "$1" "$2"; PRESET="days:$2"; shift ;;
    -r|--repo)       need_arg "$1" "$2"; REPOS+=("$2"); shift ;;
    -s|--scan)       need_arg "$1" "$2"; SCAN_DIRS+=("$2"); shift ;;
    -b|--branch)     need_arg "$1" "$2"; BRANCHES+=("$2"); shift ;;
    -a|--author)     need_arg "$1" "$2"; AUTHORS+=("$2"); shift ;;
    -m|--me)         ME=1 ;;
    -f|--fetch)      FETCH=1 ;;
    --no-tags)       NO_TAGS=1 ;;
    --all-commits)   ALL_COMMITS=1 ;;
    -o|--output)     need_arg "$1" "$2"; OUTPUT=$2; shift ;;
    --format)        need_arg "$1" "$2"; FORMAT=$2; shift ;;
    --dates)         SHOW_DATES=1 ;;
    --no-totals)     SHOW_TOTALS=0 ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; POSITIONAL+=("$@"); break ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               POSITIONAL+=("$1") ;;
  esac
  shift
done

case "$FORMAT" in
  markdown|md) FORMAT=markdown ;;
  text|plain)  FORMAT=text ;;
  slack)       ;;
  *) die "unknown format '$FORMAT' (use markdown, text or slack)" ;;
esac

if [ ${#POSITIONAL[@]} -gt 2 ]; then
  die "expected at most two dates, got: ${POSITIONAL[*]}"
elif [ ${#POSITIONAL[@]} -ge 1 ]; then
  SINCE=$(normalize_date "${POSITIONAL[0]}") || die "can't read date '${POSITIONAL[0]}'"
  UNTIL=$SINCE
  if [ ${#POSITIONAL[@]} -eq 2 ]; then
    UNTIL=$(normalize_date "${POSITIONAL[1]}") || die "can't read date '${POSITIONAL[1]}'"
  fi
else
  dow=$(date +%u)  # 1 = Monday
  case "${PRESET:-this-week}" in
    today)     SINCE=$(days_ago 0);  UNTIL=$SINCE ;;
    yesterday) SINCE=$(days_ago 1);  UNTIL=$SINCE ;;
    this-week) SINCE=$(days_ago $((dow - 1))); UNTIL=$(days_ago 0) ;;
    last-week) SINCE=$(days_ago $((dow + 6))); UNTIL=$(days_ago "$dow") ;;
    days:*)
      n=${PRESET#days:}
      [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || die "--days needs a positive number"
      SINCE=$(days_ago $((n - 1))); UNTIL=$(days_ago 0) ;;
  esac
fi

[[ "$SINCE" > "$UNTIL" ]] && die "start date $SINCE is after end date $UNTIL"

for dir in "${SCAN_DIRS[@]}"; do
  [ -d "$dir" ] || die "not a directory: $dir"
  while IFS= read -r g; do
    REPOS+=("$(dirname "$g")")
  done < <(find "$dir" -maxdepth 3 -name .git -not -path '*/node_modules/*' 2>/dev/null | sort)
done

if [ ${#REPOS[@]} -eq 0 ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die "not inside a git repository; use --repo PATH or --scan DIR"
  REPOS=("$top")
fi

[ -n "$OUTPUT" ] && exec > "$OUTPUT"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/summarize-work.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- awk programs

# Flattens `git log --merges` records (whose bodies span several lines) into one
# line each and pulls out the PR/MR title. Also flags "sync" merges such as
# "Merge branch 'main' into feature-x", which are housekeeping, not work.
read -r -d '' FLATTEN_AWK <<'AWK' || true
BEGIN { RS = R; FS = U; OFS = U }
{
  sub(/^\n+/, "")
  if ($1 == "") next
  title = ""; mref = ""
  n = split($5, L, "\n")
  for (i = 1; i <= n; i++) {
    line = L[i]; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
    if (line == "") continue
    if (line ~ /^See merge request [^ ]*![0-9]+/) { mref = line; sub(/.*!/, "!", mref); continue }
    if (line ~ /^(Signed-off-by|Co-authored-by|Reviewed-by|Approved-by|Conflicts|# )/) continue
    if (title == "") title = line
  }
  s = $4
  sync = 0
  if (s ~ /^Merge (remote-tracking )?branch '(origin\/|upstream\/)?(main|master|develop|development|dev|trunk|staging)'/) sync = 1
  if (s ~ /^Merge (remote-tracking )?branch '[^']+' of /) sync = 1
  if (s ~ /^Merge (tag|commit) /) sync = 1
  if (s ~ /^Merge pull request #[0-9]+ from [^ ]+\/(main|master|develop)$/) sync = 1
  print "M", $2, $1, s, title, $3, sync, mref
}
AWK

# Turns the combined, date-sorted stream of tags (T), merges (M) and commits (C)
# into grouped sentences.
read -r -d '' RENDER_AWK <<'AWK' || true
BEGIN {
  FS = US
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MON, " ")
  NSEC = split("releases features fixes improvements docs tests maintenance other", ORDER, " ")
  TITLE["releases"] = "Releases";        TITLE["features"] = "New features"
  TITLE["fixes"] = "Bug fixes";          TITLE["improvements"] = "Improvements"
  TITLE["docs"] = "Documentation";       TITLE["tests"] = "Testing"
  TITLE["maintenance"] = "Maintenance";  TITLE["other"] = "Other work"

  # What to say when the message has no recognizable verb.
  NOVERB["features"] = "Added ";   NOVERB["fixes"] = "Fixed ";     NOVERB["improvements"] = "Improved "
  NOVERB["docs"] = "Updated ";  NOVERB["tests"] = "Added tests for "
  NOVERB["maintenance"] = "Updated "

  # Conventional-commit types.
  split("feat feature features", tmp, " ");        for (i in tmp) CTYPE[tmp[i]] = "features"
  split("fix bugfix hotfix bug", tmp, " ");        for (i in tmp) CTYPE[tmp[i]] = "fixes"
  split("perf refactor style improvement improve ux ui", tmp, " "); for (i in tmp) CTYPE[tmp[i]] = "improvements"
  split("docs doc documentation", tmp, " ");       for (i in tmp) CTYPE[tmp[i]] = "docs"
  split("test tests testing", tmp, " ");           for (i in tmp) CTYPE[tmp[i]] = "tests"
  split("chore build ci deps dep release revert config infra ops", tmp, " "); for (i in tmp) CTYPE[tmp[i]] = "maintenance"

  # Known verbs (base form) and the section they usually belong to.
  VERBS["features"] = "add implement create introduce support enable allow expose integrate build generate launch provide wire hook connect register extend append inject"
  VERBS["fixes"] = "fix resolve correct patch repair address prevent handle catch guard avoid bypass restore recover"
  VERBS["improvements"] = "update improve refactor optimize optimise simplify rework redesign restructure reorganize consolidate unify standardize polish tweak adjust tune speed rename move replace change convert extract split increase decrease reduce limit raise lower harden secure clarify modify rewrite inline memoize normalize sanitize validate ensure cache sort filter group expand collapse align center style hide show display render load fetch parse return ignore include exclude export import sync track monitor log retry use switch make set reset keep mark label translate localize encode decode encrypt escape upload download open close accept reject pass drop remove delete strip trim disable deprecate wrap unwrap clean tidy finish complete start continue try apply define declare specify schedule check verify measure save store send bring map swap skip flag plan cut stop"
  VERBS["docs"] = "document"
  VERBS["tests"] = "test mock stub"
  VERBS["maintenance"] = "bump upgrade downgrade install uninstall lint format configure migrate revert release publish deploy merge pin unpin tag commit submit run rerun debug plug ship"

  n = split("build:built make:made write:wrote rewrite:rewrote run:ran rerun:reran set:set reset:reset split:split keep:kept send:sent hide:hid bring:brought cut:cut catch:caught speed:sped drop:dropped stop:stopped ship:shipped wrap:wrapped unwrap:unwrapped strip:stripped map:mapped plan:planned pin:pinned unpin:unpinned tag:tagged log:logged swap:swapped trim:trimmed skip:skipped flag:flagged commit:committed submit:submitted debug:debugged plug:plugged format:formatted", tmp, " ")
  for (i = 1; i <= n; i++) { split(tmp[i], p, ":"); IRR[p[1]] = p[2] }

  for (sec in VERBS) {
    n = split(VERBS[sec], tmp, " ")
    for (i = 1; i <= n; i++) {
      v = tmp[i]; VSEC[v] = sec
      PAST[v] = (v in IRR) ? IRR[v] : regular_past(v)
      PASTREV[PAST[v]] = v
    }
  }
  # Plurals that are nearly always nouns in commit messages ("Tests for X").
  split("tests logs docs styles mocks labels filters releases tags pins maps flags sets cuts plans stubs", tmp, " ")
  for (i in tmp) NOUNS[tmp[i]] = 1

  while ((getline line < XFILE) > 0) EXCL[line] = 1
}

function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function ucfirst(s) { return toupper(substr(s, 1, 1)) substr(s, 2) }
function lcfirst(s) {
  if (substr(s, 2, 1) ~ /[A-Z]/) return s   # keep acronyms like API or README
  return tolower(substr(s, 1, 1)) substr(s, 2)
}
function pretty(d,  p) { split(d, p, "-"); return MON[p[2] + 0] " " (p[3] + 0) }
function plural(n, word) { return n " " word (n == 1 ? "" : "s") }
function regular_past(v) {
  if (v ~ /e$/) return v "d"
  if (v ~ /[^aeiou]y$/) return substr(v, 1, length(v) - 1) "ied"
  return v "ed"
}
function add_ref(refs, r) { if (r == "") return refs; return refs (refs != "" ? ", " : "") r }

# Returns the base verb for a word in any common form, or "" if it is not a verb.
function base_of(x, nxt,   n, s) {
  if (x in VSEC) return x
  if (x in PASTREV) return PASTREV[x]
  n = length(x)
  if (x ~ /s$/ && n > 3) {
    if (x in NOUNS || nxt ~ /^(to|for|in|on|of|from|with|and|are|were|have|is)$/) return ""
    if (x ~ /ies$/) { s = substr(x, 1, n - 3) "y"; if (s in VSEC) return s }
    if (x ~ /(xes|ches|shes|sses|zes)$/) { s = substr(x, 1, n - 2); if (s in VSEC) return s }
    s = substr(x, 1, n - 1); if (s in VSEC) return s
  }
  if (x ~ /ing$/ && n >= 5) {
    s = substr(x, 1, n - 3)
    if (s in VSEC) return s
    if ((s "e") in VSEC) return s "e"
    s = substr(s, 1, length(s) - 1)          # dropping -> drop
    if (s in VSEC) return s
  }
  return ""
}

# Rewrites one commit/PR title as a past-tense sentence. Sets SECTION and DEPNAME.
#   hint      section suggested by a branch prefix like fix/ or feature/
#   fallback  wording when nothing else applies ("Worked on ")
#   extra_ref PR/MR number to cite
function humanize(s, hint, fallback, extra_ref,   refs, t, ctype, scope, sec, breaking, out, lw, w, rest, base, nw, W) {
  SECTION = ""; DEPNAME = ""
  refs = (extra_ref != "") ? extra_ref : ""
  s = trim(s)
  gsub(/\[(skip ci|ci skip|no ci|skip-ci)\]/, "", s)
  gsub(/:[a-z0-9_+-]+:[ ]*/, "", s)           # gitmoji shortcodes
  s = trim(s)

  while (match(s, /\(#[0-9]+\)$/)) {          # "Title (#123)" from squash merges
    t = substr(s, RSTART + 1, RLENGTH - 2)
    if (index(", " refs ",", ", " t ",") == 0) refs = add_ref(refs, t)
    s = trim(substr(s, 1, RSTART - 1))
  }
  if (match(s, /^\[?[A-Z][A-Z0-9]+-[0-9]+\]?:?[ ]+/)) {   # "PROJ-12: ..." ticket IDs
    t = substr(s, 1, RLENGTH); gsub(/[^A-Z0-9-]/, "", t)
    refs = add_ref(refs, t)
    s = substr(s, RLENGTH + 1)
  }

  ctype = ""; scope = ""; sec = ""; breaking = 0
  if (match(s, /^[A-Za-z]+(\([^)]*\))?!?:[ ]+/)) {
    t = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
    ctype = t; sub(/[(!:].*/, "", ctype); ctype = tolower(ctype)
    if (t ~ /\(/) { scope = t; sub(/^[^(]*\(/, "", scope); sub(/\).*/, "", scope) }
    if (ctype in CTYPE) {
      sec = CTYPE[ctype]; s = rest; breaking = (t ~ /!:/)
    } else if (scope == "" && t ~ /^[a-z]/ && base_of(ctype, "") == "") {
      scope = ctype; s = rest                  # "api: add endpoint" style
    } else {
      scope = ""
    }
  }
  if (sec == "" && hint != "") sec = hint
  if (scope ~ /^(deps|deps-dev|dependencies)$/) { scope = ""; if (sec == "") sec = "maintenance" }

  lw = tolower(s)
  if (sec == "") {
    if (lw ~ /(readme|documentation|changelog|docstring|jsdoc|(^| )docs?( |$))/) sec = "docs"
    else if (lw ~ /((^| )(unit |integration |e2e )?tests?( |$)|test coverage|(^| )specs?( |$))/ && lw !~ /^fix/) sec = "tests"
  }

  if (lw ~ /^(initial commit|first commit|init)$/) {
    out = "Set up the initial project"; if (sec == "") sec = "features"
  } else if (s ~ /^[Rr]evert "/) {
    t = s; sub(/^[Rr]evert "/, "", t); sub(/"$/, "", t)
    out = "Rolled back the earlier change \"" t "\""; sec = "maintenance"
  } else if (match(lw, /^(don't|dont|do not) /)) {
    out = "Made sure we don't " substr(s, RLENGTH + 1); if (sec == "") sec = "fixes"
  } else {
    nw = split(s, W, " ")
    w = W[1]; rest = trim(substr(s, length(w) + 1))
    lw = tolower(w); gsub(/[^a-z']/, "", lw)
    base = base_of(lw, tolower(W[2]))
    if (lw == "cleanup") {
      out = "Cleaned up" (rest != "" ? " " rest : ""); if (sec == "") sec = "improvements"
    } else if (lw == "setup") {
      out = "Set up" (rest != "" ? " " rest : ""); if (sec == "") sec = "features"
    } else if (lw == "readme" && rest == "") {
      out = "Updated the README"; sec = "docs"
    } else if (base == "support") {
      sub(/^for /, "", rest)
      out = "Added support for " rest; if (sec == "") sec = "features"
    } else if (base != "") {
      out = ucfirst(PAST[base]) (rest != "" ? " " rest : "")
      if (sec == "") sec = VSEC[base]
      if (base ~ /^(bump|upgrade|update)$/ && rest ~ /^[^ ]+ from [^ ]+ to [^ ]+/) {
        DEPNAME = rest; sub(/ .*/, "", DEPNAME); sec = "maintenance"
      }
    } else {
      if (sec == "") sec = "other"
      t = (sec == "other") ? fallback : NOVERB[sec]
      if (sec == "tests" && tolower(s) ~ /^(unit |integration |e2e )?tests? /) t = "Added "
      if (sec == "docs" && tolower(s) ~ /^(docs?|documentation) /) t = "Updated "
      out = t lcfirst(s)
    }
  }

  sub(/[ .!;,:]+$/, "", out)
  if (scope != "") out = (length(scope) <= 3 ? toupper(scope) : ucfirst(scope)) ": " out
  if (breaking) refs = add_ref("breaking change", refs)
  if (refs != "") out = out " (" refs ")"
  SECTION = sec
  return out
}

# Splits a branch name into readable words; sets BRHINT and BRTICKET.
function branch_text(b,   pfx) {
  BRHINT = ""; BRTICKET = ""
  sub(/^(origin|upstream)\//, "", b)
  if (match(b, /^[A-Za-z]+\//)) {
    pfx = tolower(substr(b, 1, RLENGTH - 1)); b = substr(b, RLENGTH + 1)
    if (pfx ~ /^(feat|feature|features)$/)         BRHINT = "features"
    else if (pfx ~ /^(fix|bugfix|hotfix|bug)$/)    BRHINT = "fixes"
    else if (pfx ~ /^(docs?)$/)                    BRHINT = "docs"
    else if (pfx ~ /^(chore|build|ci|deps)$/)      BRHINT = "maintenance"
    else if (pfx ~ /^(refactor|perf|improvement)$/) BRHINT = "improvements"
    else if (pfx ~ /^tests?$/)                     BRHINT = "tests"
  }
  if (match(b, /^[A-Za-z][A-Za-z0-9]+-[0-9]+/) && substr(b, 1, RLENGTH) ~ /[0-9]$/ && substr(b, 1, 1) ~ /[A-Z]/) {
    BRTICKET = substr(b, 1, RLENGTH); b = substr(b, RLENGTH + 1)
  }
  gsub(/[-_\/]+/, " ", b)
  return trim(b)
}

function add(sec, text, d,   key) {
  key = tolower(text)
  if (key in SEEN) return 0
  SEEN[key] = 1
  if (SHOW_DATES) text = text " — " pretty(d)
  else text = text "."
  N[sec]++; B[sec, N[sec]] = text
  return 1
}

function noise(s,   lw) {
  lw = tolower(trim(s))
  return lw ~ /^(wip|fixup!|squash!|amend!|tmp|temp|test commit)([ :]|$)/ || lw !~ /[a-z0-9]/ ||
         lw ~ /^merge (branch|remote-tracking)/
}

$1 == "T" {
  # T, date, tag, annotation, previous tag, commit count
  s = "Released " $3 " on " pretty($2)
  msg = trim($4)
  if (msg != "" && msg != $3) s = s " (\"" msg "\")"
  if ($6 + 0 > 0) {
    if ($5 != "") s = s ", which included " plural($6 + 0, "change") " since " $5
    else s = s ", the first tagged release"
  }
  key = tolower(s); if (!(key in SEEN)) { SEEN[key] = 1; N["releases"]++; B["releases", N["releases"]] = s "." ; NT++ }
  next
}

$1 == "M" {
  # M, date, hash, subject, title, parents, sync, mr-ref
  if ($7 == 1) next
  subj = $4; title = trim($5); ref = ""; br = ""
  if (subj ~ /^Merge pull request #[0-9]+ from /) {
    t = subj; sub(/^Merge pull request #/, "", t)
    ref = t; sub(/ .*/, "", ref); ref = "#" ref
    br = t; sub(/^[0-9]+ from /, "", br); sub(/^[^\/]+\//, "", br)
  } else if (subj ~ /^Merged PR [0-9]+: /) {                    # Azure DevOps
    t = subj; sub(/^Merged PR /, "", t)
    ref = t; sub(/:.*/, "", ref); ref = "#" ref
    title = t; sub(/^[0-9]+: /, "", title)
  } else if (subj ~ /^Merged in [^ ]+/) {                       # Bitbucket
    br = subj; sub(/^Merged in /, "", br); sub(/ .*/, "", br)
    if (match(subj, /pull request #[0-9]+/)) { ref = substr(subj, RSTART + 13, RLENGTH - 13) }
  } else if (match(subj, /^Merge branch '[^']+'/)) {
    br = substr(subj, 15, RLENGTH - 15)
    if (title ~ /^Merge branch/) title = ""
  } else {
    title = subj
  }
  if ($8 != "") ref = $8
  text = (br != "") ? branch_text(br) : ""
  if (title != "") text = title
  if (text == "") next
  if (BRTICKET != "" && index(text, BRTICKET) == 0) ref = add_ref(ref, BRTICKET)
  s = humanize(text, BRHINT, "Merged work on ", ref)
  if (add(SECTION, s, $2)) NM++
  next
}

$1 == "C" {
  if ($3 in EXCL || noise($4)) next
  s = humanize($4, "", "Worked on ", "")
  if (DEPNAME != "") {
    if (!(DEPNAME in DEPSEEN)) { DEPSEEN[DEPNAME] = 1; ND++; DEPS[ND] = DEPNAME; DEPLINE[ND] = s; DEPDATE[ND] = $2 }
    next
  }
  add(SECTION, s, $2)
  next
}

END {
  if (ND > 0 && ND <= 3) {
    for (i = 1; i <= ND; i++) add("maintenance", DEPLINE[i], DEPDATE[i])
  } else if (ND > 3) {
    s = "Updated " ND " dependencies, including " DEPS[1] ", " DEPS[2] " and " DEPS[3]
    if (ND > 3) s = s " (plus " plural(ND - 3, "other") ")"
    add("maintenance", s, DEPDATE[ND])
  }

  total = 0
  for (i = 1; i <= NSEC; i++) total += N[ORDER[i]]
  if (total == 0) exit

  if (FMT == "markdown") print "## " REPO
  else if (FMT == "slack") print "*" REPO "*"
  else { print REPO; u = REPO; gsub(/./, "=", u); print u }

  for (i = 1; i <= NSEC; i++) {
    sec = ORDER[i]
    if (!N[sec]) continue
    print ""
    if (FMT == "markdown") print "### " TITLE[sec]
    else if (FMT == "slack") print "_" TITLE[sec] "_"
    else print TITLE[sec] ":"
    for (j = 1; j <= N[sec]; j++) {
      if (FMT == "markdown") print "- " B[sec, j]
      else if (FMT == "slack") print "• " B[sec, j]
      else print "  • " B[sec, j]
    }
  }

  if (SHOW_TOTALS) {
    np = 0
    if (TOTAL + 0 > 0) P[++np] = plural(TOTAL + 0, "commit")
    if (NM > 0)        P[++np] = plural(NM, "merge")
    if (NT > 0)        P[++np] = plural(NT, "release")
    if (np > 0) {
      s = P[1]
      for (k = 2; k <= np; k++) s = s (k == np ? " and " : ", ") P[k]
      s = "Altogether that's " s "."
      print ""
      if (FMT == "markdown") print "_" s "_"
      else if (FMT == "slack") print "_" s "_"
      else print s
    }
  }
}
AWK

# ---------------------------------------------------------------- per repo

summarize_repo() {
  local repo=$1 name
  name=$(basename "$repo")
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { warn "skipping $repo (not a git repository)"; return 0; }

  if [ -n "$FETCH" ]; then
    git -C "$repo" fetch --all --tags --quiet 2>/dev/null || warn "fetch failed in $name; using local data"
  fi

  local refargs=() authargs=() range
  if [ ${#BRANCHES[@]} -gt 0 ]; then refargs=("${BRANCHES[@]}"); else refargs=(--branches --remotes); fi
  local a
  for a in "${AUTHORS[@]}"; do authargs+=("--author=$a"); done
  if [ -n "$ME" ]; then
    a=$(git -C "$repo" config user.email || true)
    [ -n "$a" ] || die "--me needs 'git config user.email' to be set (in $name)"
    authargs+=("--author=$a")
  fi
  range=(--since="$SINCE 00:00:00" --until="$UNTIL 23:59:59")

  local mfile="$TMP/merges" cfile="$TMP/commits" tfile="$TMP/tags" xfile="$TMP/exclude"

  git -C "$repo" log --merges --reverse "${refargs[@]}" "${range[@]}" "${authargs[@]}" \
      --date=short --format="%H${US}%cd${US}%P${US}%s${US}%b${RSC}" 2>/dev/null |
    awk -v R="$RSC" -v U="$US" "$FLATTEN_AWK" > "$mfile" || true

  git -C "$repo" log --no-merges --reverse "${refargs[@]}" "${range[@]}" "${authargs[@]}" \
      --date=short --format="C${US}%cd${US}%H${US}%s" 2>/dev/null > "$cfile" || true

  # Commits that arrived through a merged PR are represented by the PR itself.
  : > "$xfile"
  if [ -z "$ALL_COMMITS" ]; then
    local _t _d _h _s _ti parents sync _r
    while IFS="$US" read -r _t _d _h _s _ti parents sync _r; do
      [ "$sync" = 1 ] && continue
      set -- $parents
      [ $# -ge 2 ] || continue
      git -C "$repo" rev-list "$1..$2" >> "$xfile" 2>/dev/null || true
    done < "$mfile"
  fi

  : > "$tfile"
  if [ -z "$NO_TAGS" ]; then
    local tag tdate otype msg prev count
    git -C "$repo" for-each-ref refs/tags --sort=creatordate \
        --format="%(refname:short)${US}%(creatordate:short)${US}%(objecttype)${US}%(contents:subject)" |
    while IFS="$US" read -r tag tdate otype msg; do
      [[ "$tdate" < "$SINCE" || "$tdate" > "$UNTIL" ]] && continue
      [ "$otype" = tag ] || msg=""
      prev=$(git -C "$repo" describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)
      if [ -n "$prev" ]; then
        count=$(git -C "$repo" rev-list --count --no-merges "$prev..$tag" 2>/dev/null || echo 0)
      else
        count=$(git -C "$repo" rev-list --count --no-merges "$tag" 2>/dev/null || echo 0)
      fi
      printf 'T%s%s%s%s%s%s%s%s%s%s\n' "$US" "$tdate" "$US" "$tag" "$US" "$msg" "$US" "$prev" "$US" "$count"
    done > "$tfile"
  fi

  local total
  total=$(git -C "$repo" rev-list --count --no-merges "${refargs[@]}" "${range[@]}" "${authargs[@]}" 2>/dev/null || echo 0)

  cat "$tfile" "$mfile" "$cfile" | sort -t "$US" -k2,2 -s |
    awk -v US="$US" -v XFILE="$xfile" -v FMT="$FORMAT" -v REPO="$name" \
        -v TOTAL="$total" -v SHOW_DATES="$SHOW_DATES" -v SHOW_TOTALS="$SHOW_TOTALS" "$RENDER_AWK"
}

# ---------------------------------------------------------------- main

LABEL=$(range_label)
case "$FORMAT" in
  markdown) printf '# Work completed: %s\n' "$LABEL" ;;
  slack)    printf '*Work completed: %s*\n' "$LABEL" ;;
  text)     printf 'Work completed: %s\n' "$LABEL" ;;
esac

printed=0
for repo in "${REPOS[@]}"; do
  out=$(summarize_repo "$repo")
  if [ -n "$out" ]; then
    printf '\n%s\n' "$out"
    printed=$((printed + 1))
  fi
done

if [ "$printed" -eq 0 ]; then
  printf '\nNo commits, merges or releases found for %s.\n' "$LABEL"
fi
