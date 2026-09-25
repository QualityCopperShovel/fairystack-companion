#!/bin/bash
# MIT licensed. Downloaded scripts only start after this complete function body.
fairystack_install() (
  set -Eeuo pipefail
  umask 077
  step='checking this Mac'
  work=''
  lock=''
  child=''
  cleanup() {
    if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    [ -z "$work" ] || rm -rf "$work"
    [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || true
  }
  trap cleanup EXIT
  trap 'printf "Installation failed while %s (exit %s). Rerun the installer after resolving this error.\n" "$step" "$?" >&2' ERR
  trap 'printf "Installation cancelled.\n" >&2; exit 130' INT TERM
  fail() { printf '%s\n' "$*" >&2; exit 1; }
  [ "$(uname -s)" = Darwin ] || fail 'FairyStack for Mac supports macOS 13 or later.'
  major=$(sw_vers -productVersion); major=${major%%.*}
  [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 13 ] || fail 'macOS 13 or later is required.'
  [ "$(id -u)" != 0 ] || fail 'Run this as your Mac user, without sudo.'
  origin=${1:-https://fairystack.com}
  [[ "$origin" =~ ^https://[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]+)?$ ]] || fail 'Expected an HTTPS FairyStack origin with no path, credentials or query.'
  [ "$#" -le 1 ] || fail 'Usage: install-mac.sh [https://your-stack.fairystack.com]'
  command -v perl >/dev/null || fail 'The macOS Perl runtime is required for bounded installation checks.'
  started=$SECONDS
  # Own each command's process group and kill it on timeout or interruption.
  run() {
    local limit=$1 remaining code
    shift
    remaining=$((240 - (SECONDS - started)))
    [ "$remaining" -gt 0 ] || fail "Installation timed out while $step."
    [ "$limit" -le "$remaining" ] || limit=$remaining
    perl -e '
      use strict; use warnings; use POSIX qw(WNOHANG); use Time::HiRes qw(time sleep);
      my $limit=shift @ARGV; my $pid=fork(); defined $pid or die "fork: $!";
      if (!$pid) { setpgrp(0,0) or die "process group: $!"; exec @ARGV; die "exec: $!"; }
      sub stop { kill "TERM", -$pid; sleep 0.2; kill "KILL", -$pid; waitpid($pid,0); }
      $SIG{INT}=sub { stop(); exit 130 }; $SIG{TERM}=sub { stop(); exit 143 };
      my $end=time()+$limit;
      while (waitpid($pid,WNOHANG)==0) {
        if (time()>=$end) { stop(); print STDERR "Step timed out after ${limit}s.\n"; exit 124; }
        sleep 0.05;
      }
      exit(($? & 127) ? 128+($? & 127) : $? >> 8);
    ' "$limit" "$@" &
    child=$!
    if wait "$child"; then child=''; else code=$?; child=''; return "$code"; fi
  }
  apps="$HOME/Applications"
  mkdir -p "$apps"
  if mkdir "$apps/.fairystack-install.lock" 2>/dev/null; then
    lock="$apps/.fairystack-install.lock"
  else
    fail "Another installation is active. If its Terminal was forcibly closed, remove the empty $apps/.fairystack-install.lock directory and retry."
  fi
  target="$apps/FairyStack.app"
  # Builds before 1.2 installed here; the same signed app, moved to $target.
  legacy="$apps/FairyStack Companion.app"
  existing=$target
  if [ ! -e "$target" ] && [ ! -L "$target" ] && { [ -e "$legacy" ] || [ -L "$legacy" ]; }; then existing=$legacy; fi
  verify() {
    step='verifying the Apple signature'
    run 30 codesign --verify --deep --strict -R '=anchor apple generic and identifier "com.fairystack.companion" and certificate leaf[subject.OU] = "7ZPTPEXGRC"' "$1"
    step='checking Gatekeeper approval'
    run 45 spctl --assess --type execute --verbose "$1"
  }
  version='1.9.1'
  fetch() {
    work=$(mktemp -d "$apps/.fairystack.XXXXXX")
    step='downloading FairyStack'
    printf 'Downloading FairyStack %s…\n' "$version"
    run 125 curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 -o "$work/fairystack.zip" "https://fairystack.com/assets/FairyStack-$version.zip"
    step='checking the download checksum'
    (cd "$work"; printf '%s\n' 'bb41803be42abd8c111ec0bfb7966131b0b25be81aed2d3a928a15d6b5a26d71  fairystack.zip' > checksum)
    run 10 bash -c 'cd "$1" && shasum -a 256 -c checksum' _ "$work"
    step='unpacking the app'
    run 30 ditto -x -k "$work/fairystack.zip" "$work"
    verify "$work/FairyStack.app"
  }
  # True when dotted version $1 is older than $2.
  older() {
    local IFS=. i; local -a a=($1) b=($2)
    for i in 0 1 2; do
      [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 0
      [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 1
    done
    return 1
  }
  if [ -e "$existing" ] || [ -L "$existing" ]; then
    [ ! -L "$existing" ] || fail 'The install destination is a symbolic link; no files were changed.'
    printf 'Checking the existing %s…\n' "${existing##*/}"
    verify "$existing"
    step='reading the installed version'
    installed=$(run 10 defaults read "$existing/Contents/Info" CFBundleShortVersionString)
    [[ "$installed" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "Could not read the installed FairyStack version ($installed); no files were changed."
    if older "$installed" "$version" || [ "$existing" != "$target" ]; then
      step='checking whether FairyStack is running'
      if run 10 pgrep -x FairyStackCompanion >/dev/null; then
        fail "FairyStack $installed is open. Choose Quit from its fairy menu-bar icon, then rerun this command to update to $version. No files were changed."
      fi
    fi
    if older "$installed" "$version"; then
      fetch
      step='replacing the older app'
      run 10 mv "$existing" "$work/previous.app"
      run 10 mv "$work/FairyStack.app" "$target"
      printf 'Updated FairyStack %s to %s.\n' "$installed" "$version"
    elif [ "$existing" != "$target" ]; then
      step='renaming the app to FairyStack'
      run 10 mv "$existing" "$target"
    fi
  else
    fetch
    step='installing the app'
    [ ! -e "$target" ] && [ ! -L "$target" ] || fail 'The install destination changed; rerun to check the existing app.'
    run 10 mv "$work/FairyStack.app" "$target"
  fi
  if [ -e "$legacy" ] && [ "$existing" = "$target" ]; then
    printf 'An older %s is still in %s; delete it after quitting it.\n' "${legacy##*/}" "$apps"
  fi
  step='opening FairyStack'
  run 15 open -a "$target" --args --fairystack-origin "$origin"
  step='opening your pairing page'
  run 15 open "$origin/companions#pair"
  printf 'Installed and opened: %s\nFairyStack opens in its own window. To let agents run commands on this Mac, create a code on the pairing page, paste it in the fairy menu-bar icon → FairyStack commands: Off…, and choose a workspace.\n' "$target"
)
fairystack_install "$@"
