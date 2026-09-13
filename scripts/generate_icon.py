"""One-off app-icon generator (Pillow, project-local venv only — not a
runtime dependency). Draws a 1024x1024 master icon: a diagonal
violet->blue->cyan "aurora" gradient with a soft glow, a drop-shadowed
photo-frame glyph, and a cloud-upload badge signaling "back up your own
photos" rather than a generic gallery icon.
"""

import math

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersample factor for smoother edges/blurs


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def make_background(size):
    # Diagonal aurora gradient: violet -> electric blue -> cyan, top-left to
    # bottom-right, cooler and more energetic than the old flat indigo fade.
    stops = [
        (0.0, (129, 61, 224)),  # violet
        (0.55, (59, 92, 233)),  # electric blue
        (1.0, (34, 197, 217)),  # cyan
    ]
    img = Image.new("RGB", (size, size))
    px = img.load()
    diag = (size - 1) * 2
    for y in range(size):
        for x in range(size):
            t = (x + y) / diag
            for i in range(len(stops) - 1):
                t0, c0 = stops[i]
                t1, c1 = stops[i + 1]
                if t0 <= t <= t1 or i == len(stops) - 2:
                    local_t = 0 if t1 == t0 else (t - t0) / (t1 - t0)
                    px[x, y] = tuple(int(v) for v in lerp(c0, c1, max(0, min(1, local_t))))
                    break
    return img


def add_glow(img):
    # Soft white radial glow behind where the glyph sits, for depth — a
    # blurred bright ellipse composited under the opaque foreground layers.
    size = img.size[0]
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = size * 0.42, size * 0.40, size * 0.46
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    white = Image.new("RGB", (size, size), (255, 255, 255))
    return Image.composite(white, img, glow)


def drop_shadow(mask_img, blur, offset, opacity=110):
    size = mask_img.size[0]
    shadow = Image.new("L", (size, size), 0)
    shadow.paste(mask_img.split()[-1] if mask_img.mode == "RGBA" else mask_img, offset)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.putalpha(shadow.point(lambda a: min(a, opacity)))
    return layer


def main():
    size = SIZE * SS
    img = make_background(size)
    img = add_glow(img)
    canvas = Image.new("RGBA", (size, size))
    canvas.paste(img, (0, 0))
    draw = ImageDraw.Draw(canvas)

    # --- Photo-frame glyph -------------------------------------------------
    frame_margin = int(260 * SS)
    frame_box = [frame_margin, frame_margin, size - frame_margin, size - frame_margin - int(40 * SS)]

    frame_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(frame_mask).rounded_rectangle(frame_box, radius=int(70 * SS), fill=255)
    shadow = drop_shadow(frame_mask, blur=size * 0.02, offset=(0, int(18 * SS)), opacity=130)
    canvas = Image.alpha_composite(canvas, shadow)
    draw = ImageDraw.Draw(canvas)

    draw.rounded_rectangle(frame_box, radius=int(70 * SS), fill=(255, 255, 255, 255))

    inner_pad = int(40 * SS)
    inner_box = [frame_box[0] + inner_pad, frame_box[1] + inner_pad, frame_box[2] - inner_pad, frame_box[3] - inner_pad]

    # Gradient-tinted cutout (violet->blue) instead of a flat accent, so the
    # glyph itself carries a slice of the background's energy.
    cutout = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cutout_grad = Image.new(
        "RGB",
        (inner_box[2] - inner_box[0], inner_box[3] - inner_box[1]),
    )
    cpx = cutout_grad.load()
    w, h = cutout_grad.size
    top, bottom = (94, 66, 220), (56, 132, 224)
    for yy in range(h):
        t = yy / max(1, h - 1)
        cpx_row = tuple(int(v) for v in lerp(top, bottom, t))
        for xx in range(w):
            cpx[xx, yy] = cpx_row
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(inner_box, radius=int(36 * SS), fill=255)
    cutout.paste(cutout_grad, (inner_box[0], inner_box[1]))
    canvas = Image.composite(cutout, canvas, mask)
    draw = ImageDraw.Draw(canvas)

    # Sun.
    sun_r = int(42 * SS)
    sun_cx = inner_box[0] + int(110 * SS)
    sun_cy = inner_box[1] + int(100 * SS)
    draw.ellipse([sun_cx - sun_r, sun_cy - sun_r, sun_cx + sun_r, sun_cy + sun_r], fill=(255, 255, 255, 255))

    # Mountains (two overlapping triangles).
    base_y = inner_box[3] - int(50 * SS)
    draw.polygon(
        [
            (inner_box[0] + int(40 * SS), base_y),
            (inner_box[0] + int(220 * SS), inner_box[1] + int(140 * SS)),
            (inner_box[0] + int(400 * SS), base_y),
        ],
        fill=(255, 255, 255, 255),
    )
    draw.polygon(
        [
            (inner_box[0] + int(260 * SS), base_y),
            (inner_box[0] + int(430 * SS), inner_box[1] + int(190 * SS)),
            (inner_box[2] - int(40 * SS), base_y),
        ],
        fill=(224, 242, 254, 255),
    )

    # --- Cloud-upload badge -------------------------------------------------
    badge_cx, badge_cy, badge_r = size - int(300 * SS), size - int(340 * SS), int(195 * SS)

    badge_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(badge_mask).ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r], fill=255
    )
    badge_shadow = drop_shadow(badge_mask, blur=size * 0.018, offset=(0, int(14 * SS)), opacity=150)
    canvas = Image.alpha_composite(canvas, badge_shadow)
    draw = ImageDraw.Draw(canvas)

    draw.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r],
        fill=(255, 255, 255, 255),
    )
    # Thin bright rim instead of the old flat dark outline — reads as glass,
    # not a decal.
    draw.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r],
        outline=(34, 197, 217, 255),
        width=int(10 * SS),
    )

    cloud_color = (56, 97, 224, 255)

    base_top, base_bottom = badge_cy + int(15 * SS), badge_cy + int(75 * SS)
    base_left, base_right = badge_cx - int(105 * SS), badge_cx + int(105 * SS)
    bump_top = base_top - int(55 * SS)
    draw.ellipse(
        [base_left - int(5 * SS), bump_top, base_left + int(85 * SS), base_top + int(40 * SS)], fill=cloud_color
    )
    draw.ellipse(
        [badge_cx - int(55 * SS), bump_top - int(15 * SS), badge_cx + int(55 * SS), base_top + int(30 * SS)],
        fill=cloud_color,
    )
    draw.ellipse(
        [base_right - int(85 * SS), bump_top, base_right + int(5 * SS), base_top + int(40 * SS)], fill=cloud_color
    )
    draw.rounded_rectangle([base_left, base_top, base_right, base_bottom], radius=int(28 * SS), fill=cloud_color)

    ax = badge_cx
    shaft_bottom = bump_top - int(15 * SS)
    shaft_top = shaft_bottom - int(55 * SS)
    draw.line([(ax, shaft_top), (ax, shaft_bottom)], fill=cloud_color, width=int(24 * SS))
    head_base = shaft_top + int(20 * SS)
    draw.polygon(
        [(ax - int(38 * SS), head_base), (ax + int(38 * SS), head_base), (ax, shaft_top - int(35 * SS))],
        fill=cloud_color,
    )

    final = canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    final.save("assets/icon/app_icon.png")
    print("wrote assets/icon/app_icon.png", final.size)


if __name__ == "__main__":
    main()
