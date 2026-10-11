#!/usr/bin/env bash
# Tests for the image-major-watch workflow's Watch step. `curl` is a fake
# Docker Hub that knows the tags in $work/hub, and `gh` is a fake issue
# tracker that keeps "<state> <title>" lines in $work/issues.
#
# Run: test/image-major-watch.test.sh
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
failures=0

setup() {
  work=$(mktemp -d)
  mkdir -p "$work/bin" "$work/caller"
  : > "$work/hub"
  : > "$work/issues"
  : > "$work/created"
  # Answers `curl ... <url>` with a status code: 200 if the URL's repo:tag is
  # in $HUB, 503 if the repo is $HUB_DOWN, else 404.
  cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}
path=${url#https://hub.docker.com/v2/repositories/}
ref="${path%%/tags/*}:${path##*/tags/}"
if [[ -n "${HUB_DOWN:-}" && "$ref" == "$HUB_DOWN":* ]]; then
  printf 503
elif grep -qxF -- "$ref" "$HUB"; then
  printf 200
else
  printf 404
fi
EOF
  # `issue list` prints the titles it holds as JSON, whatever the search,
  # closed ones only with --state all, and fails if the search names
  # $GH_FAIL_ON; `issue create` adds an open one and logs it, with its label
  # and body.
  cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    [[ -n "${GH_FAIL_ON:-}" && "$*" == *"$GH_FAIL_ON"* ]] && exit 1
    states=open
    [[ "$*" == *"--state all"* ]] && states="open closed"
    jq -R --arg states "$states" 'capture("^(?<state>\\S+) (?<title>.*)$")
      | select(.state as $s | $states | split(" ") | index($s)) | {title}' "$ISSUES" | jq -s .
    ;;
  "issue create")
    shift 2
    while (($#)); do
      case "$1" in
        --title) title=$2 ;;
        --label) label=$2 ;;
        --body) body=$2 ;;
      esac
      shift 2
    done
    printf 'open %s\n' "$title" >> "$ISSUES"
    printf '%s [%s]\n%s\n' "$title" "$label" "$body" >> "$CREATED"
    ;;
  "label create") ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$work/bin/curl" "$work/bin/gh"
}

teardown() { rm -rf "$work"; }

# Runs the workflow's Watch step, as Actions would, in a fake caller checkout.
# $1 is the compose-files input, $2 the ignore input.
watch() {
  local step
  step=$(python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in wf["jobs"]["watch"]["steps"] if s.get("name") == "Watch"))
' "$repo/.github/workflows/image-major-watch.yml")
  (cd "$work/caller" &&
    PATH="$work/bin:$PATH" HUB="$work/hub" ISSUES="$work/issues" CREATED="$work/created" \
      COMPOSE_FILES="$1" IGNORE="${2:-}" \
      bash --noprofile --norc -eo pipefail -c "$step") > "$work/out" 2>&1
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

test_a_pinned_image_with_a_newer_major_gets_one_issue() {
  printf 'services:\n  db:\n    image: postgres:17\n' > "$work/caller/compose.yaml"
  printf 'library/postgres:17\nlibrary/postgres:18\n' > "$work/hub"
  watch compose.yaml || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(head -1 "$work/created")" "Postgres 18 is available: plan the upgrade [needs-triage]" "issue"
  assert_eq "$(wc -l < "$work/issues")" 1 "issue count"
}

test_a_second_run_with_the_issue_open_or_closed_raises_nothing() {
  printf 'services:\n  db:\n    image: postgres:17\n' > "$work/caller/compose.yaml"
  printf 'library/postgres:17\nlibrary/postgres:18\n' > "$work/hub"
  for state in open closed; do
    printf '%s Postgres 18 is available: plan the upgrade\n' "$state" > "$work/issues"
    : > "$work/created"
    watch compose.yaml || fail "$state: exit status $? ($(cat "$work/out"))"
    assert_eq "$(cat "$work/created")" "" "$state: issues created"
  done
}

test_images_it_cannot_check_are_skipped_with_a_warning_and_the_run_passes() {
  cat > "$work/caller/compose.yaml" <<'YAML'
services:
  app:
    image: ghcr.io/octocat/app:${IMAGE_TAG}
  cache:
    image: "redis:7-alpine"
  proxy:
    image: ghcr.io/octocat/proxy:3
  web:
    image: nginx
  db:
    image: postgres:17   # pinned: majors need a dump and restore
YAML
  printf 'library/postgres:18\nlibrary/redis:8-alpine\nlibrary/nginx:2\n' > "$work/hub"
  watch compose.yaml || fail "exit status $? ($(cat "$work/out"))"
  # shellcheck disable=SC2016 # a literal ${IMAGE_TAG}, as compose files hold it
  for image in 'ghcr.io/octocat/app:${IMAGE_TAG}' redis:7-alpine ghcr.io/octocat/proxy:3 nginx; do
    grep -qF "::warning::Skipping $image:" "$work/out" || fail "no warning for $image: $(cat "$work/out")"
  done
  assert_eq "$(cut -d' ' -f2- "$work/issues")" "Postgres 18 is available: plan the upgrade" "issues"
}

test_an_image_pinned_by_digest_is_checked_by_its_tag() {
  printf 'services:\n  db:\n    image: postgres:17@sha256:0123abcd\n' > "$work/caller/compose.yaml"
  printf 'library/postgres:18\n' > "$work/hub"
  watch compose.yaml || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(cut -d' ' -f2- "$work/issues")" "Postgres 18 is available: plan the upgrade" "issues"
}

test_ignored_images_are_not_checked() {
  printf 'services:\n  db:\n    image: postgres:17\n  q:\n    image: docker.io/rabbitmq:3\n' > "$work/caller/compose.yaml"
  printf 'library/postgres:18\nlibrary/rabbitmq:4\n' > "$work/hub"
  watch compose.yaml $'postgres\nrabbitmq' || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(cat "$work/issues")" "" "issues"
}

test_an_image_several_majors_behind_hears_about_the_newest() {
  printf 'services:\n  db:\n    image: postgres:15\n' > "$work/caller/compose.yaml"
  printf 'library/postgres:16\nlibrary/postgres:17\nlibrary/postgres:18\n' > "$work/hub"
  watch compose.yaml || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(cut -d' ' -f2- "$work/issues")" "Postgres 18 is available: plan the upgrade" "issues"
}

test_images_across_files_get_one_issue_per_major_and_namespaced_ones_keep_their_name() {
  printf 'services:\n  db:\n    image: postgres:16\n' > "$work/caller/compose.yaml"
  mkdir "$work/caller/deploy"
  printf "services:\n  db:\n    image: 'postgres:17'\n  graf:\n    image: grafana/grafana:11\n" > "$work/caller/deploy/compose.prod.yaml"
  printf 'library/postgres:17\nlibrary/postgres:18\ngrafana/grafana:12\n' > "$work/hub"
  watch $'compose.yaml\ndeploy/compose.prod.yaml' || fail "exit status $? ($(cat "$work/out"))"
  assert_eq "$(cut -d' ' -f2- "$work/issues" | LC_ALL=C sort)" "Postgres 18 is available: plan the upgrade
grafana/grafana 12 is available: plan the upgrade" "issues"
}

test_a_docker_hub_error_fails_the_run_after_checking_the_rest() {
  printf 'services:\n  a:\n    image: mariadb:10\n  b:\n    image: postgres:17\n' > "$work/caller/compose.yaml"
  printf 'library/mariadb:11\nlibrary/postgres:18\n' > "$work/hub"
  HUB_DOWN=library/mariadb watch compose.yaml && fail "exit status 0"
  grep -qF '::error::Docker Hub answered 503 for library/mariadb:11' "$work/out" || fail "no error: $(cat "$work/out")"
  assert_eq "$(cut -d' ' -f2- "$work/issues")" "Postgres 18 is available: plan the upgrade" "issues"
}

test_a_github_error_fails_the_run_after_checking_the_rest() {
  printf 'services:\n  a:\n    image: mariadb:10\n  b:\n    image: postgres:17\n' > "$work/caller/compose.yaml"
  printf 'library/mariadb:11\nlibrary/postgres:18\n' > "$work/hub"
  GH_FAIL_ON=Mariadb watch compose.yaml && fail "exit status 0"
  grep -qF '::error::Could not search issues for "Mariadb 11' "$work/out" || fail "no error: $(cat "$work/out")"
  assert_eq "$(cut -d' ' -f2- "$work/issues")" "Postgres 18 is available: plan the upgrade" "issues"
}

test_a_missing_compose_file_fails_the_run() {
  watch compose.yaml && fail "exit status 0"
  grep -qF '::error::No compose file at compose.yaml' "$work/out" || fail "no error: $(cat "$work/out")"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run "$t"
done

if ((failures)); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
printf 'all passed\n'
