// payload_inc/warp_mesh.inc.m
//
// Shared 9-slice warp-mesh builder + chrome band constants. Lives outside
// warp_cover.inc.m so the animation engine (anim.inc.m, included BEFORE
// warp_cover and unable to see its statics) can build the same chrome-pinned
// meshes per frame — the jello-policy animator and the instant-snap cover
// share one builder, one band tuning. Include this before anim.inc.m.

// Transactional warp — disasm-verified: five args, transaction opcode 0x11,
// encodes wid + w + h then w*h*4 packed floats — the immediate
// SLSSetWindowWarp shape minus the cid. w=h=0 with mesh=NULL encodes an
// empty mesh = clear, mirroring the immediate clear idiom. Signature matches
// the drag-warp extern in payload.m verbatim (redundant here for TUs
// without it).
extern CGError SLSTransactionSetWindowWarp(CFTypeRef transaction, uint32_t wid, int w, int h, float *mesh);

// Default bands (px). Left is deliberately wider — it covers the
// traffic-light cluster (x≈7–60 live).
#define WARP_SNAP_BAND_L      120.0
#define WARP_SNAP_BAND_R      24.0
#define WARP_SNAP_BAND_T      52.0
#define WARP_SNAP_BAND_B      24.0

// 4x4 nine-slice: corner cells 1:1 (chrome pinned), edge cells stretch one
// axis, center both. Bands are pair-clamped per axis against BOTH the src
// backing and the dst rect so rows/columns never cross and src band == dst
// band (that equality IS the 1:1 pin). out = 4*4*4 floats
// {srcX,srcY,dstX,dstY}, src window-local, dst global.
static void warp_mesh_9slice(double w0, double h0, CGRect dst,
                             double bl, double br, double bt, double bb,
                             float *out)
{
    double lim_w = fmin(w0, dst.size.width)  - 2.0;
    double lim_h = fmin(h0, dst.size.height) - 2.0;
    if (lim_w < 0.0) lim_w = 0.0;
    if (lim_h < 0.0) lim_h = 0.0;
    if (bl + br > lim_w && bl + br > 0.0) {
        double s = lim_w / (bl + br); bl *= s; br *= s;
    }
    if (bt + bb > lim_h && bt + bb > 0.0) {
        double s = lim_h / (bt + bb); bt *= s; bb *= s;
    }

    double sxs[4] = { 0.0, bl, w0 - br, w0 };
    double sys[4] = { 0.0, bt, h0 - bb, h0 };
    double dxs[4] = { dst.origin.x, dst.origin.x + bl,
                      dst.origin.x + dst.size.width - br,
                      dst.origin.x + dst.size.width };
    double dys[4] = { dst.origin.y, dst.origin.y + bt,
                      dst.origin.y + dst.size.height - bb,
                      dst.origin.y + dst.size.height };
    int idx = 0;
    for (int gy = 0; gy < 4; gy++) {
        for (int gx = 0; gx < 4; gx++) {
            out[idx++] = (float)sxs[gx];
            out[idx++] = (float)sys[gy];
            out[idx++] = (float)dxs[gx];
            out[idx++] = (float)dys[gy];
        }
    }
}
