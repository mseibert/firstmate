#!/usr/bin/env bash
# fm-cognee-context.sh - query the Cognee memory store for context relevant to
# upcoming work and render the relevant entries for feeding into a task brief.
#
# A lean bridge, not a framework: before commissioning a task, firstmate runs
# this with a query summarizing the upcoming work, and the returned context
# becomes a "Relevant Cognee memory context" section in the crewmate brief (see
# the cognee-memory skill and docs/cognee-memory-bridge.md).
#
# The Cognee API key is read from 1Password at RUNTIME through the service
# account only, never the captain's interactive 1Password session, and never
# from any committed or hard-coded value:
#   1. OP_SERVICE_ACCOUNT_TOKEN when set in the environment.
#   2. Otherwise the configured service-account token in the macOS keychain,
#      service name "op-service-account-claude-code" (the same per-invocation
#      token the captain's shell wrapper injects).
#   3. Otherwise the headless service-account token file at $OP_SA_TOKEN_FILE,
#      defaulting to ~/.config/op/sa-token. That is where the fleet's own `op`
#      wrapper keeps it on a host with no keychain, so a Linux firstmate reads
#      the same file its wrapper does rather than a second copy of the secret.
#   4. Otherwise fail closed: no interactive sign-in, no fallback, non-zero exit
#      with a message that names the missing service-account access.
# The script never calls `op signin` and never reads a token the captain's
# interactive session would have to unlock.
#
# Usage:
#   fm-cognee-context.sh <query>... [options]
#
# Options and query words may appear in any order, so a trailing --out is parsed
# as the out-file rather than folded into the query. A `--` ends option parsing,
# so a query can start with a dash.
#
# Options:
#   --top-k N          maximum number of entries (default 5)
#   --search-type TYPE CHUNKS (default) or SUMMARIES
#   --dataset NAME     Cognee dataset to search (default personal)
#   --out FILE         write the rendered context to FILE instead of stdout;
#                      FILE is created or truncated at mode 600 before the
#                      context is written, and removed if the run fails
#   --json             emit the raw Cognee search response instead of rendered Markdown
#   --help             print this help and exit
#
# Configuration (environment, each with a safe default):
#   COGNEE_URL        base URL of the Cognee instance (default https://cognee.seibert.tools)
#   COGNEE_DATASET    dataset to search (default personal)
#   COGNEE_OP_VAULT   1Password vault holding the Cognee item (default ai-agent-reads)
#   COGNEE_OP_ITEM    1Password item holding the Cognee API key (default "Cognee martin.seibert@seibert.group")
#   COGNEE_OP_FIELD   1Password field holding the API key (default api_key)
#   COGNEE_TIMEOUT    seconds to wait for the search request (default 60; the
#                     first query per dataset is slow while the instance warms up)
#   OP_SERVICE_ACCOUNT_TOKEN   service-account token; used verbatim when present,
#                     then unset so only `op` receives it - no other child process
#                     of this script ever sees the service-account credential
#   OP_SA_TOKEN_FILE  path of the headless service-account token file, used only
#                     when neither the environment variable nor the macOS keychain
#                     yields a token; default ~/.config/op/sa-token
#
# A non-200 search repeats a bounded excerpt of the server's own reason body, so
# a rejected credential and a rejected request shape are told apart.
#
# The context is memory from a private dataset, so --out owns the file's mode
# rather than trusting the caller's umask: the file is emptied at mode 600 first
# and the rendered context only ever lands in an already-restricted file. A mode
# that cannot be set is a failure, not a warning.
#
# Once --out has been parsed, any non-zero exit removes that file - a usage
# error, an out-of-range COGNEE_TIMEOUT, a credential failure, an outage, an
# unreadable payload, or a signal - so a failed run never leaves an earlier run's
# context behind for a reader who checks the path instead of the exit code. An
# error found earlier in the argument list than --out, such as an unknown option,
# exits before the file is known and leaves it untouched.
#
# Exit codes: 0 on success; 1 on a runtime failure (missing service account,
# unreadable key, non-200 search, unreadable search payload); 2 on usage errors
# including a missing, empty, or out-of-range option value, or an out-of-range
# COGNEE_TIMEOUT.
set -u

COGNEE_URL="${COGNEE_URL:-https://cognee.seibert.tools}"
COGNEE_DATASET="${COGNEE_DATASET:-personal}"
COGNEE_OP_VAULT="${COGNEE_OP_VAULT:-ai-agent-reads}"
COGNEE_OP_ITEM="${COGNEE_OP_ITEM:-Cognee martin.seibert@seibert.group}"
COGNEE_OP_FIELD="${COGNEE_OP_FIELD:-api_key}"
COGNEE_TIMEOUT="${COGNEE_TIMEOUT:-60}"
QUERY=
TOP_K=5
SEARCH_TYPE=CHUNKS
OUT_FILE=
RAW_JSON=0

# --- cleanup ---------------------------------------------------------------
TMP_DIR=
cleanup() {
  local status=$?
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
  if [ "$status" -ne 0 ] && [ -n "$OUT_FILE" ]; then
    rm -f -- "$OUT_FILE" 2>/dev/null || :
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

need_value() {  # need_value <flag> <remaining-arg-count> <candidate-value>
  [ "$2" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
  case "$3" in
    '') echo "error: $1 requires a value, got an empty one" >&2; exit 2 ;;
    -*) echo "error: $1 requires a value, got the option $3" >&2; exit 2 ;;
  esac
}

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { next }
       { exit }' "$0"
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --top-k)
      need_value --top-k "$#" "${2:-}"
      case "$2" in
        0* | *[!0-9]* | '') echo "error: --top-k must be a positive integer without a leading zero" >&2; exit 2 ;;
      esac
      TOP_K=$2
      shift 2
      ;;
    --search-type)
      need_value --search-type "$#" "${2:-}"
      case "$2" in
        CHUNKS|SUMMARIES) SEARCH_TYPE=$2 ;;
        *) echo "error: --search-type must be CHUNKS or SUMMARIES" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --dataset)
      need_value --dataset "$#" "${2:-}"
      COGNEE_DATASET=$2
      shift 2
      ;;
    --out)
      need_value --out "$#" "${2:-}"
      OUT_FILE=$2
      shift 2
      ;;
    --json)
      RAW_JSON=1
      shift
      ;;
    --help|-h)
      usage
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        QUERY=${QUERY:+$QUERY }$1
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      QUERY=${QUERY:+$QUERY }$1
      shift
      ;;
  esac
done

[ -n "$QUERY" ] || { echo "error: a query is required" >&2; exit 2; }
case "$COGNEE_TIMEOUT" in
  0* | *[!0-9]* | '') echo "error: COGNEE_TIMEOUT must be a positive integer without a leading zero" >&2; exit 2 ;;
esac

# --- resolve the service-account token ------------------------------------
OP_TOKEN=
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN
  unset OP_SERVICE_ACCOUNT_TOKEN
elif command -v security >/dev/null 2>&1; then
  OP_TOKEN=$(security find-generic-password -a "${USER:-$(id -un)}" -s op-service-account-claude-code -w 2>/dev/null) || OP_TOKEN=
fi
# Headless fallback: the same file the fleet's `op` wrapper injects from.
SA_TOKEN_FILE=${OP_SA_TOKEN_FILE:-$HOME/.config/op/sa-token}
if [ -z "$OP_TOKEN" ] && [ -r "$SA_TOKEN_FILE" ]; then
  OP_TOKEN=$(cat "$SA_TOKEN_FILE")
fi
if [ -z "$OP_TOKEN" ]; then
  echo "error: no 1Password service-account token available (set OP_SERVICE_ACCOUNT_TOKEN, install the op-service-account-claude-code keychain item, or provide $SA_TOKEN_FILE); refusing interactive sign-in" >&2
  exit 1
fi

# --- required tools and scratch space -------------------------------------
command -v op >/dev/null 2>&1 || { echo "error: the 1Password CLI (op) is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cognee.XXXXXX") || exit 1
OP_ERR="$TMP_DIR/op-err.txt"
BODY="$TMP_DIR/body.json"
RESP="$TMP_DIR/resp.json"

# --- read the Cognee API key at runtime -----------------------------------
ITEM_JSON=$(OP_SERVICE_ACCOUNT_TOKEN=$OP_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED=false \
  op item get "$COGNEE_OP_ITEM" --vault "$COGNEE_OP_VAULT" --format json --reveal 2>"$OP_ERR") || {
  echo "error: 1Password service account could not read item '$COGNEE_OP_ITEM' in vault '$COGNEE_OP_VAULT': $(tr '\n' ' ' < "$OP_ERR")" >&2
  exit 1
}
API_KEY=$(printf '%s' "$ITEM_JSON" | python3 -c '
import json, sys
try:
    item = json.load(sys.stdin)
except Exception:
    sys.exit(1)
field = sys.argv[1]
for f in item.get("fields", []):
    if f.get("label") == field and f.get("value"):
        sys.stdout.write(f["value"])
        sys.exit(0)
sys.exit(1)
' "$COGNEE_OP_FIELD") || {
  echo "error: Cognee API key field '$COGNEE_OP_FIELD' not found in 1Password item '$COGNEE_OP_ITEM'" >&2
  exit 1
}
[ -n "$API_KEY" ] || { echo "error: Cognee API key is empty in 1Password item '$COGNEE_OP_ITEM'" >&2; exit 1; }

# --- query Cognee ----------------------------------------------------------
if ! python3 - "$SEARCH_TYPE" "$QUERY" "$COGNEE_DATASET" "$TOP_K" > "$BODY" <<'BODY_PY'
import json, sys
stype, query, dataset, top_k = sys.argv[1:5]
json.dump(
    {"searchType": stype, "query": query, "datasets": [dataset], "topK": int(top_k)},
    sys.stdout,
    separators=(",", ":"),
)
BODY_PY
then
  echo "error: could not build the Cognee search request" >&2
  exit 1
fi

ESCAPED_KEY=${API_KEY//\\/\\\\}
ESCAPED_KEY=${ESCAPED_KEY//\"/\\\"}
HTTP_CODE=$(printf 'header = "X-Api-Key: %s"\n' "$ESCAPED_KEY" \
  | curl -sS -m "$COGNEE_TIMEOUT" -o "$RESP" -w '%{http_code}' -X POST \
  "$COGNEE_URL/api/v1/search" \
  --config - \
  -H "Content-Type: application/json" \
  --data-binary "@$BODY") || {
  echo "error: Cognee search request failed" >&2
  exit 1
}
if [ "$HTTP_CODE" != "200" ]; then
  REASON=
  if [ -s "$RESP" ]; then
    REASON=$(tr -d '\000' < "$RESP" | tr '\n\r\t' '   ' | cut -c1-500)
  fi
  echo "error: Cognee search returned HTTP $HTTP_CODE${REASON:+: $REASON}" >&2
  exit 1
fi

# --- render ---------------------------------------------------------------
# Both output modes go through the same payload validation, so --json is a
# verbatim passthrough of a body that was checked, never of an unreadable one.
RENDERED="$TMP_DIR/rendered.md"
if ! python3 - "$RESP" "$COGNEE_DATASET" "$QUERY" "$SEARCH_TYPE" > "$RENDERED" <<'PY'
import json, sys
resp_path, dataset, query, stype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


try:
    data = json.load(open(resp_path, encoding="utf-8"))
except Exception:
    die("Cognee search returned malformed JSON")
if not isinstance(data, list):
    die("Cognee search returned an unexpected payload: expected a list of dataset groups")
out = []
out.append("# Cognee memory context")
out.append("")
out.append(f"- Dataset: {dataset}")
out.append(f"- Query: {query}")
out.append(f"- Search type: {stype}")
out.append("")
total = 0
entries_seen = 0
text_keyed = 0
for group in data:
    if not isinstance(group, dict):
        die("Cognee search returned an unexpected dataset group shape")
    if "search_result" not in group:
        die("Cognee search returned a dataset group with no search_result field")
    entries = group["search_result"]
    if not isinstance(entries, list):
        die("Cognee search returned an unexpected search_result shape")
    for entry in entries:
        if not isinstance(entry, dict):
            die("Cognee search returned an unexpected entry shape")
        entries_seen += 1
        if "text" not in entry:
            continue
        text_keyed += 1
        raw_text = entry["text"]
        if raw_text is None:
            raw_text = ""
        if not isinstance(raw_text, str):
            die("Cognee search returned an unexpected entry text type")
        text = raw_text.strip()
        if not text:
            continue
        doc = entry.get("document_name") or entry.get("id") or f"entry {total + 1}"
        out.append(f"## {doc}")
        out.append("")
        out.append(text)
        out.append("")
        total += 1
if total == 0:
    if entries_seen and not text_keyed:
        die(f"Cognee search returned {entries_seen} entries and none carried a text field")
    out.append("No relevant Cognee memory entries found.")
sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
PY
then
  exit 1
fi
if [ "$RAW_JSON" -eq 1 ]; then
  OUTPUT=$RESP
else
  OUTPUT=$RENDERED
fi

if [ -n "$OUT_FILE" ]; then
  (umask 077; : > "$OUT_FILE") || {
    echo "error: could not write '$OUT_FILE'" >&2
    exit 1
  }
  chmod 600 "$OUT_FILE" || {
    echo "error: could not restrict '$OUT_FILE' to mode 600" >&2
    exit 1
  }
  cat -- "$OUTPUT" > "$OUT_FILE" || {
    echo "error: could not write '$OUT_FILE'" >&2
    exit 1
  }
else
  cat -- "$OUTPUT"
fi
