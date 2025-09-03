#include <unistd.h>  // for usleep
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
void set_next_space_shortcut(int carbonMods, int keyCode) {
    // Build the new “value” dict { type = standard; parameters = (mods, keyCode, 0) }
    CFNumberRef modsNum = CFNumberCreate(NULL, kCFNumberIntType, &carbonMods);
    CFNumberRef codeNum = CFNumberCreate(NULL, kCFNumberIntType, &keyCode);
    int zeroValue = 0;
    CFNumberRef zeroNum = CFNumberCreate(NULL, kCFNumberIntType, &zeroValue);
    CFArrayRef paramsArr = CFArrayCreate(NULL,
                                          (const void *[]){ modsNum, codeNum, zeroNum },
                                          3,
                                          &kCFTypeArrayCallBacks);
    CFRelease(zeroNum);
    CFDictionaryRef valueDict;
    {
        const void *valueKeys[]   = { CFSTR("type"), CFSTR("parameters") };
        const void *valueValues[] = { CFSTR("standard"), paramsArr };
        valueDict = CFDictionaryCreate(NULL,
                                       valueKeys,
                                       valueValues,
                                       2,
                                       &kCFTypeDictionaryKeyCallBacks,
                                       &kCFTypeDictionaryValueCallBacks);
    }

    // Wrap it in the outer entry:
    CFDictionaryRef newEntry = CFDictionaryCreate(NULL,
        (const void *[]){ CFSTR("enabled"), CFSTR("value") },
        (const void *[]){ kCFBooleanTrue, valueDict         },
        2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    // Read existing hotkeys dictionary
    CFDictionaryRef existing = CFPreferencesCopyValue(
      CFSTR("AppleSymbolicHotKeys"),
      CFSTR("com.apple.symbolichotkeys"),
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    );
    CFMutableDictionaryRef mutableDict;
    if (existing) {
        mutableDict = CFDictionaryCreateMutableCopy(NULL, 0, existing);
        CFRelease(existing);
    } else {
        mutableDict = CFDictionaryCreateMutable(
            NULL,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
    }

    // Insert or replace the "119" entry
    CFDictionarySetValue(mutableDict, CFSTR("119"), newEntry);

    // Write back the updated dictionary
    CFPreferencesSetValue(
      CFSTR("AppleSymbolicHotKeys"),
      mutableDict,
      CFSTR("com.apple.symbolichotkeys"),
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    );
    CFPreferencesAppSynchronize(CFSTR("com.apple.symbolichotkeys"));
    CFRelease(mutableDict);

    // Tear down
    CFRelease(modsNum);
    CFRelease(codeNum);
    CFRelease(paramsArr);
    CFRelease(valueDict);
    CFRelease(newEntry);
    // system("killall cfprefsd"); // No longer needed, AppSynchronize is sufficient
}

// 119 == “Move right a space”
static const CFStringRef kNextSpaceID = CFSTR("119");

// Read the Carbon-style modifiers & keyCode from prefs
static bool get_next_space_binding(CGKeyCode *outKey, CGEventFlags *outFlags) {
    CFDictionaryRef all = CFPreferencesCopyValue(
        CFSTR("AppleSymbolicHotKeys"),
        CFSTR("com.apple.symbolichotkeys"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );
    if (!all) return false;

    CFDictionaryRef entry = CFDictionaryGetValue(all, kNextSpaceID);
    if (!entry) { CFRelease(all); return false; }
    CFDictionaryRef value = CFDictionaryGetValue(entry, CFSTR("value"));
    CFArrayRef params    = CFDictionaryGetValue(value, CFSTR("parameters"));
    if (CFGetTypeID(params) != CFArrayGetTypeID() || CFArrayGetCount(params) < 2) {
        CFRelease(all);
        return false;
    }

    int carbonMods = 0, keyCode = 0;
    CFNumberGetValue(CFArrayGetValueAtIndex(params, 0), kCFNumberIntType, &carbonMods);
    CFNumberGetValue(CFArrayGetValueAtIndex(params, 1), kCFNumberIntType, &keyCode);
    CFRelease(all);

    // Map Carbon mask bits → CGEventFlags
    CGEventFlags flags = 0;
    if (carbonMods & (1 << 0)) flags |= kCGEventFlagMaskShift;
    if (carbonMods & (1 << 1)) flags |= kCGEventFlagMaskControl;
    if (carbonMods & (1 << 2)) flags |= kCGEventFlagMaskAlternate;
    if (carbonMods & (1 << 3)) flags |= kCGEventFlagMaskCommand;

    *outKey   = (CGKeyCode)keyCode;
    *outFlags = flags;
    return true;
}

// Post a single key-down or key-up event
static void post_key(CGKeyCode key, CGEventFlags flags, bool down) {
    CGEventRef ev = CGEventCreateKeyboardEvent(NULL, key, down);
    CGEventSetFlags(ev, flags);
	debug("next-space keycode=%d, flags=0x%llx\n", key, flags);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

// Trigger the “next space” shortcut (down + up)
void trigger_next_space_shortcut(void) {
	debug("triggering next space \n");
    CGKeyCode    key;
    CGEventFlags flags;

    if (!get_next_space_binding(&key, &flags)) return;
    post_key(key, flags, true);
    usleep(8000);  // small delay to ensure key event is registered
    post_key(key, flags, false);
}