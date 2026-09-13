"""App-icon generator (Pillow, project-local venv only — not a runtime
dependency). Draws a 1024x1024 master icon with three explicit glyphs
rather than one clever shape trying to carry multiple meanings: a photo
frame (main, center) for "your own photo", a cloud worn like a hat on top
of it for "your own cloud", and a padlock badge overlaid on the photo
itself for "kept private".
"""

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersample factor for smoother edges/blurs


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def make_background(size):
    # Diagonal aurora gradient: violet -> electric blue -> cyan, top-left to
    # bottom-right.
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


def drop_shadow(alpha_mask, blur, offset, opacity=120):
    size = alpha_mask.size[0]
    shadow = Image.new("L", (size, size), 0)
    shadow.paste(alpha_mask, offset)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.putalpha(shadow.point(lambda a: min(a, opacity)))
    return layer


def draw_photo_frame(canvas, size, ss):
    """Main glyph: white rounded square with a gradient-tinted sun+mountain
    cutout inside — "your own photo"."""

    def s(v):
        return v * ss

    frame_box = [s(277), s(360), s(747), s(790)]
    frame_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(frame_mask).rounded_rectangle(frame_box, radius=s(70), fill=255)
    canvas = Image.alpha_composite(canvas, drop_shadow(frame_mask, size * 0.02, (0, int(18 * ss)), opacity=130))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(frame_box, radius=s(70), fill=(255, 255, 255, 255))

    inner_pad = s(36)
    inner = [frame_box[0] + inner_pad, frame_box[1] + inner_pad, frame_box[2] - inner_pad, frame_box[3] - inner_pad]
    w, h = int(inner[2] - inner[0]), int(inner[3] - inner[1])
    grad = Image.new("RGB", (w, h))
    gpx = grad.load()
    top, bottom = (94, 66, 220), (56, 132, 224)
    for yy in range(h):
        row = tuple(int(v) for v in lerp(top, bottom, yy / max(1, h - 1)))
        for xx in range(w):
            gpx[xx, yy] = row
    inner_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(inner_mask).rounded_rectangle(inner, radius=s(30), fill=255)
    grad_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad_layer.paste(grad, (int(inner[0]), int(inner[1])))
    canvas = Image.composite(grad_layer, canvas, inner_mask)
    draw = ImageDraw.Draw(canvas)

    sun_r = s(30)
    # Kept low enough in the frame to clear the cloud hat's overlap area
    # (see draw_cloud_hat) — otherwise its bottom edge peeks out from
    # under the cloud.
    sun_cx, sun_cy = inner[0] + s(90), inner[1] + s(150)
    draw.ellipse([sun_cx - sun_r, sun_cy - sun_r, sun_cx + sun_r, sun_cy + sun_r], fill=(255, 255, 255, 255))
    base_y = inner[3] - s(40)
    draw.polygon(
        [(inner[0] + s(30), base_y), (inner[0] + s(190), inner[1] + s(120)), (inner[0] + s(350), base_y)],
        fill=(255, 255, 255, 255),
    )
    draw.polygon(
        [(inner[0] + s(230), base_y), (inner[0] + s(370), inner[1] + s(160)), (inner[2] - s(30), base_y)],
        fill=(224, 242, 254, 255),
    )
    return canvas, frame_box, inner


def draw_cloud_hat(canvas, size, ss, frame_box):
    """A cloud worn like a hat on top of the frame — "your own cloud". White,
    like the frame, with a thin colored rim so it still reads as a distinct
    shape rather than blending into the frame's border."""

    def s(v):
        return v * ss

    cx = (frame_box[0] + frame_box[2]) / 2
    base_bottom = frame_box[1] + s(130)  # sits well over the photo, not just tucked at the edge
    base_top = base_bottom - s(90)
    base_left, base_right = cx - s(185), cx + s(185)
    bump_top = base_top - s(110)

    def paint(draw_or_fn, fill):
        draw_or_fn.ellipse([base_left - s(15), bump_top, base_left + s(155), base_top + s(70)], fill=fill)
        draw_or_fn.ellipse([cx - s(110), bump_top - s(32), cx + s(110), base_top + s(58)], fill=fill)
        draw_or_fn.ellipse([base_right - s(155), bump_top, base_right + s(15), base_top + s(70)], fill=fill)
        draw_or_fn.rounded_rectangle([base_left, base_top, base_right, base_bottom], radius=s(46), fill=fill)

    cloud_mask = Image.new("L", (size, size), 0)
    paint(ImageDraw.Draw(cloud_mask), 255)
    canvas = Image.alpha_composite(canvas, drop_shadow(cloud_mask, size * 0.014, (0, int(10 * ss)), opacity=110))

    rim_color = (34, 197, 217, 255)
    draw = ImageDraw.Draw(canvas)
    paint(draw, rim_color)

    inner_mask = cloud_mask.filter(ImageFilter.MinFilter(int(9 * ss) * 2 + 1))
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    canvas = Image.composite(white, canvas, inner_mask)
    return canvas


def draw_lock_overlay(canvas, size, ss, inner):
    """A padlock badge tilted at the photo's bottom-right corner, straddling
    it (part over the photo, part hanging off the edge) rather than sitting
    fully inside — this photo is "kept private"."""

    def s(v):
        return v * ss

    # Drawn upright on its own square layer first, then rotated as a whole
    # — compound shapes like this can't be rotated via ImageDraw directly.
    dim = int(340 * ss)
    layer = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    cx = dim / 2
    shackle_r = s(56)
    body_w, body_h = s(150), s(128)
    body_top = cx + s(4)

    ld.arc(
        [cx - shackle_r, body_top - shackle_r, cx + shackle_r, body_top + shackle_r],
        start=180,
        end=360,
        fill=(255, 255, 255, 255),
        width=s(22),
    )
    ld.rounded_rectangle(
        [cx - body_w / 2, body_top, cx + body_w / 2, body_top + body_h], radius=s(20), fill=(255, 255, 255, 255)
    )
    lock_color = (63, 55, 130, 255)
    ld.ellipse([cx - s(11), body_top + s(24), cx + s(11), body_top + s(46)], fill=lock_color)
    ld.rectangle([cx - s(5.5), body_top + s(38), cx + s(5.5), body_top + s(68)], fill=lock_color)

    rotated = layer.rotate(-22, resample=Image.BICUBIC, expand=True)

    # Centered on the photo's bottom-right corner, so it visibly straddles
    # the edge instead of sitting fully inside it.
    target_cx, target_cy = inner[2], inner[3]
    pos = (int(target_cx - rotated.width / 2), int(target_cy - rotated.height / 2))
    full = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    full.paste(rotated, pos, rotated)

    canvas = Image.alpha_composite(canvas, drop_shadow(full.split()[-1], size * 0.012, (0, int(8 * ss)), opacity=150))
    canvas = Image.alpha_composite(canvas, full)
    return canvas


def main():
    size = SIZE * SS
    canvas = make_background(size).convert("RGBA")
    canvas, frame_box, inner = draw_photo_frame(canvas, size, SS)
    canvas = draw_cloud_hat(canvas, size, SS, frame_box)
    canvas = draw_lock_overlay(canvas, size, SS, inner)

    final = canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    final.save("assets/icon/app_icon.png")
    print("wrote assets/icon/app_icon.png", final.size)


if __name__ == "__main__":
    main()
