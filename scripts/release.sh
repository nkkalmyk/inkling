#!/bin/bash
# Сборка публичного релиза: ad-hoc подпись (без личного сертификата и почты), zip и sha256.
# Использование: scripts/release.sh   →  build/release/Inkling-<версия>.zip
# Команды gh (тег, релиз) здесь не вызываются: см. AGENTS.md, раздел «Версии и релиз».
set -euo pipefail
cd "$(dirname "$0")/.."

DD=build/release-dd
OUT=build/release
rm -rf "$DD" "$OUT"
mkdir -p "$OUT"

xcodegen generate >/dev/null
# Переопределяем подпись в командной строке: Config/Signing.xcconfig (если он есть) на релиз не влияет.
# -file-prefix-map убирает путь к папке проекта (с именем пользователя) из #file, отладочной информации и путей объектов.
xcodebuild -scheme Inkling -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=/src" \
  DEBUG_INFORMATION_FORMAT=dwarf STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES build >/dev/null

APP="$DD/Build/Products/Release/Inkling.app"
# Убираем отладочные ссылки на объектные файлы (в них путь к домашней папке) и подписываем заново ad-hoc.
strip -S "$APP/Contents/MacOS/Inkling" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
codesign --verify --deep --strict "$APP"
if codesign -dvv "$APP" 2>&1 | grep -q "Authority="; then
  echo "В подписи есть сертификат разработчика: релиз должен быть ad-hoc" >&2
  exit 1
fi

# Путь к домашней папке и имени пользователя не должен попасть в публичный бинарник.
ZIP="$OUT/Inkling-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

# Проверка: в бинарнике и во всём архиве нет домашней папки пользователя.
CHECK=$(mktemp -d)
ditto -x -k "$ZIP" "$CHECK"
if grep -rIl --binary-files=text -e "$HOME" -e "/Users/$USER" "$CHECK" >/dev/null 2>&1 || \
   find "$CHECK" -type f -exec strings -a {} + 2>/dev/null | grep -q -e "$HOME" -e "/Users/$USER"; then
  echo "В архиве найден путь $HOME: уберите его перед публикацией" >&2
  rm -rf "$CHECK"; exit 1
fi
rm -rf "$CHECK"
echo "Проверка путей и подписи: ок"
