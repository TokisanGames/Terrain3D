#!/usr/bin/env python3
"""Authors the two water detail textures. Spec: PASTURE3D_WATER_SHADER_SPEC.md 3.3, 3.6.

    python tools/gen_water_textures.py

Writes, into project/addons/pasture_3d/extras/shaders/water/:

    T_water_deriv.png   512^2 RGB8, RG = (dh/dx, dh/dz) remapped to [0,1], B = 0
    T_water_foam.png    256^2 RGB8, R = breakup mask, G = B = 0

The blue/green zeroing is not cosmetic. Godot picks a VRAM format from the
channels it can see in the source image (Image::detect_used_channels), so RG-only
is what gets RGTC_RG (BC5) and R-only is what gets RGTC_R (BC4). A stray non-zero
blue byte silently demotes the derivative map to DXT5 -- four times the memory and
a visibly worse gradient. The .import files pin channel_pack=Optimized for the
same reason; the sRGB-friendly default forces every channel on.

Both fields are built spectrally on a periodic grid, which is what makes them
tile: an FFT-synthesised field is periodic by construction, so there is no seam
to hide and no cross-fade to blur the result. Derivatives are taken in the
frequency domain (multiply by i*k) rather than by differencing texels, so what
ships is the exact derivative of the height field rather than a finite-difference
approximation of it -- the whole point of a derivative map is that its values
compose by addition, and an approximated derivative accumulates that error twice
per pixel once two layers are summed.

No PIL: numpy is available in this environment and PIL is not, so the PNG writer
below is the minimum that produces a valid 8-bit RGB file.
"""

import os
import struct
import zlib

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(
    HERE, os.pardir, "project", "addons", "pasture_3d", "extras", "shaders", "water"
)

# The derivative map is authored as if it covers this many metres. Nothing in the
# shader knows this number -- detail_scale is a uniform -- but the spectrum has to
# be chosen against some physical scale or "ripple" is meaningless. The shader's
# default detail_scale0 is 1/DERIV_TILE_M so the defaults agree with the artwork.
DERIV_TILE_M = 10.0
# RMS height of the authored ripple field, in metres. Wind ripples on open water
# run about a centimetre; this is what turns the spectrum's arbitrary units into a
# real slope, and therefore what makes detail_strength = 1.0 mean "the ripples as
# authored" rather than an arbitrary number the artist has to discover.
DERIV_RMS_HEIGHT_M = 0.012

DERIV_SIZE = 512
FOAM_SIZE = 256

SEED = 20260727


def write_png(path, rgb):
    """rgb: (h, w, 3) uint8."""
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(tag, data):
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def radial_wavenumbers(n):
    """|k| in cycles-per-tile for an n x n rfft2-shaped grid, plus the kx/ky grids."""
    fy = np.fft.fftfreq(n) * n  # cycles per tile, signed
    fx = np.fft.rfftfreq(n) * n
    ky, kx = np.meshgrid(fy, fx, indexing="ij")
    return kx, ky, np.sqrt(kx * kx + ky * ky)


def spectral_field(n, rng, amplitude_of_k):
    """Real periodic field from an isotropic amplitude spectrum, unit variance."""
    kx, ky, k = radial_wavenumbers(n)
    amp = amplitude_of_k(k)
    # White complex noise shaped by the spectrum. Building it in the half-spectrum
    # and using irfft2 guarantees a real result without having to enforce
    # Hermitian symmetry by hand.
    noise = rng.normal(size=k.shape) + 1j * rng.normal(size=k.shape)
    spec = noise * amp
    spec[0, 0] = 0.0  # no DC: a derivative map with a bias tilts the whole surface
    field = np.fft.irfft2(spec, s=(n, n))
    return field / field.std(), spec


def taper(k, lo, hi):
    """Smoothstep band-pass window on |k|, zero outside [lo, hi]."""
    t = np.clip((k - lo[0]) / max(lo[1] - lo[0], 1e-6), 0.0, 1.0)
    lo_w = t * t * (3.0 - 2.0 * t)
    t = np.clip((hi[1] - k) / max(hi[1] - hi[0], 1e-6), 0.0, 1.0)
    hi_w = t * t * (3.0 - 2.0 * t)
    return lo_w * hi_w


def make_derivative_map():
    n = DERIV_SIZE
    rng = np.random.default_rng(SEED)

    # Band, in cycles per tile: with a 10 m tile, k = 6 is a 1.7 m feature and k = 64
    # is 16 cm. Two ends, two different reasons.
    #
    # The low end is held back hard because this texture tiles. Any energy at k < 5
    # is a feature more than two metres across, which survives into the low mips and
    # turns the repeat into a visible plaid the moment the camera pulls back -- and
    # that scale is the Gerstner table's job anyway (3.1 floors it at 10 m), so
    # keeping it here would double-count the swell as well as advertise the tile.
    #
    # The high end stops at 64: eight texels per period at 512, so the base mip is
    # not already aliasing before the mip chain has a chance to filter anything.
    #
    # The k^-1.35 slope is flatter than a Phillips spectrum on purpose. Phillips is
    # right for a height field being displaced; this is a derivative field, and
    # differentiating multiplies by k, so a spectrum tuned to look correct as height
    # comes out low-frequency-heavy as slope.
    def amplitude_of_k(k):
        with np.errstate(divide="ignore", invalid="ignore"):
            a = np.where(k > 0, k ** -1.35, 0.0)
        return a * taper(k, (3.0, 7.0), (56.0, 76.0))

    height, _ = spectral_field(n, rng, amplitude_of_k)

    # Sharpen crests, round troughs. Real water is not Gaussian -- the nonlinearity
    # is what makes a ripple field read as water rather than as bumpy noise -- and
    # the cheapest honest version of it is a quadratic skew. Applied to the height
    # and then differentiated, so the derivative stays exact for the field that was
    # actually authored.
    height = height + 0.25 * (height * height - 1.0)
    height *= DERIV_RMS_HEIGHT_M / height.std()

    spec = np.fft.rfft2(height)
    kx, ky, k = radial_wavenumbers(n)
    # d/dx of exp(i*2*pi*k*x/L) is (i*2*pi*k/L). The tile is DERIV_TILE_M across, so
    # these come out as slope in metres per metre -- a real physical quantity, which
    # is what lets the shader's detail_strength mean something.
    scale = 2.0 * np.pi / DERIV_TILE_M
    ddx = np.fft.irfft2(1j * kx * scale * spec, s=(n, n))
    ddy = np.fft.irfft2(1j * ky * scale * spec, s=(n, n))

    # Normalise so the tail, not the peak, sets full scale: matching the single
    # largest slope in the tile would spend most of the 8-bit range on nothing and
    # quantise everything that is actually visible. 0.5% of texels clip, which on a
    # derivative map shows up as a slightly flattened crest, not as a seam or a
    # discontinuity.
    d = np.stack([ddx, ddy], axis=-1)
    full_scale = np.percentile(np.abs(d), 99.5)
    clipped = float(np.mean(np.abs(d) > full_scale))
    d = np.clip(d / full_scale, -1.0, 1.0)

    rgb = np.zeros((n, n, 3), dtype=np.uint8)
    rgb[..., 0] = np.round((d[..., 0] * 0.5 + 0.5) * 255.0).astype(np.uint8)
    rgb[..., 1] = np.round((d[..., 1] * 0.5 + 0.5) * 255.0).astype(np.uint8)
    # rgb[..., 2] stays 0 -- see the module docstring.

    stored_rms = float(np.sqrt((d ** 2).mean()))
    print(
        "T_water_deriv: %d^2, tile %.1f m, full-scale slope %.3f m/m, "
        "rms %.3f, %.2f%% clipped"
        % (n, DERIV_TILE_M, full_scale, stored_rms, clipped * 100.0)
    )
    # The normalisation above is the one thing about this texture the shader cannot
    # recover on its own, and printing it is not enough -- it was printed before,
    # and the shader still shipped with detail_strength = 1.0 meaning "the 99.5th
    # percentile" while its comment claimed it meant "the slope as authored". Two
    # summed layers then reached an rms slope of 0.39 and tilted normals below the
    # horizon. So state the consequence, not just the input.
    shipped_strength = 0.25
    # The shader multiplies the DECODED value by detail_strength and uses the
    # result as slope in m/m, so its applied slope is in stored units, not in the
    # authored ones. Two scrolled layers of the same field add in quadrature.
    applied_rms = stored_rms * shipped_strength * (2.0 ** 0.5)
    print(
        "  -> authored slope: %.3f m/m rms per layer (stored rms %.3f x full scale)\n"
        "     detail_strength = %.3f would reproduce it exactly; shipped default is %.2f,\n"
        "     which applies %.3f m/m rms over both layers."
        % (stored_rms * full_scale, stored_rms, full_scale, shipped_strength, applied_rms)
    )
    return rgb


def make_foam_map():
    n = FOAM_SIZE
    rng = np.random.default_rng(SEED + 1)

    coarse, _ = spectral_field(n, rng, lambda k: taper(k, (1.5, 3.0), (7.0, 12.0)))
    fine, _ = spectral_field(n, rng, lambda k: taper(k, (8.0, 14.0), (34.0, 52.0)))

    # Foam is clumps with holes in them, not a smooth gradient: threshold the coarse
    # band into clusters, then punch the fine band through as texture inside them.
    # Multiplying rather than adding is what keeps the gaps between clusters at
    # zero, so a low foam coverage reads as scattered patches instead of a uniform
    # grey veil over the whole surface.
    clusters = np.clip((coarse + 0.55) / 1.4, 0.0, 1.0)
    clusters = clusters * clusters * (3.0 - 2.0 * clusters)
    breakup = np.clip(0.55 + 0.55 * fine, 0.0, 1.0)
    foam = clusters * breakup

    foam /= max(foam.max(), 1e-6)

    rgb = np.zeros((n, n, 3), dtype=np.uint8)
    rgb[..., 0] = np.round(foam * 255.0).astype(np.uint8)

    print(
        "T_water_foam:  %d^2, mean %.3f, coverage>0.5 %.1f%%"
        % (n, float(foam.mean()), float(np.mean(foam > 0.5)) * 100.0)
    )
    return rgb


def main():
    out = os.path.normpath(OUT_DIR)
    write_png(os.path.join(out, "T_water_deriv.png"), make_derivative_map())
    write_png(os.path.join(out, "T_water_foam.png"), make_foam_map())
    print("wrote to %s" % out)


if __name__ == "__main__":
    main()
