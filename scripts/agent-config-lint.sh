#!/bin/bash
# agent-config-lint v1 — source of truth: dotfiles/scripts/agent-config-lint.sh; copies in other repos are refreshed by templates/agent-repo/bootstrap.sh
# agent-config-lint.sh — enforce the harness-neutral repo contract.
# Must run under macOS default bash 3.2: no mapfile, no associative arrays,
# no ${var,,}. POSIX-ish constructs only. See .agents/knowledge/harness-neutral-layout.md
# section 7 for the rules this implements.

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "agent-config-lint: not a git repository" >&2
  exit 1
fi
cd "$ROOT" || exit 1

FAIL_COUNT=0
WARN_COUNT=0

pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2: $3"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo "WARN $1 $2: $3"; WARN_COUNT=$((WARN_COUNT + 1)); }

# Tracked files whose basename is exactly $1.
tracked_named() {
  name="$1"
  git ls-files | while IFS= read -r f; do
    base=$(basename "$f")
    if [ "$base" = "$name" ]; then
      printf '%s\n' "$f"
    fi
  done
}

# Print a file's content after dropping leading blank lines and leading
# single-line HTML comments (<!-- ... -->), trailing blank lines trimmed too.
stripped_body() {
  # Command substitution around this call strips all trailing newlines, so
  # trailing blank lines in the source file collapse away on their own.
  awk '
    BEGIN { skip = 1 }
    {
      if (skip) {
        t = $0
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t == "") next
        if (t ~ /^<!--.*-->$/) next
        skip = 0
      }
      print
    }
  ' "$1"
}

# Print a file with fenced code blocks (``` ... ```) and inline backtick
# spans removed, for the bare-@ and host-name scans.
strip_fences_and_backticks() {
  awk '
    /^```/ { infence = !infence; next }
    { if (!infence) print }
  ' "$1" | sed -E 's/`[^`]*`//g'
}

################################################################################
# Optional .agent-lint-ignore: one glob pattern per line, matched against the
# repo-relative path with bash `case`. Blank lines and lines starting with #
# are ignored. `**` is not given any special find(1)-style meaning here — a
# bare `*` in a `case` pattern already matches across "/" (this is string
# pattern matching, not filesystem globbing), so `projects/*` and
# `projects/**` match exactly the same set of paths. Only the path-based
# rules (1, 4, 5, 7, 9) honor this file; rules 2, 3, 6, 8, 10 do not.
################################################################################
IGNORE_FILE="$ROOT/.agent-lint-ignore"
ignore_patterns=""
if [ -f "$IGNORE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      '#'*) continue ;;
    esac
    ignore_patterns="$ignore_patterns
$trimmed"
  done < "$IGNORE_FILE"
fi

# Usage: is_ignored <repo-relative-path>; returns 0 (true) if any pattern matches.
is_ignored() {
  candidate="$1"
  [ -z "$ignore_patterns" ] && return 1
  old_ifs="$IFS"
  IFS='
'
  # Disable pathname expansion for this loop: without it, an unquoted
  # pattern like "projects/*" is glob-expanded against the cwd's actual
  # files before `case` ever sees it, instead of being matched literally.
  set -f
  result=1
  for pat in $ignore_patterns; do
    [ -z "$pat" ] && continue
    case "$candidate" in
      $pat) result=0; break ;;
    esac
  done
  set +f
  IFS="$old_ifs"
  return "$result"
}

################################################################################
# Rule 1 (FAIL): every tracked CLAUDE.md, after dropping leading HTML-comment /
# blank lines, is exactly "@AGENTS.md".
################################################################################
rule1_bad=""
files=$(tracked_named "CLAUDE.md")
if [ -n "$files" ]; then
  echo "$files" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_ignored "$f"; then
      echo "SKIP:$f"
      continue
    fi
    body=$(stripped_body "$f")
    if [ "$body" != "@AGENTS.md" ]; then
      echo "BAD:$f"
    fi
  done > /tmp/agent-config-lint.rule1.$$
  while IFS= read -r line; do
    case "$line" in
      SKIP:*) echo "SKIP 1 ${line#SKIP:} (.agent-lint-ignore)" ;;
      BAD:*) rule1_bad="$rule1_bad ${line#BAD:}" ;;
    esac
  done < /tmp/agent-config-lint.rule1.$$
  rm -f /tmp/agent-config-lint.rule1.$$
fi
rule1_bad=$(echo "$rule1_bad" | sed -e 's/^ *//' -e 's/ *$//')
if [ -n "$rule1_bad" ]; then
  fail 1 "CLAUDE.md-pointer" "not exactly '@AGENTS.md' in: $rule1_bad"
else
  pass 1 "CLAUDE.md-pointer"
fi

################################################################################
# Rule 2 (FAIL): .claude/skills exists and is a symlink resolving to .agents/skills.
################################################################################
if [ -L .claude/skills ]; then
  resolved=$(cd .claude/skills 2>/dev/null && pwd -P)
  expected=$(cd .agents/skills 2>/dev/null && pwd -P)
  if [ -n "$resolved" ] && [ -n "$expected" ] && [ "$resolved" = "$expected" ]; then
    pass 2 "claude-skills-symlink"
  else
    fail 2 "claude-skills-symlink" ".claude/skills does not resolve to .agents/skills"
  fi
else
  fail 2 "claude-skills-symlink" ".claude/skills is missing or not a symlink"
fi

################################################################################
# Rule 3 (FAIL): no tracked AGENTS.override.md.
################################################################################
overrides=$(tracked_named "AGENTS.override.md")
if [ -n "$overrides" ]; then
  fail 3 "no-agents-override" "tracked: $(echo "$overrides" | tr '\n' ' ')"
else
  pass 3 "no-agents-override"
fi

################################################################################
# Rule 4 (FAIL): no tracked AGENTS.md contains a bare @ import.
################################################################################
rule4_hits=""
agents_files=$(tracked_named "AGENTS.md")
agents_files_checked=""
if [ -n "$agents_files" ]; then
  echo "$agents_files" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_ignored "$f"; then
      echo "SKIP:$f"
      continue
    fi
    echo "KEEP:$f"
    hit=$(strip_fences_and_backticks "$f" | grep -nE '(^|[[:space:]])@[A-Za-z0-9_./~-]')
    if [ -n "$hit" ]; then
      echo "BAD:$f: $hit"
    fi
  done > /tmp/agent-config-lint.rule4.$$
  while IFS= read -r line; do
    case "$line" in
      SKIP:*) echo "SKIP 4 ${line#SKIP:} (.agent-lint-ignore)" ;;
      KEEP:*) agents_files_checked="$agents_files_checked
${line#KEEP:}" ;;
      BAD:*) rule4_hits="$rule4_hits
${line#BAD:}" ;;
    esac
  done < /tmp/agent-config-lint.rule4.$$
  rm -f /tmp/agent-config-lint.rule4.$$
fi
if [ -n "$rule4_hits" ]; then
  fail 4 "no-bare-at-import" "$(echo "$rule4_hits" | tr '\n' ' | ')"
else
  pass 4 "no-bare-at-import"
fi

################################################################################
# Rule 5 (FAIL): sum of tracked, non-ignored AGENTS.md bytes < 32768.
################################################################################
if [ -n "$agents_files" ]; then
  echo "$agents_files" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_ignored "$f"; then
      echo "SKIP 5 $f (.agent-lint-ignore)"
    fi
  done
fi
total_bytes=0
if [ -n "$agents_files_checked" ]; then
  echo "$agents_files_checked" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    wc -c < "$f"
  done > /tmp/agent-config-lint.rule5.$$
  while IFS= read -r n; do
    total_bytes=$((total_bytes + n))
  done < /tmp/agent-config-lint.rule5.$$
  rm -f /tmp/agent-config-lint.rule5.$$
fi
if [ "$total_bytes" -ge 32768 ]; then
  fail 5 "agents-md-size-budget" "$total_bytes bytes >= 32768"
else
  pass 5 "agents-md-size-budget"
fi

################################################################################
# Rule 6 (FAIL): every .agents/skills/*/SKILL.md has name: and description: frontmatter.
################################################################################
skill_files=$(git ls-files | grep -E '^\.agents/skills/[^/]+/SKILL\.md$')
if [ -z "$skill_files" ]; then
  pass 6 "skill-frontmatter"
else
  rule6_bad=""
  echo "$skill_files" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    fm=$(awk '
      NR == 1 && $0 ~ /^---[ \t]*$/ { infm = 1; next }
      infm && $0 ~ /^---[ \t]*$/ { exit }
      infm { print }
    ' "$f")
    has_name=$(printf '%s\n' "$fm" | grep -cE '^name:')
    has_desc=$(printf '%s\n' "$fm" | grep -cE '^description:')
    if [ "$has_name" -eq 0 ] || [ "$has_desc" -eq 0 ]; then
      echo "$f"
    fi
  done > /tmp/agent-config-lint.rule6.$$
  rule6_bad=$(cat /tmp/agent-config-lint.rule6.$$)
  rm -f /tmp/agent-config-lint.rule6.$$
  if [ -n "$rule6_bad" ]; then
    fail 6 "skill-frontmatter" "missing name/description in: $(echo "$rule6_bad" | tr '\n' ' ')"
  else
    pass 6 "skill-frontmatter"
  fi
fi

################################################################################
# Rule 7 (FAIL): no tracked CLAUDE.local.md, AGENTS.local.md, AGENTS.override.md,
# or .claude/*.local.md.
################################################################################
rule7_candidates=""
for name in CLAUDE.local.md AGENTS.local.md AGENTS.override.md; do
  hit=$(tracked_named "$name")
  if [ -n "$hit" ]; then
    rule7_candidates="$rule7_candidates
$hit"
  fi
done
claude_local=$(git ls-files | grep -E '^\.claude/[^/]*\.local\.md$')
if [ -n "$claude_local" ]; then
  rule7_candidates="$rule7_candidates
$claude_local"
fi
rule7_hits=""
if [ -n "$rule7_candidates" ]; then
  echo "$rule7_candidates" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_ignored "$f"; then
      echo "SKIP:$f"
    else
      echo "BAD:$f"
    fi
  done > /tmp/agent-config-lint.rule7.$$
  while IFS= read -r line; do
    case "$line" in
      SKIP:*) echo "SKIP 7 ${line#SKIP:} (.agent-lint-ignore)" ;;
      BAD:*) rule7_hits="$rule7_hits ${line#BAD:}" ;;
    esac
  done < /tmp/agent-config-lint.rule7.$$
  rm -f /tmp/agent-config-lint.rule7.$$
fi
rule7_hits=$(echo "$rule7_hits" | sed -e 's/^ *//' -e 's/ *$//')
if [ -n "$rule7_hits" ]; then
  fail 7 "no-tracked-local-overlays" "tracked: $rule7_hits"
else
  pass 7 "no-tracked-local-overlays"
fi

################################################################################
# Rule 8 (WARN): root AGENTS.md exceeds 150 lines or 8192 bytes.
################################################################################
if [ -f AGENTS.md ]; then
  root_lines=$(wc -l < AGENTS.md | tr -d ' ')
  root_bytes=$(wc -c < AGENTS.md | tr -d ' ')
  if [ "$root_lines" -gt 150 ] || [ "$root_bytes" -gt 8192 ]; then
    warn 8 "root-agents-md-budget" "$root_lines lines, $root_bytes bytes"
  else
    pass 8 "root-agents-md-budget"
  fi
else
  warn 8 "root-agents-md-budget" "AGENTS.md not found at repo root"
fi

################################################################################
# Rule 9 (WARN): root AGENTS.md mentions a host name outside backticks/fences.
################################################################################
if is_ignored "AGENTS.md"; then
  echo "SKIP 9 AGENTS.md (.agent-lint-ignore)"
elif [ -f AGENTS.md ]; then
  hits=$(strip_fences_and_backticks AGENTS.md | grep -inE 'claude|codex|gemini|cursor|copilot')
  if [ -n "$hits" ]; then
    warn 9 "root-agents-md-host-names" "$(echo "$hits" | tr '\n' ' | ')"
  else
    pass 9 "root-agents-md-host-names"
  fi
fi

################################################################################
# Rule 10 (WARN): .claude/rules/*.md without a paths: line.
################################################################################
if [ -d .claude/rules ]; then
  rule10_bad=""
  for f in .claude/rules/*.md; do
    [ -e "$f" ] || continue
    if ! grep -qE '^paths:' "$f"; then
      rule10_bad="$rule10_bad $f"
    fi
  done
  rule10_bad=$(echo "$rule10_bad" | sed -e 's/^ *//' -e 's/ *$//')
  if [ -n "$rule10_bad" ]; then
    warn 10 "claude-rules-paths" "no paths: line in:$rule10_bad"
  else
    pass 10 "claude-rules-paths"
  fi
fi

echo "agent-config-lint: $FAIL_COUNT fail, $WARN_COUNT warn"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
