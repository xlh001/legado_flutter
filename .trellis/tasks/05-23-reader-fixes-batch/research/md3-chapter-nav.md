# Research: MD3 Cross-Chapter Page Flip Animation

- **Query**: How does Legado Android MD3 handle cross-chapter page flip transition?
- **Scope**: mixed (local repo `legado-with-MD3` + web)
- **Date**: 2026-05-23

## Findings

### Source Repository

- **GitHub**: https://github.com/HapeLee/legado-with-MD3
- **Local copy**: `/root/data/workspaces/doro_FriendMessage_641981595/legado-with-MD3`

### Key Files

| File Path | Description |
|---|---|
| `app/src/main/java/io/legado/app/ui/book/read/page/ReadView.kt` | Main reading view, hosts 3 PageView children (prev/cur/next), dispatches touch → delegate, calls `fillPage` on animation end |
| `app/src/main/java/io/legado/app/ui/book/read/page/provider/TextPageFactory.kt` | Page factory: `moveToNext`/`moveToPrev` decide chapter-vs-page crossing |
| `app/src/main/java/io/legado/app/model/ReadBook.kt` | `moveToNextChapter`/`moveToPrevChapter`: chapter switching + content loading orchestration |
| `app/src/main/java/io/legado/app/ui/book/read/page/delegate/PageDelegate.kt` | Base delegate: `hasPrev()`/`hasNext()` check via `pageFactory`, `startScroll` with distance-proportional duration |
| `app/src/main/java/io/legado/app/ui/book/read/page/delegate/HorizontalPageDelegate.kt` | Base for simulation/cover/slide: `setBitmap()` screenshots cur+next or cur+prev pages; `abortAnim` calls `fillPage` |
| `app/src/main/java/io/legado/app/ui/book/read/page/delegate/SimulationPageDelegate.kt` | `onAnimStop` calls `readView.fillPage(mDirection)` |
| `app/src/main/java/io/legado/app/ui/book/read/page/entities/TextChapter.kt` | `isCompleted` flag gates whether cross-chapter is allowed |

### How MD3 Handles Cross-Chapter Page Flip

#### Architecture: 3 PageView Children

`ReadView` (L66-L68) creates three `PageView` children at init:

```kotlin
val prevPage by lazy { PageView(context) }
val curPage by lazy { PageView(context) }
val nextPage by lazy { PageView(context) }
```

These are always present XML view children (`addView` at L117-L119). They are updated via `upContent(relativePosition)`.

#### Content Preloading at Chapter Open

When `ReadBook.loadContent(resetPageOffset)` is called (L626-L635), it fires off **three** load jobs in parallel:

```kotlin
fun loadContent(resetPageOffset: Boolean, success: (() -> Unit)? = null) {
    loadContent(durChapterIndex, resetPageOffset = resetPageOffset) { ... }  // current
    loadContent(durChapterIndex + 1, resetPageOffset = resetPageOffset)       // next (fire-and-forget)
    loadContent(durChapterIndex - 1, resetPageOffset = resetPageOffset)       // prev (fire-and-forget)
}
```

Each `loadContent(index)` (L660-L697) is async via `Coroutine.async`. It fetches chapter content from DB or network, then calls `contentLoadFinish` which triggers `ChapterProvider.getTextChapterAsync` → layout & page splitting.

#### Chapter Transition on Animation End

The flow is:

1. `SimulationPageDelegate.onAnimStop` (L241-L245): If animation was not cancelled, calls `readView.fillPage(mDirection)`
2. `ReadView.fillPage` (L504-L516): Calls `pageFactory.moveToNext(true)` or `pageFactory.moveToPrev(true)`
3. `TextPageFactory.moveToNext` (L40-L58): Checks if at chapter boundary
4. If at boundary → `ReadBook.moveToNextChapter(upContent, false)`

#### Boundary Detection: `isCompleted` Gate

`TextPageFactory.moveToNext` (L40-L58) uses `isLastIndex` (with `isCompleted` check) to decide cross-chapter:

```kotlin
fun isLastIndex(index: Int): Boolean {
    return isCompleted && index >= pages.size - 1   // BOTH completed AND at last page
}

fun isLastIndexCurrent(index: Int): Boolean {
    return index >= pages.size - 1                   // Just at last known page
}
```

**Critical behavior**: If the chapter content is still being laid out (`isCompleted == false`), `isLastIndex` returns `false` even when visually at the last known page. The user then falls into the within-chapter branch, `isLastIndexCurrent` returns `true`, and `moveToNext` returns `false` — the user **cannot** flip past a partially-laid-out chapter. MD3 blocks the flip until layout finishes.

#### What Happens When Next Chapter Content Isn't Loaded Yet

`TextPageFactory.nextPage` (L94-L114) returns content progressively:

```kotlin
override val nextPage: TextPage
    get() = ... currentChapter?.let {
        // If page exists within current chapter → return it
        if (pageIndex < it.pageSize - 1) {
            return it.getPage(pageIndex + 1)
        }
        // At chapter boundary, chapter not completed → fallback
        if (!it.isCompleted) {
            return TextPage(title = it.title).format()
        }
    }
    // Cross-chapter: next chapter loaded → first page
    nextChapter?.let {
        return it.getPage(0) ?: TextPage(title = it.title).format()
    }
    // Nothing available → empty
    return TextPage().format()
```

For simulation animation, `setBitmap()` (SimulationPageDelegate L144-L158) screenshots whatever is in the PageView at direction-set time. If next chapter isn't loaded, the `nextPage` PageView child contains a title-only fallback page. The **animation still plays** visually with whatever content is available.

#### Chapter Switching: `moveToNextChapter`

`ReadBook.moveToNextChapter` (L426-L452) does:

```kotlin
fun moveToNextChapter(upContent: Boolean, upContentInPlace: Boolean = true): Boolean {
    durChapterIndex++
    // Shift chapter windows
    prevTextChapter = curTextChapter
    curTextChapter = nextTextChapter
    nextTextChapter = null

    if (curTextChapter == null) {
        // Adjacent chapter was NOT preloaded → load it now
        callBack?.upContent()      // Refresh views with whatever is available
        loadContent(durChapterIndex, upContent)  // Start async loading
    } else if (upContent && upContentInPlace) {
        callBack?.upContent()      // Chapter was preloaded → immediate display
    }

    // Preload the next-next chapter
    loadContent(durChapterIndex.plus(1), upContent, false)
    saveRead()
    curPageChanged()
}
```

**Key**: When `upContent()` is called, `ReadView.upContent(relativePosition = 0)` (L568-L591) updates **all three** PageView children (`curPage`, `nextPage`, `prevPage`) at once. This means after chapter switch, the next-simulation-page and prev-simulation-page are immediately repopulated with whatever `TextPageFactory.nextPage`/`prevPage` return for the new chapter position.

#### `moveToPrevChapter` Symmetry

Same pattern (L485-L511): shifts chapters, loads current if null, preloads prev-1 chapter. `upContent` updates all 3 views.

### MD3 vs Flutter Port: Key Differences

| Dimension | MD3 Kotlin | Flutter Port |
|---|---|---|
| Content preloading | `loadContent(cur±1)` at chapter open | `_preloadAdjacentContent` + `_preCachePrevChapter` |
| Adjacent chapter measurement | Done inside `contentLoadFinish` → `ChapterProvider.getTextChapterAsync` → layout | `_measureAdjacentChapters` → `setNeighborChapter` → controller `_buildAndMeasure` |
| Animation-first approach | YES — animation plays regardless of content; `setBitmap` screenshots whatever is in PageView | PARTIAL — `draw` falls back to static if `nextPicture`/`prevPicture` is null |
| Block flip on incomplete layout | YES — `isCompleted` gate in `isLastIndex` | Not explicitly (boundary detection via `boundaryNextPage` null) |
| Chapter transition on anim end | `fillPage` → `pageFactory.moveToNext` → `moveToNextChapter` | `commitToNextChapter`/`commitToPrevChapter` → `_onCrossChapterCommit` or fallback to `_onPageChapterBoundary` |
| Duration formula | `animationSpeed * abs(dx) / viewWidth` (distance-proportional) | `pageAnimDurationMs` fixed (user-configurable, default 300ms) |
| Pre-rendering adjacent chapters for simulation | NO — only `setBitmap()` at direction-set time; neighbor pages are from TextPageFactory getters | NO — same approach via `curPicture`/`nextPicture`/`prevPicture` in delegate |

### Caveats / Not Found

- The `isCompleted` gate is the only mechanism preventing chapter transition during layout. There is no explicit "loading" spinner or error state shown during this window; the user simply can't flip until layout completes.
- MD3 does NOT pre-render adjacent chapters into bitmaps for the simulation animation. The bitmaps are created on-demand via `setBitmap()` → `PageView.screenshot()` when the direction is first set (touch down or tap).
- The `TextPageFactory` also has a `nextPlusPage` for scroll-mode chapter pre-buffering (used by `ScrollPageDelegate` only), not relevant to simulation mode.

## Related Specs

- `.trellis/tasks/archive/2026-05/05-18-drag-cancel-threshold-md3/research/md3-drag-cancel.md` — MD3 isCancel / drag cancel semantics
- `.trellis/tasks/archive/2026-05/05-18-drag-cancel-threshold-md3-followup/research/feature-gap-reader-bookshelf-source.md` — Feature gap between legado and flutter port
