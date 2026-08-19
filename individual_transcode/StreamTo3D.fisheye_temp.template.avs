# Fisheye pass-2 AVS: read mezzanine only (no StreamTo3D 2D->3D / MDepan).
# Mono square fisheye -> duplicate to full SBS for Skybox; already-wide SBS -> pass through.
SetFilterMTMode("DEFAULT_MT_MODE", 2)
StreamTo3D_fps_num=30000
StreamTo3D_fps_den=1001
clip = DirectShowSource("StreamTo3D_input.mp4", fps=Float(StreamTo3D_fps_num)/StreamTo3D_fps_den, convertfps=true).AssumeFPS(StreamTo3D_fps_num, StreamTo3D_fps_den)
w = width(clip)
h = height(clip)
clip = (w < h * 2 - 8) ? StackHorizontal(clip, clip) : clip
clip
