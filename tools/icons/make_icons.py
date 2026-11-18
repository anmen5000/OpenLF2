#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Renders dist/io.github.openlf2.OpenLF2.svg, the project's only copy of its icon, into every
image format the packages, the executable and the window need.

    make_icons.py OUT_DIR [--svg FILE] [--force]

Nothing this writes is committed; CMake and the dist/build-*.sh scripts run it and consume the result.
Python 3 with the standard library is enough: the SVG is rendered by the small rasterizer below, so
every CI runner and container draws the same pixels without installing an SVG tool. Pillow or
ImageMagick is used only for the Nintendo Switch's JPEG, and is optional (that one file is skipped
without it).

The rasterizer draws the subset of SVG the icon uses and refuses anything else, so a change that goes
beyond it fails here instead of rendering wrongly: rect (with rx), circle, ellipse, polygon and path
(M L H V Z, absolute or relative), groups, solid fills, linear and radial gradients in
objectBoundingBox units, opacity, and strokes with round caps and joins.

Output layout under OUT_DIR:
    window_icon.hpp               128 px PNG as a C++ array (the window icon)
    openlf2.ico, openlf2.rc       Windows executable icon and the resource script that names it
    openlf2.icns                  macOS bundle icon
    hicolor/NxN/apps/<id>.png     Linux icon theme sizes
    ios/AppIcon*.png              iOS icons (square, opaque)
    android/res/mipmap-*/ic_launcher.png
    windows/wizard*.bmp           the Windows installer's side picture (100%, 150%, 200%)
    windows/wizard-small*.bmp     its small header picture
    switch/icon.jpg               Nintendo Switch (256 px JPEG; needs Pillow or ImageMagick)
    vita/icon0.png                PlayStation Vita (128 px, palette PNG)
    web/favicon.ico, web/favicon-32.png, web/apple-touch-icon.png
    web/icon-192.png, web/icon-512.png, web/icon-maskable-512.png   the site's app icons (its manifest)
"""
import hashlib
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib
import xml.etree.ElementTree as ET

APP_ID = "io.github.openlf2.OpenLF2"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_SVG = os.path.join(ROOT, "dist", APP_ID + ".svg")
NS = "{http://www.w3.org/2000/svg}"


class Unsupported(Exception):
    pass


# --------------------------------------------------------------------------------------------
# SVG subset: parsing
# --------------------------------------------------------------------------------------------

def number(value, default=0.0):
    if value is None:
        return default
    return float(re.match(r"\s*([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)", value).group(1))


def color(value):
    """'#rgb' / '#rrggbb' -> (r, g, b) 0..1."""
    match = re.fullmatch(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})", value.strip())
    if not match:
        raise Unsupported("color %r (use #rgb or #rrggbb)" % value)
    text = match.group(1)
    if len(text) == 3:
        text = "".join(c * 2 for c in text)
    return tuple(int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def path_subpaths(data):
    """Subpaths of a path with M/L/H/V/Z: a list of (points, closed)."""
    tokens = re.findall(r"[MmLlHhVvZz]|[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?", data)
    bad = re.sub(r"[MmLlHhVvZz\s,]|[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?", "", data)
    if bad:
        raise Unsupported("path commands %r (only M L H V Z)" % bad)
    subpaths, points, closed = [], [], False
    x = y = start_x = start_y = 0.0
    command, index = None, 0
    counts = {"M": 2, "L": 2, "H": 1, "V": 1, "Z": 0}
    while index < len(tokens):
        if re.fullmatch(r"[A-Za-z]", tokens[index]):
            command = tokens[index]
            index += 1
            if command in "Zz":
                if points:
                    subpaths.append((points, True))
                    points = []
                x, y = start_x, start_y
                continue
        elif command is None:
            raise Unsupported("path data does not start with a command")
        upper, relative = command.upper(), command.islower()
        args = [float(t) for t in tokens[index:index + counts[upper]]]
        index += counts[upper]
        if upper == "M":
            if points:
                subpaths.append((points, False))
            x, y = (x + args[0], y + args[1]) if relative else (args[0], args[1])
            start_x, start_y = x, y
            points = [(x, y)]
            command = "l" if relative else "L"  # further pairs are implicit line-tos
        else:
            if upper == "L":
                x, y = (x + args[0], y + args[1]) if relative else (args[0], args[1])
            elif upper == "H":
                x = x + args[0] if relative else args[0]
            elif upper == "V":
                y = y + args[0] if relative else args[0]
            if not points:
                points = [(start_x, start_y)]
            points.append((x, y))
    if points:
        subpaths.append((points, False))
    return subpaths


def arc_points(cx, cy, rx, ry, start, end, steps):
    return [(cx + rx * math.cos(start + (end - start) * i / steps), cy + ry * math.sin(start + (end - start) * i / steps))
            for i in range(steps + 1)]


class Shape:
    """One paintable shape: fill polygons, stroke geometry, paint and opacity (all in user units)."""

    def __init__(self, polygons, closed_lines, style, bbox):
        self.polygons = polygons          # fill polygons (lists of points)
        self.lines = closed_lines         # (points, closed) polylines to stroke
        self.style = style
        self.bbox = bbox


def parse_style(element, inherited):
    style = dict(inherited)
    for name in ("fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "fill-opacity"):
        if element.get(name) is not None:
            style[name] = element.get(name)
    if element.get("style"):
        raise Unsupported("style attributes (use presentation attributes)")
    if element.get("transform"):
        raise Unsupported("transform")
    return style


def bounding_box(polygons, lines):
    points = [p for poly in polygons for p in poly] + [p for line, _ in lines for p in line]
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys)) if points else (0, 0, 1, 1)


def shapes_of(element, inherited, out, square):
    tag = element.tag.replace(NS, "")
    style = parse_style(element, inherited)
    if tag in ("svg", "g"):
        for child in element:
            shapes_of(child, style, out, square)
        return
    if tag in ("title", "desc", "defs", "metadata"):
        return
    polygons, lines = [], []
    if tag == "rect":
        x, y, w, h = (number(element.get(k)) for k in ("x", "y", "width", "height"))
        rx = 0.0 if square else number(element.get("rx"), number(element.get("ry")))
        if rx <= 0:
            polygons = [[(x, y), (x + w, y), (x + w, y + h), (x, y + h)]]
        else:
            r = min(rx, w / 2, h / 2)
            pts = []
            for cx, cy, a in ((x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)):
                pts += arc_points(cx, cy, r, r, math.radians(a), math.radians(a + 90), 16)
            polygons = [pts]
    elif tag in ("circle", "ellipse"):
        cx, cy = number(element.get("cx")), number(element.get("cy"))
        rx = number(element.get("r")) if tag == "circle" else number(element.get("rx"))
        ry = rx if tag == "circle" else number(element.get("ry"))
        polygons = [arc_points(cx, cy, rx, ry, 0, 2 * math.pi, 96)[:-1]]
    elif tag == "polygon":
        values = [float(v) for v in re.findall(r"[-+]?[0-9]*\.?[0-9]+", element.get("points", ""))]
        polygons = [list(zip(values[0::2], values[1::2]))]
        lines = [(polygons[0], True)]
    elif tag == "path":
        for points, closed in path_subpaths(element.get("d", "")):
            polygons.append(points)
            lines.append((points, closed))
    else:
        raise Unsupported("element <%s>" % tag)
    if tag in ("rect", "circle", "ellipse"):
        lines = [(polygons[0], True)]
    out.append(Shape(polygons, lines, style, bounding_box(polygons, lines)))


def parse_gradients(root):
    gradients = {}
    for element in root.iter():
        tag = element.tag.replace(NS, "")
        if tag not in ("linearGradient", "radialGradient"):
            continue
        if element.get("gradientUnits") not in (None, "objectBoundingBox") or element.get("gradientTransform"):
            raise Unsupported("gradient units/transform")
        stops = []
        for stop in element:
            if stop.tag.replace(NS, "") != "stop":
                raise Unsupported("gradient child")
            offset = number(stop.get("offset"))
            stops.append((offset, color(stop.get("stop-color", "#000000")), number(stop.get("stop-opacity"), 1.0)))
        if tag == "linearGradient":
            spec = ("linear", number(element.get("x1"), 0.0), number(element.get("y1"), 0.0),
                    number(element.get("x2"), 1.0), number(element.get("y2"), 0.0))
        else:
            spec = ("radial", number(element.get("cx"), 0.5), number(element.get("cy"), 0.5), number(element.get("r"), 0.5))
        gradients[element.get("id")] = (spec, stops)
    return gradients


# --------------------------------------------------------------------------------------------
# Rasterizer
# --------------------------------------------------------------------------------------------

SUBSAMPLES = 4


def coverage(polygons, width, height):
    """Anti-aliased nonzero-winding coverage of polygons in pixel space: {row: [coverage per pixel]}."""
    rows = {}
    buckets = {}
    for poly in polygons:
        count = len(poly)
        for i in range(count):
            x0, y0 = poly[i]
            x1, y1 = poly[(i + 1) % count]
            if y0 == y1:
                continue
            direction = 1 if y1 > y0 else -1
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            first = max(0, math.ceil(y0 * SUBSAMPLES - 0.5))
            last = min(height * SUBSAMPLES - 1, math.ceil(y1 * SUBSAMPLES - 0.5) - 1)
            slope = (x1 - x0) / (y1 - y0)
            for sub in range(first, last + 1):
                y = (sub + 0.5) / SUBSAMPLES
                buckets.setdefault(sub, []).append((x0 + (y - y0) * slope, direction))
    weight = 1.0 / SUBSAMPLES
    for sub, crossings in buckets.items():
        crossings.sort()
        row = rows.get(sub // SUBSAMPLES)
        if row is None:
            row = rows[sub // SUBSAMPLES] = ([0.0] * (width + 2), [0.0] * (width + 2))
        cov, delta = row
        winding = 0
        for x, direction in crossings:
            before = winding
            winding += direction
            if before == 0 and winding != 0:
                start = x
            elif before != 0 and winding == 0:
                a, b = max(start, 0.0), min(x, float(width))
                if b <= a:
                    continue
                ia, ib = int(a), int(b)
                if ia == ib:
                    cov[ia] += (b - a) * weight
                else:
                    cov[ia] += (ia + 1 - a) * weight
                    delta[ia + 1] += weight
                    delta[ib] -= weight
                    cov[ib] += (b - ib) * weight
    result = {}
    for y, (cov, delta) in rows.items():
        running = 0.0
        line = [0.0] * width
        for x in range(width):
            running += delta[x]
            line[x] = min(1.0, cov[x] + running)
        result[y] = line
    return result


def stroke_polygons(lines, half_width, scale):
    """Round-capped, round-joined stroke as polygons of one orientation (their union is the stroke)."""
    polygons = []
    steps = max(8, min(48, int(half_width * scale * 2)))
    circle = [(math.cos(2 * math.pi * i / steps), math.sin(2 * math.pi * i / steps)) for i in range(steps)]

    def counter_clockwise(points):
        area = sum(points[i][0] * points[(i + 1) % len(points)][1] - points[(i + 1) % len(points)][0] * points[i][1]
                   for i in range(len(points)))
        return points if area > 0 else points[::-1]

    for points, closed in lines:
        path = list(points) + ([points[0]] if closed else [])
        for point in path:
            polygons.append(counter_clockwise([(point[0] + half_width * c, point[1] + half_width * s) for c, s in circle]))
        for (x0, y0), (x1, y1) in zip(path, path[1:]):
            length = math.hypot(x1 - x0, y1 - y0)
            if length == 0:
                continue
            nx, ny = -(y1 - y0) / length * half_width, (x1 - x0) / length * half_width
            polygons.append(counter_clockwise([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]))
    return polygons


def paint_function(paint, shape, gradients, scale, offset=(0, 0)):
    """Returns f(x, y) -> (r, g, b, a) for the paint, in pixel coordinates."""
    if paint.startswith("url("):
        name = re.fullmatch(r"url\(#([^)]+)\)", paint).group(1)
        spec, stops = gradients[name]
        bx0, by0, bx1, by1 = shape.bbox
        bw, bh = max(bx1 - bx0, 1e-9), max(by1 - by0, 1e-9)

        def stop_color(t):
            t = min(1.0, max(0.0, t))
            previous = stops[0]
            if t <= stops[0][0]:
                return stops[0][1] + (stops[0][2],)
            for current in stops[1:]:
                if t <= current[0]:
                    span = max(current[0] - previous[0], 1e-9)
                    f = (t - previous[0]) / span
                    return tuple(previous[1][i] + (current[1][i] - previous[1][i]) * f for i in range(3)) + \
                        (previous[2] + (current[2] - previous[2]) * f,)
                previous = current
            return stops[-1][1] + (stops[-1][2],)

        if spec[0] == "linear":
            _, x1, y1, x2, y2 = spec
            dx, dy = x2 - x1, y2 - y1
            norm = dx * dx + dy * dy

            def linear(x, y):
                u, v = (x / scale - bx0) / bw, (y / scale - by0) / bh
                return stop_color(((u - x1) * dx + (v - y1) * dy) / norm)
            return linear
        _, cx, cy, r = spec

        def radial(x, y):
            u, v = (x / scale - bx0) / bw, (y / scale - by0) / bh
            return stop_color(math.hypot(u - cx, v - cy) / r)
        return radial
    rgb = color(paint)
    solid = rgb + (1.0,)
    return lambda x, y: solid


def render(svg_path, size, square=False):
    """Renders the icon at size x size pixels; returns rows of (r, g, b, a) 0..255 tuples."""
    root = ET.parse(svg_path).getroot()
    view = [float(v) for v in root.get("viewBox").split()]
    if view[0] != 0 or view[1] != 0:
        raise Unsupported("viewBox origin")
    scale = size / view[2]
    gradients = parse_gradients(root)
    shapes = []
    shapes_of(root, {"fill": "#000000", "stroke": "none", "stroke-width": "1", "stroke-linecap": "butt",
                     "stroke-linejoin": "miter", "opacity": "1", "fill-opacity": "1"}, shapes, square)
    buffer = [[0.0] * (size * 4) for _ in range(size)]  # premultiplied r, g, b, a

    def paint_layer(polygons, paint, opacity, shape):
        pixel_polygons = [[(x * scale, y * scale) for x, y in poly] for poly in polygons]
        function = paint_function(paint, shape, gradients, scale)
        for y, line in coverage(pixel_polygons, size, size).items():
            row = buffer[y]
            for x, c in enumerate(line):
                if c <= 0.0:
                    continue
                r, g, b, a = function(x + 0.5, y + 0.5)
                a *= c * opacity
                if a <= 0.0:
                    continue
                inverse = 1.0 - a
                i = x * 4
                row[i] = r * a + row[i] * inverse
                row[i + 1] = g * a + row[i + 1] * inverse
                row[i + 2] = b * a + row[i + 2] * inverse
                row[i + 3] = a + row[i + 3] * inverse

    for shape in shapes:
        style = shape.style
        opacity = number(style["opacity"], 1.0)
        if style["fill"] != "none":
            paint_layer(shape.polygons, style["fill"], opacity * number(style["fill-opacity"], 1.0), shape)
        if style["stroke"] != "none":
            corners = any(closed or len(points) > 2 for points, closed in shape.lines)
            if style["stroke-linecap"] != "round" or (corners and style["stroke-linejoin"] != "round"):
                raise Unsupported("strokes need stroke-linecap=round, and stroke-linejoin=round where a path has corners")
            half = number(style["stroke-width"], 1.0) / 2.0
            paint_layer(stroke_polygons(shape.lines, half, scale), style["stroke"], opacity, shape)
    image = []
    for row in buffer:
        line = []
        for i in range(0, size * 4, 4):
            a = row[i + 3]
            if a <= 0.0:
                line.append((0, 0, 0, 0))
            else:
                line.append(tuple(min(255, int(round(row[i + k] / a * 255))) for k in range(3)) + (min(255, int(round(a * 255))),))
        image.append(line)
    return image


# --------------------------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------------------------

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


def png(image, opaque=False):
    height, width = len(image), len(image[0])
    channels = 3 if opaque else 4
    raw = b"".join(b"\0" + bytes(v for px in row for v in px[:channels]) for row in image)
    header = struct.pack(">IIBBBBB", width, height, 8, 2 if opaque else 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def quantize(colors, count):
    """Median cut of a list of (r, g, b) tuples into at most `count` palette entries."""
    boxes = [list(colors)]
    while len(boxes) < count:
        boxes.sort(key=lambda box: -len(box))
        box = boxes[0]
        if len(box) < 2:
            break
        ranges = [max(c[i] for c in box) - min(c[i] for c in box) for i in range(3)]
        axis = ranges.index(max(ranges))
        if ranges[axis] == 0:
            break
        box.sort(key=lambda c: c[axis])
        middle = len(box) // 2
        boxes[0:1] = [box[:middle], box[middle:]]
    return [tuple(sum(c[i] for c in box) // len(box) for i in range(3)) for box in boxes if box]


def png_indexed(image):
    """8-bit palette PNG (with a transparent entry for fully transparent pixels), as the Vita expects."""
    height, width = len(image), len(image[0])
    opaque = sorted({px[:3] for row in image for px in row if px[3] > 0})
    palette = quantize(opaque, 255) if opaque else []
    cache = {}

    def nearest(rgb):
        if rgb not in cache:
            cache[rgb] = min(range(len(palette)), key=lambda i: sum((palette[i][k] - rgb[k]) ** 2 for k in range(3))) + 1
        return cache[rgb]

    rows = []
    for row in image:
        rows.append(b"\0" + bytes(0 if px[3] < 128 else nearest(px[:3]) for px in row))
    plte = b"\0\0\0" + b"".join(bytes(c) for c in palette)
    header = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"PLTE", plte) + chunk(b"tRNS", b"\0") +
            chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def ico(entries):
    """entries: [(size, png bytes)] -> ICO with PNG-compressed images."""
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory, data = b"", b""
    for size, payload in entries:
        directory += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(payload), offset + len(data))
        data += payload
    return header + directory + data


def bmp(image):
    """24-bit BMP of rows of (r, g, b[, a]) tuples (what Inno Setup's wizard images are)."""
    height, width = len(image), len(image[0])
    pad = b"\0" * (-width * 3 % 4)
    rows = b"".join(bytes(v for px in (row[x][:3] for x in range(width)) for v in (px[2], px[1], px[0])) + pad
                    for row in reversed(image))
    header = struct.pack("<2sIHHI", b"BM", 54 + len(rows), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(rows), 2835, 2835, 0, 0)
    return header + info + rows


def banner(width, height, icon, top, bottom, icon_y):
    """A vertical gradient with `icon` (rows of RGBA) centered horizontally at row icon_y."""
    image = []
    for y in range(height):
        t = y / max(1, height - 1)
        image.append([tuple(int(round(top[k] + (bottom[k] - top[k]) * t)) for k in range(3))] * width)
    size = len(icon)
    left = (width - size) // 2
    for y, row in enumerate(icon):
        for x, (r, g, b, a) in enumerate(row):
            py, px = icon_y + y, left + x
            if a and 0 <= py < height and 0 <= px < width:
                base = image[py][px]
                image[py][px] = tuple(int(round(c * a / 255 + base[k] * (255 - a) / 255)) for k, c in enumerate((r, g, b)))
    return image


def icns(entries):
    """entries: [(type code, png bytes)] -> ICNS."""
    body = b"".join(code + struct.pack(">I", len(payload) + 8) + payload for code, payload in entries)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def jpeg(image, path):
    """256 px JPEG for the Switch; Pillow or ImageMagick, else skipped with a warning."""
    size = len(image)
    flat = bytes(v for row in image for px in row for v in px[:3])
    try:
        from PIL import Image
        Image.frombytes("RGB", (size, size), flat).save(path, "JPEG", quality=92)
        return True
    except ImportError:
        pass
    for tool in ("magick", "convert"):
        if shutil.which(tool):
            ppm = path + ".ppm"
            with open(ppm, "wb") as f:
                f.write(b"P6\n%d %d\n255\n" % (size, size) + flat)
            subprocess.run([tool, ppm, "-quality", "92", path], check=True)
            os.remove(ppm)
            return True
    print("make_icons: no Pillow or ImageMagick, skipping %s" % path, file=sys.stderr)
    return False


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def c_array(name, data):
    lines = []
    for i in range(0, len(data), 24):
        lines.append("    " + ", ".join("0x%02x" % b for b in data[i:i + 24]) + ",")
    return ("// SPDX-License-Identifier: MIT\n// Copyright (c) 2026 OpenLF2 contributors\n\n"
            "// Generated by tools/icons/make_icons.py from the project's SVG icon; not committed.\n"
            "#pragma once\n#include <array>\n\nnamespace openlf2::icon {\n"
            "inline constexpr std::array<unsigned char, %d> %s{\n%s\n};\n}\n" % (len(data), name, "\n".join(lines)))


def generate(svg, out):
    cache = {}

    def image(size, square=False):
        if (size, square) not in cache:
            cache[(size, square)] = render(svg, size, square)
        return cache[(size, square)]

    def png_of(size, square=False, opaque=False):
        return png(image(size, square), opaque)

    # Window icon and Windows / macOS executable icons.
    write(os.path.join(out, "window_icon.hpp"), c_array("window_png", png_of(128)).encode())
    write(os.path.join(out, "openlf2.ico"), ico([(s, png_of(s)) for s in (16, 24, 32, 48, 64, 128, 256)]))
    write(os.path.join(out, "openlf2.rc"), b'IDI_APPICON ICON "openlf2.ico"\r\n')
    write(os.path.join(out, "openlf2.icns"), icns([
        (b"icp4", png_of(16)), (b"icp5", png_of(32)), (b"icp6", png_of(64)), (b"ic07", png_of(128)),
        (b"ic08", png_of(256)), (b"ic09", png_of(512)), (b"ic11", png_of(32)), (b"ic12", png_of(64)),
        (b"ic13", png_of(256)), (b"ic14", png_of(512))]))
    # The Windows installer's pictures: the side picture (164 x 314 at 100%) is the game menu's blue with the icon;
    # the header picture (55 x 55) sits on the wizard's white.
    for suffix, scale in (("", 1.0), ("-150", 1.5), ("-200", 2.0)):
        width, height = int(round(164 * scale)), int(round(314 * scale))
        icon_size = int(round(96 * scale))
        write(os.path.join(out, "windows", "wizard%s.bmp" % suffix),
              bmp(banner(width, height, image(icon_size), (0x32, 0x4d, 0x9a), (0x10, 0x20, 0x6c), int(round(70 * scale)))))
        small = int(round(55 * scale))
        write(os.path.join(out, "windows", "wizard-small%s.bmp" % suffix),
              bmp(banner(small, small, image(int(round(small * 0.9))), (255, 255, 255), (255, 255, 255), int(round(small * 0.05)))))
    # Linux icon theme.
    for size in (16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512):
        write(os.path.join(out, "hicolor", "%dx%d" % (size, size), "apps", APP_ID + ".png"), png_of(size))
    # iOS wants full-bleed opaque squares; the system rounds them.
    for name, size in (("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180), ("AppIcon76x76@2x.png", 152),
                       ("AppIcon83.5x83.5@2x.png", 167)):
        write(os.path.join(out, "ios", name), png_of(size, square=True, opaque=True))
    # Android launcher icons.
    for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        write(os.path.join(out, "android", "res", "mipmap-" + density, "ic_launcher.png"), png_of(size))
    # Consoles.
    os.makedirs(os.path.join(out, "switch"), exist_ok=True)
    jpeg(image(256, square=True), os.path.join(out, "switch", "icon.jpg"))
    write(os.path.join(out, "vita", "icon0.png"), png_indexed(image(128)))
    # Web.
    write(os.path.join(out, "web", "favicon.ico"), ico([(s, png_of(s)) for s in (16, 32, 48)]))
    write(os.path.join(out, "web", "favicon-32.png"), png_of(32))
    write(os.path.join(out, "web", "apple-touch-icon.png"), png_of(180, square=True, opaque=True))
    # The site as an installed app (dist/pages/manifest.webmanifest): the icon as it is, and full-bleed for the
    # systems that cut their own shape out of it (purpose "maskable").
    write(os.path.join(out, "web", "icon-192.png"), png_of(192))
    write(os.path.join(out, "web", "icon-512.png"), png_of(512))
    write(os.path.join(out, "web", "icon-maskable-512.png"), png_of(512, square=True, opaque=True))


def main(argv):
    args = argv[1:]
    force = "--force" in args
    svg = DEFAULT_SVG
    if "--svg" in args:
        svg = os.path.abspath(args[args.index("--svg") + 1])
    positional = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--svg")]
    if len(positional) != 1:
        print(__doc__)
        return 2
    out = os.path.abspath(positional[0])
    digest = hashlib.sha256()
    for path in (svg, os.path.abspath(__file__)):
        with open(path, "rb") as f:
            digest.update(f.read())
    stamp = os.path.join(out, ".stamp")
    if not force and os.path.exists(stamp) and open(stamp).read() == digest.hexdigest():
        return 0  # already up to date
    os.makedirs(out, exist_ok=True)
    try:
        generate(svg, out)
    except Unsupported as error:
        print("make_icons: the SVG uses something the built-in renderer does not draw: %s" % error, file=sys.stderr)
        return 1
    with open(stamp, "w") as f:
        f.write(digest.hexdigest())
    print("make_icons: wrote icons into %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
