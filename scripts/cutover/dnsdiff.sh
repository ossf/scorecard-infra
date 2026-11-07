#!/usr/bin/env bash
#
# Copyright 2026 OpenSSF Scorecard Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Verifies that the new nameservers serve the same zone the old ones did
# (task 6.3d). Written as a pre-delegation gate; delegation was changed on
# 2026-08-28, so it now runs as an after-the-fact check. While the old
# nameservers still answer, the comparison is still worth having.
#
#   ./dnsdiff.sh [--list] [capture-dir]
#
#     --list   print the expected record matrix and exit; no DNS queries, so it
#              works anywhere and shows exactly what coverage you are getting.
#
# THE CHECK LIST COMES FROM THE CAPTURE, NOT FROM A LIST IN THIS FILE
#
# The first version of this script hardcoded the domains and subdomains to
# check. Both of its blind spots came from that, and neither was visible in its
# output:
#
#   * It queried `securityscorecard.dev`. The zone is `securityscorecards.dev`
#     -- plural. Every lookup for it returned empty from both nameservers, and
#     a "skip if neither has a record" guard turned 20 silent failures into a
#     clean-looking section with no rows. api.securityscorecards.dev is one of
#     the two published API hostnames and it went unverified while the report
#     read as though the domain had passed.
#   * Its subdomain list was ("" api api-staging www), which omits the four
#     `_acme-challenge` CNAMEs. Those are the records whose loss is invisible
#     for weeks and then breaks Fastly TLS renewal -- exactly the ones a
#     pre-delegation check exists to catch.
#
# So the expected set is read from capture-config.sh's `dns-records-*.json`,
# which is what Cloud DNS actually served. A name cannot be missed by being
# forgotten, only by being absent from the capture. Silence is never success:
# a record in the capture that the new nameserver does not answer for is a
# hard failure, not a skipped row.
#
# Requires `dig`, `jq`, and `curl`, and network access to both nameservers.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OLD_NS="${OLD_NS:-ns-cloud-b1.googledomains.com}"

# The new nameserver is PER ZONE. Netlify DNS assigns each zone its own NS1
# pool, and the two zones did not get the same one: scorecard.dev is on p01,
# securityscorecards.dev on p09. Asking p01 about securityscorecards.dev
# returns nothing, because it is not authoritative for it -- and this script
# treats an empty answer as a dropped record, so a single NEW_NS would fail
# every record of the second zone and look like a catastrophe rather than a
# misdirected query. Override with NEW_NS to force one server for all zones.
new_ns_for() {
  case "$1" in
    *securityscorecards.dev*) echo "dns1.p09.nsone.net" ;;
    *scorecard.dev*)          echo "dns1.p01.nsone.net" ;;
    *)                        echo "" ;;
  esac
}

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then LIST_ONLY=1; shift; fi

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }
[ "${LIST_ONLY}" -eq 1 ] || command -v dig >/dev/null || \
  { echo "error: dig is required" >&2; exit 2; }
[ "${LIST_ONLY}" -eq 1 ] || command -v curl >/dev/null || \
  { echo "error: curl is required" >&2; exit 2; }

has_records() {
  local f
  for f in "$1"/dns-records-*.json; do [ -e "${f}" ] && return 0; done
  return 1
}

# Newest capture directory that actually holds DNS records.
find_capture() {
  local d
  find "${SCRIPT_DIR}/out" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort |
    while IFS= read -r d; do has_records "${d}" && echo "${d}"; done | tail -1
}
CAPTURE="${1:-$(find_capture)}"

if [ -z "${CAPTURE}" ] || ! has_records "${CAPTURE}"; then
  cat >&2 <<EOF
error: no DNS capture found.

  Expected dns-records-*.json under a capture directory. Produce one with:

      ./capture-config.sh

  or pass the directory explicitly:

      $0 /path/to/capture-dir
EOF
  exit 2
fi

# --- Build the expected set ----------------------------------------------
# SOA is excluded: its serial changes on every edit, so comparing it across a
# migration reports a difference that is always there and never means anything.
# Apex NS is kept but classified separately -- it *must* differ during a
# delegation move, because it is the move. Counting it as a mismatch inflates
# the total and teaches people to skim the output.
EXPECTED="$(mktemp)"
trap 'rm -f "${EXPECTED}"' EXIT

for f in "${CAPTURE}"/dns-records-*.json; do
  jq -r '.[] | select(.type != "SOA")
         | [.name, .type, (.rrdatas | join(" "))] | @tsv' "${f}" 2>/dev/null
done | sort -u > "${EXPECTED}"

if [ ! -s "${EXPECTED}" ]; then
  echo "error: capture parsed but yielded no records: ${CAPTURE}" >&2
  exit 2
fi

if [ "${LIST_ONLY}" -eq 1 ]; then
  echo "Expected records from: ${CAPTURE}"
  echo "$(wc -l < "${EXPECTED}" | tr -d ' ') records"
  echo
  printf '%-52s %-6s %s\n' "NAME" "TYPE" "VALUE"
  while IFS="$(printf '\t')" read -r name type vals; do
    printf '%-52s %-6s %s\n' "${name}" "${type}" "${vals}"
  done < "${EXPECTED}"
  exit 0
fi

# Normalize for comparison: one token per line, quotes stripped, lowercased,
# sorted, `;` diagnostic lines dropped. Values containing spaces (a multi-string
# TXT record) would be split here; none of these zones has one, and the --list
# output is where you would notice if that changed.
norm() {
  grep -v '^;' | tr ' ' '\n' | tr -d '"' | tr '[:upper:]' '[:lower:]' \
    | sed '/^$/d' | sort
}

# `dig +short` writes "connection timed out; no servers could be reached" to
# STDOUT, not stderr, and still produces output when the query never happened.
# Piping it straight into the comparison turns an unreachable resolver into a
# content mismatch: the first run of this script reported 13 differences whose
# "new" values were shredded error text. So check the exit status and make the
# distinction explicit -- "the server answered differently" and "I could not
# ask" are not the same result, and only one of them says anything about DNS.
dig_answer() {
  local out rc
  out="$(dig @"$1" "$2" "$3" +short +time=2 +tries=2 2>/dev/null)"
  rc=$?
  [ "${rc}" -eq 0 ] || return 1
  printf '%s\n' "${out}" | norm
}

# Web-facing hostnames terminating TLS (task 6.3f). Record comparison is sound
# for `api.*` and `_acme-challenge` (which are static CNAMEs) and unsound for
# anything terminating TLS on Netlify: apex A records fluctuate across regions
# due to ALIAS flattening, and www CNAMEs are flattened into ALIAS addresses.
# Crucially, record comparison cannot detect TLS certificate defects, such as
# when a certificate SAN list omits a subdomain (task 6.3d, 6.3e).
is_web_facing() {
  local name="${1%.}"
  case "${name}" in
    scorecard.dev|www.scorecard.dev|securityscorecards.dev|www.securityscorecards.dev)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# probe_https <name> <target-ns>
# Fetches the hostname over HTTPS using curl. Verifies that TLS negotiates
# cleanly with full certificate validation (catching SAN omissions or expired
# certificates) and returns a healthy web HTTP status code (2xx or 3xx).
# If the target nameserver provides an A record IP, routes directly to that IP via
# curl --resolve to test the target nameserver's destination directly.
probe_https() {
  local name="${1%.}"
  local target_ns="${2:-}"
  local target_ip=""
  local err_file code rc err_msg

  if [ -n "${target_ns}" ]; then
    target_ip="$(dig @"${target_ns}" "${name}" A +short +time=2 +tries=2 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  fi

  err_file="$(mktemp)"
  local curl_args=(
    -sS
    -o /dev/null
    -w "%{http_code}"
    --connect-timeout 5
    --max-time 10
  )

  if [ -n "${target_ip}" ]; then
    curl_args+=(--resolve "${name}:443:${target_ip}")
  fi

  code="$(curl "${curl_args[@]}" "https://${name}" 2>"${err_file}")"
  rc=$?
  err_msg="$(head -n 2 "${err_file}" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  rm -f "${err_file}"

  if [ "${rc}" -ne 0 ] || [ -z "${code}" ] || [ "${code}" = "000" ]; then
    if [ -n "${err_msg}" ]; then
      echo "TLS/connection error: ${err_msg}"
    else
      echo "curl connection failed (exit code ${rc})"
    fi
    return 1
  fi

  case "${code}" in
    2*|3*)
      if [ -n "${target_ip}" ]; then
        echo "HTTP ${code} via ${target_ip}"
      else
        echo "HTTP ${code}"
      fi
      return 0
      ;;
    *)
      echo "HTTP status ${code}"
      return 1
      ;;
  esac
}

MATCH=0; MISMATCH=0; MISSING=0; EXPECTED_DIFF=0; DRIFT=0; UNREACHABLE=0

echo "=========================================================="
echo " Post-delegation DNS check"
echo " capture: ${CAPTURE}"
echo " OLD NS:  ${OLD_NS}"
if [ -n "${NEW_NS:-}" ]; then
  echo " NEW NS:  ${NEW_NS} (forced for every zone)"
else
  echo " NEW NS:  per zone -- scorecard.dev p01, securityscorecards.dev p09"
fi
echo "=========================================================="
echo

# Preflight. Without this, an environment that cannot resolve at all spends
# two minutes timing out once per record and buries the one fact that matters
# in fifteen rows of noise. Same reasoning as the capture scripts' fail-fast on
# credentials: one problem should be reported once.
PREFLIGHT_OK=0
for S in $(sed 's/\t.*//' "${EXPECTED}" | while IFS= read -r n; do
             [ -n "${n}" ] && echo "${NEW_NS:-$(new_ns_for "${n}")}"
           done | sort -u); do
  [ -n "${S}" ] || continue
  if dig @"${S}" . NS +short +time=2 +tries=1 >/dev/null 2>&1; then
    PREFLIGHT_OK=1
    break
  fi
done
if [ "${PREFLIGHT_OK}" -eq 0 ]; then
  cat >&2 <<EOF
error: no nameserver answered a preflight query.

  DNS is not reachable from here, so every check below would fail for a
  reason that has nothing to do with the zone. Re-run from a network that
  can resolve.
EOF
  exit 2
fi

while IFS="$(printf '\t')" read -r NAME TYPE WANT; do
  [ -n "${NAME}" ] || continue

  TARGET_NS="${NEW_NS:-$(new_ns_for "${NAME}")}"
  if [ -z "${TARGET_NS}" ]; then
    MISMATCH=$((MISMATCH + 1))
    echo "❌ [NO SERVER] ${NAME} (${TYPE}) -- no nameserver mapped for this zone"
    echo "      add it to new_ns_for(), or set NEW_NS to force one"
    continue
  fi

  WANT_N="$(printf '%s' "${WANT}" | norm)"

  # An unanswerable query is an error about this machine, not a finding about
  # the zone. Never let it reach the comparison.
  if ! NEW_N="$(dig_answer "${TARGET_NS}" "${NAME}" "${TYPE}")"; then
    UNREACHABLE=$((UNREACHABLE + 1))
    echo "🚫 [UNREACHABLE] ${NAME} (${TYPE}) -- no answer from ${TARGET_NS}"
    continue
  fi
  OLD_N="$(dig_answer "${OLD_NS}" "${NAME}" "${TYPE}")" || OLD_N=""

  # The delegation itself.
  if [ "${TYPE}" = "NS" ]; then
    EXPECTED_DIFF=$((EXPECTED_DIFF + 1))
    echo "ℹ️  [EXPECTED] ${NAME} (NS) -- delegation change, not a discrepancy"
    echo "      old: $(echo "${OLD_N}" | tr '\n' ' ')"
    echo "      new: $(echo "${NEW_N}" | tr '\n' ' ')"
    continue
  fi

  # Web-facing names terminating TLS (task 6.3f). Record comparison is unsound
  # because Netlify uses ALIAS flattening for apex and www (returning dynamic A
  # addresses rather than static captured IPs or CNAMEs), and record comparison
  # cannot verify TLS certificates (task 6.3d, 6.3e). Fetching the name over
  # HTTPS verifies resolution, TLS certificate validity, and HTTP response.
  if is_web_facing "${NAME}" && { [ "${TYPE}" = "A" ] || [ "${TYPE}" = "CNAME" ]; }; then
    if res="$(probe_https "${NAME}" "${TARGET_NS}")"; then
      MATCH=$((MATCH + 1))
      echo "✅ [HTTPS OK] ${NAME} (${TYPE}) -- ${res} (TLS verified)"
    else
      MISMATCH=$((MISMATCH + 1))
      echo "❌ [HTTPS FAIL] ${NAME} (${TYPE}) -- ${res}"
    fi
    continue
  fi

  # The failure the old script could not report: the new zone simply does not
  # have the record. Empty is never a pass.
  if [ -z "${NEW_N}" ]; then
    MISSING=$((MISSING + 1))
    echo "❌ [MISSING]  ${NAME} (${TYPE}) -- absent from ${TARGET_NS}"
    echo "      expected: $(echo "${WANT_N}" | tr '\n' ' ')"
    continue
  fi

  if [ "${NEW_N}" != "${WANT_N}" ]; then
    MISMATCH=$((MISMATCH + 1))
    echo "❌ [MISMATCH] ${NAME} (${TYPE})"
    echo "      captured: $(echo "${WANT_N}" | tr '\n' ' ')"
    echo "      new:      $(echo "${NEW_N}" | tr '\n' ' ')"
    continue
  fi

  # New matches the capture. If the *old* server has since moved, the capture
  # is stale as a rebuild source -- worth knowing before trusting it again.
  if [ -n "${OLD_N}" ] && [ "${OLD_N}" != "${WANT_N}" ]; then
    DRIFT=$((DRIFT + 1))
    echo "⚠️  [DRIFT]    ${NAME} (${TYPE}) -- live old zone differs from capture"
    echo "      captured: $(echo "${WANT_N}" | tr '\n' ' ')"
    echo "      old:      $(echo "${OLD_N}" | tr '\n' ' ')"
    continue
  fi

  MATCH=$((MATCH + 1))
  echo "✅ [MATCH]    ${NAME} (${TYPE})"
done < "${EXPECTED}"

echo
echo "=========================================================="
echo " match ${MATCH}   mismatch ${MISMATCH}   missing ${MISSING}   drift ${DRIFT}"
echo " unreachable ${UNREACHABLE}   expected-diff ${EXPECTED_DIFF}"
echo
echo " Not covered: records present in the new zone but absent from the"
echo " capture. Listing those needs a zone export from the new provider;"
echo " this script can only verify that nothing was dropped."

# Reported separately and first: an unreachable resolver invalidates the whole
# run, and reading it as a zone problem is the specific mistake this script has
# already made once.
if [ "${UNREACHABLE}" -gt 0 ]; then
  echo "🚫 ${UNREACHABLE} quer(ies) got no answer. This says nothing about the"
  echo "   zone -- it says DNS is not reachable from here. Re-run somewhere"
  echo "   that can resolve; a sandbox or a VPN split-tunnel will do this."
  echo "=========================================================="
  exit 2
fi

if [ $((MISMATCH + MISSING)) -gt 0 ]; then
  echo "⚠️  Resolve these before trusting the new zone."
  echo "=========================================================="
  exit 1
fi
echo "🎉 Every captured record is served correctly by the new nameservers."
echo "=========================================================="
