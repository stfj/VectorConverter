#!/bin/sh
set -e
for NAME in vtracer upscayl-bin; do
  BIN="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/${NAME}"
  [ -f "$BIN" ] || continue
  if [ "${EXPANDED_CODE_SIGN_IDENTITY:--}" = "-" ]; then
    codesign --force --options runtime --sign - "$BIN"
  else
    codesign --force --options runtime --timestamp --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$BIN"
  fi
done

