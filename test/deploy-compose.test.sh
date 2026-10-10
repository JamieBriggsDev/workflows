#!/usr/bin/env bash
# Tests for the deploy-compose workflow's bundle step and the server script it
# talks to. `docker` is a fake on PATH that logs its calls, except in the test
# that checks the .env against the real `docker compose`.
#
# Run: test/deploy-compose.test.sh
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/server/deploy-compose"
failures=0

# Each test gets a fresh scratch dir holding the app dir, a fake docker and its log.
setup() {
  work=$(mktemp -d)
  app="$work/app"
  mkdir -p "$app" "$work/bin" "$work/bundle"
  log="$work/docker.log"
  : > "$log"
  cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Logs each call. For login, also logs the password it was given on stdin.
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "$*" == *--password-stdin* ]]; then
  printf 'password=%s\n' "$(cat)" >> "$DOCKER_LOG"
fi
if [[ -n "${DOCKER_FAIL_ON:-}" && "$*" == *"$DOCKER_FAIL_ON"* ]]; then
  exit 1
fi
EOF
  chmod +x "$work/bin/docker"
}

teardown() { rm -rf "$work"; }

# Builds a bundle by hand, as the workflow's bundle step would.
hand_bundle() {
  printf 'services: {}\n' > "$work/bundle/compose.yaml"
  printf "IMAGE_TAG='abc123'\n" > "$work/bundle/.env"
  printf 'octocat\nghp_token\n' > "$work/bundle/ghcr-login"
  tar -C "$work/bundle" -cf "$work/bundle.tar" compose.yaml .env ghcr-login
}

# Runs the workflow's bundle step, as Actions would, in a fake caller checkout.
# $1 is JSON merged over a secrets context that holds the deploy's own secrets.
bundle_step() {
  local step secrets
  secrets=$(jq -n --argjson extra "$1" '{
    github_token: "ghs_x", GHCR_TOKEN: "ghp_token",
    DEPLOY_HOST: "h", DEPLOY_USER: "u", DEPLOY_SSH_KEY: "k", DEPLOY_KNOWN_HOSTS: "kh",
    TS_OAUTH_CLIENT_ID: "c", TS_OAUTH_SECRET: "s"
  } + $extra')
  step=$(python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in wf["jobs"]["deploy"]["steps"] if s.get("name") == "Bundle"))
' "$repo/.github/workflows/deploy-compose.yml")
  rm -rf "$work/caller"
  mkdir -p "$work/caller/deploy"
  printf 'services: {}\n' > "$work/caller/deploy/compose.prod.yaml"
  (cd "$work/caller" &&
    SECRETS="$secrets" IMAGE_TAG=abc123 COMPOSE_FILE=deploy/compose.prod.yaml REGISTRY_USERNAME=octocat \
      bash --noprofile --norc -eo pipefail -c "$step") > "$work/out" 2>&1
}

deploy() {
  PATH="$work/bin:$PATH" DOCKER_LOG="$log" "$script" "$app" < "$1" > "$work/out" 2>&1
}

fail() {
  printf '  FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }

run() {
  printf '%s\n' "$1"
  setup
  "$1"
  teardown
}

test_a_valid_bundle_is_written_to_the_app_dir_then_pulled_and_started() {
  hand_bundle
  deploy "$work/bundle.tar" || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(cat "$app/compose.yaml")" 'services: {}' "compose.yaml"
  assert_eq "$(cat "$app/.env")" "IMAGE_TAG='abc123'" ".env"
  [[ ! -e "$app/ghcr-login" ]] || fail "ghcr-login was left in the app dir"
  assert_eq "$(cat "$log")" "login ghcr.io --username octocat --password-stdin
password=ghp_token
compose --project-directory $app --file $app/.deploy/compose.yaml --env-file $app/.deploy/.env pull
compose --project-directory $app --file $app/compose.yaml --env-file $app/.env up --detach --remove-orphans" "docker calls"
}

test_a_failed_pull_leaves_the_running_deploy_untouched() {
  printf 'old compose\n' > "$app/compose.yaml"
  printf 'old env\n' > "$app/.env"
  hand_bundle
  DOCKER_FAIL_ON=pull deploy "$work/bundle.tar" && fail "exit status 0"
  assert_eq "$(cat "$app/compose.yaml")" 'old compose' "compose.yaml"
  assert_eq "$(cat "$app/.env")" 'old env' ".env"
  grep -q ' up ' "$log" && fail "ran up after a failed pull"
  [[ ! -e "$app/.deploy" ]] || fail "left the staging dir behind"
}

test_a_bundle_missing_a_file_is_refused_before_docker_runs() {
  printf 'old env\n' > "$app/.env"
  hand_bundle
  tar -C "$work/bundle" -cf "$work/bundle.tar" compose.yaml ghcr-login
  deploy "$work/bundle.tar" && fail "exit status 0"
  assert_eq "$(cat "$log")" '' "docker calls"
  assert_eq "$(cat "$app/.env")" 'old env' ".env"
}

test_a_symlink_in_the_bundle_is_refused_before_docker_runs() {
  printf 'secret\n' > "$work/elsewhere"
  hand_bundle
  rm "$work/bundle/.env"
  ln -s "$work/elsewhere" "$work/bundle/.env"
  tar -C "$work/bundle" -cf "$work/bundle.tar" compose.yaml .env ghcr-login
  deploy "$work/bundle.tar" && fail "exit status 0"
  assert_eq "$(cat "$log")" '' "docker calls"
  [[ ! -e "$app/.env" ]] || fail "wrote .env"
}

test_the_bundle_carries_the_app_secrets_but_not_the_deploys_own() {
  bundle_step '{"SESSION_SECRET": "sess", "POSTGRES_PASSWORD": "pw"}' || fail "bundle step: $(cat "$work/out")"
  deploy "$work/caller/bundle.tar" || fail "deploy: $(cat "$work/out")"
  assert_eq "$(cat "$app/compose.yaml")" 'services: {}' "compose.yaml"
  assert_eq "$(cat "$app/.env")" "IMAGE_TAG='abc123'
POSTGRES_PASSWORD='pw'
SESSION_SECRET='sess'" ".env"
  assert_eq "$(head -2 "$log")" "login ghcr.io --username octocat --password-stdin
password=ghp_token" "docker login"
}

test_a_secret_env_cannot_carry_fails_the_bundle_without_printing_it() {
  bundle_step '{"OK": "fine", "QUOTED": "it'"'"'s-hunter2"}' && fail "exit status 0"
  grep -q QUOTED "$work/out" || fail "doesn't name the secret: $(cat "$work/out")"
  grep -q hunter2 "$work/out" && fail "printed the value"
  bundle_step '{"TRAILING": "hunter2\\"}' && fail "trailing backslash: exit status 0"
  grep -q TRAILING "$work/out" || fail "doesn't name the secret: $(cat "$work/out")"
}

test_a_missing_deploy_secret_fails_the_bundle_and_says_which() {
  bundle_step '{"DEPLOY_SSH_KEY": ""}' && fail "exit status 0"
  grep -q 'Missing secrets: DEPLOY_SSH_KEY\.' "$work/out" || fail "doesn't name it: $(cat "$work/out")"
}

test_a_secret_that_would_steer_compose_itself_fails_the_bundle() {
  bundle_step '{"COMPOSE_PROJECT_NAME": "other"}' && fail "exit status 0"
  grep -q COMPOSE_PROJECT_NAME "$work/out" || fail "doesn't name the secret: $(cat "$work/out")"
}

# The real docker compose, not the fake: the .env's quoting is only right if
# compose reads every value back exactly as GitHub held it.
test_docker_compose_reads_every_secret_back_literally() {
  if ! command -v docker > /dev/null; then
    printf '  SKIP: no docker\n'
    return
  fi
  local secrets
  secrets=$(jq -n '{
    DOLLAR: "a$b ${c} $$d",
    DOUBLE: "say \"hi\"",
    HASH: "x #not a comment",
    BACKSLASH: "a\\nb\\c",
    SPACES: "  padded  ",
    PEM: "-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBg\n-----END PRIVATE KEY-----"
  }')
  bundle_step "$secrets" || fail "bundle step: $(cat "$work/out")"
  cat > "$work/caller/bundle/compose.yaml" <<'EOF'
services:
  app:
    image: example:${IMAGE_TAG}
    environment:
      DOLLAR: ${DOLLAR}
      DOUBLE: ${DOUBLE}
      HASH: ${HASH}
      BACKSLASH: ${BACKSLASH}
      SPACES: ${SPACES}
      PEM: ${PEM}
EOF
  local got
  got=$(docker compose --project-directory "$work/caller/bundle" --file "$work/caller/bundle/compose.yaml" \
    --env-file "$work/caller/bundle/.env" config --format json 2>&1) ||
    { fail "compose config: $got"; return; }
  assert_eq "$(jq -r '.services.app.image' <<<"$got")" 'example:abc123' "image"
  # compose config re-escapes $ as $$ in its output, so undo that before comparing.
  assert_eq "$(jq -S '.services.app.environment | map_values(gsub("\\$\\$"; "$"))' <<<"$got")" \
    "$(jq -S . <<<"$secrets")" "environment"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run "$t"
done

if ((failures)); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
printf 'all passed\n'
