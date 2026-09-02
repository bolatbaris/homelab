#!/usr/bin/env bash
# Exposure guards for the compose files. Runnable locally and from CI:
#
#   ./tests/compose-guards.sh
#
# These assertions encode SECURITY.md's exposure tiers. A published port that
# does not name an interface binds every interface, and a Tier B service that
# joins edge-net becomes reachable by cloudflared -- both are silent failures
# that only show up as an exposed database, so they are tested rather than
# reviewed for.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILURES=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

if [ -n "${COMPOSE_BIN:-}" ]; then
  COMPOSE=$COMPOSE_BIN
elif docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE="podman-compose"
else
  echo "ERROR: need either 'docker compose' or 'podman-compose'." >&2
  exit 2
fi
echo "# using: $COMPOSE"

# --- 1. Bind allowlist -------------------------------------------------------
# Every entry under a `ports:` key must start with an allowed host part.
# Checked against the source files rather than rendered output so the rule holds
# for every value of every variable, not just the ones in .env.example.
bind_offenders() {
  awk '
    /^[[:space:]]*ports:[[:space:]]*$/ { inports = 1; next }
    inports && /^[[:space:]]*#/        { next }
    inports && /^[[:space:]]*-[[:space:]]*/ {
      entry = $0
      sub(/^[[:space:]]*-[[:space:]]*"?/, "", entry)
      if (entry !~ /^(127\.0\.0\.1:|\$\{LAN_IP[:}]|\$\{TAILSCALE_IP[:}])/) {
        printf "%s:%d: %s\n", FILENAME, FNR, $0
      }
      next
    }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { inports = 0 }
  ' "$@"
}

offenders="$(bind_offenders docker-compose.yml compose.dev.yml)"
if [ -n "$offenders" ]; then
  fail "published ports must bind 127.0.0.1, \${LAN_IP…} or \${TAILSCALE_IP…}:"
  printf '%s\n' "$offenders" >&2
else
  pass "every published port names an allowed interface"
fi

# --- 2. Tier B services must not be reachable by cloudflared ------------------
# cloudflared only reaches edge-net. Keeping the db and env services off it
# means a public hostname created by mistake still cannot route to them.
edge_members() {
  awk '
    /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); innet = 0 }
    /^[[:space:]]{4}networks:[[:space:]]*$/ { innet = 1; next }
    innet && /^[[:space:]]*-[[:space:]]*edge-net[[:space:]]*$/ { print svc }
    innet && /^[[:space:]]{4}[a-z]/ { innet = 0 }
  ' docker-compose.yml
}

for svc in appdb appdb-adminer appdb-dump infisical infisical-postgres infisical-redis infisical-db-dump umami umami-postgres umami-db-dump glitchtip glitchtip-postgres glitchtip-valkey glitchtip-db-dump; do
  if edge_members | grep -qx "$svc"; then
    fail "$svc is on edge-net; cloudflared could reach it"
  else
    pass "$svc is not on edge-net"
  fi
done

# --- 3. db and env profile services exist ------------------------------------
for svc in appdb appdb-adminer appdb-dump infisical infisical-postgres infisical-redis infisical-db-dump umami umami-postgres umami-db-dump glitchtip glitchtip-postgres glitchtip-valkey glitchtip-db-dump; do
  if grep -qE "^  ${svc}:[[:space:]]*$" docker-compose.yml; then
    pass "$svc is defined"
  else
    fail "$svc is not defined in docker-compose.yml"
  fi
done

# --- 4. Fail-closed: empty TAILSCALE_IP must break the db profile ------------
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
sed -E 's/^(TAILSCALE_IP)=.*/\1=/' .env.example > "$scratch/.env.empty"

if TAILSCALE_IP= $COMPOSE --env-file "$scratch/.env.empty" -f docker-compose.yml \
     --profile db config >/dev/null 2>&1; then
  fail "db profile rendered with an empty TAILSCALE_IP -- the guard is disarmed"
else
  pass "db profile refuses to render with an empty TAILSCALE_IP"
fi

# --- 5. Fail-open check: a set TAILSCALE_IP must render, bound to it ---------
sed -E 's/^(TAILSCALE_IP)=.*/\1=100.64.0.1/' .env.example > "$scratch/.env.set"
rendered="$($COMPOSE --env-file "$scratch/.env.set" -f docker-compose.yml \
  --profile db config 2>/dev/null)"

if printf '%s' "$rendered" | grep -q '100\.64\.0\.1'; then
  pass "db profile binds the tailscale address when it is set"
else
  fail "db profile did not bind 100.64.0.1 with TAILSCALE_IP set"
fi

if printf '%s' "$rendered" | grep -qE '(^|[^0-9.])0\.0\.0\.0:'; then
  fail "rendered config contains a 0.0.0.0 bind"
else
  pass "rendered config has no 0.0.0.0 bind"
fi

# --- 6. env profile: an empty TAILSCALE_IP degrades to loopback, never wild ---
# Unlike the db profile (which fails the render on purpose), Infisical keeps
# working on loopback so the store cannot silently land on every interface.
rendered_env="$($COMPOSE --env-file "$scratch/.env.empty" -f docker-compose.yml \
  --profile env config 2>/dev/null)"

if printf '%s' "$rendered_env" | grep -qE '(^|[^0-9.])0\.0\.0\.0:'; then
  fail "env profile rendered with an empty TAILSCALE_IP contains a 0.0.0.0 bind"
else
  pass "env profile falls back to loopback with an empty TAILSCALE_IP"
fi

# --- 7. analytics profile: same loopback-fallback rule as env ----------------
rendered_analytics="$($COMPOSE --env-file "$scratch/.env.empty" -f docker-compose.yml \
  --profile analytics config 2>/dev/null)"

if printf '%s' "$rendered_analytics" | grep -qE '(^|[^0-9.])0\.0\.0\.0:'; then
  fail "analytics profile rendered with an empty TAILSCALE_IP contains a 0.0.0.0 bind"
else
  pass "analytics profile falls back to loopback with an empty TAILSCALE_IP"
fi

# --- 8. monitoring profile: same loopback-fallback rule as env ----------------
rendered_monitoring="$($COMPOSE --env-file "$scratch/.env.empty" -f docker-compose.yml \
  --profile monitoring config 2>/dev/null)"

if printf '%s' "$rendered_monitoring" | grep -qE '(^|[^0-9.])0\.0\.0\.0:'; then
  fail "monitoring profile rendered with an empty TAILSCALE_IP contains a 0.0.0.0 bind"
else
  pass "monitoring profile falls back to loopback with an empty TAILSCALE_IP"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
echo "All compose guards passed."
