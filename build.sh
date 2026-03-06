#!/bin/bash
# build.sh - Compile, bundle, code sign, and install Peekaboo
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Peekaboo"
APP_BUNDLE="$APP_NAME.app"
INSTALL_DIR="/Applications"

echo "=== Building $APP_NAME ==="

# Compile
echo "[1/5] Compiling..."
swiftc -framework Cocoa -framework Security \
    "$SCRIPT_DIR/$APP_NAME.swift" \
    -o "$SCRIPT_DIR/$APP_NAME"

# Generate app icon
echo "[2/5] Generating app icon..."
ICONSET_DIR="$SCRIPT_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Use a small Swift script to render the icon at all required sizes
swift -e "
import Cocoa

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
        // Background rounded rect with gradient
        let inset: CGFloat = size * 0.01
        let radius = size * 0.22
        let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                  xRadius: radius, yRadius: radius)
        let gradient = NSGradient(
            starting: NSColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1.0),
            ending: NSColor(red: 0.15, green: 0.35, blue: 0.8, alpha: 1.0)
        )
        gradient?.draw(in: bgPath, angle: -90)

        // Draw monitor icon centered
        let iconSize = size * 0.55
        let s = iconSize / 18.0
        let ox = (size - iconSize) / 2.0
        let oy = (size - iconSize) / 2.0 + size * 0.01

        let color = NSColor.white
        color.setStroke()
        color.setFill()

        let lw = 1.3 * 1.8 * s

        // Monitor body
        let monitorRect = NSRect(x: ox + 2*s, y: oy + 2*s, width: 14*s, height: 10*s)
        let monitorPath = NSBezierPath(roundedRect: monitorRect, xRadius: 1.5*s, yRadius: 1.5*s)
        monitorPath.lineWidth = lw
        monitorPath.stroke()

        // Stand neck
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: ox + 9*s, y: oy + 12*s))
        neck.line(to: NSPoint(x: ox + 9*s, y: oy + 14.5*s))
        neck.lineWidth = lw
        neck.lineCapStyle = .round
        neck.stroke()

        // Stand base
        let base = NSBezierPath()
        base.move(to: NSPoint(x: ox + 6*s, y: oy + 15*s))
        base.line(to: NSPoint(x: ox + 12*s, y: oy + 15*s))
        base.lineWidth = lw
        base.lineCapStyle = .round
        base.stroke()

        // Left eye
        NSBezierPath(ovalIn: NSRect(
            x: ox + 5.3*s - 1.2*s, y: oy + 7.2*s - 1.2*s,
            width: 2.4*s, height: 2.4*s
        )).fill()

        // Right eye
        NSBezierPath(ovalIn: NSRect(
            x: ox + 12.7*s - 1.2*s, y: oy + 7.2*s - 1.2*s,
            width: 2.4*s, height: 2.4*s
        )).fill()

        return true
    }
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return }
    try! png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, CGFloat)] = [
    (\"icon_16x16.png\", 16),
    (\"icon_16x16@2x.png\", 32),
    (\"icon_32x32.png\", 32),
    (\"icon_32x32@2x.png\", 64),
    (\"icon_128x128.png\", 128),
    (\"icon_128x128@2x.png\", 256),
    (\"icon_256x256.png\", 256),
    (\"icon_256x256@2x.png\", 512),
    (\"icon_512x512.png\", 512),
    (\"icon_512x512@2x.png\", 1024),
]

let dir = \"$ICONSET_DIR\"
for (name, size) in sizes {
    let icon = drawIcon(size: size)
    savePNG(image: icon, path: dir + \"/\" + name)
}
"

# Convert iconset to icns
iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# Create .app bundle
echo "[3/5] Creating app bundle..."
rm -rf "$SCRIPT_DIR/$APP_BUNDLE"
mkdir -p "$SCRIPT_DIR/$APP_BUNDLE/Contents/MacOS"
mkdir -p "$SCRIPT_DIR/$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/$APP_NAME" "$SCRIPT_DIR/$APP_BUNDLE/Contents/MacOS/"
cp "$SCRIPT_DIR/AppIcon.icns" "$SCRIPT_DIR/$APP_BUNDLE/Contents/Resources/"

cat > "$SCRIPT_DIR/$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Peekaboo</string>
    <key>CFBundleIdentifier</key>
    <string>com.peekaboo.app</string>
    <key>CFBundleName</key>
    <string>Peekaboo</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Peekaboo discovers Macs on your network for Screen Sharing.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_rfb._tcp</string>
    </array>
</dict>
</plist>
EOF

# Code sign
echo "[4/5] Code signing..."
codesign --force --deep --sign - "$SCRIPT_DIR/$APP_BUNDLE"

# Install
echo "[5/5] Installing to $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/$APP_BUNDLE" ]; then
    echo "  Removing existing installation..."
    rm -rf "$INSTALL_DIR/$APP_BUNDLE"
fi
cp -R "$SCRIPT_DIR/$APP_BUNDLE" "$INSTALL_DIR/"

# Cleanup build artifacts
rm -f "$SCRIPT_DIR/$APP_NAME" "$SCRIPT_DIR/AppIcon.icns"

echo ""
echo "=== Done! ==="
echo ""
echo "Installed to: $INSTALL_DIR/$APP_BUNDLE"
echo ""
echo "To launch:  open $INSTALL_DIR/$APP_BUNDLE"
echo ""
echo "IMPORTANT: After rebuilding, remove and re-add Peekaboo in:"
echo "  System Settings > Privacy & Security > Accessibility"
echo ""
echo "To add to Login Items (start at login):"
echo "  System Settings > General > Login Items > add Peekaboo"
