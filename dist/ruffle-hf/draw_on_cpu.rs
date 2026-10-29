// SPDX-License-Identifier: MIT OR Apache-2.0
//
// OpenLF2's addition to Ruffle (core/src/bitmap/operations/draw_on_cpu.rs, used by `draw` in
// operations.rs): `BitmapData.draw()` of a bitmap with any transform, on the CPU.
//
// Ruffle draws a bitmap into a `BitmapData` on the CPU only when it is moved without being
// scaled, turned or flipped (`copy_on_cpu`). Anything else is drawn on the GPU, and the next CPU
// operation on the target (`copyPixels`, `fillRect`, `getPixel`, a moved-only `draw`) waits for
// the GPU and copies the pixels back. A game that mixes the two all through each frame (Hero
// Fighter draws every fighter facing left, every shadow and every effect that way, between
// `copyPixels` and `fillRect` calls) spends most of its time waiting for those copies. When both
// bitmaps' pixels are on the CPU, this draws such a bitmap there instead, as the GPU does: each
// target pixel whose centre falls on the source takes the source pixel under that centre (with
// smoothing, the bilinear mix of the four around it, edges clamped), with the colour transform
// applied as the GPU's bitmap shader applies it, blended as the GPU's fixed blend states blend.

use crate::bitmap::bitmap_data::Color;
use swf::{BlendMode, ColorTransform};

/// The blend modes drawn here; the others need the GPU's blend shaders.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CpuBlend {
    /// Normal and Layer: the source over the target.
    Normal,
    /// Screen: each colour `s + d × (1 − s)`; alpha as Normal.
    Screen,
    /// Add: each colour `s + d`, at most 1; alpha as Normal.
    Add,
    /// Subtract: each colour `d − s`, at least 0; alpha as Normal.
    Subtract,
}

impl CpuBlend {
    pub fn for_mode(mode: BlendMode) -> Option<Self> {
        match mode {
            BlendMode::Normal | BlendMode::Layer => Some(CpuBlend::Normal),
            BlendMode::Screen => Some(CpuBlend::Screen),
            BlendMode::Add => Some(CpuBlend::Add),
            BlendMode::Subtract => Some(CpuBlend::Subtract),
            _ => None,
        }
    }
}

/// Where a source pixel lands, in pixels: `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`.
#[derive(Clone, Copy, Debug)]
pub struct PixelMatrix {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}

/// A bitmap's pixels (premultiplied, row after row).
#[derive(Clone, Copy)]
pub struct Pixels<'a> {
    pub pixels: &'a [Color],
    pub width: u32,
    pub height: u32,
}

/// Whether `draw_bitmap` draws through `matrix`: one it can invert, which does not shrink a source
/// pixel to almost nothing (the source positions step along a target row in fixed point, 32 bits
/// after the point). The GPU path decides what other matrices draw.
pub fn can_draw(matrix: &PixelMatrix) -> bool {
    let determinant = matrix.a * matrix.d - matrix.b * matrix.c;
    if !determinant.is_finite() || determinant.abs() < 1e-12 {
        return false;
    }
    (matrix.d / determinant).abs() < 1e6
        && (matrix.b / determinant).abs() < 1e6
        && (matrix.c / determinant).is_finite()
        && (matrix.a / determinant).is_finite()
}

/// Draws `source` through `matrix` on `target` (`target_width` pixels a row), in the target pixels
/// `area` = `[x_min, y_min, x_max, y_max]` (inside the target) only. Returns false, having changed
/// nothing, when `can_draw` refuses the matrix.
#[expect(clippy::too_many_arguments)]
pub fn draw_bitmap(
    source: Pixels<'_>,
    target: &mut [Color],
    target_width: u32,
    opaque_target: bool,
    area: [u32; 4],
    matrix: PixelMatrix,
    color_transform: Option<&ColorTransform>,
    smoothing: bool,
    blend: CpuBlend,
) -> bool {
    if !can_draw(&matrix) {
        return false;
    }
    // The source point under a target point: the inverse matrix applied to (point - translation).
    let determinant = matrix.a * matrix.d - matrix.b * matrix.c;
    let du_dx = matrix.d / determinant;
    let du_dy = -matrix.c / determinant;
    let dv_dx = -matrix.b / determinant;
    let dv_dy = matrix.a / determinant;
    if source.width == 0 || source.height == 0 {
        return true;
    }
    let source_width = f64::from(source.width);
    let source_height = f64::from(source.height);
    let step_u = to_fixed(du_dx);
    let step_v = to_fixed(dv_dx);
    let [x_min, y_min, x_max, y_max] = area;
    let columns = x_max.saturating_sub(x_min);
    let plain = !smoothing && color_transform.is_none();
    for y in y_min..y_max {
        let from_x = f64::from(x_min) + 0.5 - matrix.tx;
        let from_y = f64::from(y) + 0.5 - matrix.ty;
        let u = du_dx * from_x + du_dy * from_y;
        let v = dv_dx * from_x + dv_dy * from_y;
        // The pixels of this row on the source (a pixel more each side: each is checked below).
        let (first_u, end_u) = span(u, du_dx, source_width, columns);
        let (first_v, end_v) = span(v, dv_dx, source_height, columns);
        let first = first_u.max(first_v);
        let end = end_u.min(end_v);
        if first >= end {
            continue;
        }
        let mut fu = to_fixed(u + du_dx * f64::from(first));
        let mut fv = to_fixed(v + dv_dx * f64::from(first));
        let row = y as usize * target_width as usize + x_min as usize;
        let pixels = &mut target[row + first as usize..row + end as usize];
        if plain {
            for pixel in pixels {
                // A negative position shifts to a negative whole part, far above the size as u64.
                let column = (fu >> 32) as u64;
                let line = (fv >> 32) as u64;
                fu += step_u;
                fv += step_v;
                if column < u64::from(source.width) && line < u64::from(source.height) {
                    let texel = clamp_to_alpha(source.pixels[line as usize * source.width as usize + column as usize]);
                    let alpha = texel.alpha();
                    if alpha == 255 && blend == CpuBlend::Normal {
                        *pixel = texel;
                    } else if alpha != 0 {
                        let blended = blend_pixel(*pixel, texel, blend);
                        *pixel = if opaque_target { blended.with_alpha(255) } else { blended };
                    }
                }
            }
            continue;
        }
        for pixel in pixels {
            let column = (fu >> 32) as u64;
            let line = (fv >> 32) as u64;
            let (at_u, at_v) = (fu, fv);
            fu += step_u;
            fv += step_v;
            if column >= u64::from(source.width) || line >= u64::from(source.height) {
                continue;
            }
            // The GPU leaves fully transparent texels as they are, colour transform or not.
            let color = if smoothing {
                let mixed = sample_bilinear(source, at_u, at_v);
                match color_transform {
                    _ if mixed[3] == 0 => None,
                    Some(transform) => Some(apply_color_transform(
                        mixed.map(|c| c as f32 / (255.0 * 65536.0)),
                        transform,
                    )),
                    None => Some(clamp_to_alpha(Color::rgba(
                        round_mixed(mixed[0]),
                        round_mixed(mixed[1]),
                        round_mixed(mixed[2]),
                        round_mixed(mixed[3]),
                    ))),
                }
            } else {
                let texel = source.pixels[line as usize * source.width as usize + column as usize];
                match color_transform {
                    _ if texel.alpha() == 0 => None,
                    Some(transform) => Some(apply_color_transform(
                        [texel.red(), texel.green(), texel.blue(), texel.alpha()]
                            .map(|c| f32::from(c) / 255.0),
                        transform,
                    )),
                    None => Some(clamp_to_alpha(texel)),
                }
            };
            if let Some(color) = color {
                let blended = blend_pixel(*pixel, color, blend);
                *pixel = if opaque_target { blended.with_alpha(255) } else { blended };
            }
        }
    }
    true
}

const ONE: f64 = 4294967296.0; // 1.0 in the fixed point below

fn to_fixed(value: f64) -> i64 {
    (value * ONE).round() as i64
}

/// The steps `k` in `0..count` (as `first..end`) where `start + step × k` may be in `0..size`,
/// with a step to spare at each end.
fn span(start: f64, step: f64, size: f64, count: u32) -> (u32, u32) {
    let count_f = f64::from(count);
    let (low, high) = if step > 0.0 {
        ((0.0 - start) / step, (size - start) / step)
    } else if step < 0.0 {
        ((size - start) / step, (0.0 - start) / step)
    } else if start >= 0.0 && start < size {
        (0.0, count_f)
    } else {
        return (0, 0);
    };
    let first = (low.floor() - 1.0).clamp(0.0, count_f) as u32;
    let end = (high.ceil() + 1.0).clamp(0.0, count_f) as u32;
    (first, end)
}

/// The bilinear mix of the four source pixels around the fixed-point position `(u, v)`, as a GPU
/// sampler with linear filtering and clamped edges reads it: premultiplied RGBA, each
/// 0..=255 × 65536.
fn sample_bilinear(source: Pixels<'_>, u: i64, v: i64) -> [u32; 4] {
    // Texel centres are at .5: the mix is between the texels around (u - .5, v - .5).
    let x = u - (1 << 31);
    let y = v - (1 << 31);
    let wx = ((x >> 24) & 0xff) as u32;
    let wy = ((y >> 24) & 0xff) as u32;
    let last_x = i64::from(source.width) - 1;
    let last_y = i64::from(source.height) - 1;
    let x0 = x >> 32;
    let y0 = y >> 32;
    let left = x0.clamp(0, last_x) as usize;
    let right = (x0 + 1).clamp(0, last_x) as usize;
    let top = y0.clamp(0, last_y) as usize * source.width as usize;
    let bottom = (y0 + 1).clamp(0, last_y) as usize * source.width as usize;
    let p00 = source.pixels[top + left];
    let p10 = source.pixels[top + right];
    let p01 = source.pixels[bottom + left];
    let p11 = source.pixels[bottom + right];
    let mix = |c00: u8, c10: u8, c01: u8, c11: u8| -> u32 {
        let upper = u32::from(c00) * (256 - wx) + u32::from(c10) * wx;
        let lower = u32::from(c01) * (256 - wx) + u32::from(c11) * wx;
        upper * (256 - wy) + lower * wy
    };
    [
        mix(p00.red(), p10.red(), p01.red(), p11.red()),
        mix(p00.green(), p10.green(), p01.green(), p11.green()),
        mix(p00.blue(), p10.blue(), p01.blue(), p11.blue()),
        mix(p00.alpha(), p10.alpha(), p01.alpha(), p11.alpha()),
    ]
}

/// What the GPU's bitmap shader does to every texel with alpha, even with no colour transform
/// (unmultiply, clamp to 0..1, premultiply): no colour above its alpha. Pixels with more (a bitmap
/// drawn with Add has them, so may a picture in the movie) would otherwise overflow the blending.
#[inline(always)]
fn clamp_to_alpha(color: Color) -> Color {
    let alpha = color.alpha();
    Color::rgba(color.red().min(alpha), color.green().min(alpha), color.blue().min(alpha), alpha)
}

fn round_mixed(channel: u32) -> u8 {
    ((channel + 32768) >> 16) as u8
}

/// What the GPU's bitmap shader does with a colour transform: unmultiply the (premultiplied, 0..1)
/// colour, multiply and add, clamp to 0..1, premultiply again.
fn apply_color_transform(color: [f32; 4], transform: &ColorTransform) -> Color {
    let multiply = transform.mult_rgba_normalized();
    let add = transform.add_rgba_normalized();
    let alpha = color[3];
    let channel = |k: usize, value: f32| (value * multiply[k] + add[k]).clamp(0.0, 1.0);
    let a = channel(3, alpha);
    let to_byte = |value: f32| (value * 255.0 + 0.5) as u8;
    Color::rgba(
        to_byte(channel(0, color[0] / alpha) * a),
        to_byte(channel(1, color[1] / alpha) * a),
        to_byte(channel(2, color[2] / alpha) * a),
        to_byte(a),
    )
}

/// `source` (premultiplied) blended onto `target` (premultiplied).
#[inline(always)]
fn blend_pixel(target: Color, source: Color, blend: CpuBlend) -> Color {
    // The GPU's `OneMinusSrc` factors: x × (255 − s) / 255, rounded.
    let scaled = |x: u8, s: u8| {
        // round(t / 255) without dividing (exact for every t up to 255 × 255)
        let t = u32::from(x) * (255 - u32::from(s)) + 128;
        ((t + (t >> 8)) >> 8) as u8
    };
    let alpha = source.alpha() + scaled(target.alpha(), source.alpha());
    match blend {
        CpuBlend::Normal => target.blend_over(&source),
        CpuBlend::Screen => Color::rgba(
            source.red() + scaled(target.red(), source.red()),
            source.green() + scaled(target.green(), source.green()),
            source.blue() + scaled(target.blue(), source.blue()),
            alpha,
        ),
        CpuBlend::Add => Color::rgba(
            source.red().saturating_add(target.red()),
            source.green().saturating_add(target.green()),
            source.blue().saturating_add(target.blue()),
            alpha,
        ),
        CpuBlend::Subtract => Color::rgba(
            target.red().saturating_sub(source.red()),
            target.green().saturating_sub(source.green()),
            target.blue().saturating_sub(source.blue()),
            alpha,
        ),
    }
}
