[English](sounds.md) · [Русский](ru/sounds.md) · [简体中文](zh-CN/sounds.md)

# Sounds

Seven short 8-bit recordings by Juhani Junkala (SubspaceAudio), released under CC0, cover opening, closing, session start, working, completion, attention and failure. Panel cues are brief clicks; session events use distinct tones. Levels and edge fades are prepared in the bundled WAV files.

**Settings → Sound** controls the master switch, volume, per-event switches and preview.

Sounds are off by default, with volume set to 30%. The working cue is also off by default. Quiet mode and zero volume mute previews too.

Each cue can use a custom audio file up to 10 MiB and 10 seconds. The app keeps a copy in `Application Support/si-notch/Sounds`. Restore the built-in cue to remove that copy; the original file stays untouched.

Repeated observations of one session or turn produce one cue. History restoration and automatic panel closing stay silent. Separate sessions do not share a sound cooldown. Previews and pointer-driven open/close cues limit immediate repeats.
