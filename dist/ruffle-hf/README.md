# Ruffle for Hero Fighter

The site page runs Hero Fighter in [Ruffle](https://ruffle.rs) 0.7.1, built from its source by
`dist/build-web.sh` with one change, in these files:

- `draw_on_cpu.rs`: a new file, `core/src/bitmap/operations/draw_on_cpu.rs`.
- `operations.patch`: uses it in `draw` (`core/src/bitmap/operations.rs`).

`BitmapData.draw()` of a bitmap that is turned, flipped or scaled, or drawn with the Screen, Add or
Subtract blend mode, is done on the CPU when the target's pixels are there. Stock Ruffle draws it on
the GPU, and the next CPU operation on the target (`copyPixels`, `fillRect`, a plain `draw`) waits
for the GPU and copies the pixels back. Hero Fighter's frames are full of both: every fighter facing
left, every shadow and every effect, between `copyPixels` and `fillRect` calls, so stock Ruffle
spends most of its time in those copies (about 80% in a fight with five computer players, measured
on a computer without a graphics card). The CPU draws as the GPU does at low stage quality, which
the site sets: the source pixel under each target pixel's centre (bilinear with smoothing, edges
clamped), the colour transform of Ruffle's bitmap shader (which also keeps every colour at most its
alpha), the GPU's fixed blend states. (At higher qualities the GPU smooths the edges of a turned
bitmap; the CPU does not. A pixel centre exactly on the edge of a flipped bitmap may go to the other
side of it.)

`Dockerfile` builds Ruffle's self-hosted package with the tools of Ruffle 0.7.1's own release (Node.js
24, Rust stable, wasm-bindgen 0.2.127, Binaryen 129, Java for Ruffle's ActionScript compiler). The
build takes about 20 minutes; if it fails, the site keeps the stock Ruffle 0.7.1 only (`RUFFLE_HF=0`
skips it), and on GitHub the run's page shows a warning with the build's errors. When it builds, the
site has the changed Ruffle in `ruffle/` (with `OPENLF2.txt`) and the stock one in `ruffle-stock/`,
which the page uses when its address has `ruffle=stock` (every game in a network room must run the
same one).

`test/run.sh` tests the change without building Ruffle: `draw_on_cpu.rs` against a model of what
the GPU draws, compiled with Ruffle's own colour and geometry code, and the patch's lines compiled
against stand-ins with Ruffle's signatures.
