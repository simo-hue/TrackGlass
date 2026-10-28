#import "TGPrivateAPI.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>

static void *TGLookupSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static Class TGLookupClass(const char *name) {
    return NSClassFromString([NSString stringWithUTF8String:name]);
}

// True when the class exposes every selector the HID event factories send (Apple's HIDEvent headers).
static BOOL TGHIDEventClassUsable(Class hidClass) {
    if (hidClass == Nil) return NO;
    const char *selectors[] = {
        "initWithType:timestamp:senderID:", "setOptions:",
        "setIntegerValue:forField:", "setDoubleValue:forField:", "appendEvent:"
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (![hidClass instancesRespondToSelector:NSSelectorFromString(
                [NSString stringWithUTF8String:selectors[i]])]) return NO;
    }
    return YES;
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
    BOOL methodsAvailable = TGHIDEventClassUsable(hidClass);
    // Missing APIs select the discrete keyboard fallback in the later injector.
    result.dockSwipe = result.gestureEvents && result.attachmentSymbol != 0 && methodsAvailable;
    // Keep these disabled until their physical G-NC/G-FORCE gates pass.
    // Their specified fallbacks are the AX Clock action and keyboard Look Up.
    result.fluidTouchGesture = NO;
    result.forceEvent = NO;
    return result;
}

// SPEC §6.9.4: every private symbol is resolved once at launch; the frame path never calls dlsym or
// NSClassFromString again. Both are Nil/NULL until `TGPrivateAPIGetCapabilities` has run.
static Class gHIDEventClass = Nil;
static void (*gAttachHIDEvent)(CGEventRef, id) = NULL;

static os_log_t TGInjectLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("app.trackglass.mac", "inject"); });   // §6.10 categories
    return log;
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
        // The HID event factories work wherever the class is usable (tests exercise them without the
        // attachment symbol); the attachment itself additionally needs the exported function.
        Class hidClass = TGLookupClass("HIDEvent");
        gHIDEventClass = TGHIDEventClassUsable(hidClass) ? hidClass : Nil;
        if (capabilities.dockSwipe) {
            // IOHIDEventRef is declared CF_BRIDGED_TYPE(HIDEvent) in IOHIDFamily, so the ObjC object is the
            // IOHIDEventRef: the same call shape serves either exported name (§6.9.4 "alternate symbol").
            gAttachHIDEvent = TGLookupSymbol(capabilities.attachmentSymbol == 1 ? "CGEventSetHIDEvent" : "CGEventSetIOHIDEvent");
            if (!gHIDEventClass || !gAttachHIDEvent) capabilities.dockSwipe = NO;
        }
        os_log_info(TGInjectLog(), "private API: attachment=%u HIDEvent=%d dock=%d gesture=%d fluid=%d force=%d",
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

// The dynamic HIDEvent class, resolved and selector-checked once by the capability probe; Nil when the
// attached path is unavailable. No allocation and no runtime lookup per call (frame path, §7).
static Class TGHIDEventClass(void) {
    (void)TGPrivateAPIGetCapabilities();
    return gHIDEventClass;
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
    if (!capabilities.dockSwipe || !gAttachHIDEvent || !event || !hidEvent) return false;
    gAttachHIDEvent(event, hidEvent);
    return true;
}

bool TGAttachDockHIDEvent(CGEventRef event, id hidEvent) {
    return TGAttachHIDEvent(event, hidEvent);
}

// Read-back selectors from Apple's HIDEvent headers (HID.framework); looked up dynamically like the setters.
@protocol TGDynamicHIDEventReading
- (uint32_t)type;
- (uint32_t)options;
- (NSInteger)integerValueForField:(uint32_t)field;
- (double)doubleValueForField:(uint32_t)field;
- (NSArray *)children;
@end

static BOOL TGResponds(id event, const char *selector) {
    return event != nil && [event respondsToSelector:sel_registerName(selector)];
}

bool TGHIDEventGetType(id event, uint32_t *outType) {
    if (!outType || !TGResponds(event, "type")) return false;
    *outType = [(id<TGDynamicHIDEventReading>)event type];
    return true;
}

bool TGHIDEventGetOptions(id event, uint32_t *outOptions) {
    if (!outOptions || !TGResponds(event, "options")) return false;
    *outOptions = [(id<TGDynamicHIDEventReading>)event options];
    return true;
}

bool TGHIDEventGetInteger(id event, uint32_t field, int64_t *outValue) {
    if (!outValue || !TGResponds(event, "integerValueForField:")) return false;
    *outValue = (int64_t)[(id<TGDynamicHIDEventReading>)event integerValueForField:field];
    return true;
}

bool TGHIDEventGetDouble(id event, uint32_t field, double *outValue) {
    if (!outValue || !TGResponds(event, "doubleValueForField:")) return false;
    *outValue = [(id<TGDynamicHIDEventReading>)event doubleValueForField:field];
    return true;
}

NSArray *TGHIDEventGetChildren(id event) {
    if (!TGResponds(event, "children")) return nil;
    id children = [(id<TGDynamicHIDEventReading>)event children];
    return [children isKindOfClass:[NSArray class]] ? children : nil;
}
