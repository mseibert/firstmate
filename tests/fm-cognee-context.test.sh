#!/usr/bin/env bash
# Behavior tests for the Cognee memory context bridge (fm-cognee-context.sh).
#
# The bridge queries the Cognee search API before a task and renders relevant
# entries for the crewmate brief. These tests are hermetic: the 1Password CLI
# (`op`), the macOS keychain helper (`security`), and the network (`curl`) are
# all stubbed with fakebins, so no real credential is read and no real network
# call is made. They assert the runtime-read contract (the key comes from the
# stubbed 1Password service-account item, never from the script or environment
# of the caller beyond the service-account token itself), the rendered context
# shape, the --json/--out modes, and the fail-closed paths (no service-account
# token, missing field, non-200 response, usage errors).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-cognee-context.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The bridge reads its instance, dataset, and 1Password coordinates from the
# environment, so every invocation below strips them: otherwise a developer with
# COGNEE_DATASET exported fails assertions for a reason unrelated to the change.
CLEAN_ENV=(env -u COGNEE_URL -u COGNEE_DATASET -u COGNEE_OP_VAULT
  -u COGNEE_OP_ITEM -u COGNEE_OP_FIELD -u COGNEE_TIMEOUT
  -u OP_SA_TOKEN_FILE)
# The bridge uses the real python3 for JSON; make it resolvable regardless of
# where it is installed, prepended after the fakebin so the fake op/security/curl
# still win.
PY_DIR=$(command -v python3 2>/dev/null) && PY_DIR=$(dirname "$PY_DIR") || PY_DIR=
[ -n "$PY_DIR" ] && BASE_PATH="$PY_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-cognee-context)
# Keep the headless token file out of the suite. The bridge's last fallback is
# $OP_SA_TOKEN_FILE, defaulting to $HOME/.config/op/sa-token - a path that really
# exists on a Linux firstmate, where the fail-closed case below would then pass
# for the wrong reason. CLEAN_ENV unsets OP_SA_TOKEN_FILE, and this HOME makes the
# default unresolvable; a test that wants the file names it explicitly.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

# Fixture 1Password item as `op item get --format json --reveal` would emit it.
OP_ITEM_FIXTURE='{
  "id": "item-uuid",
  "title": "Cognee martin.seibert@seibert.group",
  "vault": {"id": "vault-uuid", "name": "ai-agent-reads"},
  "fields": [
    {"id": "username", "label": "username", "value": "martin.seibert@seibert.group"},
    {"id": "api_key", "label": "api_key", "value": "test-cognee-api-key-12345"}
  ]
}'

# Fixture Cognee search response (CHUNKS shape): one dataset group with two
# entries so rendering and count behavior are both exercised.
COGNEE_RESP_FIXTURE='[
  {
    "dataset_id": "ds-uuid",
    "dataset_name": "personal",
    "dataset_tenant_id": null,
    "search_result": [
      {
        "id": "entry-1-uuid",
        "text": "Memory about firstmate setup and worker dispatch.",
        "document_name": "firstmate-setup-notes",
        "document_id": "doc-1-uuid"
      },
      {
        "id": "entry-2-uuid",
        "text": "Memory about the project registry.",
        "document_name": "project-registry",
        "document_id": "doc-2-uuid"
      }
    ]
  }
]'
# The fakebins below are written from quoted heredocs, so the child processes
# read the fixtures from files rather than from exported shell variables (which
# would trip ShellCheck's SC2089/SC2090 on quoted JSON).
printf '%s' "$OP_ITEM_FIXTURE" > "$TMP_ROOT/op-item.fixture"
printf '%s' "$COGNEE_RESP_FIXTURE" > "$TMP_ROOT/cognee-resp.fixture"
export OP_ITEM_FIXTURE_FILE="$TMP_ROOT/op-item.fixture"
export COGNEE_RESP_FIXTURE_FILE="$TMP_ROOT/cognee-resp.fixture"

# A fakebin `op` that answers only a fully-specified `item get` - the item, a
# --vault, and a JSON format must all be present, so a regression that dropped
# the vault or the item falls through to the exit-98 catch-all instead of being
# handed the fixture anyway. It logs its argv to FAKE_OP_LOG when set so a test
# can assert which coordinates the bridge actually asked for. A signin
# invocation exits 99, and prints nothing, so a regression to interactive auth
# is caught loudly.
make_fake_op() {  # <fakebin-dir>
  local fakebin=$1
  cat > "$fakebin/op" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_OP_LOG:-}" ]; then
  printf 'argv=%s\n' "$*" >> "$FAKE_OP_LOG"
fi
case "$*" in
  signin*)
    echo "op: interactive sign-in must never be called" >&2
    exit 99
    ;;
  item\ get\ *\ --vault\ *\ --format\ json*)
    cat "$OP_ITEM_FIXTURE_FILE"
    exit 0
    ;;
  *)
    echo "op: unexpected invocation: $*" >&2
    exit 98
    ;;
esac
SH
  chmod +x "$fakebin/op"
}

# A fakebin `security` that behaves like `find-generic-password` on macOS: when
# SECURITY_STUB_TOKEN is set it prints it; otherwise it fails like a missing
# keychain item (used for the no-token fail-closed case).
make_fake_security() {  # <fakebin-dir>
  local fakebin=$1
  cat > "$fakebin/security" <<'SH'
#!/usr/bin/env bash
if [ -n "${SECURITY_STUB_TOKEN:-}" ]; then
  printf '%s\n' "$SECURITY_STUB_TOKEN"
  exit 0
fi
echo "security: no service account keychain item" >&2
exit 44
SH
  chmod +x "$fakebin/security"
}

# A fakebin `curl` that mimics the Cognee search endpoint: writes the configured
# response body (FAKE_COGNEE_RESP, default the fixture) to the -o file, or for a
# non-200 code the configured error body (FAKE_COGNEE_ERROR_FILE, default a
# `detail` JSON object as Cognee sends), prints
# the configured HTTP code (FAKE_COGNEE_CODE), and logs the request (URL, argv,
# X-Api-Key header, body) to FAKE_CURL_LOG so tests can assert the key sent on
# the wire is exactly the one read from the stubbed 1Password item and that it
# never appears in the argument list.
#
# It also records, as `keyfiles=`, every file in the bridge's own temp directory
# whose contents hold the key at request time, so a test can assert the key is
# never written to the filesystem, and as `svctoken=`, whether the 1Password
# service-account token reached this child's environment at all.
make_fake_curl() {  # <fakebin-dir>
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" apikey="" data="" datafile="" timeout=""
svctoken=${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) shift 2 ;;
    -H)
      case "$2" in
        X-Api-Key:*) apikey=${2#X-Api-Key:} ;;
      esac
      apikey=${apikey# }
      shift 2
      ;;
    --config)
      if [ "$2" = "-" ]; then cfg=$(cat); else cfg=$(cat -- "$2"); fi
      apikey=$(printf '%s\n' "$cfg" | sed -n 's/^header = "X-Api-Key: \(.*\)"$/\1/p')
      shift 2
      ;;
    -m) timeout=$2; shift 2 ;;
    -w) shift 2 ;;
    -sS) shift ;;
    --data-binary)
      case "$2" in
        @*) datafile=${2#@}; data=$(cat -- "$datafile") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
keyfiles=""
if [ -n "$apikey" ] && [ -n "$datafile" ]; then
  keyfiles=$(grep -rl -- "$apikey" "$(dirname -- "$datafile")" 2>/dev/null | tr '\n' ' ')
fi
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "url=$url"; echo "argv=$argv"; echo "apikey=$apikey"; \
    echo "timeout=$timeout"; echo "keyfiles=$keyfiles"; echo "svctoken=$svctoken"; \
    echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
code=${FAKE_COGNEE_CODE:-200}
if [ "$code" = "200" ]; then
  [ -n "$ofile" ] && cat "${FAKE_COGNEE_RESP_FILE:-$COGNEE_RESP_FIXTURE_FILE}" > "$ofile"
elif [ -n "${FAKE_COGNEE_ERROR_FILE:-}" ]; then
  [ -n "$ofile" ] && cat "$FAKE_COGNEE_ERROR_FILE" > "$ofile"
else
  [ -n "$ofile" ] && printf '%s' '{"detail":"Unauthorized"}' > "$ofile"
fi
printf '%s' "$code"
SH
  chmod +x "$fakebin/curl"
}

# make_fake_bins <shared-dir>: create ONE fakebin dir and drop op, security,
# and curl stubs into it so all three are on PATH together. Echoes the path.
make_fake_bins() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  make_fake_op "$fakebin"
  make_fake_security "$fakebin"
  make_fake_curl "$fakebin"
  printf '%s\n' "$fakebin"
}

# ---------------------------------------------------------------------------
# 1. Rendered context includes dataset/query/type lines and every entry's
#    document name and text.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/basic")
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 2 "firstmate setup")
assert_contains "$OUT" "# Cognee memory context" "renders the context heading"
assert_contains "$OUT" "- Dataset: personal" "renders the dataset"
assert_contains "$OUT" "- Query: firstmate setup" "renders the query"
assert_contains "$OUT" "- Search type: CHUNKS" "renders the search type"
assert_contains "$OUT" "## firstmate-setup-notes" "renders the first document name"
assert_contains "$OUT" "Memory about firstmate setup and worker dispatch." "renders the first entry text"
assert_contains "$OUT" "## project-registry" "renders the second document name"
assert_contains "$OUT" "Memory about the project registry." "renders the second entry text"
pass "rendered context includes dataset, query, and each entry's name and text"

# ---------------------------------------------------------------------------
# 2. The key sent on the wire is the one read from the stubbed 1Password item,
#    never a hard-coded value: the X-Api-Key header must equal the fixture key
#    from the op stub, and it must never leak into rendered output.
# ---------------------------------------------------------------------------
FAKE_CURL_LOG="$TMP_ROOT/curl.log"
export FAKE_CURL_LOG
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 2 "firstmate setup")
assert_grep 'apikey=test-cognee-api-key-12345' "$FAKE_CURL_LOG" \
  "the API key read from the stubbed 1Password item is sent as X-Api-Key"
grep '^argv=' "$FAKE_CURL_LOG" > "$TMP_ROOT/curl-argv.log"
assert_present "$TMP_ROOT/curl-argv.log" "the curl argument list is logged"
assert_no_grep 'test-cognee-api-key-12345' "$TMP_ROOT/curl-argv.log" \
  "the API key never appears in the curl argument list"
KEYFILES=$(sed -n 's/^keyfiles=//p' "$FAKE_CURL_LOG" | tr -d ' ')
[ -z "$KEYFILES" ] || fail "the API key was written to the filesystem: $KEYFILES"
printf '%s\n' "$OUT" > "$TMP_ROOT/out.txt"
assert_no_grep 'test-cognee-api-key-12345' "$TMP_ROOT/out.txt" \
  "the API key never leaks into rendered output"
pass "the runtime-read key is used on the wire, out of argv, and never leaked"

# ---------------------------------------------------------------------------
# 3. SUMMARIES search type is passed through and rendered.
# ---------------------------------------------------------------------------
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --search-type SUMMARIES --top-k 2 "firstmate")
assert_contains "$OUT" "- Search type: SUMMARIES" "renders the SUMMARIES type"
pass "SUMMARIES search type renders"

# ---------------------------------------------------------------------------
# 4. --json emits the raw response verbatim (valid JSON).
# ---------------------------------------------------------------------------
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --json --top-k 2 "firstmate")
printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || fail "raw JSON output is not valid JSON"
assert_contains "$OUT" '"document_name": "firstmate-setup-notes"' \
  "raw JSON output contains the fixture entries"
pass "--json emits valid raw JSON"

# ---------------------------------------------------------------------------
# 5. --out writes the rendered context to a file instead of stdout.
# ---------------------------------------------------------------------------
OUTFILE="$TMP_ROOT/context-out.md"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --out "$OUTFILE" --top-k 2 "firstmate")
[ -z "$OUT" ] || fail "--out must not also print to stdout"
assert_present "$OUTFILE" "--out writes the context file"
assert_contains "$(cat "$OUTFILE")" "## firstmate-setup-notes" \
  "the written file contains the rendered context"
pass "--out writes the context to a file"

# ---------------------------------------------------------------------------
# 6. Empty search results render a no-entries note (still exit 0).
# ---------------------------------------------------------------------------
COGNEE_RESP_FIXTURE_FILE="$TMP_ROOT/cognee-resp-fixture-empty.json"
printf '%s' '[]' > "$COGNEE_RESP_FIXTURE_FILE"
export COGNEE_RESP_FIXTURE_FILE
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 2 "nothing relevant")
assert_contains "$OUT" "No relevant Cognee memory entries found." \
  "empty results render a no-entries note"
export COGNEE_RESP_FIXTURE_FILE="$TMP_ROOT/cognee-resp.fixture"
pass "empty results render a no-entries note"

# ---------------------------------------------------------------------------
# 7. Fail-closed: no service-account token at all -> refuse with the message,
#    never call op, never fall back to interactive sign-in.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/notoken")
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  -u SECURITY_STUB_TOKEN "$BRIDGE" "firstmate" 2>&1)
RC=$?
[ "$RC" -eq 1 ] || fail "no-token case must exit 1, got $RC"
assert_contains "$OUT" "no 1Password service-account token available" \
  "no-token case names the missing service-account access"
assert_contains "$OUT" "refusing interactive sign-in" \
  "no-token case refuses interactive sign-in"
pass "missing service-account token fails closed without interactive sign-in"

# ---------------------------------------------------------------------------
# 7b. The headless service-account token file is the last fallback, so a Linux
#     firstmate whose `op` wrapper injects from that file works unchanged.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/satoken")
SA_TOKEN_FILE="$TMP_ROOT/satoken/sa-token"
printf '%s\n' 'file-provided-svc-token' > "$SA_TOKEN_FILE"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  -u SECURITY_STUB_TOKEN OP_SA_TOKEN_FILE="$SA_TOKEN_FILE" \
  "$BRIDGE" --top-k 2 "firstmate")
assert_contains "$OUT" "# Cognee memory context" \
  "the headless token file renders context"
pass "the headless service-account token file is honored when no keychain yields one"

# ---------------------------------------------------------------------------
# 8. OP_SERVICE_ACCOUNT_TOKEN env is honored verbatim (portable path).
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/envtoken")
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" \
  OP_SERVICE_ACCOUNT_TOKEN=env-provided-svc-token \
  "$BRIDGE" --top-k 2 "firstmate")
assert_contains "$OUT" "# Cognee memory context" \
  "OP_SERVICE_ACCOUNT_TOKEN env path renders context"
pass "OP_SERVICE_ACCOUNT_TOKEN env token is honored"

# ---------------------------------------------------------------------------
# 9. A missing api_key field in the 1Password item fails closed.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/nofield")
cat > "$fakebin/op" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"id":"i","title":"t","fields":[{"id":"x","label":"other","value":"v"}]}'
exit 0
SH
chmod +x "$fakebin/op"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" \
  OP_SERVICE_ACCOUNT_TOKEN=env-provided-svc-token \
  "$BRIDGE" --top-k 2 "firstmate" 2>&1)
RC=$?
[ "$RC" -eq 1 ] || fail "missing-field case must exit 1, got $RC"
assert_contains "$OUT" "api_key" "missing-field case names the missing field"
pass "missing api_key field fails closed"

# ---------------------------------------------------------------------------
# 10. A non-200 Cognee response fails closed.
# ---------------------------------------------------------------------------
FAKE_COGNEE_CODE=401
export FAKE_COGNEE_CODE
fakebin=$(make_fake_bins "$TMP_ROOT/http")
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" \
  OP_SERVICE_ACCOUNT_TOKEN=env-provided-svc-token \
  "$BRIDGE" --top-k 2 "firstmate" 2>&1)
RC=$?
unset FAKE_COGNEE_CODE
[ "$RC" -eq 1 ] || fail "non-200 case must exit 1, got $RC"
assert_contains "$OUT" "HTTP 401" "non-200 case reports the HTTP code"
assert_contains "$OUT" "Unauthorized" \
  "non-200 case repeats the server's own reason so a rejected credential is nameable"
pass "non-200 Cognee response fails closed"

# ---------------------------------------------------------------------------
# 11. Usage errors exit 2.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/usage")
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
  "$BRIDGE" >/dev/null 2>&1
[ $? -eq 2 ] || fail "missing query must exit 2"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
  "$BRIDGE" --bad-option "firstmate" >/dev/null 2>&1
[ $? -eq 2 ] || fail "unknown option must exit 2"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
  "$BRIDGE" --top-k notanumber "firstmate" >/dev/null 2>&1
[ $? -eq 2 ] || fail "non-integer --top-k must exit 2"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
  "$BRIDGE" --search-type BOGUS "firstmate" >/dev/null 2>&1
[ $? -eq 2 ] || fail "unknown --search-type must exit 2"
# A leading zero used to be read as octal by the request builder, so --top-k 010
# silently asked for 8 entries and --top-k 08 silently asked for 0.
for bad in 0 010 08; do
  PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
    "$BRIDGE" --top-k "$bad" "firstmate" >/dev/null 2>&1
  [ $? -eq 2 ] || fail "--top-k $bad must exit 2"
done
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u SECURITY_STUB_TOKEN \
  COGNEE_TIMEOUT=notanumber "$BRIDGE" "firstmate" >/dev/null 2>&1
[ $? -eq 2 ] || fail "non-integer COGNEE_TIMEOUT must exit 2"
pass "usage errors exit 2"

# ---------------------------------------------------------------------------
# 12. The requested entry count reaches the wire verbatim (no octal reading).
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/topk")
FAKE_CURL_LOG="$TMP_ROOT/topk-curl.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 10 "firstmate" >/dev/null
assert_grep '"topK":10' "$FAKE_CURL_LOG" "--top-k 10 requests 10 entries on the wire"
assert_no_grep '"topK":8' "$FAKE_CURL_LOG" "no octal reinterpretation of the entry count"
pass "the requested entry count reaches the wire verbatim"

# ---------------------------------------------------------------------------
# 13. COGNEE_TIMEOUT is honored, and defaults high enough for a cold instance.
# ---------------------------------------------------------------------------
FAKE_CURL_LOG="$TMP_ROOT/timeout-curl.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" "firstmate" >/dev/null
TIMEOUT_SENT=$(sed -n 's/^timeout=//p' "$FAKE_CURL_LOG")
[ "$TIMEOUT_SENT" = "60" ] || fail "default request timeout must be 60s, got '$TIMEOUT_SENT'"
FAKE_CURL_LOG="$TMP_ROOT/timeout-override-curl.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  COGNEE_TIMEOUT=120 "$BRIDGE" "firstmate" >/dev/null
TIMEOUT_SENT=$(sed -n 's/^timeout=//p' "$FAKE_CURL_LOG")
[ "$TIMEOUT_SENT" = "120" ] || fail "COGNEE_TIMEOUT must override the timeout, got '$TIMEOUT_SENT'"
pass "the request timeout defaults to 60s and is overridable"

# ---------------------------------------------------------------------------
# 14. A 200 response whose body is not JSON reports the reason on stderr and
#     exits 1, rather than exiting silently with no output at all.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/malformed")
printf '%s' '{"search_result": [truncated' > "$TMP_ROOT/malformed-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/malformed-resp.json" \
  "$BRIDGE" "firstmate" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 1 ] || fail "malformed response body must exit 1, got $RC"
assert_contains "$OUT" "malformed JSON" "malformed response names the reason on stderr"
pass "a malformed response body reports its reason on stderr"

# ---------------------------------------------------------------------------
# 15. Entries whose text field is present but empty never become a
#     confident-looking empty context block. The payload was still readable, so
#     this is "no memory", not an outage: the no-entries note renders and the
#     bridge succeeds.
# ---------------------------------------------------------------------------
printf '%s' '[{"search_result":[{"id":"c1","text":""},{"id":"c2","text":"   "}]}]' \
  > "$TMP_ROOT/textless-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/textless-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/textless.err")
RC=$?
[ "$RC" -eq 0 ] || fail "a readable but textless payload must exit 0, got $RC"
assert_not_contains "$OUT" "## c1" "a textless entry is not rendered as a heading"
assert_not_contains "$OUT" "## c2" "a whitespace-only entry is not rendered as a heading"
assert_contains "$OUT" "No relevant Cognee memory entries found." \
  "a textless payload renders the no-entries note"
[ ! -s "$TMP_ROOT/textless.err" ] || \
  fail "a readable but textless payload must not report an error: $(cat "$TMP_ROOT/textless.err")"
pass "a readable but textless payload reads as no memory, not an outage"

# ---------------------------------------------------------------------------
# 15b. Entries WITH text still render even when a textless entry sits beside
#      them, so skipping the empty ones never drops real memory.
# ---------------------------------------------------------------------------
printf '%s' '[{"search_result":[{"id":"c1","text":""},{"id":"c2","document_name":"real-note","text":"real memory"}]}]' \
  > "$TMP_ROOT/mixed-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/mixed-resp.json" \
  "$BRIDGE" "firstmate")
RC=$?
[ "$RC" -eq 0 ] || fail "a mixed payload must exit 0, got $RC"
assert_contains "$OUT" "## real-note" "the entry with text renders"
assert_contains "$OUT" "real memory" "the entry text renders"
assert_not_contains "$OUT" "## c1" "the textless neighbour is skipped"
assert_not_contains "$OUT" "No relevant Cognee memory entries found." \
  "the no-entries note is suppressed when real memory was rendered"
pass "textless entries are skipped without dropping real memory"

# ---------------------------------------------------------------------------
# 16. An entry that is not an object is reported in plain language, not as a
#     Python traceback.
# ---------------------------------------------------------------------------
printf '%s' '[{"search_result":["a bare string"]}]' > "$TMP_ROOT/badshape-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/badshape-resp.json" \
  "$BRIDGE" "firstmate" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 1 ] || fail "unexpected entry shape must exit 1, got $RC"
assert_contains "$OUT" "unexpected entry shape" "unexpected entry shape is named"
assert_not_contains "$OUT" "Traceback" "unexpected entry shape does not print a traceback"
pass "an unexpected entry shape is reported in plain language"

# ---------------------------------------------------------------------------
# 17. The keychain fallback works on a host where USER is not exported (cron,
#     containers, some launchd contexts) instead of dying on an unbound variable.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/nouser")
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN -u USER \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 2 "firstmate" 2>"$TMP_ROOT/nouser.err")
RC=$?
[ "$RC" -eq 0 ] || fail "unset USER must not break the keychain fallback, got $RC"
assert_contains "$OUT" "# Cognee memory context" \
  "the keychain fallback still resolves the token with USER unset"
assert_no_grep 'unbound variable' "$TMP_ROOT/nouser.err" \
  "unset USER produces no unbound-variable error"
pass "the keychain fallback survives an unset USER"

# ---------------------------------------------------------------------------
# 18. Options are honored AFTER the query, the form the operator doc and the
#     cognee-memory skill both prescribe: a trailing --out writes the file and
#     never leaks flag text into the query sent to Cognee.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/trailing")
FAKE_CURL_LOG="$TMP_ROOT/trailing-curl.log"
export FAKE_CURL_LOG
OUTFILE="$TMP_ROOT/trailing-out.md"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" "firstmate setup" --out "$OUTFILE")
RC=$?
[ "$RC" -eq 0 ] || fail "a trailing --out must succeed, got $RC"
[ -z "$OUT" ] || fail "a trailing --out must not also print to stdout"
assert_present "$OUTFILE" "a trailing --out writes the context file"
assert_contains "$(cat "$OUTFILE")" "## firstmate-setup-notes" \
  "the file written by a trailing --out contains the rendered context"
assert_grep '"query":"firstmate setup"' "$FAKE_CURL_LOG" \
  "a trailing option never leaks into the query sent to Cognee"
assert_no_grep '--out' "$FAKE_CURL_LOG" "no flag text reaches the Cognee request body"
pass "options after the query are parsed, not folded into the query"

# ---------------------------------------------------------------------------
# 19. Options interleaved on both sides of the query all apply.
# ---------------------------------------------------------------------------
FAKE_CURL_LOG="$TMP_ROOT/interleaved-curl.log"
export FAKE_CURL_LOG
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --dataset team "the relay" poll --top-k 3 --search-type SUMMARIES)
assert_contains "$OUT" "- Dataset: team" "a leading --dataset applies"
assert_contains "$OUT" "- Query: the relay poll" "query words on both sides join in order"
assert_contains "$OUT" "- Search type: SUMMARIES" "a trailing --search-type applies"
assert_grep '"topK":3' "$FAKE_CURL_LOG" "a trailing --top-k applies"
pass "options interleaved around the query all apply"

# ---------------------------------------------------------------------------
# 20. Everything after `--` is query text, so a query may start with a dash.
# ---------------------------------------------------------------------------
FAKE_CURL_LOG="$TMP_ROOT/ddash-curl.log"
export FAKE_CURL_LOG
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" --top-k 2 -- --out is part of the query)
assert_contains "$OUT" "- Query: --out is part of the query" \
  "everything after -- is query text"
assert_grep '"topK":2' "$FAKE_CURL_LOG" "options before -- still apply"
pass "-- ends option parsing"

# ---------------------------------------------------------------------------
# 21. An unwritable --out fails closed in BOTH output modes, rather than
#     reporting success with nothing written.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/badout")
UNWRITABLE="$TMP_ROOT/no-such-dir/out.json"
for mode in --json --no-json; do
  case "$mode" in
    --json) args=(--json --out "$UNWRITABLE") ;;
    *) args=(--out "$UNWRITABLE") ;;
  esac
  PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    "$BRIDGE" "firstmate" "${args[@]}" >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 0 ] || fail "an unwritable --out must exit non-zero in $mode mode"
  assert_absent "$UNWRITABLE" "no file is written for an unwritable --out in $mode mode"
done
pass "an unwritable --out fails closed in both output modes"

# ---------------------------------------------------------------------------
# 22. A non-string entry text is reported in plain language, not as a traceback.
#     Falsy non-strings matter as much as truthy ones: a list, an object, or a
#     zero is drift, and reading it as "no memory" would hide real memory behind
#     an exit 0 that the caller has no way to question.
# ---------------------------------------------------------------------------
i=0
for badtext in '123' '[]' '{}' '0' 'false' '""' '[""]'; do
  i=$((i + 1))
  printf '%s' "[{\"search_result\":[{\"id\":\"c1\",\"text\":$badtext}]}]" \
    > "$TMP_ROOT/badtext-resp-$i.json"
  OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    FAKE_COGNEE_RESP_FILE="$TMP_ROOT/badtext-resp-$i.json" \
    "$BRIDGE" "firstmate" 2>&1 >/dev/null)
  RC=$?
  case "$badtext" in
    '""')
      [ "$RC" -eq 0 ] || fail "an empty string text must stay the no-memory case, got $RC"
      continue
      ;;
  esac
  [ "$RC" -eq 1 ] || fail "a text of $badtext must exit 1, got $RC"
  assert_contains "$OUT" "unexpected entry text type" "a text of $badtext is named"
  assert_not_contains "$OUT" "Traceback" "a text of $badtext does not print a traceback"
done
# A null text is the documented shape for an entry the server has no body for,
# so it must keep reading as no memory rather than joining the cases above.
printf '%s' '[{"search_result":[{"id":"c1","text":null}]}]' > "$TMP_ROOT/nulltext-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/nulltext-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/nulltext.err")
RC=$?
[ "$RC" -eq 0 ] || fail "a null entry text must exit 0, got $RC"
assert_contains "$OUT" "No relevant Cognee memory entries found." \
  "a null entry text reads as no memory"
[ ! -s "$TMP_ROOT/nulltext.err" ] || fail "a null entry text must not report an error"
pass "a non-string entry text is reported in plain language, falsy or not"

# ---------------------------------------------------------------------------
# 23. --help is the single owner of the flags, defaults, and exit codes, so it
#     must render the whole header block. The extractor stops at the first line
#     that is neither a comment nor blank, so a truncated block would silently
#     drop the trailing sections while still exiting 0.
# ---------------------------------------------------------------------------
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  -u SECURITY_STUB_TOKEN "$BRIDGE" --help 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "--help must exit 0, got $RC"
assert_contains "$OUT" "Usage:" "--help renders the usage section"
assert_contains "$OUT" "--top-k" "--help renders the options section"
assert_contains "$OUT" "COGNEE_TIMEOUT" "--help renders the configuration section"
assert_contains "$OUT" "Exit codes:" "--help renders the trailing exit-code section"
assert_not_contains "$OUT" "set -u" "--help stops before the script body"
pass "--help renders the whole documented header block"

# ---------------------------------------------------------------------------
# 24. When 1Password refuses the read, the bridge repeats op's own reason so an
#     expired token is not misreported as a renamed or missing item.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/operror")
cat > "$fakebin/op" <<'SH'
#!/usr/bin/env bash
echo "[ERROR] authentication failed: service account token expired" >&2
exit 1
SH
chmod +x "$fakebin/op"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" \
  OP_SERVICE_ACCOUNT_TOKEN=env-provided-svc-token \
  "$BRIDGE" "firstmate" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 1 ] || fail "an op read failure must exit 1, got $RC"
assert_contains "$OUT" "service account token expired" \
  "the error repeats op's own reason for refusing the read"
pass "an op read failure surfaces op's own diagnosis"

# ---------------------------------------------------------------------------
# 25. The 1Password service-account token - which grants read access to the
#     whole vault - reaches `op` and nothing else. It must be absent from every
#     other child's environment whichever source it came from, including when
#     the caller exported it.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/svcscope")
FAKE_CURL_LOG="$TMP_ROOT/svcscope-keychain.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" "firstmate" >/dev/null
assert_grep 'svctoken=UNSET' "$FAKE_CURL_LOG" \
  "a keychain-sourced service-account token never reaches curl"
assert_no_grep 'test-svc-account-token' "$FAKE_CURL_LOG" \
  "a keychain-sourced service-account token is nowhere in the request record"
FAKE_CURL_LOG="$TMP_ROOT/svcscope-env.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" \
  OP_SERVICE_ACCOUNT_TOKEN=env-provided-svc-token \
  "$BRIDGE" "firstmate" >/dev/null
assert_grep 'svctoken=UNSET' "$FAKE_CURL_LOG" \
  "a caller-exported service-account token never reaches curl either"
assert_no_grep 'env-provided-svc-token' "$FAKE_CURL_LOG" \
  "a caller-exported service-account token is nowhere in the request record"
pass "the service-account token reaches op and no other child process"

# ---------------------------------------------------------------------------
# 26. Entries that carry no text FIELD are a different case from entries whose
#     text is empty: that is what a server-side body-key rename looks like, and
#     reporting "no memory" for it would hide real memory on every query
#     indefinitely. It must fail closed instead.
# ---------------------------------------------------------------------------
printf '%s' '[{"search_result":[{"id":"c1","summary":"x"},{"id":"c2","summary":"y"}]}]' \
  > "$TMP_ROOT/nokey-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/nokey-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/nokey.err")
RC=$?
[ "$RC" -eq 1 ] || fail "entries with no text field must exit 1, got $RC"
assert_not_contains "$OUT" "No relevant Cognee memory entries found." \
  "a renamed body key is never reported as an empty result"
assert_grep 'none carried a text field' "$TMP_ROOT/nokey.err" \
  "entries with no text field name the reason on stderr"
pass "entries with no text field fail closed instead of reading as no memory"

# ---------------------------------------------------------------------------
# 26b. One entry carrying the text field is enough to prove the key still
#      exists, so a neighbour without it stays the read-but-empty case.
# ---------------------------------------------------------------------------
printf '%s' '[{"search_result":[{"id":"c1","summary":"x"},{"id":"c2","text":""}]}]' \
  > "$TMP_ROOT/somekey-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/somekey-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/somekey.err")
RC=$?
[ "$RC" -eq 0 ] || fail "a payload where the text key still exists must exit 0, got $RC"
assert_contains "$OUT" "No relevant Cognee memory entries found." \
  "a payload that still carries the text key reads as no memory"
[ ! -s "$TMP_ROOT/somekey.err" ] || \
  fail "a payload that still carries the text key must not report an error"
pass "a surviving text key keeps the read-but-empty success path"

# ---------------------------------------------------------------------------
# 27. --json is a verbatim passthrough of a CHECKED body, not an unvalidated
#     one: the skill tells the agent to parse that output as entries, so an
#     unreadable body must fail closed in this mode too.
# ---------------------------------------------------------------------------
JSONOUT="$TMP_ROOT/json-mode-out.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/malformed-resp.json" \
  "$BRIDGE" --json --out "$JSONOUT" "firstmate" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 1 ] || fail "--json on a malformed body must exit 1, got $RC"
assert_contains "$OUT" "malformed JSON" "--json names the malformed body on stderr"
assert_absent "$JSONOUT" "--json writes no file for a body it could not read"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/nokey-resp.json" \
  "$BRIDGE" --json "firstmate" 2>/dev/null)
[ $? -eq 1 ] || fail "--json on entries with no text field must exit 1"
[ -z "$OUT" ] || fail "--json must emit nothing for a body it could not read"
pass "--json fails closed on an unreadable body like the rendered mode"

# ---------------------------------------------------------------------------
# 28. The 1Password coordinates the bridge asks for are the configured ones,
#     for the default and for an override - the credential path is the whole
#     point of the routine and only a live run has ever checked them.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/opcoords")
FAKE_OP_LOG="$TMP_ROOT/op-default.log"
export FAKE_OP_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  "$BRIDGE" "firstmate" >/dev/null
assert_grep 'argv=item get Cognee martin.seibert@seibert.group --vault ai-agent-reads --format json --reveal' \
  "$FAKE_OP_LOG" "the default item and vault reach op verbatim"
FAKE_OP_LOG="$TMP_ROOT/op-override.log"
export FAKE_OP_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  COGNEE_OP_ITEM='Other Cognee Item' COGNEE_OP_VAULT=other-vault \
  "$BRIDGE" "firstmate" >/dev/null
assert_grep 'argv=item get Other Cognee Item --vault other-vault --format json --reveal' \
  "$FAKE_OP_LOG" "COGNEE_OP_ITEM and COGNEE_OP_VAULT overrides reach op"
FAKE_CURL_LOG="$TMP_ROOT/opfield-curl.log"
export FAKE_CURL_LOG
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  COGNEE_OP_FIELD=username \
  "$BRIDGE" "firstmate" >/dev/null
assert_grep 'apikey=martin.seibert@seibert.group' "$FAKE_CURL_LOG" \
  "COGNEE_OP_FIELD selects which item field becomes the API key"
pass "the configured 1Password item, vault, and field are the ones used"

# ---------------------------------------------------------------------------
# 29. A dataset group that lost its search_result field is the same key-rename
#     drift as an entry without text, one level up: it must fail closed rather
#     than report "no memory" on every query while memory exists.
# ---------------------------------------------------------------------------
printf '%s' '[{"dataset_id":"ds","dataset_name":"personal","results":[{"id":"c1","text":"real memory that exists"}]}]' \
  > "$TMP_ROOT/nogroupkey-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/nogroupkey-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/nogroupkey.err")
RC=$?
[ "$RC" -eq 1 ] || fail "a group with no search_result field must exit 1, got $RC"
assert_not_contains "$OUT" "No relevant Cognee memory entries found." \
  "a renamed group key is never reported as an empty result"
assert_grep 'no search_result field' "$TMP_ROOT/nogroupkey.err" \
  "a group with no search_result field names the reason on stderr"
pass "a group with no search_result field fails closed"

# ---------------------------------------------------------------------------
# 29b. A group whose search_result is present but empty still reads as no
#      memory, so requiring the key never relabels a legitimate empty result.
# ---------------------------------------------------------------------------
printf '%s' '[{"dataset_id":"ds","dataset_name":"personal","search_result":[]}]' \
  > "$TMP_ROOT/emptygroup-resp.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/emptygroup-resp.json" \
  "$BRIDGE" "firstmate" 2>"$TMP_ROOT/emptygroup.err")
RC=$?
[ "$RC" -eq 0 ] || fail "an empty search_result list must exit 0, got $RC"
assert_contains "$OUT" "No relevant Cognee memory entries found." \
  "an empty search_result list reads as no memory"
[ ! -s "$TMP_ROOT/emptygroup.err" ] || \
  fail "an empty search_result list must not report an error"
pass "an empty search_result list keeps the read-but-empty success path"

# ---------------------------------------------------------------------------
# 30. An option whose value is missing must not silently swallow the next flag
#     as its value - that queries the wrong dataset, or writes a file named
#     after a flag, and reports success either way. Now that options may trail
#     the query, a dropped value is no longer visually obvious.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/dropped-value")
FAKE_CURL_LOG="$TMP_ROOT/dropped-value-curl.log"
export FAKE_CURL_LOG
run_dropped() {  # run_dropped <expected-message-fragment> <args...>
  local want=$1
  shift
  local out rc
  out=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    "$BRIDGE" "$@" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a dropped value for $want must exit 2, got $rc"
  assert_contains "$out" "$want" "a dropped value for $want names the flag"
}
run_dropped '--dataset requires a value' "q" --dataset --out "$TMP_ROOT/nope.md"
run_dropped '--out requires a value' --out --json "q"
run_dropped '--top-k requires a value' "q" --top-k --json
run_dropped '--search-type requires a value' "q" --search-type --json
assert_absent "$TMP_ROOT/nope.md" "no output file is written when a value was dropped"
assert_absent "./--json" "no file named after a flag is created in the working directory"
[ ! -e "$FAKE_CURL_LOG" ] || fail "a dropped value must be rejected before any Cognee request"
pass "a dropped option value is rejected instead of swallowing the next flag"

# ---------------------------------------------------------------------------
# 31. An option value that is present but EMPTY is the same dropped-value bug
#     wearing quotes: `--out "$CTX"` with CTX unset used to set no out-file,
#     print the context to stdout, and exit 0, so the caller believed a context
#     file existed. It must be a usage error like a missing value.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/empty-value")
FAKE_CURL_LOG="$TMP_ROOT/empty-value-curl.log"
export FAKE_CURL_LOG
run_empty() {  # run_empty <expected-message-fragment> <args...>
  local want=$1
  shift
  local out rc
  out=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    "$BRIDGE" "$@" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an empty value for $want must exit 2, got $rc"
  assert_contains "$out" "$want" "an empty value for $want names the flag"
  assert_not_contains "$out" "# Cognee memory context" \
    "an empty value for $want never renders context to stdout"
}
run_empty '--out requires a value' "q" --out ""
run_empty '--dataset requires a value' "q" --dataset ""
run_empty '--top-k requires a value' "q" --top-k ""
run_empty '--search-type requires a value' "q" --search-type ""
[ ! -e "$FAKE_CURL_LOG" ] || fail "an empty value must be rejected before any Cognee request"
pass "an empty option value is a usage error, not a silent fall-through to stdout"

# ---------------------------------------------------------------------------
# 32. The reason body is folded onto the error line and bounded, so a long or
#     multi-line server reason stays one readable message instead of flooding
#     the caller's log with the whole payload.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/http-reason")
{ echo '{'; echo '  "detail": "topK must be between 1 and 100"'; echo '}'; } \
  > "$TMP_ROOT/reason-multiline.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_CODE=422 FAKE_COGNEE_ERROR_FILE="$TMP_ROOT/reason-multiline.json" \
  "$BRIDGE" "firstmate" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 1 ] || fail "a 422 must exit 1, got $RC"
assert_contains "$OUT" "HTTP 422" "the request-shape rejection reports its code"
assert_contains "$OUT" "topK must be between 1 and 100" \
  "the request-shape rejection names the rejected field"
[ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" = "0" ] || \
  fail "a multi-line reason body must be folded onto a single error line"
python3 -c 'import sys; sys.exit(0 if len(sys.argv[1]) <= 900 else 1)' "$OUT" || \
  fail "the reason excerpt must be bounded"
printf 'x%.0s' $(seq 1 4000) > "$TMP_ROOT/reason-long.json"
OUT=$(PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_CODE=500 FAKE_COGNEE_ERROR_FILE="$TMP_ROOT/reason-long.json" \
  "$BRIDGE" "firstmate" 2>&1 >/dev/null)
[ $? -eq 1 ] || fail "a 500 with a long body must exit 1"
python3 -c 'import sys; sys.exit(0 if len(sys.argv[1]) <= 900 else 1)' "$OUT" || \
  fail "a 4000-byte reason body must be truncated, not printed whole"
pass "a non-200 reason body is folded onto one bounded error line"

# ---------------------------------------------------------------------------
# 33. A failed run must not leave the previous run's context file behind. The
#     brief points a worker at the --out path, so a stale file that survives an
#     outage feeds one task's memory to the next under this task's name.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/stale-out")
STALE_OUT="$TMP_ROOT/stale-context.md"
printf '%s' '[{"search_result":[{"id":"c1","text":"memory belonging to the FIRST task"}]}]' \
  > "$TMP_ROOT/stale-first-resp.json"
run_stale_first() {  # seed the out-file from a successful run
  PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    FAKE_COGNEE_RESP_FILE="$TMP_ROOT/stale-first-resp.json" \
    "$BRIDGE" --out "$STALE_OUT" "first task" >/dev/null
}
run_stale_first || fail "the seeding run must succeed"
assert_grep 'memory belonging to the FIRST task' "$STALE_OUT" \
  "the seeding run wrote the first task's memory to the out-file"

# Failure stage 1: the search is rejected outright.
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token FAKE_COGNEE_CODE=401 \
  "$BRIDGE" --out "$STALE_OUT" "second task" >/dev/null 2>&1
[ $? -eq 1 ] || fail "a non-200 with --out must exit 1"
assert_absent "$STALE_OUT" "a non-200 removes the previous run's context file"

# Failure stage 2: the body arrives but cannot be read as memory.
run_stale_first || fail "the seeding run must succeed before the payload case"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token \
  FAKE_COGNEE_RESP_FILE="$TMP_ROOT/nokey-resp.json" \
  "$BRIDGE" --out "$STALE_OUT" "second task" >/dev/null 2>&1
[ $? -eq 1 ] || fail "an unreadable payload with --out must exit 1"
assert_absent "$STALE_OUT" "an unreadable payload removes the previous run's context file"

# Failure stage 3: the credential path fails before any request is made.
run_stale_first || fail "the seeding run must succeed before the credential case"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  -u SECURITY_STUB_TOKEN \
  "$BRIDGE" --out "$STALE_OUT" "second task" >/dev/null 2>&1
[ $? -eq 1 ] || fail "a missing service-account token with --out must exit 1"
assert_absent "$STALE_OUT" \
  "a missing service-account token removes the previous run's context file"

# --json shares the out-file path, so it must shed a stale file too.
run_stale_first || fail "the seeding run must succeed before the --json case"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token FAKE_COGNEE_CODE=500 \
  "$BRIDGE" --json --out "$STALE_OUT" "second task" >/dev/null 2>&1
[ $? -eq 1 ] || fail "a non-200 with --json --out must exit 1"
assert_absent "$STALE_OUT" "--json removes the previous run's context file too"

# Failure stage 4: a usage error found AFTER --out was parsed. These exit 2
# before any request, so they are the earliest failures that can still leave a
# stale file behind, and a caller assembling the command from parts hits them.
run_usage_stale() {  # run_usage_stale <label> <args-after---out...>
  local label=$1
  shift
  run_stale_first || fail "the seeding run must succeed before the $label case"
  PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
    SECURITY_STUB_TOKEN=test-svc-account-token \
    "$BRIDGE" --out "$STALE_OUT" "$@" >/dev/null 2>&1
  [ $? -eq 2 ] || fail "$label after --out must exit 2"
  assert_absent "$STALE_OUT" "$label after --out removes the previous run's context file"
}
run_usage_stale 'an out-of-range --top-k' "second task" --top-k 0
run_usage_stale 'a bad --search-type' "second task" --search-type BOGUS
run_usage_stale 'an unknown option' "second task" --bogus-option
run_usage_stale 'a dropped option value' "second task" --dataset --json
run_usage_stale 'a missing query'

# An out-of-range COGNEE_TIMEOUT is an environment error rather than an argument
# one, so no argument ordering can put it after --out: the cleanup has to cover
# it or the "put --out first" guidance would be false assurance.
run_stale_first || fail "the seeding run must succeed before the timeout case"
PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
  SECURITY_STUB_TOKEN=test-svc-account-token COGNEE_TIMEOUT=notanumber \
  "$BRIDGE" --out "$STALE_OUT" "second task" >/dev/null 2>&1
[ $? -eq 2 ] || fail "an out-of-range COGNEE_TIMEOUT with --out must exit 2"
assert_absent "$STALE_OUT" \
  "an out-of-range COGNEE_TIMEOUT removes the previous run's context file"

# A run that succeeds still leaves its own output in place.
run_stale_first || fail "a successful run must still write the out-file"
assert_grep 'memory belonging to the FIRST task' "$STALE_OUT" \
  "the cleanup never removes the output of a run that succeeded"
pass "a failed run removes the out-file instead of leaving stale context"

# ---------------------------------------------------------------------------
# 34. The context is memory from a private dataset, so the bridge owns the
#     out-file's mode instead of inheriting the caller's umask. Otherwise a
#     path the bridge creates itself - the task-id form, or a retry after the
#     failure cleanup removed an mktemp-created file - lands at 0644 in a shared
#     directory.
# ---------------------------------------------------------------------------
fakebin=$(make_fake_bins "$TMP_ROOT/outmode")
file_mode() {  # file_mode <path>
  python3 -c 'import os, sys; print("%03o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}
# The permissive umask belongs to the bridge invocation alone. Wrapping the
# assertions in the subshell too would swallow their `fail` - an exit 1 inside
# `( ... )` ends only the subshell, and this file runs without `set -e`, so the
# suite would report a pass with exit status 0.
run_mode_case() {  # run_mode_case <label> <path> [extra-args...]
  local label=$1 path=$2
  shift 2
  ( umask 022
    PATH="$fakebin:$BASE_PATH" "${CLEAN_ENV[@]}" -u OP_SERVICE_ACCOUNT_TOKEN \
      SECURITY_STUB_TOKEN=test-svc-account-token \
      "$BRIDGE" "$@" --out "$path" "firstmate" >/dev/null ) || \
    fail "the $label run must succeed"
  local mode
  mode=$(file_mode "$path")
  [ "$mode" = "600" ] || fail "the $label out-file must be mode 600, got $mode"
  assert_grep 'Memory about firstmate setup' "$path" \
    "the $label out-file still holds the rendered context"
}

# A path the bridge creates itself, under a permissive umask.
run_mode_case 'newly created' "$TMP_ROOT/mode-new.md"

# A file that already exists world-readable must be tightened, not inherited.
LOOSEOUT="$TMP_ROOT/mode-loose.md"
printf 'stale\n' > "$LOOSEOUT"
chmod 644 "$LOOSEOUT"
[ "$(file_mode "$LOOSEOUT")" = "644" ] || fail "the fixture out-file must start at 644"
run_mode_case 'pre-existing world-readable' "$LOOSEOUT"

# --json writes through the same path, so it must be restricted too.
run_mode_case '--json' "$TMP_ROOT/mode-json.json" --json
pass "the out-file is restricted to mode 600 whatever the caller's umask"
