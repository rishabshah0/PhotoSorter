# PhotoSorter

**PhotoSorter** is a super-fast Mac app for sorting through big folders of photos. It helps you quickly pick your favorite shots, trash bad ones, and refine your favorites through multiple culling passes without any lag.

---

## Key Features

- **Multi-Pass "Drill Down"**: Once you've picked your favorites, click **Drill Down** to filter through your Liked photos in a second pass. Keep narrowing them down until you're left with only the absolute best shots—no complicated star ratings required.
- **Lightning Fast**: Flip through high-resolution photos instantly with no loading screens.
- **Simple 1-Key Sorting**: Quickly categorize photos into **Liked**, **Disliked**, and **Blurry** folders using keys `1`, `2`, `3` or trackpad swipes.
- **Original vs. Denoised Comparison**: If you use noise-reduction software (like Lightroom or PureRAW) that creates denoised copies of your photos, PhotoSorter lets you slide between the original and denoised version side-by-side to compare details.
- **Instant Magnifying Glass**: Hover or tap any photo to get a zoomed-in detail view.
- **Safety Net**: Press `⌘Z` or `Backspace` at any time to undo your last sort action.

---

## Shortcuts

| Action | Shortcut | Gesture / Click |
|---|---|---|
| **Next / Previous Photo** | `→` / `←` Arrow Keys | - |
| **Keep / Like** | `3` | Swipe Right / Click `✓` |
| **Discard / Dislike** | `1` / `X` / `D` | Swipe Left / Click `✗` |
| **Mark Blurry** | `2` | Swipe Down / Click `👁` |
| **Undo** | `⌘Z` / `Backspace` | Click `⟲` |

---

## How to Install & Run

1. Open Terminal in the project directory.
2. Make the scripts executable and build the app:
   ```bash
   chmod +x build.sh run.sh
   ./build.sh
   ```
3. Open **PhotoSorter** from your Mac's `/Applications` folder (or run `./run.sh`).
