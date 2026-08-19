// dock_fs_clamp.inc.m — zeroes Dock's native-fullscreen transition durations at their source.
//
// Two independent site groups, both driven by the one enable flag:
//
//   one-up  the `slow ? 2.5 : 0.5` fcsel in each of the msg-1 / msg-2 workers. That value lands in
//           callee-saved d8 and feeds both Dock's own space-slide timer and the duration in the XPC
//           reply AppKit crossfades on, so zeroing d8 at the fork starves both.
//   two-up  the picker's own `Shift ? 5.0 : 0.25` fcsels. Their value is handed to Dock's
//           WATransaction animation core, which drives the per-tick SLSTransactionSetSpaceTransform
//           lerp on the tile space -- the visible motion of the two-up picker.
//
// The groups are disjoint: different functions, different registers, no shared state. Patching both
// is not a composition, just two edits.
//
// Same shape as the animation_time patch in init_instances(): a version-keyed byte pattern located
// with hex_find_seq, one instruction rewritten through a VM_PROT_COPY page.

#define DOCK_FS_FCSEL      0x1e601c28u   // fcsel d8, d1, d0, ne
#define DOCK_FS_MOVI       0x2f00e408u   // movi  d8, #0
#define DOCK_FS_ATU_FCSEL  0x1e601c20u   // fcsel d0, d1, d0, ne
#define DOCK_FS_ATU_MOVI   0x2f00e400u   // movi  d0, #0

// NOTE: the fcsel word alone repeats eleven times in Dock -- only the fmov #0.5 / fmov #2.5 pair
// ahead of it is unique to the two transition handlers, so the pattern has to carry all three.
// No wildcards: a loose match here would clamp an unrelated duration rather than fail to find one.
static const char *get_fs_clamp_pattern(NSOperatingSystemVersion os_version)
{
#ifdef __arm64__
    if (os_version.majorVersion >= 26) {
        return "00 10 6C 1E 01 90 60 1E 28 1C 60 1E";
    }
#else
    (void) os_version;
#endif

    return NULL;
}

// NOTE: the picker's fcsel triple alone also matches an unrelated site, so the d8 pattern carries
// the `mov w0, #4` timing-curve ordinal that follows it in all three picker handlers -- cancel,
// commit and hover-preview. The d0 variant is the ATU driver and is already unique at three words.
static const char *get_fs_atu_d8_pattern(NSOperatingSystemVersion os_version)
{
#ifdef __arm64__
    if (os_version.majorVersion >= 26) {
        return "00 10 6A 1E 01 90 62 1E 28 1C 60 1E 80 00 80 52";
    }
#else
    (void) os_version;
#endif

    return NULL;
}

static const char *get_fs_atu_d0_pattern(NSOperatingSystemVersion os_version)
{
#ifdef __arm64__
    if (os_version.majorVersion >= 26) {
        return "00 10 6A 1E 01 90 62 1E 20 1C 60 1E";
    }
#else
    (void) os_version;
#endif

    return NULL;
}

// NOTE: hex_find_seq gives up 0x1286a0 bytes past the address it was handed, so each group needs
// its own start offset near its sites rather than one shared scan from the first.
static uint64_t get_fs_group_offset(NSOperatingSystemVersion os_version, int group)
{
#ifdef __arm64__
    if (os_version.majorVersion >= 26) {
        return group == 0 ? 0x1F0000 : 0x2A0000;
    }
#else
    (void) os_version; (void) group;
#endif

    return 0;
}

static uint64_t fs_clamp_site[DOCK_FS_SITE_COUNT];
static int fs_clamp_site_count;
static uint64_t fs_atu_d8_site[DOCK_FS_ATU_D8_SITE_COUNT];
static int fs_atu_d8_site_count;
static uint64_t fs_atu_d0_site[DOCK_FS_ATU_D0_SITE_COUNT];
static int fs_atu_d0_site_count;

static int init_patch_group(const char *label, uint64_t baseaddr, uint64_t offset,
                            const char *pattern, int stride, int want, uint64_t *out)
{
    if (!pattern || !offset) return 0;

    int found = 0;
    uint64_t addr = baseaddr + offset;

    for (int i = 0; i < want; ++i) {
        addr = hex_find_seq(addr, pattern);
        if (!addr) break;

        out[found++] = addr + stride;
        addr += stride + 4;
    }

    if (found != want) {
        NSLog(@"[yabai-sa] failed to get pointer to %s.. (%d/%d)", label, found, want);
        return 0;
    }

    NSLog(@"[yabai-sa] (0x%llx) %s found at address 0x%llX (0x%llx)", baseaddr, label, out[0], out[0] - baseaddr);
    return found;
}

static void init_fs_clamp(NSOperatingSystemVersion os_version, uint64_t baseaddr)
{
    fs_clamp_site_count = init_patch_group("fullscreen-duration", baseaddr,
                                           get_fs_group_offset(os_version, 0),
                                           get_fs_clamp_pattern(os_version), 8,
                                           DOCK_FS_SITE_COUNT, fs_clamp_site);

    fs_atu_d8_site_count = init_patch_group("two-up picker duration", baseaddr,
                                            get_fs_group_offset(os_version, 1),
                                            get_fs_atu_d8_pattern(os_version), 8,
                                            DOCK_FS_ATU_D8_SITE_COUNT, fs_atu_d8_site);

    fs_atu_d0_site_count = init_patch_group("two-up driver duration", baseaddr,
                                            get_fs_group_offset(os_version, 1),
                                            get_fs_atu_d0_pattern(os_version), 8,
                                            DOCK_FS_ATU_D0_SITE_COUNT, fs_atu_d0_site);
}

static uint32_t apply_patch_sites(uint64_t *sites, int count, uint32_t word)
{
    uint32_t done = 0;

    for (int i = 0; i < count; ++i) {
        uint64_t addr = sites[i];
        if (*(uint32_t *) addr == word) { ++done; continue; }

        // NOTE: VM_PROT_COPY is what makes this possible at all -- it forks a private copy of the
        // code-signed page, which is also why the patch dies with Dock. EXECUTE is asked for in the
        // same breath so the page is never unmapped from under a Dock thread running on it.
        if (vm_protect(mach_task_self(), page_align(addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY) == KERN_SUCCESS ||
            vm_protect(mach_task_self(), page_align(addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
            *(uint32_t *) addr = word;
            vm_protect(mach_task_self(), page_align(addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
            sys_icache_invalidate((void *) addr, sizeof(word));
            ++done;
        } else {
            NSLog(@"[yabai-sa] fullscreen-duration vm_protect failed; unable to patch instruction!");
        }
    }

    return done;
}

// NOTE: replies with the number of sites now holding the requested word -- restores count too, so a
// full DOCK_FS_TOTAL_SITE_COUNT means "every site is in the requested state", not "every site is
// patched". The handshake attribute cannot answer this for the daemon: that handshake runs in the
// transient `yabai --load-sa` process, so the daemon never sees it.
static void do_dock_fs_clamp(int sockfd, char *message)
{
    int32_t enable;
    unpack(enable);

    uint32_t done = 0;
    done += apply_patch_sites(fs_clamp_site, fs_clamp_site_count,
                              enable ? DOCK_FS_MOVI : DOCK_FS_FCSEL);
    done += apply_patch_sites(fs_atu_d8_site, fs_atu_d8_site_count,
                              enable ? DOCK_FS_MOVI : DOCK_FS_FCSEL);
    done += apply_patch_sites(fs_atu_d0_site, fs_atu_d0_site_count,
                              enable ? DOCK_FS_ATU_MOVI : DOCK_FS_ATU_FCSEL);

    send(sockfd, &done, sizeof(done), 0);
}
