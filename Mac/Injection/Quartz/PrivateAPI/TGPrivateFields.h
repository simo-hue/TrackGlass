#pragma once
#include <CoreGraphics/CoreGraphics.h>

// Numeric facts only; independently declared from SPEC Appendix B and:
// https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/TouchSimulator.m
// https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/GestureScrollSimulator.m
// Verified 2026-10-25. Event types 29/30 are values, not CGEventField keys.
static const CGEventType TGEventTypeGesture = 29;
static const CGEventType TGEventTypeDockCompanion = 30;
static const CGEventField TGFieldEventType = 55;
static const CGEventField TGFieldDirectionInvertedFromDevice = 137;
static const CGEventField TGFieldHIDEventType = 110;
static const CGEventField TGFieldGesturePhase = 132;
static const CGEventField TGFieldDockPhase = 134;
static const CGEventField TGFieldMagnification = 113;
static const CGEventField TGFieldRotation = 114;
static const CGEventField TGFieldSwipeMask = 115;
static const CGEventField TGFieldGestureDeltaX = 116;
static const CGEventField TGFieldGestureDeltaY = 119;
static const CGEventField TGFieldDockProgress = 124;
static const CGEventField TGFieldDockProgressFloatBits = 135;
static const CGEventField TGFieldDockTypeDenormal = 119;
static const CGEventField TGFieldDockTypeDenormalAlternate = 139;
static const CGEventField TGFieldDockType = 123;
static const CGEventField TGFieldDockTypeAlternate = 165;
static const CGEventField TGFieldDockInverted = 136;
static const CGEventField TGFieldDockExitSpeedX = 129;
static const CGEventField TGFieldDockExitSpeedY = 130;
static const CGEventField TGFieldDockMarker = 41;
static const int64_t TGDockMarkerValue = 33231;

// IOHID event subtype values: SPEC Appendix B, MMF TouchSimulator.m and
// https://github.com/calftrail/Touch/blob/master/TouchSynthesis/TouchEvents.h
enum {
    TGHIDRotation = 5, TGHIDScroll = 6, TGHIDZoom = 8, TGHIDVelocity = 9,
    TGHIDNavigationSwipe = 16, TGHIDZoomToggle = 22, TGHIDDockSwipe = 23,
    TGHIDFluidTouchGesture = 27, TGHIDForce = 32,
    TGHIDGestureBegan = 61, TGHIDGestureEnded = 62
};
enum {
    TGPhaseUndefined = 0, TGPhaseBegan = 1, TGPhaseChanged = 2,
    TGPhaseEnded = 4, TGPhaseCancelled = 8, TGPhaseMayBegin = 128
};
enum { TGMomentumNone = 0, TGMomentumBegin = 1, TGMomentumContinue = 2, TGMomentumEnd = 3 };
enum { TGSwipeUp = 1, TGSwipeDown = 2, TGSwipeLeft = 4, TGSwipeRight = 8 };
