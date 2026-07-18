#ifndef PILE_TRANSFORM_H
#define PILE_TRANSFORM_H

// NOTE: matrices are CATransform3D field-order arrays (m11..m44; translate m41..m43,
// perspective m34) applied row-vector (o = p·M). SkyLight applies the transform as an
// INVERSE (screen→texture) mapping, so forward-visual matrices are inverted before SLS.

#include <math.h>

struct pile_xform {
    double perspective;   // px; m34 = -1/d (<=0 => flat / no perspective)
    double tx, ty, tz;    // per-step screen-x, screen-y, depth-z translate (px)
    double ry;            // UNIFORM yaw about the left-edge hinge (rad)
    double rx, rz;        // per-step pitch / roll (rad)
    double sc;            // per-step multiplicative scale (^step)
    double skx, sky;      // per-step skew x / y (rad)
    double origin_x;      // cascade pivot x in [0,1] (0=left .. 1=right)  [legacy, unused by global model]
    double origin_y;      // cascade pivot y in [0,1] (0=top .. 1=bottom)  [legacy, unused by global model]
    double overflow_z;    // fixed z-shelf for windows past max_step (px)  [legacy, unused by global model]
    int    max_step;      // cascade step cap
    double cx, cy;        // perspective principal point = display centre (screen px); per-call
};

static inline void pm_ident(double m[16])
{
    for (int i = 0; i < 16; ++i) m[i] = 0.0;
    m[0] = m[5] = m[10] = m[15] = 1.0;
}

// R = A·B in field-order layout. Output may alias an input (copies via t).
static inline void pm_mul(const double A[16], const double B[16], double R[16])
{
    double t[16];
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) {
            double s = 0.0;
            for (int k = 0; k < 4; ++k) s += A[k*4 + r] * B[c*4 + k];
            t[c*4 + r] = s;
        }
    for (int i = 0; i < 16; ++i) R[i] = t[i];
}

static inline void pm_trans(double x, double y, double z, double m[16])
{
    pm_ident(m); m[12] = x; m[13] = y; m[14] = z;
}

static inline void pm_scale(double x, double y, double z, double m[16])
{
    for (int i = 0; i < 16; ++i) m[i] = 0.0;
    m[0] = x; m[5] = y; m[10] = z; m[15] = 1.0;
}

static inline void pm_rotx(double a, double m[16])
{
    double c = cos(a), s = sin(a);
    m[0]=1; m[1]=0;  m[2]=0;  m[3]=0;
    m[4]=0; m[5]=c;  m[6]=s;  m[7]=0;
    m[8]=0; m[9]=-s; m[10]=c; m[11]=0;
    m[12]=0;m[13]=0; m[14]=0; m[15]=1;
}

static inline void pm_roty(double a, double m[16])
{
    double c = cos(a), s = sin(a);
    m[0]=c; m[1]=0; m[2]=-s; m[3]=0;
    m[4]=0; m[5]=1; m[6]=0;  m[7]=0;
    m[8]=s; m[9]=0; m[10]=c; m[11]=0;
    m[12]=0;m[13]=0;m[14]=0; m[15]=1;
}

static inline void pm_rotz(double a, double m[16])
{
    double c = cos(a), s = sin(a);
    m[0]=c;  m[1]=s; m[2]=0;  m[3]=0;
    m[4]=-s; m[5]=c; m[6]=0;  m[7]=0;
    m[8]=0;  m[9]=0; m[10]=1; m[11]=0;
    m[12]=0; m[13]=0;m[14]=0; m[15]=1;
}

static inline void pm_skew(double ax, double ay, double m[16])
{
    pm_ident(m); m[1] = tan(ay); m[4] = tan(ax);
}

static inline int pm_step_for(int i, int max_step)
{
    return i < max_step ? i : max_step;
}

static inline void pile_build_matrix(double bounds_w, double bounds_h,
                                     double win_w, double win_h,
                                     int depth, double fit,
                                     const struct pile_xform *st, double out[16])
{
    (void)bounds_h;   // fit already folds in bounds height; plant uses width only
    int max_step  = st->max_step > 0 ? st->max_step : 2;
    int s         = pm_step_for(depth, max_step);
    double behind = (depth > max_step) ? st->overflow_z : 0.0;
    double W = win_w * fit, H = win_h * fit;

    double tmp[16], M[16];

    double RYi[16], SCf[16], inner[16];
    pm_roty(st->ry, RYi);
    pm_scale(fit, fit, 1.0, SCf);
    pm_mul(RYi, SCf, inner);

    double Rx[16], Rz[16], Sk[16], Sc[16], casc[16];
    pm_rotx(st->rx * (double)s, Rx);
    pm_rotz(st->rz * (double)s, Rz);
    pm_skew(st->skx * (double)s, st->sky * (double)s, Sk);
    double k = pow(st->sc, (double)s);
    pm_scale(k, k, 1.0, Sc);
    pm_mul(Rx, Rz, tmp);
    pm_mul(tmp, Sk, tmp);
    pm_mul(tmp, Sc, casc);
    double ocx = st->origin_x * W;
    double ocy = (st->origin_y - 0.5) * H;
    double Toc[16], Tnoc[16];
    pm_trans(ocx, ocy, 0.0, Toc);
    pm_trans(-ocx, -ocy, 0.0, Tnoc);
    pm_mul(Toc, casc, tmp);
    pm_mul(tmp, Tnoc, casc);

    double Tz[16];
    pm_trans(0.0, 0.0, st->tz * (double)s + behind, Tz);
    pm_mul(Tz, casc, tmp);
    pm_mul(tmp, inner, M);

    if (st->perspective > 0.0) {
        double P[16]; pm_ident(P); P[11] = -(1.0 / st->perspective);
        pm_mul(P, M, M);
    }

    double Wp = M[15]; if (Wp < 1e-3) Wp = 1e-3;
    double lcx = M[12] / Wp, lcy = M[13] / Wp;
    double Tx = (-bounds_w / 2.0 + st->tx * (double)s) - lcx;
    double Ty = (st->ty * (double)s) - lcy;
    double Tp[16]; pm_trans(Tx, Ty, 0.0, Tp);
    pm_mul(Tp, M, out);
}

static inline void pile_apply(const double m[16], double x, double y, double z,
                              double out[3])
{
    double X = x*m[0] + y*m[4] + z*m[8]  + m[12];
    double Y = x*m[1] + y*m[5] + z*m[9]  + m[13];
    double Z = x*m[2] + y*m[6] + z*m[10] + m[14];
    double W = x*m[3] + y*m[7] + z*m[11] + m[15];
    if (W < 1e-9 && W > -1e-9) W = 1e-9;
    out[0] = X / W; out[1] = Y / W; out[2] = Z / W;
}

// NOTE: corners must be in perimeter order (either winding); edge hits count as inside.
static inline int pile_point_in_quad(const double qx[4], const double qy[4],
                                     double px, double py)
{
    int pos = 0, neg = 0;
    for (int i = 0; i < 4; ++i) {
        int j = (i + 1) & 3;
        double ex = qx[j] - qx[i], ey = qy[j] - qy[i];
        double cx = px   - qx[i], cy = py   - qy[i];
        double cross = ex * cy - ey * cx;
        if      (cross > 0.0) ++pos;
        else if (cross < 0.0) ++neg;
    }
    return !(pos && neg);
}

// NOTE: returns 0 and leaves out_m untouched when singular.
static inline int pile_mat4_inverse(const double m[16], double out_m[16])
{
    double inv[16];
    inv[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
    inv[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
    inv[8]  =  m[4]*m[9]*m[15]  - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
    inv[12] = -m[4]*m[9]*m[14]  + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
    inv[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
    inv[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
    inv[9]  = -m[0]*m[9]*m[15]  + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
    inv[13] =  m[0]*m[9]*m[14]  - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
    inv[2]  =  m[1]*m[6]*m[15]  - m[1]*m[7]*m[14]  - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7]  - m[13]*m[3]*m[6];
    inv[6]  = -m[0]*m[6]*m[15]  + m[0]*m[7]*m[14]  + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7]  + m[12]*m[3]*m[6];
    inv[10] =  m[0]*m[5]*m[15]  - m[0]*m[7]*m[13]  - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7]  - m[12]*m[3]*m[5];
    inv[14] = -m[0]*m[5]*m[14]  + m[0]*m[6]*m[13]  + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6]  + m[12]*m[2]*m[5];
    inv[3]  = -m[1]*m[6]*m[11]  + m[1]*m[7]*m[10]  + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7]   + m[9]*m[3]*m[6];
    inv[7]  =  m[0]*m[6]*m[11]  - m[0]*m[7]*m[10]  - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7]   - m[8]*m[3]*m[6];
    inv[11] = -m[0]*m[5]*m[11]  + m[0]*m[7]*m[9]   + m[4]*m[1]*m[11] - m[4]*m[3]*m[9]  - m[8]*m[1]*m[7]   + m[8]*m[3]*m[5];
    inv[15] =  m[0]*m[5]*m[10]  - m[0]*m[6]*m[9]   - m[4]*m[1]*m[10] + m[4]*m[2]*m[9]  + m[8]*m[1]*m[6]   - m[8]*m[2]*m[5];

    double det = m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12];
    if (det > -1e-12 && det < 1e-12) return 0;
    double idet = 1.0 / det;
    for (int i = 0; i < 16; ++i) out_m[i] = inv[i] * idet;
    return 1;
}

// NOTE: forward-visual pile matrix in the window-local frame: screen = nat.origin +
// apply(out_vis, local). slot = on-screen target rect; nat = the window's real rect.
// Perspective is GLOBAL about the display centre (xf->cx,cy), not per-window — the
// native SM camera. Identity on degenerate input.
static inline void pile_compose_visual(double slot_x, double slot_y, double slot_w, double slot_h,
                                       double nat_x,  double nat_y,  double nat_w,  double nat_h,
                                       int depth, const struct pile_xform *xf, double out_vis[16])
{
    pm_ident(out_vis);
    if (!xf) return;
    if (nat_w  <= 0.0 || nat_h  <= 0.0) return;
    if (slot_w <= 0.0 || slot_h <= 0.0) return;
    if (depth < 0) depth = 0;

    int max_step = xf->max_step > 0 ? xf->max_step : 2;
    int step     = depth < max_step ? depth : max_step;
    double fit     = slot_h / nat_h;
    double plant_x = slot_x + xf->tx * (double)step;
    double plant_y = slot_y;

    double M[16], T[16];
    pm_scale(fit, fit, fit, M);
    pm_roty(xf->ry, T);            pm_mul(T, M, M);
    pm_trans(plant_x, plant_y, 0.0, T); pm_mul(T, M, M);
    if (xf->perspective > 0.0) {
        pm_trans(-xf->cx, -xf->cy, 0.0, T); pm_mul(T, M, M);
        double P[16]; pm_ident(P); P[11] = -(1.0 / xf->perspective); pm_mul(P, M, M);
        pm_trans(xf->cx, xf->cy, 0.0, T);  pm_mul(T, M, M);
    }
    pm_trans(-nat_x, -nat_y, 0.0, T); pm_mul(T, M, M);
    for (int i = 0; i < 16; ++i) out_vis[i] = M[i];
}

// NOTE: SLS-ready inverse of pile_compose_visual; identity on degenerate/singular input.
static inline void pile_compose_sls(double slot_x, double slot_y, double slot_w, double slot_h,
                                    double nat_x,  double nat_y,  double nat_w,  double nat_h,
                                    int depth, const struct pile_xform *xf, double out_m[16])
{
    double Vis[16];
    pile_compose_visual(slot_x, slot_y, slot_w, slot_h,
                        nat_x, nat_y, nat_w, nat_h, depth, xf, Vis);
    if (!pile_mat4_inverse(Vis, out_m)) pm_ident(out_m);
}

// Tween toward the pile pose. `full` = the settled knobs (g_strip_layout);
// progress p∈[0,1] is 0 at full window size, 1 at the settled thumb pose. Ramps
// the rotation / cascade / position knobs by p but holds PERSPECTIVE CONSTANT —
// the native Stage-Manager signature (perspective is full from the first frame;
// only yaw/scale/position ride in, and with no rotation the perspective is inert
// so p=0 reads as a flat full-size window). `slot` is the per-frame lerped rect
// (natural → thumb). At p=0 with slot=natural the result is ~identity; at p=1
// with slot=thumb it equals pile_compose_sls(full).
static inline void pile_build_tween(double slot_x, double slot_y, double slot_w, double slot_h,
                                    double nat_x,  double nat_y,  double nat_w,  double nat_h,
                                    int depth, const struct pile_xform *full, double p,
                                    double out_m[16])
{
    if (!full) { pm_ident(out_m); return; }
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    struct pile_xform xf = *full;
    xf.tx  *= p; xf.ty  *= p; xf.tz *= p;
    xf.ry  *= p; xf.rx  *= p; xf.rz *= p;
    xf.skx *= p; xf.sky *= p;
    xf.sc   = 1.0 + (full->sc - 1.0) * p;
    pile_compose_sls(slot_x, slot_y, slot_w, slot_h,
                     nat_x, nat_y, nat_w, nat_h, depth, &xf, out_m);
}

#endif
