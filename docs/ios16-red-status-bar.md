# iOS 16: the red "rdar:45025538" status bar on non-Apple screen sizes

Applies to iOS 16.7 (20H392), read from UIKitCore, SpringBoard and SpringBoardHome; tested on a phone without a home button (an iPhone X identity) at 375x750 points @3x.

## Symptom

A red bar replaces the status bar, and SpringBoard logs:

```
No status bar visual provider for screen <UIScreen ...; bounds: {{0, 0}, {375, 750}}; mode: ... 1125 x 2250> (width: 375.00, scale: 3.00, idiom: 0, cornerRadius: 33.33). Please see rdar://45025538.
```

## How UIKit picks a status bar

1. `+[_UIStatusBarVisualProvider_Phone visualProviderSubclassForScreen:visualProviderInfo:]` reads the screen's `_exclusionArea` (the notch):
   - with no exclusion area → `_UIStatusBarVisualProvider_LegacyPhone`;
   - with an exclusion rect whose y > 0 (an island) → `_UIStatusBarVisualProvider_DynamicSplit`, which has no size check;
   - otherwise → `_UIStatusBarVisualProvider_Split`.
2. `Split` tries each of `Split1125`, `Split1080`, `Split1080_Wide`, `Split1170`, `Split1170_Wide`, `Split1242`, `Split828`, `Split1284` and `Split1284_Wide`. A class matches when both of these hold, within 0.0001:
   - its `nativeDisplayWidth` equals the screen's width in pixels;
   - its `notchSize` equals the exclusion area's size × `_nativeScale` / (`referenceScreenScale` if the class has one, else `_scale`).

   For example, `Split1125` has width 1125 and notch 209x30 (iPhone X). `Split1080` has width 1080, reference scale 2.88 and notch 226x34.33 (iPhone 12 mini).
3. If nothing matches, the result depends on the `SpringBoard/Jindo` feature flag (Dynamic Island):
   - flag on: nil, which gives the red bar;
   - flag off: `_UIStatusBarVisualProvider_FixedSplit`, a layout built from the screen's own exclusion area that works at any size.

## Where the exclusion area comes from

`+[UISDisplayContext(SpringBoard) sb_embeddedDisplayDefaultContext]` takes the exclusion area from `sb_thisDeviceDisplayShape`. That uses a fixed rect per screen type, and the screen type comes from `SBHScreenTypeForCurrentDevice` → `_SBHScreenTypeLookup`:

- **Exact match:** size in points, scale, artwork subtype (if the type has one) and home-button type.
- **Fallback (no home button):** the first of these sizes that the screen is at least as large as:

  | Size (points) | Screen type |
  |---|---|
  | 430x932 | D74 |
  | 428x926 | D54 |
  | 414x896 | D33 |
  | 393x852 | D73 |
  | 390x844 | D53 |
  | 375x812 | D22 |
  | anything smaller | D22Zoomed (type 4) |

D22Zoomed's notch is 178.35x25.6 points (raw rect 249,0,627,90 ÷ 3.515625). At scale 3 that matches no `Split` class, so a 375x750 @3x screen gets the red bar.

The fallback ignores MobileGestalt. Changing `ArtworkDeviceSubType` or the "has notch" answer (`8S7ydMJ4DlCUF38/hI/fJA`) does not change the exclusion area.

## Fixes

**A. Use a screen size an iPhone has.** Pick a canvas whose size in points exactly matches a listed type. For example, 786x1704 @2x = 393x852, the 14 Pro: this is the approach of [FixRDAR4XR11](https://github.com/HorizonUnix/FixRDAR4XR11) for the XR/11.

**B. Turn the Jindo flag off.** Create `/var/preferences/FeatureFlags/Domain/SpringBoard.plist`:

```xml
<plist version="1.0">
<dict>
	<key>Jindo</key>
	<dict>
		<key>Enabled</key>
		<false/>
	</dict>
</dict>
</plist>
```

Then restart SpringBoard. The status bar becomes `FixedSplit` at whatever size the screen is. Setting the same key in `/System/Library/FeatureFlags/Domain/SpringBoard.plist` has no effect. Not tested on a device that has an island.
