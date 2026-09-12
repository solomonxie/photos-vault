"""One-off app-icon generator (Pillow, project-local venv only — not a
runtime dependency). Draws a 1024x1024 master icon: indigo gradient
background, a simple photo-frame glyph, and a cloud-upload badge signaling
"back up your own photos" rather than a generic gallery icon.
"""

import math

from PIL import Image, ImageDraw

SIZE = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_background():
    top = (99, 102, 241)  # indigo-500
    bottom = (55, 48, 163)  # indigo-800
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        color = lerp(top, bottom, t)
        for x in range(SIZE):
            px[x, y] = color
    return img


def rounded_rect(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def main():
    img = make_background()
    draw = ImageDraw.Draw(img)

    # Photo-frame glyph: white rounded rect with a mountain+sun cutout in
    # the background color, universally-read as "a photo".
    frame_margin = 260
    frame_box = [frame_margin, frame_margin, SIZE - frame_margin, SIZE - frame_margin - 40]
    rounded_rect(draw, frame_box, radius=70, fill=(255, 255, 255))

    inner_pad = 40
    inner_box = [frame_box[0] + inner_pad, frame_box[1] + inner_pad, frame_box[2] - inner_pad, frame_box[3] - inner_pad]
    accent = (79, 70, 229)  # indigo-600, cutout color reads as the glyph
    rounded_rect(draw, inner_box, radius=36, fill=accent)

    # Sun.
    sun_r = 42
    sun_cx = inner_box[0] + 110
    sun_cy = inner_box[1] + 100
    draw.ellipse([sun_cx - sun_r, sun_cy - sun_r, sun_cx + sun_r, sun_cy + sun_r], fill=(255, 255, 255))

    # Mountains (two overlapping triangles).
    base_y = inner_box[3] - 50
    draw.polygon(
        [(inner_box[0] + 40, base_y), (inner_box[0] + 220, inner_box[1] + 140), (inner_box[0] + 400, base_y)],
        fill=(255, 255, 255),
    )
    draw.polygon(
        [(inner_box[0] + 260, base_y), (inner_box[0] + 430, inner_box[1] + 190), (inner_box[2] - inner_box[0] - 40 + inner_box[0], base_y)],
        fill=(237, 233, 254),
    )

    # Cloud-upload badge, bottom-right, overlapping the frame corner —
    # this is the part that says "backup", not just "photos".
    badge_cx, badge_cy, badge_r = SIZE - 300, SIZE - 340, 195
    draw.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r],
        fill=(255, 255, 255),
        outline=(55, 48, 163),
        width=10,
    )
    cloud_color = accent

    # Cloud silhouette: a rounded base with three bumps along the top,
    # all bumps' tops aligned so the outline reads cleanly.
    base_top, base_bottom = badge_cy + 15, badge_cy + 75
    base_left, base_right = badge_cx - 105, badge_cx + 105
    bump_top = base_top - 55
    draw.ellipse([base_left - 5, bump_top, base_left + 85, base_top + 40], fill=cloud_color)
    draw.ellipse([badge_cx - 55, bump_top - 15, badge_cx + 55, base_top + 30], fill=cloud_color)
    draw.ellipse([base_right - 85, bump_top, base_right + 5, base_top + 40], fill=cloud_color)
    draw.rounded_rectangle([base_left, base_top, base_right, base_bottom], radius=28, fill=cloud_color)

    # Upward arrow, with a visible gap above the cloud so the arrowhead and
    # shaft read as a distinct glyph — same color as the cloud (standard
    # cloud-upload convention), so it shows against the white badge.
    ax = badge_cx
    shaft_bottom = bump_top - 15
    shaft_top = shaft_bottom - 55
    draw.line([(ax, shaft_top), (ax, shaft_bottom)], fill=cloud_color, width=24)
    head_base = shaft_top + 20
    draw.polygon([(ax - 38, head_base), (ax + 38, head_base), (ax, shaft_top - 35)], fill=cloud_color)

    img.save("assets/icon/app_icon.png")
    print("wrote assets/icon/app_icon.png", img.size)


if __name__ == "__main__":
    main()
