Run sequence:

# Canonical:     P:\all_scripts\global_rand_3d_playlist  (run here; no F:\all_scripts hub)
# Transcode:     robocopy from P:\all_scripts\3d_playlist_local\individual_transcode on batch start
# Other deps:    P:\all_scripts\py_venv1, P:\all_scripts\setup_venv.bat, P:\all_scripts\AutoHotkey
# DLNA output:   F:\f1_media\3d_fullsbs_trans  (Skybox share; dummy subst F: during run via
#                Ensure-DlnaSegmentRoot; never a real F: volume; quit clears dummy letter)
#   If a real F: (or subst to some other folder) is already mapped, Ensure-DlnaSegmentRoot
#   throws and the batch stops — unmount it so the dummy letter can be created.
#   Run start (fisheye + hybrid batches): Ensure-DlnaSegmentRoot -Force recreates trees and restores
#     any <sha256>.tmp media and .avs (via .dlna_obf_map.json) from a prior quit.
#   Run quit (both batches finally): Invoke-DlnaWorkflowQuitCleanup obfuscates media and .avs to
#     <sha256(relativePath)>.tmp (scrambled .dlna_obf_map.json; includes fisheye_temp\avs\*.avs),
#     then Remove-DlnaSegmentRootSubst (clears dummy subst F: + junction).
#   On error: same obfuscate, but -KeepLogs retains *.log / logs\ (including fisheye_temp\logs).
#     Triggers: clip/child failures, fatal batch stop (exit 1).
#     Batch timeout (124) and user cancel (130) purge DLNA-root logs like clean success.
#   Manual delete (former quit clear): Cleanup-DlnaSegmentRoot.ps1 (beside this Readme)
#     -> Clear-DlnaSegmentRootContents in individual_transcode\Invoke-LeafFfmpegControl.ps1
#   Hard-kill of the batch console skips finally (no obfuscate/subst cleanup until next normal quit
#     or manual Cleanup-DlnaSegmentRoot.ps1).

P:
cd P:\all_scripts\global_rand_3d_playlist

# 1.
# overwrites 2d_media_paths.txt in this folder (double-click .py or: python select_rand_media_per_category.py; pauses 5s then exits)
#   python select_rand_media_per_category.py --no-pause   (for scripts / automation)

# 2.
# StreamTo3D > Settings > Conversion > Ffmpeg Options: -h 
# StreamTo3D > Convert > 'Select 2D Video...' dialog > Filter: List (.txt) > P:\all_scripts\global_rand_3d_playlist\2d_media_paths.txt
# StreamTo3D > Convert > 'Select Dest. Dir...' dialog > P:\all_scripts\global_rand_3d_playlist\op_logs
# if no 'Converting: ...' process loop, restart app and retry!
# wait for batch to finish with error logs saved to .\op_logs (ignore them)

# 3.
# moves new avs files from 'C:\ProgramData\StreamTo3D\...' to .\avs (creates .\avs if missing)
# sorts avs file list by latest timestamp (prioritizing 'rand_combo' till custom max count) + appends to playlist.m3u
P:\all_scripts\global_rand_3d_playlist\gen_m3u.py

# 4.
# optional/as-needed
P:\all_scripts\global_rand_3d_playlist\purge_old_data.py

# =============================================================================
# HYBRID batch (per-clip flat vs fisheye from bitrate + codec; uses 2d_media_paths.txt)
# =============================================================================
# Recommended automated path when mixed flat/fisheye DLNA is wanted:
P:\all_scripts\global_rand_3d_playlist\run_batch_vr_hybrid_rand.ps1
#   Same PotPlayer gate / -ResumeAfter / DPL seek / -BatchTimeoutSec 5400 as fisheye-only.
#   Syncs individual_transcode from P:\all_scripts\3d_playlist_local; Purge-OldAvs -KeepCount 50 under .\avs
#     (purge skips if .\avs is missing; hybrid recreates it on first flat AVS write)
#   Fixed 2d_media_paths.txt queue (no live media_files watcher).
#   Per clip probes format/stream bitrate + v:0 codec_name (Resolve-HybridWorkflowRoute.ps1):
#     flat when: (<4 Mbps AND not hevc/av1) OR (<2 Mbps AND hevc/av1); otherwise fisheye
#   Per clip: if already-3D (Test-Skip3dFormattedMediaName / Test-RandSkipStreamTo3DMediaName)
#     -> Run-SegmentCopyAsIs (-c copy -re) into ...\hybrid\ (Get-AsIsDlnaSegmentSuffix); else:
#   Routes:
#     fisheye -> Run-V360PrepareFisheye -AutoChaseTranscode -ChaseSync -SegmentNameSuffix LR_180_FISHEYE
#               -> F:\f1_media\3d_fullsbs_trans\hybrid\3d_op_%02d_LR_180_FISHEYE.mkv
#     flat    -> Export StreamTo3D.fisheye_temp.template.avs (no StreamTo3D GUI; StackHorizontal if not SBS)
#               -> Run-TranscodeFfmpeg -SegmentNameSuffix Full_SBS
#               -> F:\f1_media\3d_fullsbs_trans\hybrid\3d_op_%02d_Full_SBS.mkv
#   Minute segments multiplexed to one folder; Sync-DlnaHybridSegmentHandoff retires prior-suffix leaves
#     gradually after the new wrap pair starts writing (keep ~two playable); clip end -Finalize cleans up.
#   Flat AVS written as .\avs\StreamTo3D.flat_temp.{source}.avs (mkdir if needed)
#   Fisheye pass-2 AVS is under fisheye_temp\avs (created by prepare; not the project .\avs folder)
#   Console (batch control window): Space=pause/resume leaf 3d_op_* ffmpeg (mezzanine keeps running);
#     Enter=cancel clip/batch; batch deadline keeps ticking while paused
#   -SkipPotPlayer / -DryRun / -SkipPotPlayerSeek / -ResumeAfter same as fisheye batch
#   Ref: https://skybox.xyz/support/How-to-Adjust-2D&3D&VR-Video-Formats
#   Logs: individual_transcode\LOGS.md (after sync) + transcode_logs\hybrid_batch\
#   Quit: obfuscates DLNA media and .avs + clears dummy F: (see DLNA output block above)

# =============================================================================
# FISHEYE-only batch (v360 mezzanine + DLNA chase; uses 2d_media_paths.txt, not local media_files)
# =============================================================================
#   Syncs transcode scripts from P:\all_scripts\3d_playlist_local\individual_transcode
#   AutoHotkey: P:\all_scripts\AutoHotkey -> .\AutoHotkey\ beside project
#   Opens PotPlayer on fisheye_batch_potplayer.dpl (all 2d paths, including offline pointers)
#   Browse to your start clip; triple-left-click in video area (or File > Exit) closes PotPlayer -> batch runs
#   PotPlayer-only gate (no transcode): fisheye_batch\Invoke-RandPotPlayerGateOnly.ps1
#   Console: Space=pause/resume leaf DLNA export; Enter=cancel (same as hybrid)
P:\all_scripts\global_rand_3d_playlist\run_batch_fisheye_rand.ps1
#   -SkipPotPlayer to skip gate; -DryRun to preview queue; -SkipPotPlayerSeek for 0s start on every clip
#   Already-3D (Test-RandSkipStreamTo3DMediaName): Run-SegmentCopyAsIs -> ...\hybrid\ (not skipped; no prepare/chase)
#   Quit: obfuscates DLNA media and .avs + clears dummy F: (see DLNA output block above)
#
# DLNA output (same 60-second segment rules as 3d_playlist_local; see that Readme + individual_transcode\LOGS.md):
#   F:\f1_media\3d_fullsbs_trans\fisheye\3d_op_%02d_LR_180_FISHEYE.mkv  (two rotating ~60s buffers)
#   As-is already-3D: F:\f1_media\3d_fullsbs_trans\hybrid\3d_op_%02d_LR_180.mkv (-c copy -re)
#   Pass 1: fisheye_temp\{base}.fisheye.frag.mp4  (Run-FisheyeV360.ps1, av1_qsv 50M)
#   Pass 2: Run-V360PrepareFisheye.ps1 chase -> Run-TranscodeFfmpeg.ps1 on fisheye_temp\avs\*.avs
#     ffmpeg: -segment_time 60 -segment_wrap 2 -reset_timestamps 1 -readrate 1 (viewing pace)
#     Chase rounds alternate -segment_start_number 0/1 + -t 60 per round
#       so short rounds at the mezzanine edge still refresh both slots
#     End of clip: optional tail refresh (~120s segment mux, no -t 60) if last round <60s progress
#   Source extension (.mkv/.mp4/...) does not change segment behavior; all clips use the paths above


# FLAT DLNA (orchestrator on playlist .avs — classic path; hybrid flat uses template AVS instead):
#   Run-TranscodeOrchestrator.ps1 -> Run-TranscodeFfmpeg.ps1 per .avs
#   Classic/Skybox flat slots: F:\f1_media\3d_fullsbs_trans\flat\3d_op_%02d_Full_SBS.mkv
#   Hybrid multiplex slots:    F:\f1_media\3d_fullsbs_trans\hybrid\3d_op_%02d_Full_SBS.mkv (shared with fisheye route)
#   -segment_time 60 -segment_wrap 2 (one invocation per clip; no chase alternation)

Notes:
.\avs is not a required empty fixture: hybrid/gen_m3u recreate it when writing; fisheye-only does not need the project folder.
Adding new media:
  Manually move them to top of 2d_media_paths.txt so their avs file gets created earlier by StreamTo3d (+skip re-converting existing)
Changing folder paths:
  Missing/obsolete avs links are auto-skipped in 10s during playback, or can be manually skipped earlier!

Issues:
of_media\**rand_combo.m* new entry may get added (unlike fixed \rand_combo.m* slots) to playlist after each full refresh
