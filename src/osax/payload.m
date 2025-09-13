#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGAffineTransform.h>
#include <CoreGraphics/CGDirectDisplay.h>
#include <Foundation/Foundation.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <unistd.h>
#include <netdb.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "common.h"

#ifdef __x86_64__
#include "x64_payload.m"
#elif __arm64__
#include "arm64_payload.m"
#include <ptrauth.h>
#endif

#define HASHTABLE_IMPLEMENTATION
#include "../misc/hashtable.h"
#undef HASHTABLE_IMPLEMENTATION

#define SOCKET_PATH_FMT "/tmp/yabai-sa_%s.socket"
#define page_align(addr) (vm_address_t)((uintptr_t)(addr) & (~(vm_page_size - 1)))
#define unpack(v) memcpy(&v, message, sizeof(v)); message += sizeof(v)
#define lerp(a, t, b) (((1.0-t)*a) + (t*b))

// Warp mesh constants
#define WARP_MESH_WIDTH 16
#define WARP_MESH_HEIGHT 16
#define WARP_MESH_POINTS (WARP_MESH_WIDTH * WARP_MESH_HEIGHT)

// Transitional opacity controls for big size changes
#define TRANSITION_SIZE_THRESHOLD 0.45f  // If current width < 45% of final width
#define TRANSITION_MIN_OPACITY 0.7f      // Clamp opacity to minimum 70%

extern int SLSMainConnectionID(void);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid, float alpha);

extern OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSReassociateWindowsSpacesByGeometry(int cid, CFArrayRef window_list);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *window_cid);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x_offset, float y_offset, CFTypeRef shape);
extern CGError SLSSetWindowClipShape(int cid, uint32_t wid, CFTypeRef shape);
extern CGError SLSSetWindowWarp(int cid, uint32_t wid, int w, int h, CGPoint *mesh);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
extern CGError CGSNewRegionWithRect(CGRect *rect, CFTypeRef *outRegion);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowAlphaAnimated(CFTypeRef transaction, uint32_t wid, float alpha, float duration);
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int unknown, int unknown2, CGAffineTransform t);
extern CGError SLSTransactionSetWindowShape(CFTypeRef transaction, uint32_t wid, float x_offset, float y_offset, CFTypeRef shape);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);

struct window_fade_context
{
    pthread_t thread;
    uint32_t wid;
    volatile float alpha;
    volatile float duration;
    volatile bool skip;
};

pthread_mutex_t window_fade_lock;
struct table window_fade_table;

static id dock_spaces;
static id dp_desktop_picture_manager;
static uint64_t add_space_fp;
static uint64_t remove_space_fp;
static uint64_t move_space_fp;
static uint64_t set_front_window_fp;
static uint64_t animation_time_addr;
static bool macOSSequoia;

static pthread_t daemon_thread;
static int daemon_sockfd;

static void dump_class_info(Class c)
{
    const char *name = class_getName(c);
    unsigned int count = 0;

    Ivar *ivar_list = class_copyIvarList(c, &count);
    for (int i = 0; i < count; i++) {
        Ivar ivar = ivar_list[i];
        const char *ivar_name = ivar_getName(ivar);
        NSLog(@"%s ivar: %s", name, ivar_name);
    }
    if (ivar_list) free(ivar_list);

    objc_property_t *property_list = class_copyPropertyList(c, &count);
    for (int i = 0; i < count; i++) {
        objc_property_t property = property_list[i];
        const char *prop_name = property_getName(property);
        NSLog(@"%s property: %s", name, prop_name);
    }
    if (property_list) free(property_list);

    Method *method_list = class_copyMethodList(c, &count);
    for (int i = 0; i < count; i++) {
        Method method = method_list[i];
        const char *method_name = sel_getName(method_getName(method));
        NSLog(@"%s method: %s", name, method_name);
    }
    if (method_list) free(method_list);
}

static Class dump_class_info_by_name(const char *name)
{
    Class c = objc_getClass(name);
    if (c != nil) {
        dump_class_info(c);
    }
    return c;
}

static uint64_t static_base_address(void)
{
    const struct segment_command_64 *command = getsegbyname("__TEXT");
    uint64_t addr = command->vmaddr;
    return addr;
}

static uint64_t image_slide(void)
{
    char path[1024];
    uint32_t size = sizeof(path);

    if (_NSGetExecutablePath(path, &size) != 0) {
        return -1;
    }

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }

    return 0;
}

static uint64_t hex_find_seq(uint64_t baddr, const char *c_pattern)
{
    if (!baddr || !c_pattern) return 0;

    uint64_t addr = baddr;
    uint64_t pattern_length = (strlen(c_pattern) + 1) / 3;
    char buffer_a[pattern_length];
    char buffer_b[pattern_length];
    memset(buffer_a, 0, sizeof(buffer_a));
    memset(buffer_b, 0, sizeof(buffer_b));

    char *pattern = (char *) c_pattern + 1;
    for (int i = 0; i < pattern_length; ++i) {
        char c = pattern[-1];
        if (c == '?') {
            buffer_b[i] = 1;
        } else {
            int temp = c <= '9' ? 0 : 9;
            temp = (temp + c) << 0x4;
            c = pattern[0];
            int temp2 = c <= '9' ? 0xd0 : 0xc9;
            buffer_a[i] = temp2 + c + temp;
        }
        pattern += 3;
    }

loop:
    for (int counter = 0; counter < pattern_length; ++counter) {
        if ((buffer_b[counter] == 0) && (((char *)addr)[counter] != buffer_a[counter])) {
            addr = (uint64_t)((char *)addr + 1);
            if (addr - baddr < 0x1286a0) {
                goto loop;
            } else {
                return 0;
            }
        }
    }

    return addr;
}

#if __arm64__
uint64_t decode_adrp_add(uint64_t addr, uint64_t offset)
{
    uint32_t adrp_instr = *(uint32_t *) addr;

    uint32_t immlo = (0x60000000 & adrp_instr) >> 29;
    uint32_t immhi = (0xffffe0 & adrp_instr) >> 3;

    int32_t value = (immhi | immlo) << 12;
    int64_t value_64 = value;

    uint32_t add_instr = *(uint32_t *) (addr + 4);
    uint64_t imm12 = (add_instr & 0x3ffc00) >> 10;

    if (add_instr & 0xc00000) {
        imm12 <<= 12;
    }

    return (offset & 0xfffffffffffff000) + value_64 + imm12;
}
#endif

static bool verify_os_version(NSOperatingSystemVersion os_version)
{
    NSLog(@"[yabai-sa] checking for macOS %ld.%ld.%ld compatibility!", os_version.majorVersion, os_version.minorVersion, os_version.patchVersion);

#ifdef __x86_64__
    if (os_version.majorVersion == 11) {
        return true; // Big Sur 11.0
    } else if (os_version.majorVersion == 12) {
        return true; // Monterey 12.0
    } else if (os_version.majorVersion == 13) {
        return true; // Ventura 13.0
    } else if (os_version.majorVersion == 14) {
        return true; // Sonoma 14.0
    } else if (os_version.majorVersion == 15) {
        macOSSequoia = true;
        return true; // Sequoia 15.0
    }

    NSLog(@"[yabai-sa] spaces functionality is only supported on macOS Big Sur 11.0.0+, Monterey 12.0.0+, Ventura 13.0.0+, Sonoma 14.0.0+, and Sequoia 15.0");
#elif __arm64__
    if (os_version.majorVersion == 12) {
        return true; // Monterey 12.0
    } else if (os_version.majorVersion == 13) {
        return true; // Ventura 13.0
    } else if (os_version.majorVersion == 14) {
        return true; // Sonoma 14.0
    } else if (os_version.majorVersion == 15) {
        macOSSequoia = true;
        return true; // Sequoia 15.0
    }

    NSLog(@"[yabai-sa] spaces functionality is only supported on macOS Monterey 12.0.0+, and Ventura 13.0.0+, Sonoma 14.0.0+, and Sequoia 15.0");
#endif

    return false;
}

static void init_instances()
{
    NSOperatingSystemVersion os_version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (!verify_os_version(os_version)) return;

    uint64_t baseaddr = static_base_address() + image_slide();

    uint64_t dock_spaces_addr = hex_find_seq(baseaddr + get_dock_spaces_offset(os_version), get_dock_spaces_pattern(os_version));
    if (dock_spaces_addr == 0) {
        dock_spaces = nil;
        NSLog(@"[yabai-sa] could not locate pointer to dock.spaces! spaces functionality will not work!");
    } else {
#ifdef __x86_64__
        uint32_t dock_spaces_offset = *(int32_t *)dock_spaces_addr;
        NSLog(@"[yabai-sa] (0x%llx) dock.spaces found at address 0x%llX (0x%llx)", baseaddr, dock_spaces_addr, dock_spaces_addr - baseaddr);
        dock_spaces = [(*(id *)(dock_spaces_addr + dock_spaces_offset + 0x4)) retain];
#elif __arm64__
        uint64_t dock_spaces_offset = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        NSLog(@"[yabai-sa] (0x%llx) dock.spaces found at address 0x%llX (0x%llx)", baseaddr, dock_spaces_offset, dock_spaces_offset - baseaddr);
        dock_spaces = [(*(id *)(baseaddr + dock_spaces_offset)) retain];
#endif
    }

    uint64_t dppm_addr = hex_find_seq(baseaddr + get_dppm_offset(os_version), get_dppm_pattern(os_version));
    if (dppm_addr == 0) {
        dp_desktop_picture_manager = nil;
        NSLog(@"[yabai-sa] could not locate pointer to dppm! moving spaces will not work!");
    } else {
#ifdef __x86_64__
        uint32_t dppm_offset = *(int32_t *)dppm_addr;
        NSLog(@"[yabai-sa] (0x%llx) dppm found at address 0x%llX (0x%llx)", baseaddr, dppm_addr, dppm_addr - baseaddr);
        dp_desktop_picture_manager = [(*(id *)(dppm_addr + dppm_offset + 0x4)) retain];
#elif __arm64__
        uint64_t dppm_offset = decode_adrp_add(dppm_addr, dppm_addr - baseaddr);
        NSLog(@"[yabai-sa] (0x%llx) dppm found at address 0x%llX (0x%llx)", baseaddr, dppm_offset, dppm_offset - baseaddr);
        dp_desktop_picture_manager = [(*(id *)(baseaddr + dppm_offset)) retain];
#endif

        //
        // @hack
        //
        // NOTE(koekeishiya): For whatever reason, in Sonoma, DPDesktopPictureManager is initialized and swapped
        // to an alternate storage location instead of where it used to be stored in previous macOS versions..
        //
        // This alternate storage location resides 8-bytes before the usual location, so we simply do
        // the subtract to arrive at the correct location in cases where the usual location is null.
        //

#ifdef __x86_64__
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(dppm_addr + dppm_offset + 0x4 - 0x8)) retain];
        }
#elif __arm64__
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(baseaddr + dppm_offset - 0x8)) retain];
        }
#endif
    }

    uint64_t add_space_addr = hex_find_seq(baseaddr + get_add_space_offset(os_version), get_add_space_pattern(os_version));
    if (add_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to addSpace function..");
        add_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) addSpace found at address 0x%llX (0x%llx)", baseaddr, add_space_addr, add_space_addr - baseaddr);
#ifdef __x86_64__
        add_space_fp = add_space_addr;
#elif __arm64__
        add_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) add_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t remove_space_addr = hex_find_seq(baseaddr + get_remove_space_offset(os_version), get_remove_space_pattern(os_version));
    if (remove_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to removeSpace function..");
        remove_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) removeSpace found at address 0x%llX (0x%llx)", baseaddr, remove_space_addr, remove_space_addr - baseaddr);
#ifdef __x86_64__
        remove_space_fp = remove_space_addr;
#elif __arm64__
        remove_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) remove_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t move_space_addr = hex_find_seq(baseaddr + get_move_space_offset(os_version), get_move_space_pattern(os_version));
    if (move_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to moveSpace function..");
        move_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) moveSpace found at address 0x%llX (0x%llx)", baseaddr, move_space_addr, move_space_addr - baseaddr);
#ifdef __x86_64__
        move_space_fp = move_space_addr;
#elif __arm64__
        move_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) move_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t set_front_window_addr = hex_find_seq(baseaddr + get_set_front_window_offset(os_version), get_set_front_window_pattern(os_version));
    if (set_front_window_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to setFrontWindow function..");
        set_front_window_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) setFrontWindow found at address 0x%llX (0x%llx)", baseaddr, set_front_window_addr, set_front_window_addr - baseaddr);
#ifdef __x86_64__
        set_front_window_fp = set_front_window_addr;
#elif __arm64__
        set_front_window_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) set_front_window_addr, ptrauth_key_asia, 0);
#endif
    }

    animation_time_addr = hex_find_seq(baseaddr + get_fix_animation_offset(os_version), get_fix_animation_pattern(os_version));
    if (animation_time_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to animation-time..");
    } else {
        NSLog(@"[yabai-sa] (0x%llx) animation_time_addr found at address 0x%llX (0x%llx)", baseaddr, animation_time_addr, animation_time_addr - baseaddr);
        if (vm_protect(mach_task_self(), page_align(animation_time_addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
#ifdef __x86_64__
            *(uint64_t *) animation_time_addr = 0x660fefc0660fefc0;
#elif __arm64__
            *(uint32_t *) animation_time_addr = 0x2f00e400;
#endif
            vm_protect(mach_task_self(), page_align(animation_time_addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
        } else {
            NSLog(@"[yabai-sa] animation_time_addr vm_protect failed; unable to patch instruction!");
        }
    }
}

static inline id get_ivar_value(id instance, const char *name)
{
    id result = nil;
    object_getInstanceVariable(instance, name, (void **) &result);
    return result;
}

static inline void set_ivar_value(id instance, const char *name, id value)
{
    object_setInstanceVariable(instance, name, value);
}

static inline uint64_t get_space_id(id space)
{
    return ((uint64_t (*)(id, SEL)) objc_msgSend)(space, @selector(spid));
}


// BSP Grid Animation Transform Helper
// Creates transform to animate window within screen bounds context
// Window is physically at target position, needs to appear at source position
// Anchor points: 0=TL, 1=TR, 2=BL, 3=BR
static CGAffineTransform create_anchor_transform(
                                                float target_x, float target_y, float target_w, float target_h,  // where window IS (relative to frame)
                                                float source_x, float source_y, float source_w, float source_h,  // where it should APPEAR (relative to frame)
                                                int anchor)
{
    // Calculate scale factors (source/target since we're going backwards)
    float sx_factor = source_w / target_w;
    float sy_factor = source_h / target_h;
    
    // Calculate anchor-based translation using the same logic as the original code
    CGFloat ax, ay;
    
    switch (anchor) {
        case 0: // TL
            ax = -source_x;
            ay = -source_y;
            break;
        case 1: // TR  
            ax = -(source_x + source_w) + target_w;
            ay = -source_y;
            break;
        case 2: // BL
            ax = -source_x;
            ay = -(source_y + source_h) + target_h;
            break;
        case 3: // BR
            ax = -(source_x + source_w) + target_w;
            ay = -(source_y + source_h) + target_h;
            break;
        default:
            ax = -source_x;
            ay = -source_y;
            break;
    }
    
    // Create transform: scale first, then translate (matching original pattern)
    CGAffineTransform scale_transform = CGAffineTransformMakeScale(sx_factor, sy_factor);
    CGAffineTransform final_transform = CGAffineTransformConcat(scale_transform, 
                                                              CGAffineTransformMakeTranslation(ax, ay));
    
    return final_transform;
}

// Warp mesh generation functions
static void create_base_mesh(CGPoint *mesh, CGRect bounds)
{
    float step_x = bounds.size.width / (WARP_MESH_WIDTH - 1);
    float step_y = bounds.size.height / (WARP_MESH_HEIGHT - 1);
    
    for (int y = 0; y < WARP_MESH_HEIGHT; y++) {
        for (int x = 0; x < WARP_MESH_WIDTH; x++) {
            int index = y * WARP_MESH_WIDTH + x;
            mesh[index].x = bounds.origin.x + (x * step_x);
            mesh[index].y = bounds.origin.y + (y * step_y);
        }
    }
}

static void apply_wobble_effect(CGPoint *mesh, CGRect bounds, float time, float intensity)
{
    float step_x = bounds.size.width / (WARP_MESH_WIDTH - 1);
    float step_y = bounds.size.height / (WARP_MESH_HEIGHT - 1);
    
    for (int y = 0; y < WARP_MESH_HEIGHT; y++) {
        for (int x = 0; x < WARP_MESH_WIDTH; x++) {
            int index = y * WARP_MESH_WIDTH + x;
            
            // Base position
            float base_x = bounds.origin.x + (x * step_x);
            float base_y = bounds.origin.y + (y * step_y);
            
            // Normalized coordinates (0.0 to 1.0)
            float norm_x = (float)x / (WARP_MESH_WIDTH - 1);
            float norm_y = (float)y / (WARP_MESH_HEIGHT - 1);
            
            // Multiple sine waves for complex wobble
            float offset_x = intensity * (
                sin(time * 2.0f + norm_x * 8.0f) * 0.5f +
                sin(time * 3.0f + norm_y * 6.0f) * 0.3f +
                sin(time * 1.5f + (norm_x + norm_y) * 4.0f) * 0.2f
            );
            
            float offset_y = intensity * (
                cos(time * 2.5f + norm_y * 7.0f) * 0.4f +
                cos(time * 1.8f + norm_x * 5.0f) * 0.3f +
                cos(time * 2.2f + (norm_x - norm_y) * 3.0f) * 0.3f
            );
            
            mesh[index].x = base_x + offset_x;
            mesh[index].y = base_y + offset_y;
        }
    }
}

static void apply_ripple_effect(CGPoint *mesh, CGRect bounds, float time, float intensity, CGPoint center)
{
    float step_x = bounds.size.width / (WARP_MESH_WIDTH - 1);
    float step_y = bounds.size.height / (WARP_MESH_HEIGHT - 1);
    
    for (int y = 0; y < WARP_MESH_HEIGHT; y++) {
        for (int x = 0; x < WARP_MESH_WIDTH; x++) {
            int index = y * WARP_MESH_WIDTH + x;
            
            // Base position
            float base_x = bounds.origin.x + (x * step_x);
            float base_y = bounds.origin.y + (y * step_y);
            
            // Distance from center
            float dx = base_x - center.x;
            float dy = base_y - center.y;
            float distance = sqrt(dx * dx + dy * dy);
            
            // Ripple calculation
            float ripple = sin(distance * 0.02f - time * 4.0f) * intensity * exp(-distance * 0.001f);
            
            // Apply ripple in radial direction
            if (distance > 0) {
                float norm_dx = dx / distance;
                float norm_dy = dy / distance;
                
                mesh[index].x = base_x + norm_dx * ripple;
                mesh[index].y = base_y + norm_dy * ripple;
            } else {
                mesh[index].x = base_x;
                mesh[index].y = base_y;
            }
        }
    }
}

static inline id space_for_display_with_id(CFStringRef display_uuid, uint64_t space_id)
{
    NSArray *spaces_for_display = ((NSArray *(*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(spacesForDisplay:), display_uuid);
    for (id space in spaces_for_display) {
        if (space_id == get_space_id(space)) {
            return space;
        }
    }
    return nil;
}

static inline id display_space_for_display_uuid(CFStringRef display_uuid)
{
    id result = nil;

    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id display_source_space = get_ivar_value(display_space, "_currentSpace");
            uint64_t sid = get_space_id(display_source_space);
            CFStringRef uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
            bool match = CFEqual(uuid, display_uuid);
            CFRelease(uuid);
            if (match) {
                result = display_space;
                break;
            }
        }
    }

    return result;
}

static inline id display_space_for_space_with_id(uint64_t space_id)
{
    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id display_source_space = get_ivar_value(display_space, "_currentSpace");
            if (get_space_id(display_source_space) == space_id) {
                return display_space;
            }
        }
    }
    return nil;
}

static void do_space_move(char *message)
{
    if (dock_spaces == nil || dp_desktop_picture_manager == nil || move_space_fp == 0) return;

    uint64_t source_space_id, dest_space_id, source_prev_space_id;
    unpack(source_space_id);
    unpack(dest_space_id);
    unpack(source_prev_space_id);

    bool focus_dest_space;
    unpack(focus_dest_space);

    CFStringRef source_display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), source_space_id);
    id source_space = space_for_display_with_id(source_display_uuid, source_space_id);
    id source_display_space = display_space_for_display_uuid(source_display_uuid);

    CFStringRef dest_display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
    id dest_space = space_for_display_with_id(dest_display_uuid, dest_space_id);
    unsigned dest_display_id = ((unsigned (*)(id, SEL, id)) objc_msgSend)(dock_spaces, @selector(displayIDForSpace:), dest_space);
    id dest_display_space = display_space_for_display_uuid(dest_display_uuid);

    if (source_prev_space_id) {
        NSArray *ns_source_space = @[ @(source_space_id) ];
        NSArray *ns_dest_space = @[ @(source_prev_space_id) ];
        id new_source_space = space_for_display_with_id(source_display_uuid, source_prev_space_id);
        SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_dest_space);
        SLSHideSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_source_space);
        SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), source_display_uuid, source_prev_space_id);
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);
        [ns_dest_space release];
        [ns_source_space release];
    }

    asm__call_move_space(source_space, dest_space, dest_display_uuid, dock_spaces, move_space_fp);

    dispatch_sync(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, unsigned, CFStringRef)) objc_msgSend)(dp_desktop_picture_manager, @selector(moveSpace:toDisplay:displayUUID:), source_space, dest_display_id, dest_display_uuid);
    });

    if (focus_dest_space) {
        uint64_t new_source_space_id = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), source_display_uuid);
        id new_source_space = space_for_display_with_id(source_display_uuid, new_source_space_id);
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);

        NSArray *ns_dest_monitor_space = @[ @(dest_space_id) ];
        SLSHideSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_dest_monitor_space);
        SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display_uuid, source_space_id);
        set_ivar_value(dest_display_space, "_currentSpace", [source_space retain]);
        [ns_dest_monitor_space release];
    }

    CFRelease(source_display_uuid);
    CFRelease(dest_display_uuid);
}

typedef void (*remove_space_call)(id space, id display_space, id dock_spaces, uint64_t space_id1, uint64_t space_id2);
static void do_space_destroy(char *message)
{
    if (dock_spaces == nil || remove_space_fp == 0) return;

    uint64_t space_id;
    unpack(space_id);

    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), space_id);
    uint64_t active_space_id = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);

    id space = space_for_display_with_id(display_uuid, space_id);
    id display_space = display_space_for_display_uuid(display_uuid);

    dispatch_sync(dispatch_get_main_queue(), ^{
        ((remove_space_call) remove_space_fp)(space, display_space, dock_spaces, space_id, space_id);
    });

    if (active_space_id == space_id) {
        uint64_t dest_space_id = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);
        id dest_space = space_for_display_with_id(display_uuid, dest_space_id);
        set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
    }

    CFRelease(display_uuid);
}

static void do_space_create(char *message)
{
    if (dock_spaces == nil || add_space_fp == 0) return;

    uint64_t space_id;
    unpack(space_id);

    CFStringRef __block display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), space_id);
    dispatch_sync(dispatch_get_main_queue(), ^{
        id new_space = macOSSequoia
                     ? [[objc_getClass("ManagedSpace") alloc] init]
                     : [[objc_getClass("Dock.ManagedSpace") alloc] init];
        id display_space = display_space_for_display_uuid(display_uuid);
        asm__call_add_space(new_space, display_space, add_space_fp);
        CFRelease(display_uuid);
    });
}

static void do_space_focus(char *message)
{
    if (dock_spaces == nil) return;

    uint64_t dest_space_id;
    unpack(dest_space_id);

    if (dest_space_id) {
        CFStringRef dest_display = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
        id source_space = macOSSequoia
                        ? ((id (*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(currentSpaceForDisplayUUID:), dest_display)
                        : ((id (*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(currentSpaceforDisplayUUID:), dest_display);
        uint64_t source_space_id = get_space_id(source_space);

        if (source_space_id != dest_space_id) {
            id dest_space = space_for_display_with_id(dest_display, dest_space_id);
            if (dest_space != nil) {
                id display_space = display_space_for_space_with_id(source_space_id);
                if (display_space != nil) {
                    NSArray *ns_source_space = @[ @(source_space_id) ];
                    NSArray *ns_dest_space = @[ @(dest_space_id) ];
                    SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_dest_space);
                    SLSHideSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_source_space);
                    SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display, dest_space_id);
                    set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
                    [ns_dest_space release];
                    [ns_source_space release];
                }
            }
        }

        CFRelease(dest_display);
    }
}

static void do_window_scale(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    // Get the actual window bounds (e.g., 600x400 at some position)
    CGRect frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);
    
    // Return a transform which translates by `(tx, ty)':t' = [ 1 0 0 1 tx ty ]
    CGAffineTransform original_transform = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);


    CGAffineTransform current_transform; 
    // Get the current transform applied to the window and store it in `current_transform`
    SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform);

    // on first run, current_transform == original_transform 
    // so this will be true. This creates the PiP window.
    if (CGAffineTransformEqualToTransform(current_transform, original_transform)) {
        float dx, dy, dw, dh;
        // Unpack the screen coordinates with padding applied
        // For a 1024x768 screen with 20px padding: dx=20, dy=20, dw=984, dh=728
        unpack(dx); // left padding (20)
        unpack(dy); // top padding (20)
        unpack(dw); // usable width (1024 - 20 - 20 = 984)
        unpack(dh); // usable height (768 - 20 - 20 = 728)

        // Calculate PiP window size (1/4 of usable screen width)
        int target_width  = dw / 4; // 984 / 4 = 246px wide
        // Maintain window's aspect ratio (600:400 = 1.5:1)
        int target_height = target_width / (frame.size.width/frame.size.height); // 246 / 1.5 = 164px tall

        // Calculate scale factors to shrink the 600x400 window to 246x164
        float x_scale = frame.size.width/target_width;   // 600/246 = 2.44x
        float y_scale = frame.size.height/target_height; // 400/164 = 2.44x

        // Calculate transform position to place PiP at bottom-right corner
        // transformed_x positions the scaled window's right edge at screen's right edge
        CGFloat transformed_x = -(dx+dw) + (frame.size.width * (1/x_scale)); // -(20+984) + (600/2.44) = -1004 + 246 = -758
        // transformed_y positions the scaled window at the bottom padding
        CGFloat transformed_y = -dy; // -20

        
        // Apply the scale transform (shrink to 246x164)
        CGAffineTransform scale = CGAffineTransformConcat(CGAffineTransformIdentity, CGAffineTransformMakeScale(x_scale, y_scale));
        // Then translate to position at bottom-right corner
        CGAffineTransform transform = CGAffineTransformTranslate(scale, transformed_x, transformed_y);
        SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
    } else {
        // Window is already in PiP mode, restore to original size/position
        SLSSetWindowTransform(SLSMainConnectionID(), wid, original_transform);
    }
}

static void do_window_scale_custom(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    CGRect frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);
    CGAffineTransform original_transform = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);

    CGAffineTransform current_transform;
    SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform);

    // Unpack the operation mode and coordinates
    int mode;
    unpack(mode);
    
    float dx, dy, dw, dh;
    unpack(dx);
    unpack(dy);
    unpack(dw);
    unpack(dh);
    
    // Optional: Unpack clipping rectangle (0 means no clipping)
    float clip_x, clip_y, clip_w, clip_h;
    unpack(clip_x);
    unpack(clip_y);
    unpack(clip_w);
    unpack(clip_h);
    
    bool should_clip = (clip_w > 0 && clip_h > 0);

    switch (mode) {
        case 0: // create_pip - scale window and position it
        {
            if (!CGAffineTransformEqualToTransform(current_transform, original_transform)) {
                // Already scaled, restore first then create
                SLSSetWindowTransform(SLSMainConnectionID(), wid, original_transform);
            }
            
            int target_width  = dw;
            int target_height = target_width / (dw/dh);

            float x_scale = 1;
            float y_scale = 1;

            CGFloat transformed_x = -(dx+dw) + (frame.size.width * (1/x_scale));
            CGFloat transformed_y = -dy;
            
            NSLog(@"🎯 create_pip: target(%f,%f,%f,%f) transform(%f,%f) scale(%f,%f)", 
                   dx, dy, dw, dh, transformed_x, transformed_y, x_scale, y_scale);
            
            CGAffineTransform scale = CGAffineTransformConcat(CGAffineTransformIdentity, CGAffineTransformMakeScale(x_scale, y_scale));
            CGAffineTransform transform = CGAffineTransformTranslate(scale, transformed_x, transformed_y);
            SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
            break;
        }
        
        case 1: // move_pip - update position of already scaled window
        {
            if (CGAffineTransformEqualToTransform(current_transform, original_transform)) {
                // Not scaled yet, can't move - should create first
                NSLog(@"🎯 move_pip: window not scaled, ignoring");
                return;
            }
            
            // Extract current scale from transform
            float current_x_scale = current_transform.a;
            float current_y_scale = current_transform.d;
            
            // Calculate new translation using existing scale and new coordinates
            CGFloat new_transformed_x = -(dx+dw) + (frame.size.width * (1/current_x_scale));
            CGFloat new_transformed_y = -dy;
            
            NSLog(@"🎯 move_pip: new_pos(%f,%f) transform(%f,%f) existing_scale(%f,%f)", 
                   dx, dy, new_transformed_x, new_transformed_y, current_x_scale, current_y_scale);
            
            CGAffineTransform scale = CGAffineTransformConcat(CGAffineTransformIdentity, CGAffineTransformMakeScale(current_x_scale, current_y_scale));
            CGAffineTransform transform = CGAffineTransformTranslate(scale, new_transformed_x, new_transformed_y);
            SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
            break;
        }
        
        case 2: // restore_pip - reset to original transform
        {
            NSLog(@"🎯 restore_pip: resetting to original transform");
            SLSSetWindowTransform(SLSMainConnectionID(), wid, original_transform);
            break;
        }
        
        default:
            NSLog(@"🎯 unknown mode: %d", mode);
            break;
    }
    
}

static void do_window_scale_forced_local(CFTypeRef transaction, uint32_t wid, int mode,
                                         float start_x, float start_y, float start_w, float start_h,
                                         float current_x, float current_y, float current_w, float current_h,
                                         float end_x, float end_y, float end_w, float end_h,
                                         float opacity, float duration, uint32_t proxy_wid, int resize_anchor, int meta)
{
    if (!wid) {
        return;
    }
    
    int sx, sy, sw, sh;
    sx = start_x; sy = start_y; sw = start_w; sh = start_h;
    int cx, cy, cw, ch;
    cx = current_x; cy = current_y; cw = current_w; ch = current_h;
    int ex, ey, ew, eh;
    ex = end_x; ey = end_y; ew = end_w; eh = end_h;
    
    // Unpack individual values from meta using bit operations
    int opacity_enabled = 0;                    // bit 0
    int fade_threshold = 5;             // bits 1-8 (0-255)
    int extra_flag = (meta >> 9) & 0x1;                  // bit 9 (for future use)
    // bits 10-31 reserved for additional flags/values

    CGRect frame = {};
    if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame) != kCGErrorSuccess) {
        return;
    }
    
    int guess1 = 0;
    int guess2 = 0;

    float window_alpha;
    SLSGetWindowAlpha(SLSMainConnectionID(), wid, &window_alpha);
    CGRect display = CGDisplayBounds(CGMainDisplayID());

    float start_x_factor = frame.size.width / current_w;
    float start_y_factor = frame.size.height / current_h;

    CGFloat ax;
    CGFloat ay;
    switch (resize_anchor) {
        case 0: // TL
            ax = -current_x;
            ay = -current_y;
            break;
        case 1: // TR
            ax = -(current_x + current_w) + frame.size.width;
            ay = -current_y;
            break;
        case 2: // BL
            ax = -current_x;
            ay = -(current_y + current_h) + frame.size.height;
            break;
        case 3: // BR
            ax = -(current_x + current_w) + frame.size.width;
            ay = -(current_y + current_h) + frame.size.height;
            break;
        default:
            ax = -current_x;
            ay = -current_y;
            break;
    }
    
    CGAffineTransform curr_scale = CGAffineTransformMakeScale(start_x_factor, start_y_factor);

    // Use our helper function with correct parameters:
    // Window is physically at END position (ex, ey, ew, eh)
    // We want to transform it to CURRENT position (cx, cy, cw, ch)
    CGAffineTransform anchored_scale = create_anchor_transform(ex, ey, ew, eh, cx, cy, cw, ch, resize_anchor);
    CGAffineTransform translate = CGAffineTransformMakeTranslation(current_x - end_x, current_y - end_y);
    
    // Combined transform: scale first, then translate
    CGAffineTransform scale_and_translate = CGAffineTransformConcat(anchored_scale, translate);

    // Get the original transform for fallback
    CGAffineTransform original_transform;
    bool has_original = (SLSGetWindowTransform(SLSMainConnectionID(), wid, &original_transform) == kCGErrorSuccess);
    if (!has_original) {
        original_transform = CGAffineTransformIdentity;
    }

    // Determine the appropriate transform based on what changed
    bool changes_size = (fabs(start_w - end_w) > 1.0f || fabs(start_h - end_h) > 1.0f);
    bool changes_position = (fabs(start_x - end_x) > 1.0f || fabs(start_y - end_y) > 1.0f);
    
    // Check if position change is only due to anchor-based scaling
    bool is_anchor_induced_position_change = false;
    if (changes_size && changes_position) {
        switch (resize_anchor) {
            case 0: // TL - top-left stays put, position shouldn't change due to scaling
                is_anchor_induced_position_change = (start_x == end_x && start_y == end_y);
                break;
            case 1: // TR - top-right stays put, only X should change due to width scaling
                is_anchor_induced_position_change = (start_y == end_y);
                break;
            case 2: // BL - bottom-left stays put, only Y should change due to height scaling  
                is_anchor_induced_position_change = (start_x == end_x);
                break;
            case 3: // BR - bottom-right stays put, both X,Y change only due to scaling
                is_anchor_induced_position_change = true;
                break;
            default:
                is_anchor_induced_position_change = false;
                break;
        }
    }
    
    CGAffineTransform final_transform;
    if (changes_size && !changes_position) {
        // Pure scaling - use anchored scale transform
        final_transform = anchored_scale;
    } else if (!changes_size && changes_position) {
        // Pure translation - use translate transform
        final_transform = translate;
    } else if (changes_size && changes_position && is_anchor_induced_position_change) {
        // Position change is only due to anchor-based scaling - use pure anchored scale
        final_transform = anchored_scale;
    } else if (changes_size && changes_position) {
        // Both independent size and position changes - use combined transform
        final_transform = scale_and_translate;
    } else {
        // No changes - use original transform
        final_transform = original_transform;
    }

    float final_window_alpha = (mode == 2) ? opacity : window_alpha;

    switch (mode) {
        case 0: // Initial setup - create small fade-in effect
        {
            // Order proxy above the real window
            SLSTransactionOrderWindowGroup(transaction, proxy_wid, 1, wid);
            
            // Start with both windows at small size (start position)
            CGAffineTransform start_transform = create_anchor_transform(
                end_x, end_y, end_w, end_h,  // Window is physically at end position
                start_x, start_y, start_w, start_h,  // Make it appear at start position (small)
                resize_anchor
            );
            
            // Both windows start at the small transform
            SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, start_transform);
            SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, start_transform);

            // Window starts invisible, proxy starts visible (acts as captured content)
            SLSTransactionSetWindowAlpha(transaction, wid, 0.0f);
            //SLSTransactionSetWindowSystemAlpha(transaction, proxy_wid, window_alpha);
            
            NSLog(@"🎬 fade_small_to_large: mode=0 start_transform applied to both windows");
            break;
        }
        
        case 1: // Animation frame - scale up while cross-fading
        {
            // Calculate current transform based on interpolated size
            CGAffineTransform current_transform = create_anchor_transform(
                end_x, end_y, end_w, end_h,  // Window is physically at end position  
                current_x, current_y, current_w, current_h,  // Make it appear at current interpolated position
                resize_anchor
            );
            
            // Both windows scale up together
            SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, current_transform);
            SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, current_transform);
            
            // Calculate fade progress based on size progression
            float progress = 0.0f;
            if (fabs(end_w - start_w) > 1.0f) {
                progress = (current_w - start_w) / (end_w - start_w);
            } else if (fabs(end_h - start_h) > 1.0f) {
                progress = (current_h - start_h) / (end_h - start_h);
            }
            progress = fmax(0.0f, fmin(1.0f, progress)); // Clamp to [0,1]
            
            // Cross-fade: proxy fades out, real window fades in
            float proxy_alpha = window_alpha * (1.0f - progress);
            float window_alpha_current = window_alpha * progress;
            
            //SLSTransactionSetWindowSystemAlpha(transaction, proxy_wid, proxy_alpha);
                SLSTransactionSetWindowAlpha(transaction, wid, 1.0f * duration);
  
            
            NSLog(@"🎬 fade_small_to_large: mode=1 progress=%.3f proxy_alpha=%.3f window_alpha=%.3f", 
                  progress, proxy_alpha, window_alpha_current);
            break;
        }
        
        case 2: // Final position - complete the transition
        {
            // Hide proxy completely and order it behind
            //SLSTransactionSetWindowAlpha(transaction, proxy_wid, 0.0f);
            SLSTransactionOrderWindowGroup(transaction, proxy_wid, 0, wid);
            
            // Set window to final transform and full opacity
            SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, final_transform);
            SLSTransactionSetWindowAlpha(transaction, wid, 0.0);
            
            NSLog(@"🎬 fade_small_to_large: mode=2 final transform applied, proxy hidden");
            break;
        }
        
        default:
            break;
    }
}



static void do_window_scale_forced(char *message)
{
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());

    uint32_t wid;
    unpack(wid);
    if (!wid) {
        return;
    }
    
    int mode;
    unpack(mode);
    
    float start_x, start_y, start_w, start_h;
    unpack(start_x);
    unpack(start_y);
    unpack(start_w);
    unpack(start_h);
    int sx, sy, sw, sh;
    sx = start_x; sy = start_y; sw = start_w; sh = start_h;
    float current_x, current_y, current_w, current_h;
    unpack(current_x);
    unpack(current_y);
    unpack(current_w);
    unpack(current_h);
    int cx, cy, cw, ch;
    cx = current_x; cy = current_y; cw = current_w; ch = current_h;
    float end_x, end_y, end_w, end_h;
    unpack(end_x);
    unpack(end_y);
    unpack(end_w);
    unpack(end_h);
    int ex, ey, ew, eh;
    ex = end_x; ey = end_y; ew = end_w; eh = end_h;
    // Unpack opacity value (0.0 to 1.0)
    float opacity;
    unpack(opacity);
    
    // Unpack duration value (in seconds, 0.0 = immediate)
    float duration;
    unpack(duration);
    
    // Unpack proxy window ID (0 = no proxy)
    uint32_t proxy_wid;
    unpack(proxy_wid);
    
    // Unpack resize anchor (0-3: TL, TR, BL, BR)
    int resize_anchor;
    unpack(resize_anchor);
    
    // Unpack meta data (additional flags/info)
    int meta;
    unpack(meta);
    
    // Unpack individual values from meta using bit operations
    int opacity_enabled = 0;                    // bit 0
    int fade_threshold = 5;             // bits 1-8 (0-255)
    int extra_flag = (meta >> 9) & 0x1;                  // bit 9 (for future use)
    // bits 10-31 reserved for additional flags/values

    CGRect frame = {};
    if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame) != kCGErrorSuccess) {
        return;
    }
    
    int guess1 = 0;
    int guess2 = 0;

    float window_alpha;
    SLSGetWindowAlpha(SLSMainConnectionID(), wid, &window_alpha);
    CGRect display = CGDisplayBounds(CGMainDisplayID());

    float start_x_factor = frame.size.width / current_w;
    float start_y_factor = frame.size.height / current_h;


    CGFloat ax;
    CGFloat ay;
    switch (resize_anchor) {
        case 0: // TL
            ax = -current_x;
            ay = -current_y;
            break;
        case 1: // TR
            ax = -(current_x + current_w) + frame.size.width;
            ay = -current_y;
            break;
        case 2: // BL
            ax = -current_x;
            ay = -(current_y + current_h) + frame.size.height;
            break;
        case 3: // BR
            ax = -(current_x + current_w) + frame.size.width;
            ay = -(current_y + current_h) + frame.size.height;
            break;
        default:
            ax = -current_x;
            ay = -current_y;
            break;
    }
    CGAffineTransform curr_scale = CGAffineTransformMakeScale(start_x_factor, start_y_factor);
    //CGAffineTransform anchored_scale = CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformIdentity, curr_scale),CGAffineTransformMakeTranslation(ax, ay));

    // Use our helper function with correct parameters:
    // Window is physically at END position (ex, ey, ew, eh)
    // Want it to appear at CURRENT interpolated position (cx, cy, cw, ch)
    // Transform: end → current
    CGAffineTransform anchored_scale = create_anchor_transform(
        cx , cy, cw, ch,   
        ex, ey, ew, eh,          
        resize_anchor);

    bool is_tl = start_x == end_x && start_y == end_y;
    bool is_growing = (start_w < end_w || start_h < end_h);
    bool is_shrinking = (start_w > end_w || start_h > end_h);
    bool stays_same_size = (!is_growing && !is_shrinking);
    bool changes_size = (is_growing || is_shrinking);
    bool changes_position = (start_x != end_x || start_y != end_y);
    bool is_big_transition = (current_w < (end_w * TRANSITION_SIZE_THRESHOLD));
    float max_alpha = (window_alpha < 1.0f) ? window_alpha : opacity;
    float proxy_progress = 1.0f - duration;
    
    float fade_threshold_value = fade_threshold / 255.0f;
    
    // For big transitions, enforce minimum opacity to maintain visibility
    if (is_big_transition && max_alpha < TRANSITION_MIN_OPACITY) {
        max_alpha = TRANSITION_MIN_OPACITY;
    }
    
    float final_window_alpha, final_proxy_alpha;
    if (opacity_enabled) {
        // Use fade threshold for opacity calculations
        final_window_alpha = max_alpha * (1.0f - proxy_progress);
        final_proxy_alpha = proxy_progress;
        
        // Apply fade threshold - only fade if below threshold
        if (final_window_alpha < fade_threshold_value) {
            final_window_alpha = fade_threshold_value;
        }
    } else {
        // Opacity animations disabled - keep full opacity
        final_window_alpha = max_alpha;
        final_proxy_alpha = 0.0f;
    }


    CGAffineTransform translate = CGAffineTransformMakeTranslation(-(current_x), -(current_y));
    CGAffineTransform scale_and_translate = CGAffineTransformConcat(curr_scale,  translate);

    CGAffineTransform original_transform = CGAffineTransformMakeTranslation(-end_x, -end_y);
    CGAffineTransform current_transform;
    SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform);

    CGAffineTransform final_transform;
    
    // More robust logic: Check if position change is due to anchor-based scaling
    bool is_anchor_induced_position_change = false;
    if (changes_size && changes_position) {
        // Check if position change is only due to scaling from a specific anchor
        switch (resize_anchor) {
            case 0: // TL - top-left stays put, no position change expected
                is_anchor_induced_position_change = false;
                break;
            case 1: // TR - top-right stays put, only X should change due to width scaling
                is_anchor_induced_position_change = (start_y == end_y);
                break;
            case 2: // BL - bottom-left stays put, only Y should change due to height scaling  
                is_anchor_induced_position_change = (start_x == end_x);
                break;
            case 3: // BR - bottom-right stays put, both X,Y change only due to scaling
                is_anchor_induced_position_change = true;
                break;
            default:
                is_anchor_induced_position_change = false;
                break;
        }
    }
    
    if (changes_size && !changes_position) {
        // Pure scaling - use anchored scale transform
        final_transform = anchored_scale;
    } else if (!changes_size && changes_position) {
        // Pure translation - use translate transform
        final_transform = translate;
    } else if (changes_size && changes_position && is_anchor_induced_position_change) {
        // Position change is only due to anchor-based scaling - use pure anchored scale
        final_transform = anchored_scale;
    } else if (changes_size && changes_position) {
        // Both independent size and position changes - use combined transform
        final_transform = scale_and_translate;
    } else {
        // No changes - use original transform
        final_transform = original_transform;
    }

    switch (mode) {
        case 0: // Initial setup - move window to start position
        {
            //if (proxy_wid != 0) {
                
                SLSTransactionOrderWindowGroup(transaction, proxy_wid, 1, wid);
                
                SLSTransactionSetWindowSystemAlpha(transaction, wid, 1.0f);
                SLSTransactionSetWindowSystemAlpha(transaction, proxy_wid, 1.0f);

                SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, final_transform) ;
                SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, final_transform);
            //} 
            break;
        }
        
        case 1: // move_pip - update position using current interpolated values
        {
            if (changes_size && !changes_position) {
                // Pure scaling - use anchored scale transform
                 SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, anchored_scale);
                SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2,  anchored_scale);
            } else if (!changes_size && changes_position) {
                // Pure translation - use translate transform
                SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, translate);
                SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2,  translate);
            } else if (changes_size && changes_position && is_anchor_induced_position_change) {
                  SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, anchored_scale);
                     SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, anchored_scale);
                //SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, translate);
                    //SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, translate);    
                //                     SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, scale_and_translate);
                //SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, scale_and_translate);
                  
            } else if (changes_size && changes_position) {
                SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, anchored_scale);
                    SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, anchored_scale);
                    SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, translate);
                    SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, translate);
                //    SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, scale_and_translate);
                //SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, scale_and_translate);
                    
            } else {
                // No changes - use original transform
                SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, original_transform);
                SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2,  original_transform);
            }
                //SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, final_transform);
                //SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2,  final_transform);

                SLSTransactionSetWindowSystemAlpha(transaction, wid,  final_window_alpha);
                SLSTransactionSetWindowSystemAlpha(transaction, proxy_wid, final_proxy_alpha);
            break;
        }
        
        case 2: // restore_pip - reset to original transform
        {
            //if (proxy_wid == 0) {
                SLSTransactionSetWindowTransform(transaction, proxy_wid, guess1, guess2, final_transform);
                SLSTransactionSetWindowSystemAlpha(transaction, proxy_wid, 0.0f);
                SLSTransactionOrderWindowGroup(transaction, proxy_wid, 0, wid);
            //}
            SLSTransactionSetWindowTransform(transaction, wid, guess1, guess2, final_transform);

            SLSTransactionSetWindowSystemAlpha(transaction, wid, final_window_alpha);
            SLSTransactionSetWindowSystemAlpha(transaction, wid, window_alpha);

            break;
        }
        
        default:
            break;
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_animate_frame(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    // Unpack animation frame data
    float src_x, src_y, src_w, src_h;
    float dst_x, dst_y, dst_w, dst_h;
    float progress; // 0.0 to 1.0
    int anchor_point; // 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
    
    unpack(src_x); unpack(src_y); unpack(src_w); unpack(src_h);
    unpack(dst_x); unpack(dst_y); unpack(dst_w); unpack(dst_h);
    unpack(progress);
    unpack(anchor_point);
    
    // Interpolate current frame values
    float current_x = src_x + (dst_x - src_x) * progress;
    float current_y = src_y + (dst_y - src_y) * progress;
    float current_w = src_w + (dst_w - src_w) * progress;
    float current_h = src_h + (dst_h - src_h) * progress;
    
    // Get actual window bounds for transform calculation
    CGRect window_frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &window_frame);
    
    // Calculate scale factors
    float x_scale = window_frame.size.width / current_w;
        //testing
        //float x_scale = window_frame.size.width / current_w;

    float y_scale = window_frame.size.height / current_h;
        //testing
        //float y_scale = current_h;
    
    // Calculate anchor-based position
    float anchor_x = current_x;
    float anchor_y = current_y;
    
    switch (anchor_point) {
        case 0: // top-left (default)
            // anchor_x and anchor_y are already correct
            break;
        case 1: // top-right
            anchor_x = current_x + current_w - window_frame.size.width / x_scale;
            break;
        case 2: // bottom-left
            anchor_y = current_y + current_h - window_frame.size.height / y_scale;
            break;
        case 3: // bottom-right
            anchor_x = current_x + current_w - window_frame.size.width / x_scale;
            anchor_y = current_y + current_h - window_frame.size.height / y_scale;
            break;
    }
    
    // Calculate transform translation (relative to window's natural position)
    float transform_x = -(anchor_x + current_w) + (window_frame.size.width * (1.0f / x_scale));
    float transform_y = -anchor_y;
    
    // Apply the transform (reusing your existing scaling infrastructure)
    CGAffineTransform scale = CGAffineTransformMakeScale(x_scale, y_scale);
    CGAffineTransform transform = CGAffineTransformTranslate(scale, transform_x, transform_y);
    SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
    
    NSLog(@"🎬 animate_frame: wid=%d progress=%.2f pos=(%.1f,%.1f) size=(%.1fx%.1f) anchor=%d scale=(%.2f,%.2f)", 
          wid, progress, current_x, current_y, current_w, current_h, anchor_point, x_scale, y_scale);
}

static void do_window_warp(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    // Unpack warp parameters
    int effect_type; // 0=none, 1=wobble, 2=ripple
    float time;      // Animation time
    float intensity; // Effect intensity
    float center_x, center_y; // Center point for ripple effect
    
    unpack(effect_type);
    unpack(time);
    unpack(intensity);
    unpack(center_x);
    unpack(center_y);
    
    // Get window bounds
    CGRect window_frame = {};
    if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &window_frame) != kCGErrorSuccess) {
        NSLog(@"🌊 do_window_warp: failed to get window bounds for wid=%d", wid);
        return;
    }
    
    // Create mesh array
    CGPoint mesh[WARP_MESH_POINTS];
    
    switch (effect_type) {
        case 0: // No effect - reset to normal
        {
            // Create a perfectly regular mesh
            create_base_mesh(mesh, window_frame);
            NSLog(@"🌊 warp_reset: wid=%d", wid);
            break;
        }
        
        case 1: // Wobble effect
        {
            apply_wobble_effect(mesh, window_frame, time, intensity);
            NSLog(@"🌊 warp_wobble: wid=%d time=%.2f intensity=%.2f", wid, time, intensity);
            break;
        }
        
        case 2: // Ripple effect
        {
            CGPoint center = CGPointMake(center_x, center_y);
            apply_ripple_effect(mesh, window_frame, time, intensity, center);
            NSLog(@"🌊 warp_ripple: wid=%d time=%.2f intensity=%.2f center=(%.1f,%.1f)", 
                  wid, time, intensity, center_x, center_y);
            break;
        }
        
        default:
            NSLog(@"🌊 warp_unknown: unsupported effect type %d for wid=%d", effect_type, wid);
            return;
    }
    
    // Apply the warp mesh to the window
    CGError result = SLSSetWindowWarp(SLSMainConnectionID(), wid, WARP_MESH_WIDTH, WARP_MESH_HEIGHT, mesh);
    if (result != kCGErrorSuccess) {
        NSLog(@"🌊 warp_error: SLSSetWindowWarp failed with error %d for wid=%d", result, wid);
    }
}

static void do_animate_windows_list(char *message)
{
    // Unpack the minimal metadata
    uint64_t space_id;
    uint32_t window_count;
    float animation_progress; // 0.0 to 1.0
    uint32_t frame_number;
    uint32_t total_frames;
    uint8_t animation_mode; // 0=start, 1=update, 2=end
    
    unpack(space_id);
    unpack(window_count);
    unpack(animation_progress);
    unpack(frame_number);
    unpack(total_frames);
    unpack(animation_mode);
    
    if (window_count == 0) {
        NSLog(@"🎬 animate_windows_list: no windows to animate");
        return;
    }
    
    // Create a single transaction for all windows
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) {
        NSLog(@"🎬 animate_windows_list: failed to create transaction");
        return;
    }
    
    NSLog(@"🎬 animate_windows_list: space=%llu count=%u progress=%.3f frame=%u/%u mode=%u", 
          space_id, window_count, animation_progress, frame_number, total_frames, animation_mode);
    
    // Process each window in the batch
    for (uint32_t i = 0; i < window_count; i++) {
        uint32_t wid;
        unpack(wid);
        
        if (!wid) continue;
        //SLSTransactionSetWindowSystemAlpha(transaction, wid, 0.0f);
        // Unpack window animation data
        float start_x, start_y, start_w, start_h;
        float end_x, end_y, end_w, end_h;
        int resize_anchor; // 0-3: TL, TR, BL, BR
        uint8_t window_flags; // bit flags for special handling
        
        unpack(start_x); unpack(start_y); unpack(start_w); unpack(start_h);
        unpack(end_x); unpack(end_y); unpack(end_w); unpack(end_h);
        unpack(resize_anchor);
        unpack(window_flags);
        
        // Calculate interpolated position and size
        float current_x = start_x + (end_x - start_x) * animation_progress;
        float current_y = start_y + (end_y - start_y) * animation_progress;
        float current_w = start_w + (end_w - start_w) * animation_progress;
        float current_h = start_h + (end_h - start_h) * animation_progress;
        
        // Calculate opacity based on animation progress and flags
        float opacity = 1.0f;
        if (window_flags & 0x01) { // opacity animation flag
            float start_alpha = 1.0f;
            float end_alpha = 1.0f;
            opacity = start_alpha + (end_alpha - start_alpha) * animation_progress;
        }
        
        // Default duration for SLS calls (not used in this context but required by local function)
        float duration = 0.0f;
        
        // No proxy window in batch animations
        uint32_t proxy_wid = 0;
        
        // Pack window flags into meta parameter (opacity enabled, fade threshold, etc.)
        int meta = (window_flags & 0x01) ? 1 : 0; // opacity_enabled bit
        meta |= (5 << 1); // fade_threshold = 5 (bits 1-8)
        
        // Use the existing local function to handle all the complex transform logic
        do_window_scale_forced_local(transaction, wid, animation_mode,
                                   start_x, start_y, start_w, start_h,
                                   current_x, current_y, current_w, current_h,
                                   end_x, end_y, end_w, end_h,
                                   opacity, duration, proxy_wid, resize_anchor, meta);
        
        NSLog(@"🎬 window: wid=%u pos=(%.1f,%.1f) size=(%.1fx%.1f) anchor=%d mode=%u", 
              wid, current_x, current_y, current_w, current_h, resize_anchor, animation_mode);
    }
    
    // Commit the entire batch transaction
    CGError commit_result = SLSTransactionCommit(transaction, 1); // synchronous commit
    if (commit_result != kCGErrorSuccess) {
        NSLog(@"🎬 animate_windows_list: transaction commit failed with error %d", commit_result);
    }
    
    // Clean up
    CFRelease(transaction);
    
    NSLog(@"🎬 animate_windows_list: batch completed for %u windows", window_count);
}

static void do_window_move(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    int x, y;
    unpack(x);
    unpack(y);

    CGPoint point = CGPointMake(x, y);
    SLSMoveWindowWithGroup(SLSMainConnectionID(), wid, &point);

    NSArray *window_list = @[ @(wid) ];
    SLSReassociateWindowsSpacesByGeometry(SLSMainConnectionID(), (__bridge CFArrayRef) window_list);
    [window_list release];
}

static void do_window_opacity(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float alpha;
    unpack(alpha);

    pthread_mutex_lock(&window_fade_lock);
    struct window_fade_context *context = table_find(&window_fade_table, &wid);

    if (context) {
        context->alpha = alpha;
        context->duration = 0.0f;
        __asm__ __volatile__ ("" ::: "memory");

        context->skip = true;
        pthread_mutex_unlock(&window_fade_lock);
    } else {
        SLSSetWindowAlpha(SLSMainConnectionID(), wid, alpha);
        pthread_mutex_unlock(&window_fade_lock);
    }
}

static void *window_fade_thread_proc(void *data)
{
entry:;
    struct window_fade_context *context = (struct window_fade_context *) data;
    context->skip  = false;

    float start_alpha;
    float end_alpha = context->alpha;
    SLSGetWindowAlpha(SLSMainConnectionID(), context->wid, &start_alpha);

    int frame_duration = 8;
    int total_duration = (int)(context->duration * 1000.0f);
    int frame_count = (int)(((float) total_duration / (float) frame_duration) + 1.0f);

    for (int frame_index = 1; frame_index <= frame_count; ++frame_index) {
        if (context->skip) goto entry;

        float t = (float) frame_index / (float) frame_count;
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;

        float alpha = lerp(start_alpha, t, end_alpha);
        SLSSetWindowAlpha(SLSMainConnectionID(), context->wid, alpha);

        usleep(frame_duration*1000);
    }

    pthread_mutex_lock(&window_fade_lock);
    if (!context->skip) {
        table_remove(&window_fade_table, &context->wid);
        pthread_mutex_unlock(&window_fade_lock);
        free(context);
        return NULL;
    }
    pthread_mutex_unlock(&window_fade_lock);

    goto entry;
}

static void do_window_opacity_fade(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float alpha, duration;
    unpack(alpha);
    unpack(duration);

    pthread_mutex_lock(&window_fade_lock);
    struct window_fade_context *context = table_find(&window_fade_table, &wid);

    if (context) {
        context->alpha = alpha;
        context->duration = duration;
        __asm__ __volatile__ ("" ::: "memory");

        context->skip = true;
        pthread_mutex_unlock(&window_fade_lock);
    } else {
        context = malloc(sizeof(struct window_fade_context));
        context->wid = wid;
        context->alpha = alpha;
        context->duration = duration;
        context->skip = false;
        __asm__ __volatile__ ("" ::: "memory");

        table_add(&window_fade_table, &wid, context);
        pthread_mutex_unlock(&window_fade_lock);
        pthread_create(&context->thread, NULL, &window_fade_thread_proc, context);
        pthread_detach(context->thread);
    }
}

static void do_window_layer(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    int layer;
    unpack(layer);

    SLSSetWindowSubLevel(SLSMainConnectionID(), wid, CGWindowLevelForKey(layer));
}

static void do_window_sticky(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    bool value;
    unpack(value);

    uint64_t tags = (1 << 11);
    if (value == 1) {
        SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    } else {
        SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    }
}

typedef void (*focus_window_call)(ProcessSerialNumber psn, uint32_t wid);
static void do_window_focus(char *message)
{
    if (set_front_window_fp == 0) return;

    int window_connection;
    ProcessSerialNumber window_psn;

    uint32_t wid;
    unpack(wid);

    SLSGetWindowOwner(SLSMainConnectionID(), wid, &window_connection);
    SLSGetConnectionPSN(SLSMainConnectionID(), &window_psn);

    ((focus_window_call) set_front_window_fp)(window_psn, wid);
}

static void do_window_shadow(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    bool value;
    unpack(value);

    uint64_t tags = (1 << 3);
    if (value == 1) {
        SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    } else {
        SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    }
}

static void do_window_swap_proxy_in(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        uint32_t proxy_wid;
        unpack(proxy_wid);

        SLSTransactionOrderWindowGroup(transaction, proxy_wid, 1, wid);
        SLSTransactionSetWindowSystemAlpha(transaction, wid, 0);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_swap_proxy_out(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        uint32_t proxy_wid;
        unpack(proxy_wid);

        SLSTransactionSetWindowSystemAlpha(transaction, wid, 1.0f);
        SLSTransactionOrderWindowGroup(transaction, proxy_wid, 0, wid);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_order(char *message)
{
    uint32_t a_wid;
    unpack(a_wid);
    if (!a_wid) return;

    int order;
    unpack(order);

    uint32_t b_wid;
    unpack(b_wid);

    SLSOrderWindow(SLSMainConnectionID(), a_wid, order, b_wid);
}

static void do_window_order_in(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        SLSTransactionOrderWindowGroup(transaction, wid, 1, 0);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static inline CFArrayRef cfarray_of_cfnumbers(void *values, size_t size, int count, CFNumberType type)
{
    CFNumberRef temp[count];

    for (int i = 0; i < count; ++i) {
        temp[i] = CFNumberCreate(NULL, type, ((char *)values) + (size * i));
    }

    CFArrayRef result = CFArrayCreate(NULL, (const void **)temp, count, &kCFTypeArrayCallBacks);

    for (int i = 0; i < count; ++i) {
        CFRelease(temp[i]);
    }

    return result;
}

static void do_window_list_move_to_space(char *message)
{
    uint64_t sid;
    unpack(sid);

    int count = 0;
    unpack(count);

    CFArrayRef window_list_ref = cfarray_of_cfnumbers((uint32_t*)message, sizeof(uint32_t), count, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);
    CFRelease(window_list_ref);
}

static void do_window_move_to_space(char *message)
{
    uint64_t sid;
    unpack(sid);

    uint32_t wid;
    unpack(wid);

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);
    CFRelease(window_list_ref);
}

static void do_handshake(int sockfd)
{
    uint32_t attrib = 0;

    if (dock_spaces != nil)                attrib |= OSAX_ATTRIB_DOCK_SPACES;
    if (dp_desktop_picture_manager != nil) attrib |= OSAX_ATTRIB_DPPM;
    if (add_space_fp)                      attrib |= OSAX_ATTRIB_ADD_SPACE;
    if (remove_space_fp)                   attrib |= OSAX_ATTRIB_REM_SPACE;
    if (move_space_fp)                     attrib |= OSAX_ATTRIB_MOV_SPACE;
    if (set_front_window_fp)               attrib |= OSAX_ATTRIB_SET_WINDOW;
    if (animation_time_addr)               attrib |= OSAX_ATTRIB_ANIM_TIME;

    char bytes[BUFSIZ] = {};
    int version_length = strlen(OSAX_VERSION);
    int attrib_length = sizeof(uint32_t);
    int bytes_length = version_length + 1 + attrib_length;

    memcpy(bytes, OSAX_VERSION, version_length);
    memcpy(bytes + version_length + 1, &attrib, attrib_length);
    bytes[version_length] = '\0';
    bytes[bytes_length] = '\n';

    send(sockfd, bytes, bytes_length+1, 0);
}

static void handle_message(int sockfd, char *message)
{
    enum sa_opcode op = *message++;
    switch (op) {
    case SA_OPCODE_HANDSHAKE: {
        do_handshake(sockfd);
    } break;
    case SA_OPCODE_SPACE_FOCUS: {
        do_space_focus(message);
    } break;
    case SA_OPCODE_SPACE_CREATE: {
        do_space_create(message);
    } break;
    case SA_OPCODE_SPACE_DESTROY: {
        do_space_destroy(message);
    } break;
    case SA_OPCODE_SPACE_MOVE: {
        do_space_move(message);
    } break;
    case SA_OPCODE_WINDOW_MOVE: {
        do_window_move(message);
    } break;
    case SA_OPCODE_WINDOW_OPACITY: {
        do_window_opacity(message);
    } break;
    case SA_OPCODE_WINDOW_OPACITY_FADE: {
        do_window_opacity_fade(message);
    } break;
    case SA_OPCODE_WINDOW_LAYER: {
        do_window_layer(message);
    } break;
    case SA_OPCODE_WINDOW_STICKY: {
        do_window_sticky(message);
    } break;
    case SA_OPCODE_WINDOW_SHADOW: {
        do_window_shadow(message);
    } break;
    case SA_OPCODE_WINDOW_FOCUS: {
        do_window_focus(message);
    } break;
    case SA_OPCODE_WINDOW_SCALE: {
        do_window_scale(message);
    } break;
    case SA_OPCODE_WINDOW_SCALE_CUSTOM: {
        do_window_scale_custom(message);
    } break;
    case SA_OPCODE_WINDOW_SCALE_FORCED: {
        do_window_scale_forced(message);
    } break;
    case SA_OPCODE_WINDOW_ANIMATE_FRAME: {
        do_window_animate_frame(message);
    } break;
    case SA_OPCODE_WINDOW_ANIMATE_LIST: {
        do_animate_windows_list(message);
    } break;
    case SA_OPCODE_WINDOW_WARP: {
        do_window_warp(message);
    } break;
    case SA_OPCODE_WINDOW_SWAP_PROXY_IN: {
        do_window_swap_proxy_in(message);
    } break;
    case SA_OPCODE_WINDOW_SWAP_PROXY_OUT: {
        do_window_swap_proxy_out(message);
    } break;
    case SA_OPCODE_WINDOW_ORDER: {
        do_window_order(message);
    } break;
    case SA_OPCODE_WINDOW_ORDER_IN: {
        do_window_order_in(message);
    } break;
    case SA_OPCODE_WINDOW_LIST_TO_SPACE: {
        do_window_list_move_to_space(message);
    } break;
    case SA_OPCODE_WINDOW_TO_SPACE: {
        do_window_move_to_space(message);
    } break;
    }
}

static inline bool read_message(int sockfd, char *message)
{
    int bytes_read    = 0;
    int bytes_to_read = 0;

    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) == sizeof(int16_t)) {
        do {
            int cur_read = read(sockfd, message+bytes_read, bytes_to_read-bytes_read);
            if (cur_read <= 0) break;

            bytes_read += cur_read;
        } while (bytes_read < bytes_to_read);
        return bytes_read == bytes_to_read;
    }

    return false;
}

static void *handle_connection(void *unused)
{
    for (;;) {
        int sockfd = accept(daemon_sockfd, NULL, 0);
        if (sockfd == -1) continue;

        char message[0x1000];
        if (read_message(sockfd, message)) {
            handle_message(sockfd, message);
        }

        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
    }

    return NULL;
}

static TABLE_HASH_FUNC(hash_wid)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(compare_wid)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
}

static bool start_daemon(char *socket_path)
{
    struct sockaddr_un socket_address;
    socket_address.sun_family = AF_UNIX;
    snprintf(socket_address.sun_path, sizeof(socket_address.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        return false;
    }

    if (bind(daemon_sockfd, (struct sockaddr *) &socket_address, sizeof(socket_address)) == -1) {
        return false;
    }

    if (chmod(socket_path, 0600) != 0) {
        return false;
    }

    if (listen(daemon_sockfd, SOMAXCONN) == -1) {
        return false;
    }

    init_instances();
    pthread_mutex_init(&window_fade_lock, NULL);
    table_init(&window_fade_table, 150, hash_wid, compare_wid);
    pthread_create(&daemon_thread, NULL, &handle_connection, NULL);

    return true;
}

__attribute__((constructor))
void load_payload(void)
{
    NSLog(@"[yabai-sa] loaded payload..");

    const char *user = getenv("USER");
    if (!user) {
        NSLog(@"[yabai-sa] could not get 'env USER'! abort..");
        return;
    }

    char socket_file[255];
    snprintf(socket_file, sizeof(socket_file), SOCKET_PATH_FMT, user);

    if (start_daemon(socket_file)) {
        NSLog(@"[yabai-sa] now listening..");
    } else {
        NSLog(@"[yabai-sa] failed to spawn thread..");
    }
}
