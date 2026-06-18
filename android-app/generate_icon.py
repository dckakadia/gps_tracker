"""
Generate GPS Tracker app icon in all required Android densities.
Design: Deep blue circle bg, white location pin, teal inner dot, subtle pulse rings.
"""
from PIL import Image, ImageDraw
import math
import os

def lerp_color(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))

def create_icon(size, is_foreground=False, is_round=None):
    """
    is_foreground=True → transparent bg (for adaptive icon foreground layer)
    is_foreground=False → full opaque icon
    is_round → ignored, same shape used (circle bg already is round)
    """
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx = size // 2

    # ── Background circle ────────────────────────────────────────────
    if not is_foreground:
        # Radial gradient: bright blue at center → dark navy at edges
        center_col = (30, 120, 220)   # #1E78DC
        edge_col   = (10,  45, 110)   # #0A2D6E
        for r in range(cx, 0, -1):
            t = r / cx                # 1 at edge, 0 at center
            col = lerp_color(center_col, edge_col, t * t)  # quadratic → gentler
            draw.ellipse([cx - r, cx - r, cx + r - 1, cx + r - 1], fill=(*col, 255))

    # ── Location pin ────────────────────────────────────────────────
    # Foreground layer uses 108/192 safe zone = 56.25% of size
    if is_foreground:
        scale = 0.52   # keep pin inside safe zone
    else:
        scale = 0.64

    pin_w     = int(size * scale * 0.72)
    head_r    = pin_w // 2
    head_cx   = cx
    # Center pin visually: pin occupies top 72% of the icon height
    pin_total = int(size * scale)
    # Top of pin sits at cy - pin_total/2 + small nudge upward
    head_cy   = cx - pin_total // 2 + head_r + int(size * 0.02)
    pin_tip_y = head_cy + int(pin_total * 0.68)

    # Shadow / depth layer under pin
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    pad = max(2, size // 40)
    sd.ellipse([head_cx - head_r - pad, head_cy - head_r - pad,
                head_cx + head_r + pad, head_cy + head_r + pad],
               fill=(0, 0, 0, 55))
    from PIL import ImageFilter
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(2, size // 30)))
    img = Image.alpha_composite(img, shadow)
    draw = ImageDraw.Draw(img)

    # Pin tail — smooth tapered polygon
    tail_top_y = head_cy + int(head_r * 0.68)
    tail_half  = int(head_r * 0.48)
    tail_pts = [
        (head_cx - tail_half, tail_top_y),
        (head_cx + tail_half, tail_top_y),
        (head_cx, pin_tip_y),
    ]
    draw.polygon(tail_pts, fill=(255, 255, 255, 255))

    # Pin head circle
    draw.ellipse([head_cx - head_r, head_cy - head_r,
                  head_cx + head_r, head_cy + head_r],
                 fill=(255, 255, 255, 255))

    # Slight highlight on top-left of pin head (gives 3-D feel)
    hl_r = int(head_r * 0.55)
    hl_img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    hl_draw = ImageDraw.Draw(hl_img)
    hl_off = int(head_r * 0.18)
    hl_draw.ellipse([head_cx - hl_r - hl_off, head_cy - hl_r - hl_off,
                     head_cx + hl_r - hl_off, head_cy + hl_r - hl_off],
                    fill=(255, 255, 255, 40))
    img = Image.alpha_composite(img, hl_img)
    draw = ImageDraw.Draw(img)

    # Inner dot — teal/green shows "live tracking active"
    inner_r = int(head_r * 0.33)
    draw.ellipse([head_cx - inner_r, head_cy - inner_r,
                  head_cx + inner_r, head_cy + inner_r],
                 fill=(0, 200, 150, 255))   # #00C896 teal

    # Tiny white ring around inner dot for contrast
    ring_w = max(1, size // 96)
    draw.ellipse([head_cx - inner_r - ring_w, head_cy - inner_r - ring_w,
                  head_cx + inner_r + ring_w, head_cy + inner_r + ring_w],
                 outline=(255, 255, 255, 200), width=ring_w)

    # ── Pulse rings at pin tip ───────────────────────────────────────
    pulse_cx = head_cx
    pulse_cy = pin_tip_y
    ring_max = int(size * 0.19 * scale / 0.64)

    for i, (radius, alpha, thickness) in enumerate([
        (int(ring_max * 0.42), 90, max(1, size // 80)),
        (int(ring_max * 0.78), 50, max(1, size // 100)),
        (int(ring_max * 1.05), 22, max(1, size // 120)),
    ]):
        ell_img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        ell_draw = ImageDraw.Draw(ell_img)
        # Flatten the rings slightly (ellipse, not circle) → looks like ground shadow
        ry = max(1, radius // 3)
        ell_draw.ellipse([pulse_cx - radius, pulse_cy - ry,
                          pulse_cx + radius, pulse_cy + ry],
                         outline=(255, 255, 255, alpha), width=thickness)
        img = Image.alpha_composite(img, ell_img)

    return img


def create_adaptive_background(size):
    """Solid dark blue for adaptive icon background layer."""
    img = Image.new('RGBA', (size, size), (10, 45, 110, 255))
    return img


# Android mipmap sizes: (density, launcher_px, foreground_px)
SIZES = [
    ('mipmap-mdpi',    48,  108),
    ('mipmap-hdpi',    72,  162),
    ('mipmap-xhdpi',   96,  216),
    ('mipmap-xxhdpi',  144, 324),
    ('mipmap-xxxhdpi', 192, 432),
]

RES_DIR = os.path.join(os.path.dirname(__file__),
                        'app', 'src', 'main', 'res')

# Generate at high res then downscale for quality
MASTER_SIZE = 1024
print(f'Rendering master icon at {MASTER_SIZE}px …')
master      = create_icon(MASTER_SIZE, is_foreground=False)
master_fg   = create_icon(MASTER_SIZE, is_foreground=True)
master_bg   = create_adaptive_background(MASTER_SIZE)

for density, launcher_px, fg_px in SIZES:
    dir_path = os.path.join(RES_DIR, density)
    os.makedirs(dir_path, exist_ok=True)

    # ic_launcher.png  (legacy full icon)
    icon = master.resize((launcher_px, launcher_px), Image.LANCZOS)
    # Flatten onto white bg for PNG (some launchers don't handle alpha)
    flat = Image.new('RGBA', (launcher_px, launcher_px), (0, 0, 0, 0))
    flat.paste(icon, (0, 0), icon)
    flat.convert('RGB').save(os.path.join(dir_path, 'ic_launcher.png'), 'PNG')

    # ic_launcher_round.png  (same design, already circular)
    flat.convert('RGB').save(os.path.join(dir_path, 'ic_launcher_round.png'), 'PNG')

    # Adaptive icon layers
    fg = master_fg.resize((fg_px, fg_px), Image.LANCZOS)
    fg.save(os.path.join(dir_path, 'ic_launcher_foreground.png'), 'PNG')

    bg = master_bg.resize((fg_px, fg_px), Image.LANCZOS)
    bg.convert('RGB').save(os.path.join(dir_path, 'ic_launcher_background.png'), 'PNG')

    print(f'  {density}: ic_launcher {launcher_px}px, foreground {fg_px}px ✓')

# Also write the adaptive icon XML descriptors
mipmap_anydpi = os.path.join(RES_DIR, 'mipmap-anydpi-v26')
os.makedirs(mipmap_anydpi, exist_ok=True)

for fname in ('ic_launcher.xml', 'ic_launcher_round.xml'):
    with open(os.path.join(mipmap_anydpi, fname), 'w') as f:
        f.write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''')
print('  mipmap-anydpi-v26: adaptive icon XML ✓')

print('\nAll icon assets generated.')
