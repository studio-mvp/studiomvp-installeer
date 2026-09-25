#!/bin/bash
# Studio MVP op een nieuwe Mac, met één regel in Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/mennovanpaassen/studiomvp-installeer/main/installeer.sh | bash
#
# Wat het doet: Homebrew installeren (als dat er nog niet op staat), Node en het GitHub-programma (gh), inloggen bij
# GitHub, Studio MVP ophalen naar ~/Projecten/studiomvp-starter en daar ./install.sh starten. Dat doet de rest: de
# instellingen van het bureau (met het Studio MVP-wachtwoord), Sanity, je naam, Claude Code en de app in het Dock.
# Opnieuw draaien is altijd veilig: wat klaar is, wordt overgeslagen. sudo alleen voor Homebrew (het officiële
# installatieprogramma van brew.sh), en alleen als Homebrew er nog niet op staat.
#
# Dit bestand is openbaar: er staan geen wachtwoorden, tokens of sleutels in. De instellingen van het bureau staan
# versleuteld in de privé-repo mennovanpaassen/studiomvp-starter. Daar staat ook de bron van dit script, met tests.
#
# Proef (verandert niets):   curl -fsSL …/installeer.sh | bash -s -- --proef
# Logboek (zonder geheimen): ~/Library/Logs/studiomvp-installeer.log
#
# Safe under `curl | bash`: everything is inside functions and `main` is called on the very LAST line, so a download
# that breaks off halfway does nothing. Every question and every interactive program reads from the terminal
# (/dev/tty, opened once as fd 3), never from stdin: under `curl | bash` stdin is this script itself. Programs that
# need no answers get </dev/null.
# Test hooks: STUDIOMVP_INSTALLEER_TTY (a file with the answers instead of /dev/tty), STUDIOMVP_INSTALLEER_DRYRUN=1,
# STUDIOMVP_INSTALLEER_REPO_URL (what to clone), STUDIOMVP_BREW_CANDIDATES (where Homebrew may be),
# STUDIOMVP_BREW_INSTALLER_URL; everything else (brew, gh, git, curl, sudo, id, uname) by fakes on PATH.

set -Eeuo pipefail

init() {
  REPO='mennovanpaassen/studiomvp-starter'
  REPO_URL="${STUDIOMVP_INSTALLEER_REPO_URL:-https://github.com/$REPO.git}"
  GH_ACCOUNT='mennovanpaassen'
  STARTER="$HOME/Projecten/studiomvp-starter"
  # shellcheck disable=SC2088 # (shown to the person, not expanded)
  STARTER_SHOWN='~/Projecten/studiomvp-starter'
  LOG="$HOME/Library/Logs/studiomvp-installeer.log"
  # shellcheck disable=SC2088
  LOG_SHOWN='~/Library/Logs/studiomvp-installeer.log'
  BREW_INSTALLER_URL="${STUDIOMVP_BREW_INSTALLER_URL:-https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh}"
  DRY=0
  HANDLED=0
  STEP='het begin'
  BREW=''
  NODE_V=''
  KEEPALIVE_PID=''
  ERR_LINE=''
  ERR_CMD=''
  FINISHED=0
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' C=$'\033[36m' D=$'\033[2m' N=$'\033[0m'
  else
    B='' G='' Y='' R='' C='' D='' N=''
  fi
}

# ── Output (also in the log; nothing secret ever passes through here) ────────────────────────────────────────────
log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }
ok() {
  printf '  %s✓%s %s\n' "$G" "$N" "$1"
  log "✓ $1"
}
bad() {
  printf '  %s✗%s %s\n' "$R" "$N" "$1"
  log "✗ $1"
}
note() {
  printf '  %s!%s %s\n' "$Y" "$N" "$1"
  log "! $1"
}
tip() {
  printf '    %s→%s %s\n' "$Y" "$N" "$1"
  log "→ $1"
}
say() {
  printf '  %s\n' "$1"
  log "  $1"
}
plan() {
  printf '  %s○ zou nu:%s %s\n' "$D" "$N" "$1"
  log "○ zou nu: $1"
}
step() {
  STEP="$1"
  printf '\n%s%s%s\n' "$B" "$1" "$N"
  log "== $1"
}

log_hint() {
  if [ "$LOG" = /dev/null ]; then return 0; fi
  printf '    %s→%s Kom je er niet uit? Stuur dit bestand naar Karim: %s\n' "$Y" "$N" "$LOG_SHOWN"
  printf '      (in de Finder: menu Ga → Ga naar map…, typ ~/Library/Logs en druk op Enter)\n'
}

# die <message> [what to do …]: a problem we know, in plain Dutch, then stop.
die() {
  local msg="$1" h
  shift
  printf '\n  %s✗%s %s\n' "$R" "$N" "$msg"
  log "✗ $msg"
  for h in "$@"; do
    printf '    %s→%s %s\n' "$Y" "$N" "$h"
    log "→ $h"
  done
  log_hint
  HANDLED=1
  exit 1
}

on_err() {
  ERR_LINE="$1"
  ERR_CMD="$2"
}

# Every way out that is not the normal end (FINISHED) or a known problem (HANDLED) is shown, and is never exit 0:
# bash 3.2 (the bash of macOS) even exits with 0 on an unset variable under `set -u`.
on_exit() {
  local code=$?
  stop_keepalive
  if [ "${FINISHED:-0}" = 1 ] || [ "${HANDLED:-0}" = 1 ]; then return 0; fi
  if [ "$code" -eq 130 ]; then
    printf '\n  Gestopt. Er is niets kapotgegaan: plak de installatieregel gerust nog eens om verder te gaan.\n'
    log "gestopt (Ctrl+C) bij: ${STEP:-?}"
    exit 130
  fi
  printf '\n  %s✗%s Er ging onverwacht iets mis bij: %s\n' "${R:-}" "${N:-}" "${STEP:-?}"
  log "✗ onverwacht: exit $code bij '${STEP:-?}' (regel ${ERR_LINE:-?}: ${ERR_CMD:-?})"
  printf '    %s→%s Plak de installatieregel nog eens in Terminal: wat al klaar is, wordt overgeslagen.\n' "${Y:-}" "${N:-}"
  log_hint
  if [ "$code" -eq 0 ]; then exit 1; fi
  exit "$code"
}

# ── Questions: always from the terminal (fd 3), never from stdin ────────────────────────────────────────────────
open_tty() {
  local src="${STUDIOMVP_INSTALLEER_TTY:-/dev/tty}"
  if (: <"$src") 2>/dev/null; then
    exec 3<"$src"
  elif [ "$DRY" = 1 ]; then
    exec 3</dev/null
  else
    die "Ik kan hier geen vragen stellen: dit draait niet in een Terminal-venster." \
      "Open Terminal (Cmd+Spatie, typ Terminal en druk op Enter), plak de installatieregel daar en druk op Enter."
  fi
}

# ask <variable> <question>: one line from the terminal ('' at the end of the input). (Its own variable is called
# _ask_reply: bash scopes dynamically, so a local with the caller's name would swallow the answer.)
ask() {
  local _ask_reply=''
  printf '  %s?%s %s ' "$C" "$N" "$2"
  if ! IFS= read -r _ask_reply <&3; then _ask_reply=''; fi
  _ask_reply="${_ask_reply%$'\r'}"
  # (a file with answers is not echoed by a terminal)
  if [ -n "${STUDIOMVP_INSTALLEER_TTY:-}" ]; then printf '%s\n' "$_ask_reply"; fi
  printf -v "$1" '%s' "$_ask_reply"
}

# yes_no <question>: Enter = yes.
yes_no() {
  local answer
  ask answer "$1 (J/n)"
  case "$answer" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# ── Checks ───────────────────────────────────────────────────────────────────────────────────────────────────
check_mac() {
  if [ "$(uname -s 2>/dev/null || true)" != Darwin ]; then
    printf '\n  %s✗%s Deze installatie is alleen voor een Mac.\n' "$R" "$N"
    printf '    %s→%s Op een andere computer: vraag Karim hoe het daar moet.\n' "$Y" "$N"
    HANDLED=1
    exit 1
  fi
  if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then
    printf '\n  %s✗%s Start dit niet met sudo (en niet als root).\n' "$R" "$N"
    printf '    %s→%s Plak de installatieregel precies zoals hij is, zonder sudo ervoor.\n' "$Y" "$N"
    HANDLED=1
    exit 1
  fi
}

start_log() {
  if [ "$DRY" = 1 ]; then
    LOG=/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  if ! (: >>"$LOG") 2>/dev/null; then LOG=/dev/null; fi
  printf '\n===== %s · Studio MVP installeren · macOS %s · %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(sw_vers -productVersion 2>/dev/null || echo '?')" "$(uname -m 2>/dev/null || echo '?')" >>"$LOG" 2>/dev/null || true
}

is_admin() {
  local groups
  groups=" $(id -Gn 2>/dev/null || true) "
  case "$groups" in *" admin "*) return 0 ;; *) return 1 ;; esac
}

# git's answer when GitHub refuses this account (as opposed to no internet).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_offline() {
  case "$(lower "$1")" in
    *"could not resolve host"* | *"failed to connect"* | *"timed out"* | *"network is unreachable"* | *"connection refused"* | *"connection reset"*) return 0 ;;
  esac
  return 1
}
is_refused() {
  if is_offline "$1"; then return 1; fi
  case "$(lower "$1")" in
    *"not found"* | *"does not exist"* | *"authentication failed"* | *"could not read username"* | *"permission denied"* | *"403"* | *"terminal prompts disabled"* | *"access denied"*) return 0 ;;
  esac
  return 1
}
last_line() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -n 1; }

# ── Intro ────────────────────────────────────────────────────────────────────────────────────────────────────
intro() {
  printf '\n%sStudio MVP installeren op deze Mac%s' "$B" "$N"
  if [ "$DRY" = 1 ]; then printf '  %s(proef: er verandert niets)%s' "$Y" "$N"; fi
  printf '\n\n'
  say "Ik zet alles klaar om websites te maken met Studio MVP. Dat duurt 15 tot 30 minuten."
  say "Onderweg vraag ik je om:"
  say "  • het wachtwoord van je Mac (één keer, alleen als Homebrew er nog niet op staat);"
  say "  • in te loggen bij GitHub in je browser, als $GH_ACCOUNT;"
  say "  • het Studio MVP-wachtwoord dat je van Karim of Menno kreeg;"
  say "  • in te loggen bij Sanity in je browser, en je naam en e-mailadres."
  say "Gaat er iets mis? Plak de regel dan gewoon nog eens: wat al klaar is, wordt overgeslagen."
  printf '\n'
  local answer
  ask answer "Druk op Enter om te beginnen (of sluit dit venster om te stoppen)"
}

# ── 1. Homebrew ──────────────────────────────────────────────────────────────────────────────────────────────
find_brew() {
  local b
  b="$(command -v brew 2>/dev/null || true)"
  if [ -n "$b" ]; then
    BREW="$b"
    return 0
  fi
  for b in ${STUDIOMVP_BREW_CANDIDATES-/opt/homebrew/bin/brew /usr/local/bin/brew}; do
    if [ -x "$b" ]; then
      BREW="$b"
      return 1 # (found, but not in PATH yet)
    fi
  done
  BREW=''
  return 1
}

# The file a new Terminal window reads for this account's shell: zsh (the standard since macOS 10.15) ~/.zprofile;
# bash (an account that came over from an older Mac) the first of ~/.bash_profile, ~/.bash_login and ~/.profile that
# exists, because bash reads only that one (a new ~/.bash_profile would hide an existing ~/.profile), else ~/.bash_profile.
shell_profile() {
  local f
  case "${SHELL:-/bin/zsh}" in
    */bash)
      for f in .bash_profile .bash_login .profile; do
        if [ -f "$HOME/$f" ]; then
          printf '%s\n' "$HOME/$f"
          return 0
        fi
      done
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    *) printf '%s\n' "$HOME/.zprofile" ;;
  esac
}

# Homebrew in PATH for the rest of this script, and for every new Terminal window (the shell's profile, once).
load_brew() {
  local profile shown
  set +u
  eval "$("$BREW" shellenv)"
  set -u
  hash -r
  profile="$(shell_profile)"
  # shellcheck disable=SC2088 # (shown to the person, not expanded)
  shown="~${profile#"$HOME"}"
  if grep -qs 'brew shellenv' "$profile"; then return 0; fi
  if [ "$DRY" = 1 ]; then
    plan "Homebrew bekend maken in nieuwe Terminal-vensters (een regel in $shown)"
    return 0
  fi
  printf '\n# Homebrew (toegevoegd door de installatie van Studio MVP)\neval "$(%s shellenv)"\n' "$BREW" >>"$profile"
  ok "Homebrew werkt nu ook in nieuwe Terminal-vensters ($shown)"
}

start_keepalive() {
  # (the Homebrew installer uses `sudo -n`: keep the password of a minute ago valid while it works)
  # (sleeps of one second: when it is stopped, nothing lingers)
  (while kill -0 "$$" 2>/dev/null; do
    sudo -n -v 2>/dev/null || true
    i=0
    while [ "$i" -lt 30 ] && kill -0 "$$" 2>/dev/null; do
      sleep 1
      i=$((i + 1))
    done
  done) </dev/null >/dev/null 2>&1 &
  KEEPALIVE_PID=$!
  disown "$KEEPALIVE_PID" 2>/dev/null || true # (no "Terminated" line when it is stopped)
}
# (and the Mac password of a minute ago is forgotten at once: sudo was only for Homebrew. Homebrew's own installer
# would do that, `sudo -k`, but only when sudo was not active before it started, and here it was.)
stop_keepalive() {
  if [ -n "$KEEPALIVE_PID" ]; then
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    KEEPALIVE_PID=''
    sleep 0.3 2>/dev/null || true # (a `sudo -n -v` of the loop that was just running must not renew it after -k)
    sudo -k </dev/null >/dev/null 2>&1 || true
  fi
}

install_homebrew() {
  if ! is_admin; then
    die "Je Mac-account ($(id -un 2>/dev/null || echo '?')) is geen beheerder, en alleen een beheerder kan Homebrew installeren." \
      "Vraag degene die deze Mac beheert om van je account een beheerder te maken: Systeeminstellingen → Gebruikers en groepen → jouw account → zet \"Sta deze gebruiker toe deze computer te beheren\" aan." \
      "Log daarna opnieuw in op de Mac en plak de installatieregel nog eens."
  fi
  if [ "$DRY" = 1 ]; then
    plan "Homebrew installeren met het officiële installatieprogramma van brew.sh (vraagt één keer het wachtwoord van je Mac)"
    return 0
  fi
  say "Homebrew is een hulpprogramma waarmee ik de rest installeer. Daarvoor is één keer het wachtwoord van je Mac nodig."
  say "Typ het wachtwoord van je Mac en druk op Enter. Je ziet niets terwijl je typt; dat hoort zo."
  if ! sudo -v <&3; then
    die "Het wachtwoord van je Mac werd niet geaccepteerd." "Plak de installatieregel nog eens en typ het wachtwoord waarmee je op deze Mac inlogt."
  fi
  start_keepalive
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/homebrew-install.XXXXXX")"
  if ! curl -fsSL "$BREW_INSTALLER_URL" -o "$tmp" </dev/null 2>>"$LOG"; then
    rm -f "$tmp"
    die "Het installatieprogramma van Homebrew kon niet worden opgehaald (geen internet?)." "Controleer de internetverbinding en plak de installatieregel nog eens."
  fi
  say "Homebrew wordt geïnstalleerd: 5 tot 15 minuten. Er komt veel tekst voorbij; dat hoort zo."
  say "Verschijnt er een venster over opdrachtregelprogramma's (Command Line Tools)? Klik dan op Installeer."
  if ! NONINTERACTIVE=1 /bin/bash "$tmp" </dev/null 2>&1 | tee -a "$LOG"; then
    rm -f "$tmp"
    stop_keepalive
    die "Homebrew installeren lukte niet (zie de regels hierboven)." "Plak de installatieregel nog eens: wat al klaar is, wordt overgeslagen."
  fi
  rm -f "$tmp"
  stop_keepalive
  if ! find_brew && [ -z "$BREW" ]; then
    die "Homebrew is geïnstalleerd, maar ik kan het programma brew niet vinden." "Sluit Terminal, open het opnieuw en plak de installatieregel nog eens."
  fi
  ok "Homebrew geïnstalleerd"
  say "(De \"Next steps\" die Homebrew hierboven noemt, regel ik zo meteen voor je.)"
}

ensure_homebrew() {
  step "Voorbereiden 1/4 · Homebrew"
  if find_brew; then
    ok "Homebrew"
    return 0
  fi
  if [ -z "$BREW" ]; then
    install_homebrew
    if [ -z "$BREW" ]; then return 0; fi # (proef: Homebrew is er nog niet)
  else
    ok "Homebrew (staat erop, nog niet in PATH)"
  fi
  load_brew
}

# ── 2. Node, git and gh ──────────────────────────────────────────────────────────────────────────────────────
node_ok() {
  local v major rest minor
  v="$(node -p 'process.versions.node' 2>/dev/null </dev/null || true)"
  NODE_V="$v"
  if [ -z "$v" ]; then return 1; fi
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  case "$major$minor" in *[!0-9]*) return 1 ;; esac
  [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 12 ]; }
}

brew_run() {
  if ! "$BREW" "$@" </dev/null 2>&1 | tee -a "$LOG"; then
    die "Homebrew kon dit niet: brew $*" "Plak de installatieregel nog eens; blijft het misgaan, stuur dan het logbestand."
  fi
  hash -r
}

git_ok() {
  local g
  g="$(command -v git 2>/dev/null || true)"
  if [ -z "$g" ]; then return 1; fi
  # (/usr/bin/git without the Command Line Tools opens an Apple window instead of answering: ask xcode-select first)
  if [ "$g" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  git --version >/dev/null 2>&1 </dev/null
}

ensure_git() {
  if git_ok; then
    ok "$(git --version </dev/null)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    plan "de opdrachtregelprogramma's van Apple installeren (daar zit git in)"
    return 0
  fi
  say "git ontbreekt nog; dat zit in de opdrachtregelprogramma's (Command Line Tools) van Apple."
  say "Er verschijnt zo een venster: klik op Installeer (en daarna op Akkoord). Dat duurt 5 tot 15 minuten."
  xcode-select --install >/dev/null 2>&1 </dev/null || true
  local i answer
  for i in 1 2 3; do
    ask answer "Druk op Enter als het venster zegt dat de software is geïnstalleerd"
    if git_ok; then
      ok "$(git --version </dev/null)"
      return 0
    fi
    if [ "$i" -lt 3 ]; then tip "Nog niet klaar. Wacht tot het venster klaar is en druk dan op Enter."; fi
  done
  die "git werkt nog niet." "Plak de installatieregel nog eens zodra de opdrachtregelprogramma's zijn geïnstalleerd."
}

# An old Node that Homebrew did not install, in Homebrew's own bin folder: on an Intel Mac the installer from nodejs.org
# puts it in /usr/local/bin, exactly where Homebrew links its own, so `brew install node` stops there every time (and
# pasting the line again would never help). Homebrew's own links are always symlinks; that one is a real file.
foreign_node() {
  local n
  if [ -z "$BREW" ]; then return 1; fi
  n="$(dirname "$BREW")/node"
  [ -e "$n" ] && [ ! -L "$n" ]
}

ensure_tools() {
  step "Voorbereiden 2/4 · Node, git en het GitHub-programma"
  local missing='' upgrade=0
  if command -v node >/dev/null 2>&1; then
    if node_ok; then
      ok "Node $NODE_V"
    else
      note "Node ${NODE_V:-?} is te oud (22.12 of nieuwer nodig)"
      upgrade=1
    fi
  else
    missing="$missing node"
  fi
  if { [ "$upgrade" = 1 ] || [ -n "$missing" ]; } && foreign_node; then
    local bindir prefix
    bindir="$(dirname "$BREW")"
    prefix="$(dirname "$bindir")"
    log "node buiten Homebrew: $(ls -l "$bindir/node" 2>/dev/null || echo "$bindir/node")"
    log "voor Karim: sudo rm $bindir/node $bindir/npm $bindir/npx && sudo rm -rf $prefix/lib/node_modules/npm $prefix/include/node, dan de installatieregel opnieuw"
    die "Op deze Mac staat een oude Node${NODE_V:+ ($NODE_V)} die niet via Homebrew is geïnstalleerd (waarschijnlijk van nodejs.org), in $bindir. Die zit Homebrew in de weg, dus de installatieregel nog eens plakken helpt nu niet." \
      "Vraag Karim om die oude Node weg te halen (stuur hem het logboek hieronder: daar staat hoe); plak daarna de installatieregel nog eens."
  fi
  if command -v gh >/dev/null 2>&1; then ok "GitHub-programma (gh)"; else missing="$missing gh"; fi
  if [ -n "$missing" ]; then
    if [ "$DRY" = 1 ] || [ -z "$BREW" ]; then
      plan "installeren met Homebrew: brew install$missing"
    else
      say "Installeren met Homebrew:$missing (een paar minuten)"
      # shellcheck disable=SC2086 # (a list of formula names)
      brew_run install $missing
    fi
  fi
  if [ "$upgrade" = 1 ]; then
    if [ "$DRY" = 1 ] || [ -z "$BREW" ]; then
      plan "Node bijwerken met Homebrew (brew upgrade node)"
    elif "$BREW" list --versions node >/dev/null 2>&1 </dev/null; then
      brew_run upgrade node
    else
      brew_run install node
    fi
  fi
  if [ "$DRY" != 1 ] && [ -n "$BREW" ] && { [ -n "$missing" ] || [ "$upgrade" = 1 ]; }; then
    # (the Node of Homebrew first, also when an older one is elsewhere in PATH)
    PATH="$(dirname "$BREW"):$PATH"
    hash -r
    if ! node_ok; then die "Node ${NODE_V:-} is nog te oud of ontbreekt (22.12 of nieuwer nodig)." "Plak de installatieregel nog eens; blijft het misgaan, stuur dan het logbestand."; fi
    ok "Node $NODE_V"
    if ! command -v gh >/dev/null 2>&1; then die "Het GitHub-programma (gh) ontbreekt nog." "Plak de installatieregel nog eens."; fi
    ok "GitHub-programma (gh)"
  fi
  if [ -n "$BREW" ] || [ "$DRY" != 1 ]; then ensure_git; fi
}

# ── 3. GitHub ────────────────────────────────────────────────────────────────────────────────────────────────
gh_logged_in() { gh auth status --hostname github.com >/dev/null 2>&1 </dev/null; }
gh_login_name() { gh api user --jq .login 2>/dev/null </dev/null || true; }

# (the order of gh's own questions: first "Authenticate Git …?" (unless gh already does that for git), then the code)
gh_login() {
  say "Log in met het GitHub-account van Studio MVP: nu is dat $GH_ACCOUNT (de inlog krijg je van Karim of Menno)."
  say "Zo gaat het:"
  say "  1. Eerst vraagt het \"Authenticate Git with your GitHub credentials?\": druk op Enter (ja)."
  say "  2. Er verschijnt een code van 8 tekens (zoals A1B2-C3D4). Druk op Enter: je browser opent GitHub."
  say "  3. Log daar in als $GH_ACCOUNT, typ de code over en klik op Authorize."
  say "     (Staat je browser al ingelogd bij GitHub met je eigen account? Log daar dan eerst uit: rechtsboven op je"
  say "     profielfoto → Sign out. Anders krijgt je eigen account de toegang, en dat werkt niet.)"
  log "gh auth login gestart"
  gh auth login --hostname github.com --git-protocol https --web <&3 || true
  gh_logged_in
}

ensure_github() {
  step "Voorbereiden 3/4 · Inloggen bij GitHub"
  if ! command -v gh >/dev/null 2>&1; then
    plan "inloggen bij GitHub in je browser (gh auth login), als $GH_ACCOUNT"
    return 0
  fi
  if gh_logged_in; then
    ok "Ingelogd bij GitHub als $(gh_login_name)"
  elif [ "$DRY" = 1 ]; then
    plan "inloggen bij GitHub in je browser (gh auth login), als $GH_ACCOUNT"
    return 0
  elif gh_login; then
    ok "Ingelogd bij GitHub als $(gh_login_name)"
  else
    die "Je bent nog niet ingelogd bij GitHub." "Plak de installatieregel nog eens en log in als $GH_ACCOUNT."
  fi
  # (git uses the login of gh for github.com: no password questions from git)
  if [ "$DRY" != 1 ]; then gh auth setup-git --hostname github.com >/dev/null 2>&1 </dev/null || true; fi
}

# GitHub said no: explain, and offer to log in again with the right account. → 0 = try again
refused_again() {
  local who
  bad "GitHub geeft dit account geen toegang tot Studio MVP ($REPO)."
  who="$(gh_login_name)"
  if [ -n "$who" ]; then say "Je bent bij GitHub ingelogd als $who; Studio MVP staat onder $GH_ACCOUNT."; fi
  say "Meestal komt dat doordat je browser nog bij GitHub ingelogd was met je eigen account. Doe dit eerst:"
  say "  ga in je browser naar github.com, klik rechtsboven op je profielfoto → Sign out."
  say "Daarna log je hieronder opnieuw in, nu als $GH_ACCOUNT."
  if yes_no "Opnieuw inloggen bij GitHub, nu als $GH_ACCOUNT?"; then
    if gh_login; then
      gh auth setup-git --hostname github.com >/dev/null 2>&1 </dev/null || true
      return 0
    fi
  fi
  return 1
}

# ── 4. Studio MVP itself ─────────────────────────────────────────────────────────────────────────────────────
is_starter_repo() {
  local top
  top="$(git -C "$STARTER" rev-parse --show-toplevel 2>/dev/null </dev/null || true)"
  [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$STARTER" && pwd -P)" ]
}

clone_starter() {
  local out attempt
  if [ "$DRY" = 1 ]; then
    plan "Studio MVP ophalen van GitHub naar $STARTER_SHOWN"
    return 0
  fi
  mkdir -p "$(dirname "$STARTER")"
  for attempt in 1 2; do
    say "Studio MVP ophalen naar ${STARTER_SHOWN}…"
    if out="$(GIT_TERMINAL_PROMPT=0 git clone -q "$REPO_URL" "$STARTER" </dev/null 2>&1)"; then
      ok "Studio MVP opgehaald ($STARTER_SHOWN)"
      return 0
    fi
    log "git clone: $out"
    if is_offline "$out"; then
      die "GitHub is niet bereikbaar (geen internet?)." "Controleer de internetverbinding en plak de installatieregel nog eens."
    elif is_refused "$out"; then
      if [ "$attempt" = 1 ] && refused_again; then continue; fi
      die "Studio MVP is niet opgehaald: GitHub gaf dit account geen toegang." \
        "Log in als $GH_ACCOUNT (of vraag Karim of Menno om toegang voor je eigen account) en plak de installatieregel nog eens."
    else
      die "Studio MVP ophalen lukte niet ($(last_line "$out"))." "Plak de installatieregel nog eens; blijft het misgaan, stuur dan het logbestand."
    fi
  done
}

update_starter() {
  local dirty branch out attempt
  dirty="$(git -C "$STARTER" status --porcelain --untracked-files=no 2>/dev/null </dev/null || true)"
  branch="$(git -C "$STARTER" symbolic-ref --short -q HEAD 2>/dev/null </dev/null || true)"
  ok "Studio MVP staat er al ($STARTER_SHOWN)"
  if [ -n "$dirty" ]; then
    note "Daarin zijn bestanden veranderd. Die laat ik met rust, dus ik haal nu geen nieuwe versie op."
    tip "Is dat niet de bedoeling? Vraag Karim om te kijken. Ik ga verder met de versie die er staat."
    log "veranderde bestanden: $(printf '%s' "$dirty" | tr '\n' ' ')"
    return 0
  fi
  if [ "$branch" != main ]; then
    note "Die staat niet op de gewone versie (main) maar op ${branch:-een losse versie}; ik haal nu geen nieuwe versie op."
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    plan "de nieuwste versie van Studio MVP ophalen (git pull --ff-only)"
    return 0
  fi
  for attempt in 1 2; do
    if out="$(GIT_TERMINAL_PROMPT=0 git -C "$STARTER" pull --ff-only -q </dev/null 2>&1)"; then
      ok "De nieuwste versie van Studio MVP staat erop"
      return 0
    fi
    log "git pull: $out"
    if is_refused "$out" && [ "$attempt" = 1 ] && refused_again; then continue; fi
    if is_offline "$out"; then
      note "Geen internet: ik ga verder met de versie die er staat."
    else
      note "Een nieuwe versie ophalen lukte niet ($(last_line "$out")); ik ga verder met de versie die er staat."
    fi
    return 0
  done
}

ensure_starter() {
  step "Voorbereiden 4/4 · Studio MVP ophalen"
  if [ ! -e "$STARTER" ]; then
    clone_starter
  elif ! command -v git >/dev/null 2>&1 || ! git_ok; then
    plan "Studio MVP bijwerken in $STARTER_SHOWN (zodra git er is)"
  elif ! is_starter_repo; then
    die "In $STARTER_SHOWN staat al een map die geen kopie van Studio MVP (git) is. Daar blijf ik vanaf." \
      "Geef die map in de Finder een andere naam (bijvoorbeeld studiomvp-starter-oud) en plak de installatieregel nog eens."
  else
    update_starter
  fi
}

# ── 5. The rest: install.sh in Studio MVP ────────────────────────────────────────────────────────────────────
hand_over() {
  local script="$STARTER/install.sh" flag='--van-installeer' code=0
  if [ ! -f "$script" ]; then
    if [ "$DRY" = 1 ]; then
      step "Studio MVP inrichten"
      plan "$STARTER_SHOWN/install.sh starten: de instellingen (met het Studio MVP-wachtwoord), Sanity, je naam, Claude Code en de app in het Dock"
      printf '\n  %sProef klaar: er is niets veranderd.%s Echt installeren: plak de installatieregel zonder --proef.\n\n' "$G" "$N"
      return 0
    fi
    die "In $STARTER_SHOWN ontbreekt install.sh." "Vraag Karim om te kijken."
  fi
  # (an older Studio MVP does not know the option yet)
  if ! grep -q -- '--van-installeer' "$script"; then flag=''; fi
  STEP='Studio MVP inrichten (install.sh)'
  log "install.sh gestart"
  # shellcheck disable=SC2086 # ($flag is one word, or nothing)
  # (STUDIOMVP_INSTALLEER_LOG: install.sh writes its own steps in the same log, never an answer)
  if [ "$DRY" = 1 ]; then
    /bin/bash "$script" --dry-run $flag <&3 || code=$?
  else
    STUDIOMVP_INSTALLEER_LOG="$LOG" /bin/bash "$script" $flag <&3 || code=$?
  fi
  log "install.sh klaar (exit $code)"
  if [ "$code" -ne 0 ]; then
    printf '\n  %s!%s De installatie is nog niet helemaal klaar (zie hierboven).\n' "$Y" "$N"
    printf '    %s→%s Plak de installatieregel gerust nog eens in Terminal: wat al klaar is, wordt overgeslagen.\n' "$Y" "$N"
    log_hint
    HANDLED=1
    exit "$code"
  fi
}

usage() {
  printf 'Studio MVP installeren op deze Mac:\n'
  printf '  curl -fsSL https://raw.githubusercontent.com/mennovanpaassen/studiomvp-installeer/main/installeer.sh | bash\n'
  printf 'Proef (verandert niets): … | bash -s -- --proef\n'
}

main() {
  init
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run | --proef) DRY=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf 'Onbekende optie: %s (alleen --proef kan).\n' "$arg"
        HANDLED=1
        exit 2
        ;;
    esac
  done
  if [ "${STUDIOMVP_INSTALLEER_DRYRUN:-}" = 1 ]; then DRY=1; fi
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  trap on_exit EXIT
  trap 'exit 130' INT
  check_mac
  start_log
  open_tty
  intro
  ensure_homebrew
  ensure_tools
  ensure_github
  ensure_starter
  hand_over
  log "klaar"
  FINISHED=1
}

main "$@"
