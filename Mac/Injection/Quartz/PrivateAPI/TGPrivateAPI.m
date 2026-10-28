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

// Method signatures from Apple's HIDEvent headers. Class lookup stays dynamic.
@protocol TGDynamicHIDEvent
- (instancetype)initWithType:(uint32_t)type timestamp:(uint64_t)timestamp senderID:(uint64_t)senderID;
- (void)setOptions:(uint32_t)options;
- (void)setIntegerValue:(NSInteger)value forField:(uint32_t)field;
- (void)setDoubleValue:(double)value forField:(uint32_t)field;
- (void)appendEvent:(id)event;
@end

// Returns the dynamic HIDEvent class once every required selector is present, else Nil.
static Class TGHIDEventClass(void) {
    (void)TGPrivateAPIGetCapabilities();
    Class cls = NSClassFromString(@"HIDEvent");
    if (!cls) return Nil;
    for (NSString *name in @[@"initWithType:timestamp:senderID:", @"setOptions:", @"setIntegerValue:forField:", @"setDoubleValue:forField:", @"appendEvent:"]) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(name)]) return Nil;
    }
    return cls;
}

id TGCreateDockHIDEvent(int64_t kind, int64_t phase, double progress, double velocity) {
    Class cls = TGHIDEventClass();
    if (!cls) return nil;
    id<TGDynamicHIDEvent> event = [(id<TGDynamicHIDEvent>)[cls alloc] initWithType:TGHIDDockSwipe timestamp:0 senderID:0];
    [event setOptions:(uint32_t)phase << TGHIDPhaseShift];
    [event setIntegerValue:kind forField:TGHIDDockMotionField];
    [event setIntegerValue:TGHIDDockPrimary forField:TGHIDDockFlavorField];
    [event setDoubleValue:progress forField:TGHIDDockProgressField];
    if (phase == TGPhaseEnded || phase == TGPhaseCancelled) {
        id<TGDynamicHIDEvent> child = [(id<TGDynamicHIDEvent>)[cls alloc] initWithType:TGHIDVelocity timestamp:0 senderID:0];
        [child setDoubleValue:velocity forField:TGHIDVelocityXField];
        [child setDoubleValue:velocity forField:TGHIDVelocityYField];
        [child setDoubleValue:0 forField:TGHIDVelocityZField];
        [event appendEvent:child];
    }
    return event;
}

id TGCreateFluidTouchHIDEvent(int64_t motion, int64_t flavor, int64_t phase, double progress) {
    Class cls = TGHIDEventClass();
    if (!cls) return nil;
    id<TGDynamicHIDEvent> event = [(id<TGDynamicHIDEvent>)[cls alloc] initWithType:TGHIDFluidTouchGesture timestamp:0 senderID:0];
    [event setOptions:(uint32_t)phase << TGHIDPhaseShift];
    [event setIntegerValue:0 forField:TGHIDFluidMaskField];
    [event setIntegerValue:motion forField:TGHIDFluidMotionField];
    [event setIntegerValue:flavor forField:TGHIDFluidFlavorField];
    [event setDoubleValue:progress forField:TGHIDFluidProgressField];
    return event;
}

id TGCreateForceHIDEvent(int64_t stage, double pressure, double progress) {
    Class cls = TGHIDEventClass();
    if (!cls) return nil;
    id<TGDynamicHIDEvent> event = [(id<TGDynamicHIDEvent>)[cls alloc] initWithType:TGHIDForce timestamp:0 senderID:0];
    [event setIntegerValue:0 forField:TGHIDForceBehaviorField];
    [event setIntegerValue:stage forField:TGHIDForceStageField];
    [event setDoubleValue:pressure forField:TGHIDForceStagePressureField];
    [event setDoubleValue:progress forField:TGHIDForceProgressField];
    return event;
}

bool TGAttachHIDEvent(CGEventRef event, id hidEvent) {
    PrivateAPICapabilities capabilities = TGPrivateAPIGetCapabilities();
    // dockSwipe is the "HIDEvent class + attachment symbol" capability; every attached path shares it.
    if (!capabilities.dockSwipe) return false;
    const char *name = capabilities.attachmentSymbol == 1 ? "CGEventSetHIDEvent" : "CGEventSetIOHIDEvent";
    void (*attach)(CGEventRef, id) = dlsym(RTLD_DEFAULT, name);
    if (!attach) return false;
    attach(event, hidEvent);
    return true;
}

bool TGAttachDockHIDEvent(CGEventRef event, id hidEvent) {
    return TGAttachHIDEvent(event, hidEvent);
}
