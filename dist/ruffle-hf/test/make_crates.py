# SPDX-License-Identifier: MIT
#
# Makes the Cargo workspace run.sh tests in, from a (patched, sparse) Ruffle 0.7.1 checkout:
#   swf      Ruffle's own Color, ColorTransform, Fixed8, Twips, Point and Rectangle files (and BlendMode)
#   harness  draw_on_cpu.rs as it sits in Ruffle (with Ruffle's Color), and the tests in draw.rs
#   glue     the patch's lines in `draw` (from the patched operations.rs), compiled against stand-ins
#            with the signatures Ruffle 0.7.1 has, and Ruffle's own PixelRegion
#   python3 make_crates.py <ruffle checkout> <output folder> <draw.rs>
import os
import re
import sys

ruffle, out, tests = sys.argv[1:4]


def read(*parts):
    with open(os.path.join(ruffle, *parts), encoding='utf-8') as f:
        return f.read()


def write(path, text):
    path = os.path.join(out, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


types = os.path.join(os.path.abspath(ruffle), 'swf', 'src', 'types')
operations = os.path.join(os.path.abspath(ruffle), 'core', 'src', 'bitmap', 'operations')

write('Cargo.toml', '[workspace]\nmembers = ["swf", "harness", "glue"]\nresolver = "2"\n')
for name, deps in (('swf', ''), ('harness', 'swf = { path = "../swf" }\n'), ('glue', 'swf = { path = "../swf" }\n')):
    write(f'{name}/Cargo.toml', f'[package]\nname = "{name}"\nversion = "0.0.0"\nedition = "2024"\n\n[dependencies]\n{deps}')

# BlendMode as swf/src/types.rs has it (without its derives from other crates).
types_rs = read('swf', 'src', 'types.rs')
blend = re.search(r'pub enum BlendMode \{.*?\n\}\n', types_rs, re.S).group(0)
modules = ''.join(f'    #[path = "{types}/{name}.rs"]\n    pub mod {name};\n'
                  for name in ('color', 'fixed', 'color_transform', 'twips', 'point', 'rectangle'))
write('swf/src/lib.rs', f'''pub mod types {{
{modules}}}
pub use types::color::Color;
pub use types::color_transform::ColorTransform;
pub use types::fixed::{{Fixed8, Fixed16}};
pub use types::point::{{Point, PointDelta}};
pub use types::rectangle::Rectangle;
pub use types::twips::Twips;

#[derive(Default, Clone, Copy, Debug, Eq, PartialEq)]
{blend}''')

# Ruffle's Color, from core/src/bitmap/bitmap_data.rs (without bytemuck).
bitmap_data = read('core', 'src', 'bitmap', 'bitmap_data.rs')
start = bitmap_data.index('/// This can represent both a premultiplied')
end = bitmap_data.index('\n}\n', bitmap_data.index('impl From<Color> for swf::Color {')) + 3
color = bitmap_data[start:end].replace(', bytemuck::NoUninit', '')
color = re.sub(r'\n    fn slice_as_rgba\(slice: &\[Self\]\) -> &\[u8\] \{\n        bytemuck::cast_slice\(slice\)\n    \}\n', '\n', color)
color = re.sub(r'#\[derive\(Debug, Clone\)\]\npub enum BitmapDataDrawError \{\n    Unimplemented,\n\}\n', '', color)
write('harness/src/color.rs', color)
write('harness/src/lib.rs', f'''pub mod bitmap {{
    pub mod bitmap_data {{
        include!("color.rs");
    }}
    pub mod operations {{
        #[path = "{operations}/draw_on_cpu.rs"]
        pub mod draw_on_cpu;
    }}
}}
''')
with open(tests, encoding='utf-8') as f:
    write('harness/tests/draw.rs', f.read())

# The glue: Ruffle's PixelRegion (render/src/bitmap.rs) and the patched lines of `draw`.
bitmap_rs = read('render', 'src', 'bitmap.rs')
start = bitmap_rs.rfind('\n\n', 0, bitmap_rs.index('fn intersection_same_coordinate_system(')) + 2
end = bitmap_rs.index('#[cfg(test)]', bitmap_rs.index('pub struct PixelRegion'))
pixel_region = bitmap_rs[start:end]
ops = read('core', 'src', 'bitmap', 'operations.rs')
start = ops.index('        // OpenLF2: any other draw of a bitmap')
end = ops.index('\n    }\n\n    let mut transform_stack', start)
glue = '\n'.join(('    ' + line) if line else '' for line in (ops[start:end] + '\n').split('\n'))
indented_color = '\n'.join(('        ' + line) if line else '' for line in color.split('\n'))
write('glue/src/lib.rs', f'''#![allow(dead_code, unused_variables, unused_mut)]

pub mod gc {{
    use std::marker::PhantomData;
    pub struct Mutation<'gc>(PhantomData<&'gc ()>);
    // gc-arena's GcRefLock<'gc, T> (Gc<'gc, RefLock<T>>): Copy; borrow_mut(self, &Mutation) -> RefMut<'gc, T>
    pub struct GcRefLock<'gc, T: 'gc>(pub &'gc std::cell::RefCell<T>);
    impl<'gc, T> Clone for GcRefLock<'gc, T> {{ fn clone(&self) -> Self {{ *self }} }}
    impl<'gc, T> Copy for GcRefLock<'gc, T> {{}}
    impl<'gc, T> GcRefLock<'gc, T> {{
        pub fn borrow(self) -> std::cell::Ref<'gc, T> {{ self.0.borrow() }}
        pub fn borrow_mut(self, _mc: &Mutation<'gc>) -> std::cell::RefMut<'gc, T> {{ self.0.borrow_mut() }}
    }}
}}

pub mod render {{
    use swf::{{Rectangle, Twips}};
    pub trait RenderBackend {{}}
    pub struct Matrix {{ pub a: f32, pub b: f32, pub c: f32, pub d: f32, pub tx: Twips, pub ty: Twips }}
    pub struct Transform {{ pub matrix: Matrix, pub tz: f64, pub color_transform: swf::ColorTransform }}
    #[derive(Clone, Copy)]
    pub enum StageQuality {{ Low, High }}
{pixel_region}}}

pub mod context {{
    use crate::gc::Mutation;
    use crate::render::RenderBackend;
    pub struct UpdateContext<'gc> {{
        pub gc_context: &'gc Mutation<'gc>,
        pub renderer: &'gc mut dyn RenderBackend,
    }}
    impl<'gc> UpdateContext<'gc> {{
        pub fn gc(&self) -> &'gc Mutation<'gc> {{ self.gc_context }}
    }}
}}

pub mod bitmap {{
    pub mod bitmap_data {{
{indented_color}
        use crate::gc::{{GcRefLock, Mutation}};
        use crate::render::{{PixelRegion, RenderBackend}};
        use std::cell::Ref;
        use std::marker::PhantomData;

        #[derive(Debug, Clone)]
        pub enum BitmapDataDrawError {{ Unimplemented }}

        pub struct BitmapRawData<'gc> {{ pixels: Vec<Color>, width: u32, height: u32, transparency: bool, gc: PhantomData<&'gc ()> }}
        impl<'gc> BitmapRawData<'gc> {{
            pub fn width(&self) -> u32 {{ self.width }}
            pub fn height(&self) -> u32 {{ self.height }}
            pub fn transparency(&self) -> bool {{ self.transparency }}
            pub fn raw_pixels(&self) -> &[Color] {{ &self.pixels }}
            pub fn raw_pixels_mut(&mut self) -> &mut Vec<Color> {{ &mut self.pixels }}
            pub fn set_cpu_dirty(&mut self, gc_context: &Mutation<'gc>, region: PixelRegion) {{}}
        }}

        #[derive(Clone, Copy)]
        pub struct BitmapData<'gc>(GcRefLock<'gc, BitmapRawData<'gc>>);
        impl<'gc> BitmapData<'gc> {{
            pub fn width(&self) -> u32 {{ self.0.borrow().width }}
            pub fn height(&self) -> u32 {{ self.0.borrow().height }}
            pub fn transparency(&self) -> bool {{ self.0.borrow().transparency }}
            pub fn can_read(&self, read_area: PixelRegion) -> bool {{ true }}
            pub fn ptr_eq(&self, other: BitmapData<'gc>) -> bool {{ std::ptr::eq(self.0.0, other.0.0) }}
            pub fn sync(&self, renderer: &mut dyn RenderBackend) -> GcRefLock<'gc, BitmapRawData<'gc>> {{ self.0 }}
            pub fn read_area(&self, read_area: PixelRegion, renderer: &mut dyn RenderBackend) -> Ref<'_, BitmapRawData<'gc>> {{ self.0.borrow() }}
        }}

        pub enum IBitmapDrawable<'gc> {{
            BitmapData(BitmapData<'gc>),
            DisplayObject(PhantomData<&'gc ()>),
        }}
    }}

    pub mod operations {{
        use crate::bitmap::bitmap_data::{{BitmapData, BitmapDataDrawError, IBitmapDrawable}};
        use crate::context::UpdateContext;
        use crate::render::{{PixelRegion, StageQuality, Transform}};
        use swf::{{BlendMode, ColorTransform, Rectangle, Twips}};

        #[path = "{operations}/draw_on_cpu.rs"]
        mod draw_on_cpu;

        #[allow(clippy::too_many_arguments)]
        pub fn draw<'gc>(
            context: &mut UpdateContext<'gc>,
            target: BitmapData<'gc>,
            mut source: IBitmapDrawable<'gc>,
            transform: Transform,
            smoothing: bool,
            blend_mode: BlendMode,
            clip_rect: Option<Rectangle<Twips>>,
            quality: StageQuality,
        ) -> Result<(), BitmapDataDrawError> {{
            let mut dirty_region = PixelRegion::for_whole_size(target.width(), target.height());
            dirty_region.clamp(target.width(), target.height());
            if let IBitmapDrawable::BitmapData(source) = &source {{
{glue}
            }}
            // What the GPU path does with these afterwards, with the same borrows.
            match &mut source {{
                IBitmapDrawable::BitmapData(data) => {{}}
                IBitmapDrawable::DisplayObject(object) => {{}}
            }}
            dirty_region.union(PixelRegion::for_whole_size(1, 1));
            let _ = (transform.matrix.a, &transform.color_transform, smoothing, quality, clip_rect.map(|c| c.x_min));
            Ok(())
        }}
    }}
}}
''')
