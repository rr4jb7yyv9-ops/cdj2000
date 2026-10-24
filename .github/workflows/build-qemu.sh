#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work"
mkdir -p "$WORK" "$ROOT/ci-output"
cd "$WORK"

# Exact source revision recorded in the original uploaded QEMU ZIP comment.
COMMIT="b6c4b7e86dec12d07f5cac65265b986d38ee9002"
QEMU_ZIP="$WORK/qemu-source.zip"
GITLAB="https://gitlab.com/qemu-project/qemu/-/archive/$COMMIT/qemu-$COMMIT.zip"
GITHUB="https://github.com/qemu/qemu/archive/$COMMIT.zip"
echo "Downloading pinned QEMU source revision $COMMIT"
if ! curl -fLSs --connect-timeout 25 --retry 2 "$GITLAB" -o "$QEMU_ZIP"; then
  echo "GitLab download failed, trying GitHub mirror"
  curl -fLSs --connect-timeout 25 --retry 2 "$GITHUB" -o "$QEMU_ZIP"
fi
python3 - "$QEMU_ZIP" <<'PYZIP'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as f:
    names=f.namelist()
    assert names and all(n.split('/')[0]==names[0].split('/')[0] for n in names), 'Unexpected archive roots'
    assert 'qemu' in names[0].lower(), 'Unexpected QEMU archive'
    print('QEMU archive OK, members:', len(names))
PYZIP
SRC="$(unzip -Z1 "$QEMU_ZIP" | sed -n '1p' | cut -d/ -f1)"
unzip -q "$QEMU_ZIP"
mv "$WORK/$SRC" "$WORK/qemu-master"
QEMU="$WORK/qemu-master"
[[ "$(cat "$QEMU/VERSION")" == "11.1.50" ]] || { echo 'QEMU version mismatch'; exit 4; }

unzip -q "$ROOT/source/cdj-qemu-port.zip" -d "$WORK"
PORT="$WORK/CDJ2000_QEMU_11_1_50_PORT_20261023"
python3 "$PORT/check_clean_inputs.py" "$QEMU" "$PORT/source_files.json"
mkdir -p "$QEMU/hw/sh4/c6x/binutils" "$QEMU/include/exec"
patch -d "$QEMU" -p1 --forward --batch < "$PORT/qemu-cdj2000-11.1.50.patch"
python3 "$PORT/check_patched.py" "$QEMU" "$PORT/source_files.json"

# QEMU 11 compatibility: upstream replaced TB_FLAG_GUSA_EXCLUSIVE with
# TB_FLAG_GUSA_MASK (the gUSA state is a bitfield). Apply this AFTER the
# upstream CDJ patch hash audit, preserving the original 138-file audit.
python3 - "$QEMU/target/sh4/translate.c" "$QEMU/target/sh4/cpu.h" <<'PY_SH4_COMPAT'
from pathlib import Path
import sys
translation = Path(sys.argv[1])
header = Path(sys.argv[2]).read_text()
old = 'TB_FLAG_GUSA_EXCLUSIVE | TB_FLAG_DELAY_SLOT_RTE'
new = 'TB_FLAG_GUSA_MASK | TB_FLAG_DELAY_SLOT_RTE'
content = translation.read_text()
assert '#define TB_FLAG_GUSA_MASK' in header, 'Modern SH4 gUSA mask not available'
assert content.count(old) == 1, 'Unexpected SH4 translator state; refusing blind patch'
assert content.count(new) == 0, 'Replacement already present or changed'
translation.write_text(content.replace(old, new, 1))
assert old not in translation.read_text()
print('QEMU 11 SH4 compatibility correction: OK')
PY_SH4_COMPAT

echo 'All CDJ source modifications checked; SH4 compatibility correction applied.'

# This subproject is absent from source archives; Actions fetches it online.
python3 -m venv "$ROOT/ci-venv"
"$ROOT/ci-venv/bin/python" -m pip install --no-index --find-links "$QEMU/python/wheels" meson==1.12.0
(cd "$QEMU" && "$ROOT/ci-venv/bin/meson" subprojects download keycodemapdb)
test -f "$QEMU/subprojects/keycodemapdb/README"
mkdir -p "$QEMU/build"
cd "$QEMU/build"
../configure --target-list=sh4-softmmu --enable-download \
  --disable-gtk --disable-sdl --disable-vnc --disable-spice \
  --disable-docs --disable-guest-agent --disable-tools \
  --disable-fdt --disable-werror
ninja qemu-system-sh4
BIN="$QEMU/build/qemu-system-sh4"
test -x "$BIN"
"$BIN" -M help | tee "$ROOT/ci-output/machines.txt"
grep -qi 'cdj' "$ROOT/ci-output/machines.txt"
cp "$BIN" "$ROOT/ci-output/qemu-system-sh4"
ldd "$BIN" > "$ROOT/ci-output/ldd.txt" || true
sha256sum "$BIN" > "$ROOT/ci-output/sha256.txt"
echo 'SUCCESS: CDJ SH-4 emulator compiled.'
