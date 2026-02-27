#!/bin/bash
# setup-iterm-profiles.sh -- One-time iTerm2 profile setup for BDD E2E grid
#
# Creates a composite background image from the robot PNGs:
#   Top-left:     Blue_robot.png    (Writer)
#   Top-right:    Green_rotbot.png  (Executor)
#   Bottom:       orchestrator.png  (Orchestrator)
#
# Creates a "BDD" iTerm2 profile with the composite as background image.
# The tmux panes are set to transparent so the image shows through.
#
# Usage:
#   bash scripts/setup-iterm-profiles.sh

set -e

IMAGE_DIR="$HOME/.config/bdd-e2e-orchestrator/images"
PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_IMAGES="$SCRIPT_DIR/images"

# Verify source images exist in project
MISSING=false
for img in Blue_robot.png Green_rotbot.png orchestrator.png; do
    if [ ! -f "$SRC_IMAGES/$img" ]; then
        echo "Error: Image not found: $SRC_IMAGES/$img"
        MISSING=true
    fi
done
if $MISSING; then
    echo ""
    echo "Expected images in $SRC_IMAGES/"
    exit 1
fi

# Copy source images to persistent config location
echo "Copying images to $IMAGE_DIR..."
mkdir -p "$IMAGE_DIR"
cp "$SRC_IMAGES/Blue_robot.png" "$IMAGE_DIR/"
cp "$SRC_IMAGES/Green_rotbot.png" "$IMAGE_DIR/"
cp "$SRC_IMAGES/orchestrator.png" "$IMAGE_DIR/"

echo "Creating composite background image..."

python3 << 'PYEOF'
import os
from PIL import Image

image_dir = os.path.expanduser("~/.config/bdd-e2e-orchestrator/images")

writer_img = Image.open(os.path.join(image_dir, "Blue_robot.png")).convert("RGBA")
executor_img = Image.open(os.path.join(image_dir, "Green_rotbot.png")).convert("RGBA")
orch_img = Image.open(os.path.join(image_dir, "orchestrator.png")).convert("RGBA")

# 16:9 aspect ratio for widescreen terminals
composite_w, composite_h = 3840, 2160
cell_w = composite_w // 2   # 1920
top_h = composite_h // 2    # 1080
bot_h = composite_h // 2    # 1080

# Pure black background
composite = Image.new("RGBA", (composite_w, composite_h), (0, 0, 0, 255))

# Top-left: Writer (blue), Top-right: Executor (green), Bottom: Orchestrator (full width)
for img, qx, qy, qw, qh in [
    (writer_img,   0,      0,      cell_w,      top_h),     # top-left: Writer
    (executor_img, cell_w, 0,      cell_w,      top_h),     # top-right: Executor
    (orch_img,     0,      top_h,  composite_w, bot_h),     # bottom: Orchestrator
]:
    resized = img.resize((qw, qh), Image.LANCZOS)
    r, g, b, a = resized.split()
    a = a.point(lambda p: int(p * 0.35))
    resized = Image.merge("RGBA", (r, g, b, a))
    composite.paste(resized, (qx, qy), resized)

output_path = os.path.join(image_dir, "bdd_composite.png")
composite.save(output_path, "PNG")
print(f"  Composite saved: {output_path} ({composite_w}x{composite_h})")
PYEOF

# Verify iTerm2 plist exists
if [ ! -f "$PLIST" ]; then
    echo "Error: iTerm2 plist not found at $PLIST"
    echo "Make sure iTerm2 has been launched at least once."
    exit 1
fi

echo "Creating iTerm2 'BDD' profile..."

python3 << 'PYEOF'
import plistlib
import os
import copy

plist_path = os.path.expanduser("~/Library/Preferences/com.googlecode.iterm2.plist")
image_dir = os.path.expanduser("~/.config/bdd-e2e-orchestrator/images")
composite_path = os.path.join(image_dir, "bdd_composite.png")

with open(plist_path, "rb") as f:
    plist = plistlib.load(f)

bookmarks = plist.get("New Bookmarks", [])

# Find the Default profile to use as a base
default_profile = None
for bm in bookmarks:
    if bm.get("Name") == "Default":
        default_profile = bm
        break

if not default_profile:
    if bookmarks:
        default_profile = bookmarks[0]
    else:
        print("Error: No profiles found in iTerm2 plist")
        raise SystemExit(1)

# Remove existing BDD profile to allow re-running
remove_names = {"BDD"}
bookmarks = [bm for bm in bookmarks if bm.get("Name") not in remove_names]

# Create the BDD profile
profile = copy.deepcopy(default_profile)
profile["Name"] = "BDD"
profile["Guid"] = "bdd-composite-profile"

# Dark background
profile["Background Color"] = {
    "Red Component": 0.04,
    "Green Component": 0.04,
    "Blue Component": 0.04,
    "Alpha Component": 1.0,
    "Color Space": "sRGB",
}

# Readable foreground
profile["Foreground Color"] = {
    "Red Component": 0.9,
    "Green Component": 0.9,
    "Blue Component": 0.9,
    "Alpha Component": 1.0,
    "Color Space": "sRGB",
}

# Background image: the composite
profile["Background Image Location"] = composite_path
profile["Background Image Is Path"] = True
profile["Blend"] = 1.0
profile["Has Background Image"] = True
profile["Background Image Mode"] = 2  # Scale to Fill

# Opaque terminal
profile["Transparency"] = 0.0

bookmarks.append(profile)
plist["New Bookmarks"] = bookmarks

with open(plist_path, "wb") as f:
    plistlib.dump(plist, f)

print("  Created profile: BDD (composite background)")
print("  Profile written to iTerm2 plist")
PYEOF

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Quit iTerm2 completely (Cmd+Q)"
echo "  2. Re-open iTerm2"
echo "  3. Verify profile in Settings > Profiles: 'BDD'"
echo "  4. Start a session: bash scripts/start.sh <project>"
echo ""
echo "The start.sh script will set the iTerm2 profile to 'BDD' and"
echo "use transparent tmux pane backgrounds so the images show through."
