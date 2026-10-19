#!/usr/bin/env bash
#
# auth-prompt.sh - offline test of install.sh's one-time web-login offer.
#
#   bash tests/auth-prompt.sh
#
# Runs install.sh against a stubbed docker binary with no Docker Hub login and
# no token file, with and without a terminal. `script` (util-linux) supplies the
# terminal and feeds the answers; `setsid` takes the terminal away. The stub
# fails every pull, so a run that reaches "could not pull" got past
# authentication. Needs bash, script and setsid; never touches the real Docker.
set -euo pipefail

INSTALL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
state="$FAKE_DOCKER_STATE"
echo "$1" >> "$state/calls"
case "$1" in
  --version) echo "Docker version 29.0.0, build stub" ;;
  compose) echo "2.0.0" ;;
  info)
    [[ -f "$state/user" ]] || exit 0
    if [[ "$*" == *--format* ]]; then cat "$state/user"; else echo " Username: $(cat "$state/user")"; fi
    ;;
  login)
    if [[ ! -t 0 ]]; then echo "error: cannot perform an interactive login from a non-TTY device" >&2; exit 1; fi
    echo "Your one-time device confirmation code is: ABCD-EFGH"
    if [[ "${FAKE_LOGIN:-fail}" == ok ]]; then echo pfclient > "$state/user"; echo "Login Succeeded"; exit 0; fi
    echo "Error: device code expired" >&2; exit 1
    ;;
  pull) echo "stub: pull refused" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/docker"

fails=0
# run <name> <answers|-> [VAR=value ...]; '-' means no terminal at all.
run() {
  local name="$1" answers="$2"; shift 2
  rm -rf "$WORK/state"; mkdir -p "$WORK/state"; : > "$WORK/state/calls"
  local -a env=(env "PATH=$WORK/bin:$PATH" "HOME=$WORK/home" "FAKE_DOCKER_STATE=$WORK/state" "$@")
  RC=0
  if [[ "$answers" == - ]]; then
    OUT="$(setsid -w "${env[@]}" bash "$INSTALL_SH" </dev/null 2>&1)" || RC=$?
  else
    OUT="$(printf '%b' "$answers" | "${env[@]}" script -qec "bash '$INSTALL_SH'" /dev/null 2>&1)" || RC=$?
  fi
  CASE="$name"
}
has()    { grep -qF -- "$1" <<<"$OUT" || { echo "FAIL [$CASE]: expected '$1'"; fails=$((fails + 1)); }; }
hasnt()  { ! grep -qF -- "$1" <<<"$OUT" || { echo "FAIL [$CASE]: unexpected '$1'"; fails=$((fails + 1)); }; }
called() { grep -qx "$1" "$WORK/state/calls" || { echo "FAIL [$CASE]: docker $1 not called"; fails=$((fails + 1)); }; }
not_called() { ! grep -qx "$1" "$WORK/state/calls" || { echo "FAIL [$CASE]: docker $1 called"; fails=$((fails + 1)); }; }
failed() { [[ "$RC" -ne 0 ]] || { echo "FAIL [$CASE]: expected a non-zero exit"; fails=$((fails + 1)); }; }

PROMPT="Proceed with one-time web login? (requires live support with Pacefactory) [Y/n]"
HEADER="required and none were found."

run "no terminal" -
failed; has "$HEADER"; has "Remediation:"; hasnt "$PROMPT"; not_called login

run "declined" 'n\n'
failed; has "$HEADER"; has "$PROMPT"; has "Remediation:"; hasnt "Web login remediation:"; not_called login

run "Enter accepts, login ok" '\n' FAKE_LOGIN=ok
failed; has "$PROMPT"; has "ABCD-EFGH"; has "one-time web login succeeded as 'pfclient'"
hasnt "Remediation:"; called login; called pull; has "could not pull"

run "accepted, login fails" 'y\n' FAKE_LOGIN=fail
failed; has "$PROMPT"; has "Web login remediation:"; has "Remediation:"; called login; not_called pull

run "unclear answer re-asks" 'maybe\nN\n'
failed; has "Please answer y or n."; has "Remediation:"; not_called login

run "PF_DOCKER_AUTH=oat never offers" 'y\n' PF_DOCKER_AUTH=oat
failed; has "$HEADER"; hasnt "$PROMPT"; not_called login

run "PF_DOCKER_AUTH=existing offers" 'y\n' PF_DOCKER_AUTH=existing FAKE_LOGIN=ok
has "$PROMPT"; called login; called pull

if [[ "$fails" -ne 0 ]]; then echo "$fails failure(s)"; exit 1; fi
echo "auth prompt tests ok"
