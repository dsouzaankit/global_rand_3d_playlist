# Transcode and fisheye log files

All paths below are relative to a media folder that contains `3d_playlist_local\`, unless noted as global.

Robocopy sync (`/XF *.log`) copies scripts but **does not overwrite** local `transcode_logs\` on deploy copies.

Repo `Readme.txt` points here for the full catalog; use `Cleanup-TranscodeLogs.ps1` / `Purge-OldAvs.ps1` as described under [Cleanup](#cleanup).

---

## Under `3d_playlist_local\individual_transcode\transcode_logs\`

| Location / pattern | Producer | Contents |
|--------------------|----------|----------|
| `transcode_yyyyMMdd_HHmmss_<pid>.log` | `Run-TranscodeFfmpeg.ps1` (default transcript) | Full PowerShell transcript per transcode invocation (context menu or orchestrator child). |
| `transcode_failures.log` | `Run-TranscodeFfmpeg.ps1` (`-NoLogFile` or failed runs) | Short failure blocks: timestamp, input path, exit code, ffmpeg command line. |
| `transcode_lock_owner.txt` | `Run-TranscodeFfmpeg.ps1` (mutex) | PID / lock metadata while a transcode holds `Local\FfmpegAvsTranscodeLock`. |
| `orchestrator_child\orch_child_<stamp>_<safe>.stdout.log` | `Run-TranscodeOrchestrator.ps1` | Redirected stdout from each child `Run-TranscodeFfmpeg.ps1` window. |
| `orchestrator_child\orch_child_<stamp>_<safe>.stderr.log` | `Run-TranscodeOrchestrator.ps1` | Redirected stderr (primary ffmpeg progress/errors for flat queue). |
| `ffmpeg_process\<stamp>_<pid>_<input>.stdout.log` | `Run-TranscodeFfmpeg.ps1` | ffmpeg stdout for one encode (often sparse). |
| `ffmpeg_process\<stamp>_<pid>_<input>.stderr.log` | `Run-TranscodeFfmpeg.ps1` | ffmpeg stderr (progress, warnings, errors). |
| `fisheye_batch\fisheye_batch_console_<stamp>_<pid>.log` | `run_batch_fisheye_v360.ps1` | Batch control shell transcript (console + file). |
| `fisheye_batch_prepare\fisheye_batch_prepare_<stamp>_<clip>.stdout.log` | `Run-V360PrepareFisheye.ps1` (`-BatchStdOutLog`) | Per-clip prepare + inline pass-2 chase transcript. |
| `fisheye_batch_prepare\fisheye_batch_prepare_<stamp>_<clip>.stdout.log.finished` | `Run-V360PrepareFisheye.ps1` | Empty marker written when clip succeeds (batch wait uses this before log tail). |
| `fisheye_batch_prepare\` (stderr path reserved) | — | Prepare uses stdout transcript only in normal batch flow. |
| `hybrid_batch\hybrid_batch_console_<stamp>_<pid>.log` | `run_batch_vr_hybrid.ps1` | Hybrid batch control shell transcript. |
| `hybrid_batch_prepare\hybrid_batch_{fisheye\|flat}_<stamp>_<clip>.stdout.log` | hybrid child shells | Per-clip fisheye prepare or flat template-AVS encode transcript. |
| `media_folder_watcher\watcher_<stamp>_<pid>.log` | `Watch-MediaFolderPlaylists.ps1` | Background playlist watcher transcript (media / `.avs` refresh). |

---

## Under `M:\m1_media\3d_fullsbs_trans\fisheye_temp\logs\` (global, shared across clips)

| Location / pattern | Producer | Contents |
|--------------------|----------|----------|
| `<mezzanine_base>_v360.stderr.log` | `Run-FisheyeV360.ps1` | Pass-1 mezzanine ffmpeg stderr. |
| `<mezzanine_base>_v360.stdout.log` | `Run-FisheyeV360.ps1` | Pass-1 mezzanine ffmpeg stdout (if enabled). |
| `chase_<stamp>_<avs_safe>.stdout.log` | `Run-V360PrepareFisheye.ps1` (`-ChaseWorker`) | Hidden pass-2 chase worker transcript (context-menu fisheye). |
| `chase_<stamp>_<avs_safe>.stderr.log` | `Run-V360PrepareFisheye.ps1` (`-ChaseWorker`) | Chase worker stderr capture. |
| `chase_resume_state.json` | `Run-TranscodeFfmpeg.ps1` (pass-2 chase) | JSON seek/progress between pass-2 rounds (state, not a text log). |

---

## Other paths (not under `transcode_logs\` / not cleaned by `Cleanup-TranscodeLogs.ps1`)

| Location / pattern | Producer | Purge |
|--------------------|----------|-------|
| `{media}\op_logs\` | StreamTo3D GUI (flat step 1) | Manual / ignore (Readme). Not `Cleanup-TranscodeLogs`. |
| `{media}\fisheye_context_handoff.log` | Fisheye context-menu → batch follow-up (`Resolve-FisheyePlaylistMedia.ps1`) | Manual delete (media root; not under `transcode_logs\`). |
| `{media}\3d_playlist_local\avs\*.avs` | StreamTo3D GUI / hybrid `StreamTo3D.flat_temp.*` | **`Purge-OldAvs.ps1`** (not log cleanup): standalone = full wipe; workflows pass `-KeepCount 50`. |

---

## Not file logs (console only)

Keyboard handling differs by workflow; full matrix in repo `Readme.txt` (Console controls section).

| Component | Space / Enter |
|-----------|----------------|
| `Run-TranscodeOrchestrator.ps1` | Host window: inline `ReadKey` (Space + Enter). No transcript file. |
| `run_batch_fisheye_v360.ps1` / `run_batch_vr_hybrid.ps1` | Batch window: `Invoke-BatchConsoleControlPoll`. |
| Hidden prepare (`-ChaseSync`) | Batch window polls; hidden shell is Space-only via `Invoke-TranscodeConsoleKeyPoll`. |
| `run_batch_convert_streamTo3D.ps1` | No key poll (StreamTo3D GUI step only). |

---

## DLNA segment output (not logs)

Preferred root: `M:\m1_media\3d_fullsbs_trans` (Skybox PC-client DLNA share path). `Ensure-DlnaSegmentRoot` in `Invoke-LeafFfmpegControl.ps1` always stores under `%AppData%\3d_playlist_local` and keeps Explorer dummy `M:` via `subst` + a directory junction when `M:` is free. If `M:` is a real volume or someone else's subst, it picks a random free D–Z letter and uses `{letter}:\m1_media\3d_fullsbs_trans` for that run. On workflow start it **starts the Skybox PC client if idle** via `P:\all_scripts\Skybox_vr_pc` (exe / Steam, hide to tray, wait for `http://127.0.0.1:8018`), **maps the AirScreen share** (`p_cld_media` from `skybox_vr_pc.config.json`), then **adds/updates Add-folders** so `3d_fullsbs_trans` points at the live dummy. It does not change Loop Segments `pcld_ios_media` / `L:` rclone nodes. If Skybox cannot be started, it warns instead. Flat, fisheye, and hybrid all call `Ensure-DlnaSegmentRoot` and write under that mapped letter. Do not repoint Skybox at AppData, and do not write onto a real `M:` volume.

**Lifecycle:** workflow **start** calls `Ensure-DlnaSegmentRoot -Force` (create tree if needed), starts Skybox via `Skybox_vr_pc` if idle, maps the AirScreen share, maps `3d_fullsbs_trans`, and **restores** any `<sha256>.tmp` media (and `fisheye_temp\avs\*.avs`) using scrambled `.dlna_obf_map.json`. Workflow **quit** (`finally` in flat orchestrator / fisheye batch / hybrid batch, including abort/timeout) calls `Invoke-DlnaWorkflowQuitCleanup`: **remove Skybox Add-folders `3d_fullsbs_trans`**, **unmap the Skybox_vr_pc AirScreen share**, then **quit Skybox only if this workflow started it** (already-running Skybox is left alone), then `Obfuscate-DlnaSegmentRootMedia`. On **error** (clip/child failures, fatal batch stop), `-KeepLogs` retains `*.log` / `logs\` (including `fisheye_temp\logs`). **Batch timeout (124) and user cancel (130) purge those DLNA-root logs** like clean success. **Manual delete** (old clear-on-quit): script `Cleanup-DlnaSegmentRoot.ps1` beside `Readme.txt` calls function `Clear-DlnaSegmentRootContents` (covers `flat\` / `fisheye\` / `hybrid\` / `fisheye_temp\` under the shared root). Playlist-local `transcode_logs\` are never under this root and are unaffected.

| Path | Notes |
|------|--------|
| `M:\m1_media\3d_fullsbs_trans\hybrid\3d_op_00_Full_SBS.mkv`, `3d_op_01_Full_SBS.mkv` / `*_LR_180_FISHEYE.mkv` / `*_LR_180.mkv` | Hybrid batch multiplex: flat + fisheye + **already-3D as-is** (`Run-SegmentCopyAsIs` `-c copy -re` → `LR_180`) share one folder; gradual handoff keeps ~two playable. |
| `M:\m1_media\3d_fullsbs_trans\fisheye\3d_op_00_LR_180_FISHEYE.mkv`, `3d_op_01_LR_180_FISHEYE.mkv` | Dedicated fisheye batch / context-menu DLNA double-buffer (~**60 seconds** per segment; trial `LR_180_FISHEYE`). |
| `M:\m1_media\3d_fullsbs_trans\flat\3d_op_00_Full_SBS.mkv`, `3d_op_01_Full_SBS.mkv` | Dedicated flat orchestrator / context-menu DLNA double-buffer (Skybox `Full_SBS`). |
| `M:\m1_media\3d_fullsbs_trans\fisheye_temp\avs\StreamTo3D.fisheye_temp.*.avs` | Fisheye pass-2 chase scripts. Obfuscated on quit with the rest of the DLNA root (same `<sha256>.tmp` map). `Purge-OldAvs.ps1` does **not** touch this folder unless you pass `-AvsFolder`. |
| Legacy `*_VR180_SBS.mkv` / `*_VR190.mkv` | Earlier fisheye suffixes (still matched by Space pause). |

**Mux (flat orchestrator and fisheye pass-2):** `-f segment -segment_time 60 -segment_wrap 2 -reset_timestamps 1` → `flat\`, `fisheye\`, or hybrid `hybrid\` + pattern `3d_op_%02d_Full_SBS.mkv` / `3d_op_%02d_LR_180_FISHEYE.mkv` ([Skybox format keywords](https://skybox.xyz/support/How-to-Adjust-2D&3D&VR-Video-Formats)).

**Hybrid retention:** `Sync-DlnaHybridSegmentHandoff` during the clip wait — prior-suffix pair stays until the new encode has written (>=1 MiB); then inactive leaves retire one-by-one toward two playable files. Clip end `-Finalize` clears other-suffix leaves only when the active pair has >=1 ready file; otherwise it holds the prior pair (does not empty the folder).

**Fisheye pass-2 chase** (`Run-V360PrepareFisheye.ps1` → `Run-TranscodeFfmpeg.ps1` on `fisheye_temp\avs\*.avs`, `-ChaseResumeStateFile` set):

| Behavior | Detail |
|----------|--------|
| Per chase round | `-t 60` caps wall-clock encode; `-readrate 1` (~viewing pace). |
| Slot alternation | Round 1,3,5… `-segment_start_number 0` (first segment → `3d_op_00.mkv`); round 2,4,6… start at `3d_op_01.mkv`. Fixes stale `3d_op_01` when rounds end before 60s at the mezzanine edge. |
| Between rounds | Prior `3d_op_*` ffmpeg stopped; new round overwrites target slot (`-y`). |
| Tail refresh | After chase loop, if last round progress &lt;60s: one segment-mux pass from ~last 120s of mezzanine (no `-t 60`; may refresh both slots). |
| Source type | Original media extension does not change segment rules; mezzanine is always `*.fisheye.frag.mp4`. |

**Flat queue** (orchestrator child on playlist `.avs`, not `fisheye_temp`): single transcode per clip; standard segment mux only (no alternation / no chase `-t 60`).

**Rand fisheye batch** (`global_rand_3d_playlist\run_batch_fisheye_rand.ps1`): same pass-2 chase scripts (synced from this tree).

---

## Cleanup scope (matches `Cleanup-TranscodeLogs.ps1`)

| LOGS.md section | Root path cleaned | What cleanup does |
|-----------------|-------------------|-------------------|
| [transcode_logs](#under-3d_playlist_localindividual_transcodetranscode_logs) | `{each media}\3d_playlist_local\individual_transcode\transcode_logs\` | Default: every such folder found under `F:\f1_media`, `P:\bbf_media`, `P:\all_scripts`. **Recursive delete of all `*.log`**, including `orchestrator_child\`, `ffmpeg_process\`, `fisheye_batch\`, `fisheye_batch_prepare\`, `hybrid_batch\`, `hybrid_batch_prepare\`, `media_folder_watcher\`, and root transcripts/failures. Also removes `fisheye_batch_prepare\*.finished`. `-LocalOnly`: only the copy next to the script. |
| [fisheye_temp\logs](#under-f1_media3d_fullsbs_transfisheye_templogs-global-shared-across-clips) | `M:\m1_media\3d_fullsbs_trans\fisheye_temp\logs\` | Recursive delete of all `*.log` (pass-1 `*_v360.*.log`, chase worker `chase_*.log`). `-NoFisheyeTempLogs` skips. |
| `3d_playlist_local\standardized\` | `{each media}\3d_playlist_local\standardized\` | Default: delete all files under every discoverable playlist `standardized\` (`selective_stdize.ps1` copies). `-NoStandardized` skips. `-LocalOnly`: only this playlist’s folder. Not run for `-LogsRoot` / `-PruneByCount`. |

**Not removed by `Cleanup-TranscodeLogs.ps1`:**

| Item | Reason / how to clear |
|------|------------------------|
| `transcode_lock_owner.txt` | Lock metadata, not a `*.log` |
| `chase_resume_state.json` | Pass-2 state, not a `*.log` |
| `3d_op_*.mkv` (flat/fisheye folders) | DLNA output, not logs |
| `{media}\op_logs\` | StreamTo3D GUI; manual / ignore |
| `{media}\fisheye_context_handoff.log` | Media-root handoff log; manual delete |
| `3d_playlist_local\avs\*.avs` | Use **`Purge-OldAvs.ps1`** (see below) |
| Orchestrator / batch host window | Console only, no file |

---

## Cleanup

### Logs — `Cleanup-TranscodeLogs.ps1`

Double-click or run from `individual_transcode\`:

```powershell
.\Cleanup-TranscodeLogs.ps1
```

**Default:** **delete** all `*.log` under every discoverable playlist `transcode_logs\` tree (`F:\f1_media`, `P:\bbf_media`, `P:\all_scripts`) — including **`media_folder_watcher\`**, **`hybrid_batch*\`**, fisheye batch folders, orchestrator/ffmpeg children — and under `fisheye_temp\logs\`. Removes stale `*.finished` markers under `fisheye_batch_prepare\`. Also **deletes files** under every discoverable `3d_playlist_local\standardized\` (`-NoStandardized` skips). Logs held open by a running encode/watcher are truncated to 0 bytes instead of deleted.

| Goal | Command |
|------|---------|
| All deploy copies + fisheye_temp logs | `.\Cleanup-TranscodeLogs.ps1` |
| Only this playlist’s `transcode_logs\` | `.\Cleanup-TranscodeLogs.ps1 -LocalOnly` |
| Empty files in place (keep Explorer entries) | `.\Cleanup-TranscodeLogs.ps1 -TruncateInstead` |
| Keep N newest transcripts/child logs (legacy retention) | `.\Cleanup-TranscodeLogs.ps1 -PruneByCount -LocalOnly` |
| Skip `standardized\` copies | `.\Cleanup-TranscodeLogs.ps1 -NoStandardized` |

### AVS (not logs) — `Purge-OldAvs.ps1`

Beside `Readme.txt` / orchestrator (`3d_playlist_local\Purge-OldAvs.ps1`):

| Goal | Command |
|------|---------|
| Full wipe of `.\avs` | `.\Purge-OldAvs.ps1` (standalone / double-click) |
| Keep newest 50 | `.\Purge-OldAvs.ps1 -KeepCount 50` (flat/hybrid/orchestrator startup) |
| Preview | add `-DryRun` |
