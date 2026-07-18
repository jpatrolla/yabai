// cgs_transform3d.inc.m — read the full 4x4 window transform via _CGSGetWindowTransform3D.
// NOTE: that getter and its _CGSGetConnectionPortById port helper are NOT exported
// (dlsym-null) — resolved from the live SkyLight image by string-xref, prologue-verified
// so an unknown SkyLight layout bails to -1 instead of crashing.

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <ptrauth.h>

#define FRT3D_MARKER      "GetWindowTransform3D"      // _CGSGetWindowTransform3D
#define FRT3D_PORT_MARKER "Invalid Connection ID %d"  // _CGSGetConnectionPortById
#define FRT3D_PACIBSP     0xd503237fU
#define FRT3D_PACIASP     0xd503233fU

typedef int (*frt3d_get_conn_port_fn)(int cid);
typedef int (*frt3d_get_tf3d_fn)(int port, uint32_t wid, float *out16);

static const struct mach_header_64 *frt3d_image(intptr_t *slide_out)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "SkyLight")) {
            *slide_out = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static uintptr_t frt3d_find_string(const struct mach_header_64 *mh, intptr_t slide, const char *marker)
{
    size_t len = strlen(marker);
    const uint8_t *p = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(p + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            const struct section_64 *se = (const struct section_64 *)((const uint8_t *)sg + sizeof(*sg));
            for (uint32_t s = 0; s < sg->nsects; s++) {
                const uint8_t *base = (const uint8_t *)(uintptr_t)(se[s].addr + slide);
                size_t sz = (size_t)se[s].size;
                for (size_t o = 0; o + len < sz; o++) {
                    if (base[o] == (uint8_t)marker[0] && memcmp(base + o, marker, len) == 0)
                        return (uintptr_t)(base + o);
                }
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return 0;
}

static uintptr_t frt3d_find_xref(const uint32_t *text, size_t count, uintptr_t base, uintptr_t want)
{
    for (size_t i = 0; i + 1 < count; i++) {
        uint32_t ins = text[i];
        if ((ins & 0x9f000000) != 0x90000000) continue;  // not ADRP
        uint32_t rd = ins & 0x1f;
        int64_t lo = (ins >> 29) & 0x3, hi = (ins >> 5) & 0x7ffff;
        int64_t imm = ((hi << 2) | lo) << 12;
        if (imm & ((int64_t)1 << 32)) imm |= ~(((int64_t)1 << 33) - 1);  // sign-extend
        uintptr_t page = ((base + i * 4) & ~0xfffULL) + (uintptr_t)imm;
        for (size_t j = i + 1; j < i + 6 && j < count; j++) {
            uint32_t n2 = text[j];
            if ((n2 & 0xff800000) == 0x91000000 && ((n2 >> 5) & 0x1f) == rd) {  // ADD imm
                if (page + ((n2 >> 10) & 0xfff) == want) return base + i * 4;
            }
            if ((n2 & 0xffc00000) == 0xf9400000 && ((n2 >> 5) & 0x1f) == rd) {  // LDR uimm
                if (page + (((n2 >> 10) & 0xfff) << 3) == want) return base + i * 4;
            }
        }
    }
    return 0;
}

static void *frt3d_resolve_by_string(const struct mach_header_64 *mh, intptr_t slide, const char *marker)
{
    uintptr_t str = frt3d_find_string(mh, slide, marker);
    if (!str) return NULL;
    unsigned long tsz = 0;
    uint8_t *text = getsectiondata(mh, "__TEXT", "__text", &tsz);
    if (!text) return NULL;
    uintptr_t interior = frt3d_find_xref((const uint32_t *)text, tsz / 4, (uintptr_t)text, str);
    if (!interior) return NULL;
    const uint32_t *t = (const uint32_t *)text;
    for (size_t k = (interior - (uintptr_t)text) / 4; k > 0; k--) {
        if (t[k] == FRT3D_PACIBSP || t[k] == FRT3D_PACIASP)
            return (void *)((uintptr_t)text + k * 4);
    }
    return NULL;
}

static frt3d_get_conn_port_fn g_frt3d_get_port = NULL;
static frt3d_get_tf3d_fn      g_frt3d_get_tf3d = NULL;
static int                    g_frt3d_tried    = 0;

// arm64e signs function pointers (key IA / disc 0); a raw scanned __text address
// must be signed before we can call it, or the blraa auth-branch faults with a
// PAC_EXCEPTION. Mirrors payload.m's add_space_fp handling. NULL stays NULL so
// an unresolved marker never becomes a bogus signed ptr.
static void *frt3d_pac_sign(void *raw)
{
    return raw ? ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, 0) : NULL;
}

// resolved once from payload_focus_mirror_init BEFORE the ca_step registers — the
// per-VBL reader never races the first resolve
static int fr_cgs_t3d_resolve(void)
{
    if (!g_frt3d_tried) {
        g_frt3d_tried = 1;
        intptr_t slide = 0;
        const struct mach_header_64 *mh = frt3d_image(&slide);
        if (mh) {
            g_frt3d_get_port = (frt3d_get_conn_port_fn)frt3d_pac_sign(frt3d_resolve_by_string(mh, slide, FRT3D_PORT_MARKER));
            g_frt3d_get_tf3d = (frt3d_get_tf3d_fn)frt3d_pac_sign(frt3d_resolve_by_string(mh, slide, FRT3D_MARKER));
        }
    }
    return (g_frt3d_get_port && g_frt3d_get_tf3d) ? 1 : 0;
}

// Read window `wid`'s full 4x4 (row-major float[16]) into `out`. Returns 0 on
// success (out filled), -1 if unresolved on this SkyLight build, else the MIG rc.
static int fr_cgs_read_window_t3d(int cid, uint32_t wid, float out[16])
{
    if (!fr_cgs_t3d_resolve()) return -1;
    int port = g_frt3d_get_port(cid);
    return g_frt3d_get_tf3d(port, wid, out);
}
