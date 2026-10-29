// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Tests for draw_on_cpu.rs: against a floating-point model of what the GPU draws (pixel centres,
// nearest or clamped bilinear sampling of premultiplied texels, the bitmap shader's colour
// transform, the fixed blend states), and against Ruffle's own CPU copy for plain moves.
use harness::bitmap::bitmap_data::Color;
use harness::bitmap::operations::draw_on_cpu::{CpuBlend, PixelMatrix, Pixels, draw_bitmap};
use swf::{ColorTransform, Fixed8};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

fn premultiplied(rng: &mut Rng, transparent: bool) -> Color {
    let a = if !transparent {
        255
    } else {
        match rng.below(4) {
            0 => 0,
            1 => 255,
            _ => rng.below(256) as u8,
        }
    };
    let c = |rng: &mut Rng| rng.below(256) as u8;
    Color::rgba(c(rng), c(rng), c(rng), a).to_premultiplied_alpha(true)
}

fn bitmap(rng: &mut Rng, w: u32, h: u32, transparent: bool) -> Vec<Color> {
    (0..w * h).map(|_| premultiplied(rng, transparent)).collect()
}

// ---- The model -----------------------------------------------------------------------------
type Rgba = [f64; 4];

fn to_f(c: Color) -> Rgba {
    [c.red() as f64 / 255.0, c.green() as f64 / 255.0, c.blue() as f64 / 255.0, c.alpha() as f64 / 255.0]
}

fn texel(src: &[Color], w: u32, x: i64, y: i64, h: u32) -> Rgba {
    let x = x.clamp(0, w as i64 - 1) as u32;
    let y = y.clamp(0, h as i64 - 1) as u32;
    to_f(src[(y * w + x) as usize])
}

fn model_sample(src: &[Color], w: u32, h: u32, u: f64, v: f64, smoothing: bool) -> Rgba {
    if !smoothing {
        return texel(src, w, u.floor() as i64, v.floor() as i64, h);
    }
    let x = u - 0.5;
    let y = v - 0.5;
    let (x0, y0) = (x.floor(), y.floor());
    let (fx, fy) = (x - x0, y - y0);
    let (x0, y0) = (x0 as i64, y0 as i64);
    let p00 = texel(src, w, x0, y0, h);
    let p10 = texel(src, w, x0 + 1, y0, h);
    let p01 = texel(src, w, x0, y0 + 1, h);
    let p11 = texel(src, w, x0 + 1, y0 + 1, h);
    let mut out = [0.0; 4];
    for k in 0..4 {
        out[k] = (p00[k] * (1.0 - fx) + p10[k] * fx) * (1.0 - fy) + (p01[k] * (1.0 - fx) + p11[k] * fx) * fy;
    }
    out
}

fn model_transform(c: Rgba, t: Option<&ColorTransform>) -> Rgba {
    let Some(t) = t else { return c };
    if c[3] <= 0.0 {
        return c;
    }
    let mult = t.mult_rgba_normalized();
    let add = t.add_rgba_normalized();
    let mut u = [c[0] / c[3], c[1] / c[3], c[2] / c[3], c[3]];
    for k in 0..4 {
        u[k] = (u[k] * mult[k] as f64 + add[k] as f64).clamp(0.0, 1.0);
    }
    [u[0] * u[3], u[1] * u[3], u[2] * u[3], u[3]]
}

fn model_blend(d: Rgba, s: Rgba, blend: CpuBlend) -> Rgba {
    let over = s[3] + d[3] * (1.0 - s[3]);
    match blend {
        CpuBlend::Normal => [s[0] + d[0] * (1.0 - s[3]), s[1] + d[1] * (1.0 - s[3]), s[2] + d[2] * (1.0 - s[3]), over],
        CpuBlend::Screen => [s[0] + d[0] * (1.0 - s[0]), s[1] + d[1] * (1.0 - s[1]), s[2] + d[2] * (1.0 - s[2]), over],
        CpuBlend::Add => [(s[0] + d[0]).min(1.0), (s[1] + d[1]).min(1.0), (s[2] + d[2]).min(1.0), over],
        CpuBlend::Subtract => [(d[0] - s[0]).max(0.0), (d[1] - s[1]).max(0.0), (d[2] - s[2]).max(0.0), over],
    }
}

struct Case {
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
    matrix: PixelMatrix,
    transform: Option<ColorTransform>,
    smoothing: bool,
    blend: CpuBlend,
    opaque: bool,
}

// Draws one case both ways; returns (pixels compared, worst channel difference, coverage mismatches away from edges).
fn run(rng: &mut Rng, case: &Case) -> (usize, i32, usize) {
    let src = bitmap(rng, case.sw, case.sh, true);
    let dest0 = bitmap(rng, case.dw, case.dh, !case.opaque);
    let mut dest = dest0.clone();
    let area = [0, 0, case.dw, case.dh];
    let ok = draw_bitmap(
        Pixels { pixels: &src, width: case.sw, height: case.sh },
        &mut dest,
        case.dw,
        case.opaque,
        area,
        case.matrix,
        case.transform.as_ref(),
        case.smoothing,
        case.blend,
    );
    assert!(ok);
    let m = case.matrix;
    let det = m.a * m.d - m.b * m.c;
    let mut worst = 0;
    let mut compared = 0;
    let mut mismatches = 0;
    for y in 0..case.dh {
        for x in 0..case.dw {
            let px = x as f64 + 0.5 - m.tx;
            let py = y as f64 + 0.5 - m.ty;
            let u = (m.d * px - m.c * py) / det;
            let v = (-m.b * px + m.a * py) / det;
            let inside = u >= 0.0 && v >= 0.0 && u < case.sw as f64 && v < case.sh as f64;
            let near_edge = [u, v, u - case.sw as f64, v - case.sh as f64].iter().any(|e| e.abs() < 1e-6);
            // A centre right on the line between two texels: either is right (the GPU's float maths picks one).
            let tie = |t: f64| (t - t.round()).abs() < 1e-6;
            let near_edge = near_edge || (!case.smoothing && (tie(u) || tie(v)));
            let i = (y * case.dw + x) as usize;
            let before = dest0[i];
            let after = dest[i];
            if !inside {
                if after != before && !near_edge {
                    mismatches += 1;
                    if std::env::var("DEBUG_DRAW").is_ok() {
                        println!("outside ({x}, {y}): u {u} v {v} sw {} sh {} matrix {:?} smoothing {} blend {:?} before {before:?} after {after:?}", case.sw, case.sh, m, case.smoothing, case.blend);
                    }
                }
                continue;
            }
            let s = model_sample(&src, case.sw, case.sh, u, v, case.smoothing);
            if near_edge {
                continue;
            }
            if (s[3] * 255.0).round() == 0.0 {
                if after != before && !case.smoothing {
                    mismatches += 1;
                    if std::env::var("DEBUG_DRAW").is_ok() {
                        println!("transparent ({x}, {y}): u {u} v {v} sw {} sh {} matrix {:?} blend {:?} before {before:?} after {after:?}", case.sw, case.sh, m, case.blend);
                    }
                }
                continue;
            }
            let s = model_transform(s, case.transform.as_ref());
            let mut out = model_blend(to_f(before), s, case.blend);
            if case.opaque {
                out[3] = 1.0;
            }
            let got = to_f(after);
            compared += 1;
            for k in 0..4 {
                let diff = ((out[k] - got[k]) * 255.0).round().abs() as i32;
                worst = worst.max(diff);
            }
        }
    }
    (compared, worst, mismatches)
}

fn random_matrix(rng: &mut Rng, sw: u32, sh: u32, dw: u32, dh: u32) -> PixelMatrix {
    let angle = match rng.below(4) {
        0 => 0.0,
        1 => std::f64::consts::FRAC_PI_2 * rng.below(4) as f64,
        _ => rng.unit() * std::f64::consts::TAU,
    };
    let sx = [1.0, -1.0, 2.0, -2.0, 0.5, 1.37, -0.73][rng.below(7) as usize];
    let sy = [1.0, 2.0, 0.5, 0.81, -1.0][rng.below(5) as usize];
    let (cos, sin) = (angle.cos(), angle.sin());
    // scale, then rotate, then move the middle of the source to somewhere in the target
    let a = cos * sx;
    let b = sin * sx;
    let c = -sin * sy;
    let d = cos * sy;
    let (cx, cy) = (sw as f64 / 2.0, sh as f64 / 2.0);
    let tx = dw as f64 * rng.unit() - (a * cx + c * cy);
    let ty = dh as f64 * rng.unit() - (b * cx + d * cy);
    // Twips: whole 1/20 pixels
    PixelMatrix { a, b, c, d, tx: (tx * 20.0).round() / 20.0, ty: (ty * 20.0).round() / 20.0 }
}

fn random_transform(rng: &mut Rng) -> Option<ColorTransform> {
    if rng.below(3) != 0 {
        return None;
    }
    let f = |rng: &mut Rng| Fixed8::from_f32((rng.below(512) as f32) / 256.0);
    let o = |rng: &mut Rng| rng.below(200) as i16 - 100;
    Some(ColorTransform {
        r_multiply: f(rng),
        g_multiply: f(rng),
        b_multiply: f(rng),
        a_multiply: f(rng),
        r_add: o(rng),
        g_add: o(rng),
        b_add: o(rng),
        a_add: o(rng),
    })
}

#[test]
fn random_draws_match_the_gpu_model() {
    let mut rng = Rng(0x9e3779b97f4a7c15);
    let blends = [CpuBlend::Normal, CpuBlend::Screen, CpuBlend::Add, CpuBlend::Subtract];
    let mut total = 0;
    let mut worst_by = [[0i32; 2]; 4];
    for round in 0..1000 {
        let sw = 1 + rng.below(40) as u32;
        let sh = 1 + rng.below(40) as u32;
        let dw = 8 + rng.below(80) as u32;
        let dh = 8 + rng.below(80) as u32;
        let case = Case {
            sw,
            sh,
            dw,
            dh,
            matrix: random_matrix(&mut rng, sw, sh, dw, dh),
            transform: random_transform(&mut rng),
            smoothing: rng.below(2) == 0,
            blend: blends[rng.below(4) as usize],
            opaque: rng.below(4) == 0,
        };
        let (compared, worst, mismatches) = run(&mut rng, &case);
        assert_eq!(mismatches, 0, "round {round}: pixels changed outside the drawn bitmap");
        total += compared;
        let b = blends.iter().position(|b| *b == case.blend).unwrap();
        let t = case.transform.is_some() as usize;
        worst_by[b][t] = worst_by[b][t].max(worst);
    }
    println!("compared {total} pixels; worst difference by blend [no transform, transform]: {worst_by:?}");
    assert!(total > 100000);
    for (b, worst) in worst_by.iter().enumerate() {
        // Normal uses Flash's own over (256-based), the colour transform Fixed8: a few steps at most.
        assert!(worst[0] <= 2, "blend {b}: {worst:?}");
        assert!(worst[1] <= 4, "blend {b}: {worst:?}");
    }
}

#[test]
fn a_plain_move_is_what_ruffles_cpu_copy_makes() {
    let mut rng = Rng(12345);
    for _ in 0..50 {
        let (sw, sh, dw, dh) = (1 + rng.below(30) as u32, 1 + rng.below(30) as u32, 40, 40);
        let src = bitmap(&mut rng, sw, sh, true);
        let dest0 = bitmap(&mut rng, dw, dh, true);
        let (ox, oy) = (rng.below(20) as u32, rng.below(20) as u32);
        let mut dest = dest0.clone();
        let matrix = PixelMatrix { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: ox as f64, ty: oy as f64 };
        assert!(draw_bitmap(Pixels { pixels: &src, width: sw, height: sh }, &mut dest, dw, false, [0, 0, dw, dh], matrix, None, false, CpuBlend::Normal));
        for y in 0..dh {
            for x in 0..dw {
                let i = (y * dw + x) as usize;
                let expected = if x >= ox && y >= oy && x - ox < sw && y - oy < sh {
                    dest0[i].blend_over(&src[((y - oy) * sw + (x - ox)) as usize])
                } else {
                    dest0[i]
                };
                assert_eq!(dest[i], expected, "({x}, {y})");
            }
        }
    }
}

#[test]
fn flips_scales_and_turns_land_where_flash_puts_them() {
    let w = 5;
    let h = 3;
    let src: Vec<Color> = (0..w * h).map(|k| Color::rgba(k as u8, 0, 0, 255)).collect();
    let pixels = Pixels { pixels: &src, width: w, height: h };
    let blank = || vec![Color::rgba(0, 0, 0, 0); 100];
    // Facing left: scale(-1, 1), then moved by its width.
    let mut dest = blank();
    let flip = PixelMatrix { a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 5.0, ty: 0.0 };
    assert!(draw_bitmap(pixels, &mut dest, 10, false, [0, 0, 10, 10], flip, None, false, CpuBlend::Normal));
    for y in 0..h {
        for x in 0..w {
            assert_eq!(dest[(y * 10 + x) as usize].red(), (y * w + (w - 1 - x)) as u8);
        }
    }
    assert_eq!(dest[5].alpha(), 0);
    // Twice as big: each source pixel is a 2×2 block.
    let mut dest = blank();
    let twice = PixelMatrix { a: 2.0, b: 0.0, c: 0.0, d: 2.0, tx: 0.0, ty: 0.0 };
    assert!(draw_bitmap(pixels, &mut dest, 10, false, [0, 0, 10, 10], twice, None, false, CpuBlend::Normal));
    for y in 0..2 * h {
        for x in 0..2 * w {
            assert_eq!(dest[(y * 10 + x) as usize].red(), (y / 2 * w + x / 2) as u8);
        }
    }
    // A quarter turn (rotate(90°): x' = -y, y' = x), moved back into view.
    let mut dest = blank();
    let turn = PixelMatrix { a: 0.0, b: 1.0, c: -1.0, d: 0.0, tx: 3.0, ty: 0.0 };
    assert!(draw_bitmap(pixels, &mut dest, 10, false, [0, 0, 10, 10], turn, None, false, CpuBlend::Normal));
    for sy in 0..h {
        for sx in 0..w {
            let (x, y) = (3 - 1 - sy, sx); // the source pixel's centre (sx+.5, sy+.5) lands at (3-sy-.5, sx+.5)
            assert_eq!(dest[(y * 10 + x) as usize].red(), (sy * w + sx) as u8, "source ({sx}, {sy})");
        }
    }
    // Half as big, smoothed: the mean of each 2×2 block.
    let src4: Vec<Color> = (0..16).map(|k| Color::rgba((k * 16) as u8, 0, 0, 255)).collect();
    let mut dest = blank();
    let half = PixelMatrix { a: 0.5, b: 0.0, c: 0.0, d: 0.5, tx: 0.0, ty: 0.0 };
    assert!(draw_bitmap(Pixels { pixels: &src4, width: 4, height: 4 }, &mut dest, 10, false, [0, 0, 10, 10], half, None, true, CpuBlend::Normal));
    for y in 0..2 {
        for x in 0..2 {
            let sum: u32 = [(0, 0), (1, 0), (0, 1), (1, 1)].iter().map(|(dx, dy)| ((2 * y + dy) * 4 + 2 * x + dx) * 16).sum();
            assert_eq!(dest[(y * 10 + x) as usize].red() as u32, (sum + 2) / 4, "({x}, {y})");
        }
    }
}

#[test]
fn what_is_not_drawn_stays() {
    let src = vec![Color::rgba(0, 0, 0, 0); 4];
    let dest0: Vec<Color> = (0..16).map(|k| Color::rgba(k, k, k, 255)).collect();
    // Fully transparent pixels stay as they were, even with a colour transform that adds alpha.
    let add_alpha = ColorTransform { a_add: 200, r_add: 50, ..ColorTransform::IDENTITY };
    for blend in [CpuBlend::Normal, CpuBlend::Screen, CpuBlend::Add, CpuBlend::Subtract] {
        let mut dest = dest0.clone();
        let m = PixelMatrix { a: 1.5, b: 0.3, c: -0.2, d: 1.1, tx: 0.5, ty: 0.5 };
        assert!(draw_bitmap(Pixels { pixels: &src, width: 2, height: 2 }, &mut dest, 4, true, [0, 0, 4, 4], m, Some(&add_alpha), true, blend));
        assert_eq!(dest, dest0);
    }
    // A matrix that squashes everything to a line draws nothing here (the GPU path decides).
    let mut dest = dest0.clone();
    let flat = PixelMatrix { a: 1.0, b: 2.0, c: 2.0, d: 4.0, tx: 0.0, ty: 0.0 };
    let red = vec![Color::rgba(255, 0, 0, 255); 4];
    assert!(!draw_bitmap(Pixels { pixels: &red, width: 2, height: 2 }, &mut dest, 4, true, [0, 0, 4, 4], flat, None, false, CpuBlend::Normal));
    assert_eq!(dest, dest0);
    // Only the area asked for changes.
    let mut dest = dest0.clone();
    let big = PixelMatrix { a: 3.0, b: 0.0, c: 0.0, d: 3.0, tx: 0.0, ty: 0.0 };
    assert!(draw_bitmap(Pixels { pixels: &red, width: 2, height: 2 }, &mut dest, 4, true, [1, 1, 3, 2], big, None, false, CpuBlend::Normal));
    for y in 0..4 {
        for x in 0..4 {
            let inside = (1..3).contains(&x) && y == 1;
            assert_eq!(dest[y * 4 + x] == red[0], inside, "({x}, {y})");
        }
    }
}

#[test]
fn screen_add_and_subtract_on_their_own() {
    let one = |c: Color| vec![c];
    let draw = |src: Color, dest: Color, blend: CpuBlend| {
        let s = one(src);
        let mut d = one(dest);
        let m = PixelMatrix { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };
        assert!(draw_bitmap(Pixels { pixels: &s, width: 1, height: 1 }, &mut d, 1, false, [0, 0, 1, 1], m, None, false, blend));
        d[0]
    };
    let grey = Color::rgba(128, 128, 128, 255);
    let white = Color::rgba(255, 255, 255, 255);
    let black = Color::rgba(0, 0, 0, 255);
    assert_eq!(draw(black, grey, CpuBlend::Screen), grey);
    assert_eq!(draw(white, grey, CpuBlend::Screen), white);
    assert_eq!(draw(grey, grey, CpuBlend::Screen), Color::rgba(192, 192, 192, 255));
    assert_eq!(draw(grey, grey, CpuBlend::Add), white);
    assert_eq!(draw(grey, white, CpuBlend::Subtract), Color::rgba(127, 127, 127, 255));
    // A glow (half transparent, premultiplied) screened over a transparent target keeps its colour.
    let glow = Color::rgba(100, 50, 0, 128);
    assert_eq!(draw(glow, Color::rgba(0, 0, 0, 0), CpuBlend::Screen), glow);
}

#[test]
fn screen_rounds_like_dividing_by_255() {
    // Every target and source value: a 1×1 Screen draw against round(d × (255 − s) / 255).
    for s in 0..=255u32 {
        for d in 0..=255u32 {
            let src = vec![Color::rgba(s as u8, 0, 0, 255)];
            let mut dest = vec![Color::rgba(d as u8, 0, 0, 255)];
            let m = PixelMatrix { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };
            assert!(draw_bitmap(Pixels { pixels: &src, width: 1, height: 1 }, &mut dest, 1, false, [0, 0, 1, 1], m, None, false, CpuBlend::Screen));
            let expected = s + (d * (255 - s) + 127) / 255;
            assert_eq!(dest[0].red() as u32, expected, "s {s} d {d}");
        }
    }
}

#[test]
fn extreme_draws_do_not_panic_or_spill() {
    // Matrices from almost nothing to huge, turned, skewed, far away; areas anywhere in the target.
    let mut rng = Rng(77);
    let scales = [1e-9, 1e-6, 0.001, 0.01, 0.3, 1.0, 3.0, 100.0, 5000.0, 1e7];
    for round in 0..20000 {
        let sw = 1 + rng.below(64) as u32;
        let sh = 1 + rng.below(64) as u32;
        let dw = 1 + rng.below(120) as u32;
        let dh = 1 + rng.below(120) as u32;
        let src: Vec<Color> = (0..sw * sh).map(|k| Color::rgba(k as u8, 7, 9, if k % 5 == 0 { 0 } else { 200 })).collect();
        let dest0: Vec<Color> = (0..dw * dh).map(|k| Color::rgba(1, 2, (k % 256) as u8, 255)).collect();
        let mut dest = dest0.clone();
        let s = |rng: &mut Rng| {
            let v = scales[rng.below(scales.len() as u64) as usize];
            if rng.below(2) == 0 { -v } else { v }
        };
        let angle = rng.unit() * std::f64::consts::TAU;
        let (sx, sy) = (s(&mut rng), s(&mut rng));
        let skew = if rng.below(4) == 0 { s(&mut rng) } else { 0.0 };
        let far = |rng: &mut Rng| (rng.unit() - 0.5) * 1e6 * if rng.below(3) == 0 { 1.0 } else { 1e-4 };
        let m = PixelMatrix {
            a: angle.cos() * sx,
            b: angle.sin() * sx,
            c: -angle.sin() * sy + skew,
            d: angle.cos() * sy,
            tx: far(&mut rng),
            ty: far(&mut rng),
        };
        let x0 = rng.below(dw as u64 + 1) as u32;
        let x1 = x0 + rng.below((dw - x0) as u64 + 1) as u32;
        let y0 = rng.below(dh as u64 + 1) as u32;
        let y1 = y0 + rng.below((dh - y0) as u64 + 1) as u32;
        let t = ColorTransform { a_multiply: Fixed8::from_f32(1.5), a_add: 40, ..ColorTransform::IDENTITY };
        let transform = if rng.below(3) == 0 { Some(&t) } else { None };
        let blend = [CpuBlend::Normal, CpuBlend::Screen, CpuBlend::Add, CpuBlend::Subtract][rng.below(4) as usize];
        let opaque = rng.below(2) == 0;
        let smoothing = rng.below(2) == 0;
        let _ = draw_bitmap(Pixels { pixels: &src, width: sw, height: sh }, &mut dest, dw, opaque, [x0, y0, x1, y1], m, transform, smoothing, blend);
        for y in 0..dh {
            for x in 0..dw {
                let i = (y * dw + x) as usize;
                if !(x >= x0 && x < x1 && y >= y0 && y < y1) {
                    assert_eq!(dest[i], dest0[i], "round {round}: ({x}, {y}) outside the area changed");
                }
            }
        }
    }
}

#[test]
fn colours_above_alpha_are_clamped_as_the_gpu_does() {
    // (255, 255, 255, 243), what Add leaves on a transparent target: the GPU's bitmap shader reads
    // it as (243, 243, 243, 243). Flipped over white, that is white (not a wrapped-around dark grey).
    let src = vec![Color::rgba(255, 255, 255, 243)];
    let flip = PixelMatrix { a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 1.0, ty: 0.0 };
    for smoothing in [false, true] {
        let mut dest = vec![Color::rgba(255, 255, 255, 255)];
        assert!(draw_bitmap(Pixels { pixels: &src, width: 1, height: 1 }, &mut dest, 1, false, [0, 0, 1, 1], flip, None, smoothing, CpuBlend::Normal));
        assert_eq!(dest[0], Color::rgba(255, 255, 255, 255), "smoothing {smoothing}");
    }
    // Added on black, (255, 0, 0, 100) gives the GPU's 100.
    let src = vec![Color::rgba(255, 0, 0, 100)];
    let mut dest = vec![Color::rgba(0, 0, 0, 255)];
    let twice = PixelMatrix { a: 2.0, b: 0.0, c: 0.0, d: 2.0, tx: 0.0, ty: 0.0 };
    assert!(draw_bitmap(Pixels { pixels: &src, width: 1, height: 1 }, &mut dest, 1, true, [0, 0, 1, 1], twice, None, false, CpuBlend::Add));
    assert_eq!(dest[0], Color::rgba(100, 0, 0, 255));
}

#[test]
fn any_pixels_at_all_never_overflow() {
    // Source and target pixels of any value, premultiplied or not (run.sh runs this with overflow checks).
    let mut rng = Rng(99);
    for _ in 0..20000 {
        let (sw, sh) = (1 + rng.below(6) as u32, 1 + rng.below(6) as u32);
        let (dw, dh) = (1 + rng.below(12) as u32, 1 + rng.below(12) as u32);
        let src: Vec<Color> = (0..sw * sh).map(|_| Color::from(rng.next() as u32)).collect();
        let mut dest: Vec<Color> = (0..dw * dh).map(|_| Color::from(rng.next() as u32)).collect();
        let m = [
            PixelMatrix { a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: sw as f64, ty: 0.0 },
            PixelMatrix { a: 1.7, b: 0.4, c: -0.3, d: 1.2, tx: 0.5, ty: 0.25 },
            PixelMatrix { a: 0.5, b: 0.0, c: 0.0, d: -0.5, tx: 1.0, ty: 3.0 },
        ][rng.below(3) as usize];
        let t = ColorTransform { r_add: 10, ..ColorTransform::IDENTITY };
        let transform = if rng.below(3) == 0 { Some(&t) } else { None };
        let blend = [CpuBlend::Normal, CpuBlend::Screen, CpuBlend::Add, CpuBlend::Subtract][rng.below(4) as usize];
        let (opaque, smoothing) = (rng.below(2) == 0, rng.below(2) == 0);
        assert!(draw_bitmap(Pixels { pixels: &src, width: sw, height: sh }, &mut dest, dw, opaque, [0, 0, dw, dh], m, transform, smoothing, blend));
    }
}
