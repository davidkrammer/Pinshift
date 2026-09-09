#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PATH="${PINSHIFT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PinshiftBuild}"
DESTINATION="${1:-/Applications/Pinshift.app}"
if pgrep -x Pinshift >/dev/null; then
  echo 'Quit Pinshift after restoring GPS, then run this installer again.' >&2
  exit 1
fi
xcodebuild -project "$PROJECT_ROOT/Pinshift.xcodeproj" -scheme Pinshift \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_PATH" CODE_SIGN_IDENTITY=- build
SOURCE="$BUILD_PATH/Build/Products/Release/Pinshift.app"
# Move the previous bundle aside so obsolete files cannot invalidate signing.
if [ -e "$DESTINATION" ]; then
  BACKUP="${DESTINATION%.app}-backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$DESTINATION" "$BACKUP"
fi
ditto --noextattr "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
echo "Installed: $DESTINATION"
