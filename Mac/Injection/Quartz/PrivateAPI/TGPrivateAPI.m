#import "TGPrivateAPI.h"
#import <dlfcn.h>
#import <os/log.h>

static void *TGLookupSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static Class TGLookupClass(const char *name) {
    return NSClassFromString([NSString stringWithUTF8String:name]);
}

PrivateAPICapabilities TGPrivateAPIProbe(TGSymbolLookup symbols, TGClassLookup classes) {
    PrivateAPICapabilities result = {0};
    // Public CGEvent construction supports the legacy gesture-field mechanism.
    // Runtime availability is not proof of application-level gesture acceptance.
    CGEventRef event = CGEventCreate(NULL);
    result.gestureEvents = event != NULL;
    if (event) CFRelease(event);

    if (symbols("CGEventSetHIDEvent")) result.attachmentSymbol = 1;
    else if (symbols("CGEventSetIOHIDEvent")) result.attachmentSymbol = 2;

    Class hidClass = classes("HIDEvent");
    result.hidEventClass = hidClass != Nil;
    BOOL methodsAvailable = hidClass != Nil;
    const char *selectors[] = {
        "initWithType:timestamp:senderID:", "setOptions:",
        "setIntegerValue:forField:", "setDoubleValue:forField:", "appendEvent:"
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (![hidClass instancesRespondToSelector:NSSelectorFromString(
                [NSString stringWithUTF8String:selectors[i]])]) methodsAvailable = NO;
    }
    // Missing APIs select the discrete keyboard fallback in the later injector.
    result.dockSwipe = result.gestureEvents && result.attachmentSymbol != 0 && methodsAvailable;
    // Keep these disabled until their physical G-NC/G-FORCE gates pass.
    // Their specified fallbacks are the AX Clock action and keyboard Look Up.
    result.fluidTouchGesture = NO;
    result.forceEvent = NO;
    return result;
}

PrivateAPICapabilities TGPrivateAPIGetCapabilities(void) {
    static dispatch_once_t once;
    static PrivateAPICapabilities capabilities;
    dispatch_once(&once, ^{
        // Optional frameworks must never become load-time linker dependencies.
        // Retain successful handles for process lifetime so resolved APIs stay valid.
        (void)dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_LAZY | RTLD_GLOBAL);
        (void)dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
        capabilities = TGPrivateAPIProbe(TGLookupSymbol, TGLookupClass);
        os_log_info(OS_LOG_DEFAULT, "Trackglass private API: attachment=%u HIDEvent=%d dock=%d gesture=%d fluid=%d force=%d",
                    capabilities.attachmentSymbol, capabilities.hidEventClass,
                    capabilities.dockSwipe, capabilities.gestureEvents,
                    capabilities.fluidTouchGesture, capabilities.forceEvent);
    });
    return capabilities;
}
