# Veil

A privacy-focused iOS browser with video downloading and basic editing. Version 0.1.3. "Veil" is a placeholder name.

## What Version 1 Does

**Browsing and Privacy**
- Tabs and private tabs. Each private tab gets its own throwaway storage, so its cookies and site data vanish when you close it.
- Blocks 59 tracker and ad networks through Apple's built-in content blocker.
- HTTPS Only mode upgrades plain http pages and warns before loading a site that has no secure version.
- Private tabs lock with Face ID when you leave the app and are hidden from the app switcher.
- No history, no analytics, no accounts. Search defaults to DuckDuckGo.
- Normal tabs reopen when you relaunch the app (Settings > Reopen Tabs on Launch). Private tabs are never saved. Settings always stay as you set them.

**Downloading**
- Detects video files a page loads. A badge on the download button shows how many it found.
- Plain video files (MP4, MOV, WebM) download in the background.
- Streamed video (HLS) downloads and converts to MP4. This part is experimental.
- Files appear in the Files app under On My iPhone > Veil.
- DRM-protected video and blob streams can't be downloaded.

**Editing**
- Trim start and end, remove audio, change speed (0.5x to 2x).
- Crop to 1:1, 9:16, 16:9 or 4:5, slide the crop to the part you want, and see it outlined on the preview before exporting.
- Export to MP4, share, or save to Photos.

## Build It Without a Mac

1. **Make a GitHub account** at github.com.
2. **Create a new repository.** Click the plus at the top right, then New Repository. Name it `veil-browser`. A public repo gets free build time. A private repo works too, but has a small monthly allowance of Mac build minutes.
3. **Upload the files.** On the new repo page, click "uploading an existing file" and drag in everything from this folder, including the `.github` folder. Click Commit Changes. If the `.github` folder doesn't upload, install GitHub Desktop and push the folder from there.
4. **Run the build.** Open the Actions tab. If GitHub asks, click to enable workflows. Pick Build Veil, then Run Workflow. It takes about 5 to 10 minutes.
5. **Download the app.** Open the finished run and download `Veil-ipa` under Artifacts. Unzip it to get `Veil.ipa`.

## Install on the iPhone

1. Open Sideloadly on your PC and plug in the iPhone.
2. Drag `Veil.ipa` into Sideloadly, enter an Apple ID, and click Start.
3. On the iPhone, go to Settings > General > VPN & Device Management and trust your Apple ID.
4. If iOS asks for Developer Mode, turn it on in Settings > Privacy & Security > Developer Mode and restart.

With a free Apple ID the app stops opening after 7 days. Re-run step 2 to refresh it. Your downloads stay.

## If the Build Fails

The code hasn't been compiled yet. Open the failed run and click the Show Errors step. It lists only the error lines, so copy those and paste them to Claude. The full log is also saved under Artifacts as `build-log`. Most first-build errors are one-line fixes.

## Project Layout

| Path | What It Holds |
|---|---|
| `project.yml` | Project definition. The build turns it into an Xcode project. |
| `.github/workflows/build.yml` | The cloud Mac build. |
| `Veil/App` | App entry point. |
| `Veil/Browser` | Tabs, web views, settings, tracker blocking, video detection. |
| `Veil/Downloads` | Download manager and the video exporter. |
| `Veil/Views` | Every screen. |
| `Veil/Resources/blocklist.json` | Tracker and ad rules. |
