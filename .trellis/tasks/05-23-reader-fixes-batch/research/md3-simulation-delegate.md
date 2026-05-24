# Research: MD3 SimulationPageDelegate — Shadow, Drag, Corner Anchoring

- **Query**: How does legado-with-MD3 `SimulationPageDelegate.kt` handle shadow rendering, drag start position, and corner anchoring?
- **Scope**: internal (local `legado-with-MD3` repo)
- **Date**: 2026-05-23

## Findings

### Source File

**Path**: `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/read/page/delegate/SimulationPageDelegate.kt` (613 lines)

### 1. Corner Anchoring Logic

#### `calcCornerXY(x, y)` (L513-L518)

The corner is **immediately anchored** to one of 4 page corners based on which quadrant the touch falls in:

```kotlin
private fun calcCornerXY(x: Float, y: Float) {
    mCornerX = if (x <= viewWidth / 2) 0 else viewWidth
    mCornerY = if (y <= viewHeight / 2) 0 else viewHeight
    mIsRtOrLb = (mCornerX == 0 && mCornerY == viewHeight)
            || (mCornerY == 0 && mCornerX == viewWidth)
}
```

- `mCornerX` is 0 (left edge) or `viewWidth` (right edge)
- `mCornerY` is 0 (top edge) or `viewHeight` (bottom edge)
- **Always snaps to a page corner** — never a midpoint
- `mIsRtOrLb` = true for **top-right** `(viewWidth, 0)` or **bottom-left** `(0, viewHeight)` — controls shadow direction

#### Direction Override in `onTouch` MOVE (L173-L185)

During drag, the touchY is overridden based on start position and direction:

```kotlin
MotionEvent.ACTION_MOVE -> {
    if ((startY > viewHeight / 3 && startY < viewHeight * 2 / 3)
        || mDirection == PageDirection.PREV
    ) {
        readView.touchY = viewHeight.toFloat()    // Force to bottom
    }
    if (startY > viewHeight / 3 && startY < viewHeight / 2
        && mDirection == PageDirection.NEXT
    ) {
        readView.touchY = 1f                      // Force to top
    }
}
```

**Rules**:
- If user starts drag in middle 1/3 of screen (vertically) → force touchY to bottom → corner stays at top or bottom but fold line is at bottom
- PREV direction always forces touchY to `viewHeight` (bottom) — ensures the "page flip backward" animation works correctly
- NEXT direction + startY in upper-middle 1/3 → touchY forced to top

#### `setDirection` Mirroring (L188-L206)

When direction is determined, `setDirection` adjusts the corner:

```kotlin
override fun setDirection(direction: PageDirection) {
    super.setDirection(direction)
    when (direction) {
        PageDirection.PREV ->
            // Always anchor to bottom-right for backward flip
            if (startX > viewWidth / 2) {
                calcCornerXY(startX, viewHeight.toFloat())
            } else {
                calcCornerXY(viewWidth - startX, viewHeight.toFloat())
            }

        PageDirection.NEXT ->
            // Mirror to right side if started on left half
            if (viewWidth / 2 > startX) {
                calcCornerXY(viewWidth - startX, startY)
            }
    }
}
```

**PREV direction**: Corner is **always** at bottom-right quadrant (cornerX=viewWidth, cornerY=viewHeight). If user touched left half → mirrored to right half. This makes PREV look like "page flipping back to cover previous content" from bottom-right pivot.

**NEXT direction**: If user touched left half of screen → mirror cornerX to right side. If touched right half → keep as-is. This ensures the fold visual is always from the right side for forward page turns.

### 2. Drag Start Position

**User CAN drag from ANYWHERE on the screen** — middle, corner, edge. At `ACTION_DOWN`, `calcCornerXY(event.x, event.y)` is called (L169), which immediately anchors the corner to one of the 4 page corners based on the touch quadrant. There is no restriction that the user must drag from a corner.

Key difference from Flutter port worth noting:
- Flutter `_calcCornerXY` (L130-L136) mirrors this exactly: `_cornerX = x <= w / 2 ? 0 : w`
- Flutter `_setDirectionMirrorCorner` (L150-L163) mirrors the `setDirection` logic
- Flutter `onDragUpdate` (L120-L128) calls mirror on direction detection — same as MD3's `setDirection` being called when direction is first set in `HorizontalPageDelegate.onScroll` (L92-L100)

### 3. Shadow Rendering — Complete Breakdown

MD3 uses **4 types** of shadows, rendered in `onDraw` (L247-L268) in this order:

```
drawCurrentPageArea        → draw the non-folded portion of current page
drawNextPageAreaAndShadow  → draw next page visible area + BackShadow
drawCurrentPageShadow      → FrontShadow_V + FrontShadow_H
drawCurrentBackArea        → reflect current page back + FolderShadow
```

#### 3a. BackShadow (`drawNextPageAreaAndShadow`, L438-L483)

**Purpose**: Shadow cast by the folded page onto the next page beneath it.

**Shape**: A gradient strip along the fold line (at `mBezierStart1`), extending from `mBezierStart1.y` to `mMaxLength + mBezierStart1.y` (diagonal of screen).

**Width**: `mTouchToCornerDis / 4` (1/4 of the distance from touch point to corner)

**Color**: `mBackShadowColors = intArrayOf(-0xeeeeef, 0x111111)`
- Start: `0xFF111111` (very dark, nearly black)
- End: `0x00111111` (transparent)
- Decoded: `-0xeeeeef = 0xFF111111`, `0x111111 = 0x00111111`

**Orientation**: Depends on `mIsRtOrLb`:
- Top-right or bottom-left (`mIsRtOrLb=true`): LEFT→RIGHT gradient (`mBackShadowDrawableLR`)
- Others: RIGHT→LEFT gradient (`mBackShadowDrawableRL`)

**Position**:
- If `mIsRtOrLb`: `leftX = mBezierStart1.x`, `rightX = mBezierStart1.x + mTouchToCornerDis/4`
- Else: `leftX = mBezierStart1.x - mTouchToCornerDis/4`, `rightX = mBezierStart1.x`

The entire strip is rotated by `mDegrees` around `(mBezierStart1.x, mBezierStart1.y)`.

#### 3b. FrontShadow_V (Vertical, along control1) (`drawCurrentPageShadow`, L340-L435, first segment)

**Purpose**: Shadow along the vertical fold edge (near control point 1). The shadow of the lifted page edge cast onto the underlying content.

**Shape**: Triangle/quad from `(x, y)` → `(mTouchX, mTouchY)` → `(mBezierControl1.x, mBezierControl1.y)` → `(mBezierStart1.x, mBezierStart1.y)` → close.

Where `(x, y)` is calculated from the shadow vertex offset (25px * √2, rotated by the fold angle).

**Width**: 25px band

**Color**: `mFrontShadowColors = intArrayOf(-0x7feeeeef, 0x111111)`
- Start: `0x88111111` (semi-transparent dark)
- End: `0x00111111` (transparent)

**Orientation**: `mFrontShadowDrawableVLR` (LEFT→RIGHT) or `mFrontShadowDrawableVRL` (RIGHT→LEFT) based on `mIsRtOrLb`.

**Rotation**: Rotated around `(mBezierControl1.x, mBezierControl1.y)` by `atan2(mTouchX - mBezierControl1.x, mBezierControl1.y - mTouchY)` degrees.

**Clip region**: Clipped by `mPath0` (the folded region OUT — `clipOutPath` or `clipPath XOR`) AND by the triangle path (`clipPath INTERSECT`).

#### 3c. FrontShadow_H (Horizontal, along control2) (`drawCurrentPageShadow`, second segment)

**Purpose**: Shadow along the horizontal fold edge (near control point 2).

Same shape logic but aligned with control2 instead of control1.

**Width**: 25px band

**Color**: `mFrontShadowColors` (same as FrontShadow_V)

**Orientation**: `mFrontShadowDrawableHTB` (TOP→BOTTOM) or `mFrontShadowDrawableHBT` (BOTTOM→TOP) based on `mIsRtOrLb`.

**Rotation**: Rotated around `(mBezierControl2.x, mBezierControl2.y)` by `atan2(mBezierControl2.y - mTouchY, mBezierControl2.x - mTouchX)` degrees.

**Edge case**: If `mBezierControl2.y < 0`, uses `mBezierControl2.y - viewHeight` for hypotenuse calculation, and extends rect bounds to `mBezierControl2.x - 25 - hmg` to ensure shadow covers full visible area.

#### 3d. FolderShadow (`drawCurrentBackArea`, L273-L335)

**Purpose**: Shadow on the back side of the folded page (the curl shadow).

**Shape**: A gradient strip along the fold line, same position as BackShadow but different color and width.

**Width**: `f3 = min(f1, f2)` where:
- `f1 = abs((mBezierStart1.x + mBezierControl1.x)/2 - mBezierControl1.x)` — half distance horizontally
- `f2 = abs((mBezierStart2.y + mBezierControl2.y)/2 - mBezierControl2.y)` — half distance vertically

**Color**: `intArrayOf(0x333333, -0x4fcccccd)` — `0xFF333333` to semi-transparent (approx `0xB0333333`)

**Orientation**: `mFolderShadowDrawableLR` (LEFT→RIGHT) or `mFolderShadowDrawableRL` (RIGHT→LEFT).

**Position**: Strip from `mBezierStart1.y` to `mBezierStart1.y + mMaxLength` (screen diagonal).

**Rotation**: Rotated by `mDegrees` around `(mBezierStart1.x, mBezierStart1.y)`.

#### 3e. Back Page ColorFilter

The reflected back page (in `drawCurrentBackArea`) uses a `ColorMatrixColorFilter`:

```kotlin
mColorMatrixFilter = ColorMatrixColorFilter(
    ColorMatrix(floatArrayOf(
        1f, 0f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f, 0f,
        0f, 0f, 1f, 0f, 0f,
        0f, 0f, 0f, 1f, 0f    // Identity matrix — NO color change
    ))
)
```

**Important**: The MD3 color matrix is IDENTITY. It does NOT darken the reflected back page. The Flutter port uses a `_backFilter` with 0.85 scale on RGB (making the back page ~15% darker):

```dart
// Flutter: makes back page slightly darker
static final ColorFilter _backFilter = const ColorFilter.matrix(<double>[
    0.85, 0, 0, 0, 0,
    0, 0.85, 0, 0, 0,
    0, 0, 0.85, 0, 0,
    0, 0, 0, 1, 0,
]);
```

And the Flutter port draws the background color before the reflected picture (L733-L734):
```dart
final bgColor = Color(settings.effectiveBackgroundColor);
canvas.drawColor(bgColor, BlendMode.srcOver);
```

MD3 also draws background: `canvas.drawColor(ReadBookConfig.bgMeanColor)` (L325) before the reflected bitmap.

### 4. Shadow Initialization (`init` block, L108-L142)

All shadow `GradientDrawable` objects are pre-created in the `init` block and reused every frame. This avoids per-frame allocation overhead:

```kotlin
init {
    val color = intArrayOf(0x333333, -0x4fcccccd)
    mFolderShadowDrawableRL = GradientDrawable(GradientDrawable.Orientation.RIGHT_LEFT, color)
    mFolderShadowDrawableRL.gradientType = GradientDrawable.LINEAR_GRADIENT
    // ... 8 more drawables for different orientations
}
```

### 5. Key Geometry Variables

| Variable | Description |
|---|---|
| `mTouchX`, `mTouchY` | Current touch/drag point (via `readView.touchX/touchY`) |
| `mCornerX`, `mCornerY` | Anchored corner (0 or viewWidth, 0 or viewHeight) |
| `mBezierStart1/2` | Bezier curve start points (on top/bottom edges) |
| `mBezierControl1/2` | Bezier curve control points (one on edge, one computed) |
| `mBezierEnd1/2` | Bezier curve endpoints (intersections) |
| `mBezierVertex1/2` | Bezier curve vertices (computed from start+control+end) |
| `mMiddleX`, `mMiddleY` | Midpoint between touch and corner |
| `mDegrees` | Rotation angle for fold shadows |
| `mTouchToCornerDis` | Distance from touch to corner (hypotenuse) |
| `mMaxLength` | Screen diagonal: `hypot(viewWidth, viewHeight)` |
| `mIsRtOrLb` | Top-right or bottom-left quadrant → flips shadow orientation |

### 6. Flutter Port Divergence Checklist

For Bug 4 ("仿真翻页阴影奇怪"), here is a line-by-line comparison:

| Aspect | MD3 Kotlin | Flutter Dart | Match? |
|---|---|---|---|
| `calcCornerXY` logic | `x <= w/2 ? 0 : w` | Same | ✅ |
| `setDirection` PREV mirror | Always bottom-right corner + touchY=viewHeight | `_setDirectionMirrorCorner` mirrors corner + `prevPageByAnim` sets virtualStart=(0,h) | ✅ (logic matches) |
| `setDirection` NEXT | Mirror only if startX < w/2 | Same (L158-L161) | ✅ |
| `onTouch` MOVE touchY override | `startY in middle 1/3 → touchY=viewHeight` | NOT present in Flutter | ❌ |
| BackShadow color (start→end) | `0xFF111111 → 0x00111111` | `0xFF111111 → 0x00111111` (L574) | ✅ |
| BackShadow width | `mTouchToCornerDis / 4` | `_touchToCornerDis / 4` (L549, L552) | ✅ |
| FrontShadow color | `0x88111111 → 0x00111111` | `0x88111111 → 0x00111111` (L622, L677) | ✅ |
| FrontShadow width | 25px | 25.0 (L608, L652) | ✅ |
| FolderShadow color | `0xFF333333 → 0xB0333333` | `0x99333333 → (decaying)` multi-segment (L766-L786) | ⚠️ Flutter has multi-segment enhancement |
| FolderShadow width | `min(f1, f2)` | `min(f1, f2)` (L689) | ✅ |
| Back page ColorFilter | Identity matrix (no darkening) | 0.85 scale (darkens by 15%) | ❌ **DIFFERENCE** |
| Background before back page | `ReadBookConfig.bgMeanColor` | `settings.effectiveBackgroundColor` | ✅ (equivalent) |
| Reflection matrix formula | `1-2*f9², 2*f8*f9, ...` + `preTranslate` + `postTranslate` | Same formula with Matrix4 (L719-L731) | ✅ |
| Per-frame object allocation | Pre-created GradientDrawables, reused via `setBounds()` | Per-frame `ui.Gradient.linear` Shader creation | ⚠️ Flutter less efficient |
| `clipOutPath` | Android `canvas.clipOutPath(mPath0)` (API 26+) | Even-odd subtraction path (L521-L529) | ✅ (equivalent) |

### 7. Missing `onTouch` MOVE TouchY Override (Potential Bug 4 Cause)

MD3's `onTouch` MOVE handler (L173-L185) overrides touchY based on start position. The Flutter port **does not** have this logic. This could cause:

- When user starts drag in the middle of the screen, the fold line may appear in an unnatural position
- The touchY override ensures that regardless of where the user starts dragging, the fold line is anchored at top or bottom edge, making the visual look like a real page fold

### Caveats / Not Found

- The BackColorFilter identity matrix (Kotlin) vs 0.85 darkening (Flutter) is a deliberate difference. MD3 leaves the back page at full brightness; Flutter darkens it. The PRD mentions "阴影奇怪" (shadows look weird) — this is one candidate difference.
- The multi-segment FolderShadow in Flutter (L757-L786) is an enhancement not present in MD3. MD3 uses a single gradient strip. If the multi-segment logic has a bug, it could cause shadow artifacts.
- The `ui.Gradient.linear` calls in Flutter create new Shader objects each frame. While this has been evaluated as "开销可控" (acceptable overhead), it differs from MD3's pre-created GradientDrawables, which only call `setBounds()` each frame. On low-end devices, this could contribute to jank.
