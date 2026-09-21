#!/bin/bash
# MIT licensed. Downloaded scripts only start after this complete function body.
companion_install() (
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
  [ "$(uname -s)" = Darwin ] || fail 'FairyStack Companion currently supports macOS 13 or later.'
  major=$(sw_vers -productVersion); major=${major%%.*}
  [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 13 ] || fail 'macOS 13 or later is required.'
  [ "$(id -u)" != 0 ] || fail 'Run this as your Mac user, without sudo.'
  origin=${1:-https://fairystack.com}
  [[ "$origin" =~ ^https://[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]+)?$ ]] || fail 'Expected an HTTPS FairyStack origin with no path, credentials or query.'
  [ "$#" -le 1 ] || fail 'Usage: install-companion.sh [https://your-stack.fairystack.com]'
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
  if mkdir "$apps/.fairystack-companion-install.lock" 2>/dev/null; then
    lock="$apps/.fairystack-companion-install.lock"
  else
    fail "Another installation is active. If its Terminal was forcibly closed, remove the empty $apps/.fairystack-companion-install.lock directory and retry."
  fi
  target="$apps/FairyStack Companion.app"
  verify() {
    step='verifying the Apple signature'
    run 30 codesign --verify --deep --strict -R '=anchor apple generic and identifier "com.fairystack.companion" and certificate leaf[subject.OU] = "7ZPTPEXGRC"' "$1"
    step='checking Gatekeeper approval'
    run 45 spctl --assess --type execute --verbose "$1"
  }
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ ! -L "$target" ] || fail 'The install destination is a symbolic link; no files were changed.'
    printf 'Checking the existing FairyStack Companion…\n'
    verify "$target"
  else
    work=$(mktemp -d "$apps/.fairystack-companion.XXXXXX")
    step='downloading FairyStack Companion'
    printf 'Downloading FairyStack Companion 1.0.1…\n'
    run 125 curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 -o "$work/companion.zip" https://fairystack.com/assets/FairyStack-Companion-1.0.1.zip
    step='checking the download checksum'
    (cd "$work"; printf '%s\n' 'd956310c3f3c5f5e1f5e052030b58c68d1561ff65e7845e6bb40db07c4acfad6  companion.zip' > checksum)
    run 10 bash -c 'cd "$1" && shasum -a 256 -c checksum' _ "$work"
    step='unpacking the app'
    run 30 ditto -x -k "$work/companion.zip" "$work"
    verify "$work/FairyStack Companion.app"
    step='installing the app'
    [ ! -e "$target" ] && [ ! -L "$target" ] || fail 'The install destination changed; rerun to check the existing app.'
    run 10 mv "$work/FairyStack Companion.app" "$target"
  fi
  step='opening FairyStack Companion'
  run 15 open -a "$target"
  step='opening your pairing page'
  run 15 open "$origin/companions#pair"
  printf 'Installed and opened: %s\nNext: create a code on the pairing page, paste it in the link menu → FairyStack commands: Off…, and choose a workspace.\n' "$target"
)
companion_install "$@"
