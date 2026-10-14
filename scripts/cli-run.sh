#!/bin/bash
# Запуск CLI в «GUI-подобном» чистом окружении во временной папке.
# Использование: scripts/cli-run.sh <метка> <бинарник> [аргументы...]
# Картинки из $IMAGES (через пробел) копируются в рабочую папку.
# Результат: $OUT/<метка>.{out,err,exit}
set -u
label="$1"; shift
OUT="${OUT:-/Users/nkkalmyk/study-app-local/docs/cli-experiments/raw}"
mkdir -p "$OUT"
W=$(mktemp -d "${SCRATCH:-/tmp}/run.XXXX")
for f in ${IMAGES:-}; do cp "$f" "$W/"; done
cd "$W"
start=$(date +%s)
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
  PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/bin:/bin:/usr/sbin:/sbin" \
  "$@" > "$OUT/$label.out" 2> "$OUT/$label.err" < /dev/null
code=$?
echo "$code" > "$OUT/$label.exit"
echo "[$label] exit=$code time=$(( $(date +%s) - start ))s dir=$W"
