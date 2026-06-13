mac os x gui for converting raster images to vector

paste or drag a bitmap in.
command-c or command-s to get a svg out.
space bar to pan / hide control points
z to zoom tool
v to cursor tool
w to magic wand lasso — drag around shapes, scroll to set the size cutoff so only small shapes stay selected

delete / command-z to delete shapes you dont want or undo that.

## Third-party software

This repo bundles prebuilt binaries from other projects:

- **[vtracer](https://github.com/visioncortex/vtracer)** — the raster-to-vector tracing engine. MIT licensed; see [licenses/vtracer-MIT.txt](licenses/vtracer-MIT.txt).
- **[upscayl-ncnn](https://github.com/upscayl/upscayl-ncnn)** (`upscayl-bin`) — the AI upscaling engine from [Upscayl](https://github.com/upscayl/upscayl), used for the optional pre-trace upscale step. AGPL-3.0 licensed; see [licenses/upscayl-ncnn-AGPL-3.0.txt](licenses/upscayl-ncnn-AGPL-3.0.txt). The bundled binary is unmodified; its source is available at the link above.
- **digital-art-4x model** — the "Digital Art" upscaling model from the [Upscayl](https://github.com/upscayl/upscayl) project (AGPL-3.0).

Code in this repo is MIT licensed (see [LICENSE](LICENSE)).
