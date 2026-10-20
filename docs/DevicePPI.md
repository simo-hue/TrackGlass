# Device pixel density references

Checked against Apple's specifications on 2026-10-20 for M1.6. Model identifiers select exact exceptions before the family fallback (iPhone 460, iPad 264). Recognized iPad mini identifiers use 326. New unidentified models retain SPEC Appendix C's fallback; they do not guess a marketing name.

| Models | PPI | Apple specification |
|---|---:|---|
| iPhone XR | 326 | [XR](https://support.apple.com/en-us/111868) |
| iPhone 11 | 326 | [11](https://support.apple.com/en-us/111865) |
| iPhone SE (2nd generation) | 326 | [SE 2](https://support.apple.com/en-gb/111882) |
| iPhone SE (3rd generation) | 326 | [SE 3](https://support.apple.com/it-it/111866) |
| iPhone XS / XS Max | 458 | [XS](https://support.apple.com/en-us/111881), [XS Max](https://support.apple.com/en-kg/111880) |
| iPhone 11 Pro / Pro Max | 458 | [11 Pro](https://support.apple.com/en-us/111879), [11 Pro Max](https://support.apple.com/en-ie/111878) |
| iPhone 12 mini / 13 mini | 476 | [12 mini](https://support.apple.com/en-in/111877), [13 mini](https://support.apple.com/en-sg/111873) |
| iPhone 12 / 12 Pro | 460 | [12](https://www.apple.com/by/iphone-12/specs/), [12 Pro](https://support.apple.com/en-us/111875) |
| iPhone 12 Pro Max | 458 | [12 Pro Max](https://support.apple.com/en-us/111874) |
| iPhone 13 / 13 Pro | 460 | [13](https://www.apple.com/by/iphone-13/specs/), [13 Pro](https://support.apple.com/en-us/111871) |
| iPhone 13 Pro Max / 14 Plus | 458 | [13 Pro Max](https://support.apple.com/en-euro/111870), [14 Plus](https://support.apple.com/en-in/111854) |
| iPhone 14 / 14 Pro / 14 Pro Max | 460 | [14](https://support.apple.com/en-us/111850), [14 Pro](https://support.apple.com/it-it/111849), [14 Pro Max](https://support.apple.com/id-id/111846) |
| iPhone 15 / 15 Plus / 15 Pro / 15 Pro Max | 460 | [15](https://www.apple.com/it/iphone-15/specs/), [15 Plus](https://support.apple.com/it-it/111830), [15 Pro](https://support.apple.com/en-us/111829), [15 Pro Max](https://support.apple.com/en-us/111828) |
| iPhone 16 / 16 Plus | 460 | [16 family](https://www.apple.com/br/iphone-16/specs/) |
| iPhone 16 Pro / 16 Pro Max | 460 | [16 Pro](https://support.apple.com/en-us/121031), [16 Pro Max](https://support.apple.com/en-sa/121032) |
| iPhone 16e | 460 | [16e](https://www.apple.com/shop/product/fd0f4ll/a/Refurbished-iPhone-16e-256GB-Black-Unlocked) |
| iPhone 17 / 17 Pro / 17 Pro Max / Air | 460 | [17](https://www.apple.com/iphone-17/specs/), [17 Pro](https://support.apple.com/en-us/125090), [17 Pro Max](https://support.apple.com/en-us/125091), [Air](https://www.apple.com/iphone-air/specs/) |
| iPad Pro 11-inch (1st generation; owner's reference) | 264 | [11-inch Pro](https://support.apple.com/en-us/111974) |
| iPad (9th generation) / iPad Air (4th generation) | 264 | [iPad 9](https://support.apple.com/en-us/111898), [Air 4](https://support.apple.com/en-qa/111905) |
| iPad mini (5th generation) | 326 | [mini 5 comparison](https://www.apple.com/ipad/compare/?modelList=ipad-pro-12-9-6th-gen%2Cipad-mini-5th-gen) |
| iPad mini (6th generation) / mini (A17 Pro) | 326 | [mini 6](https://support.apple.com/en-lamr/111886), [mini A17 Pro](https://support.apple.com/en-us/121456) |

Geometry uses the caller's actual window bounds and native screen scale, with no UIKit or CoreGraphics dependency. Native scale is injected rather than assumed to be 2 or 3; this also accommodates downsampled display modes. Rotation exchanges width and height; Split View changes the supplied bounds without clamping.
