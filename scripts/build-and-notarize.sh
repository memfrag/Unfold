#!/bin/bash
set -euo pipefail

# --- Constants ---
SCHEME="Unfold"
APP_NAME="Unfold"
KEYCHAIN_PROFILE="notary"
SPARKLE_VERSION="2.9.0"
GITHUB_REPO="memfrag/Unfold"

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SPARKLE_TOOLS_DIR="$PROJECT_DIR/Sparkle-tools"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
INFO_PLIST="$PROJECT_DIR/$APP_NAME/Info.plist"
PBXPROJ="$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj"

# --- Helpers ---
error() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- Clean and create build directory ---
echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Download Sparkle tools if needed ---
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
    echo "==> Downloading Sparkle tools $SPARKLE_VERSION..."
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$BUILD_DIR/Sparkle.tar.xz"
    mkdir -p "$SPARKLE_TOOLS_DIR"
    tar -xf "$BUILD_DIR/Sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR"
    rm "$BUILD_DIR/Sparkle.tar.xz"
    echo "    Sparkle tools installed at $SPARKLE_TOOLS_DIR"
fi

# --- Version checking ---
echo "==> Checking version..."
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION=$(grep 'MARKETING_VERSION' "$PBXPROJ" | head -1 | sed 's/.*= *//;s/ *;.*//' || true)
fi
echo "    Current version: $CURRENT_VERSION"

LATEST_TAG=$(gh release view --repo "$GITHUB_REPO" --json tagName -q '.tagName' 2>/dev/null || true)
if [ -n "$LATEST_TAG" ]; then
    echo "    Latest release: $LATEST_TAG"
fi

NEED_NEW_VERSION=false
if [ -z "$LATEST_TAG" ]; then
    echo "    No existing releases found."
    read -rp "    Enter version to release [$CURRENT_VERSION]: " VERSION
    VERSION="${VERSION:-$CURRENT_VERSION}"
else
    if [ "$CURRENT_VERSION" = "$LATEST_TAG" ]; then
        NEED_NEW_VERSION=true
        echo "    Current version matches latest release."
    fi
    if [ "$NEED_NEW_VERSION" = true ]; then
        read -rp "    Enter new version: " VERSION
        if [ -z "$VERSION" ]; then
            error "Version cannot be empty."
        fi
    else
        read -rp "    Enter version to release [$CURRENT_VERSION]: " VERSION
        VERSION="${VERSION:-$CURRENT_VERSION}"
    fi
fi

if [ "$VERSION" != "$CURRENT_VERSION" ]; then
    echo "==> Updating version to $VERSION..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST" \
        || error "Failed to update CFBundleShortVersionString in Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$INFO_PLIST" \
        || error "Failed to update CFBundleVersion in Info.plist"
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/" "$PBXPROJ" || error "Failed to update MARKETING_VERSION in project.pbxproj"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $VERSION/" "$PBXPROJ" || error "Failed to update CURRENT_PROJECT_VERSION in project.pbxproj"
    cd "$PROJECT_DIR"
    git add "$INFO_PLIST" "$PBXPROJ"
    git commit -m "Bump version to $VERSION"
    git push origin HEAD
    echo "    Version updated and pushed."
else
    # Ensure Info.plist matches even if no bump needed
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$INFO_PLIST" 2>/dev/null || true
fi

TAG="$VERSION"

# --- Archive ---
echo "==> Archiving..."
xcodebuild archive \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    -arch arm64 \
    ENABLE_HARDENED_RUNTIME=YES \
    2>&1 | tee "$BUILD_DIR/archive.log" | tail -5

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "--- Last 30 lines of archive.log ---"
    tail -30 "$BUILD_DIR/archive.log"
    error "Archive failed. See $BUILD_DIR/archive.log for details."
fi
echo "    Archive created."

# --- Export ---
echo "==> Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | tee "$BUILD_DIR/export.log" | tail -5

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "--- Last 30 lines of export.log ---"
    tail -30 "$BUILD_DIR/export.log"
    error "Export failed. See $BUILD_DIR/export.log for details."
fi
echo "    Export complete."

# --- Read version from exported app ---
EXPORTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
echo "    Exported app version: $EXPORTED_VERSION"

# --- Create DMG ---
echo "==> Creating DMG..."
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -a "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" || error "Failed to create DMG."
rm -rf "$DMG_STAGING"
echo "    DMG created: $DMG_PATH"

# --- Verify codesign ---
echo "==> Verifying codesign..."
codesign --verify --deep --strict "$APP_PATH" || error "Codesign verification failed."
echo "    Codesign verified."

# --- Notarize ---
echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait || error "Notarization failed."
echo "    Notarization complete."

# --- Staple ---
echo "==> Stapling..."
xcrun stapler staple "$DMG_PATH" || error "Stapling failed."
echo "    Stapled."

# --- Sign for Sparkle ---
echo "==> Signing for Sparkle..."
"$SPARKLE_TOOLS_DIR/bin/sign_update" "$DMG_PATH" || error "Sparkle signing failed."

# --- Prompt for release title ---
read -rp "==> Enter release title: " RELEASE_TITLE
if [ -z "$RELEASE_TITLE" ]; then
    RELEASE_TITLE="$APP_NAME $VERSION"
fi

# --- Create GitHub release ---
echo "==> Creating GitHub release..."
cd "$PROJECT_DIR"
git tag "$TAG" || error "Failed to create tag $TAG."
git push origin "$TAG" || error "Failed to push tag $TAG."
gh release create "$TAG" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "$RELEASE_TITLE" \
    --generate-notes || error "Failed to create GitHub release."
echo "    Release created: $TAG"

# --- Generate appcast ---
echo "==> Generating appcast..."
APPCAST_DIR="$BUILD_DIR/appcast-assets"
mkdir -p "$APPCAST_DIR"

if [ -f "$PROJECT_DIR/appcast.xml" ]; then
    cp "$PROJECT_DIR/appcast.xml" "$APPCAST_DIR/"
fi

cp "$DMG_PATH" "$APPCAST_DIR/"

"$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$TAG/" \
    -o "$APPCAST_DIR/appcast.xml" \
    "$APPCAST_DIR" || error "Failed to generate appcast."

cp "$APPCAST_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"
cd "$PROJECT_DIR"
git add appcast.xml
git commit -m "Update appcast for $VERSION"
git push origin HEAD
echo "    Appcast updated and pushed."

echo ""
echo "==> Done! Released $APP_NAME $VERSION"
