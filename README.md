# YouTubeDL — LMS Plugin
![Status](https://img.shields.io/badge/status-experimental-orange) ![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows%20%7C%20macOS-blue) ![LMS](https://img.shields.io/badge/LMS-7.7%2B-informational) ![License](https://img.shields.io/badge/license-GPLv2-green) ![Maintenance](https://img.shields.io/badge/maintained-for%20personal%20use-lightgrey) ![Release](https://img.shields.io/github/v/release/ElFishi/yt2lms)

> **⚠️ Experimental — use at your own risk.**  
> This plugin is a personal project, provided as-is with no warranty and no support.
> It is not affiliated with or endorsed by the [LMS YouTube plugin](https://github.com/philippe44/LMS-YouTube) by [Philippe](https://github.com/philippe44).

---

## What it does

YouTubeDL is a [Logitech Media Server](https://lyrion.org/) plugin that lets you download YouTube audio to your music library via **yt-dlp**, triggered directly from an LMS JSON-RPC or telnet command. It adds no menus, no UI integration, and no Material skin context entries — just two CLI commands you can call from any JSON-RPC client, automation script, or the LMS telnet interface.

Downloads run as a detached background process. LMS keeps playing normally while yt-dlp does its work.

---

## Requirements

- **Logitech Media Server** 7.7 or later
- **[LMS YouTube plugin](https://github.com/philippe44/LMS-YouTube)** — recommended but not strictly required. YouTubeDL reuses its yt-dlp binary by default.
- **yt-dlp** — either via the YouTube plugin's bundled binary or installed separately
- **ffmpeg** — required by yt-dlp for audio extraction, thumbnail embedding and conversion. Must be on the system PATH or configured in the plugin settings.

---

## Installation

### From my plugin repository

Point LMS at my repository-xml under Settings → Advanced → Plugins:

```
https://smplu.link/ElFishi.xml
```
If you first want to see where this link leads to, try it [here](https://www.whatsmydns.net/url-unshortener?q=https%3A%2F%2Fsmplu.link%2FElFishi.xml)

### Manual installation

1. Download the zip from the [Releases](../../releases) page.
2. Unzip into your LMS `Plugins` directory as a `YouTubeDL` folder.
3. Restart LMS.

---

## Configuration

Open **Settings → Plugins → YouTubeDL** in the LMS web UI.

| Setting | Description |
|---|---|
| **yt-dlp binary** | Leave blank to use the binary configured in the YouTube plugin (recommended). Enter an absolute path to use a custom yt-dlp installation. The settings page shows whether the binary is found and executable. |
| **ffmpeg path** | Leave blank if `ffmpeg` is on your system PATH. Enter an absolute path if it isn't. The settings page shows whether ffmpeg is found. |
| **Media folder root** | Root directory for downloaded files. Leave blank to use LMS's configured audio folder. |
| **Playlist output template** | yt-dlp `-o` template for playlist downloads. Leave blank for the default (see below). |
| **Single video output template** | yt-dlp `-o` template for individual video downloads. Leave blank for the default (see below). |

### Default output paths

```
# Single video
<media folder>/YouTube/Singles/%(uploader)s - %(title)s.%(ext)s

# Playlist or channel
<media folder>/YouTube/%(playlist)s/%(playlist_index)03d.%(title)s.%(ext)s
```

yt-dlp output template syntax (e.g. `%(title)s`, `%(uploader)s`) is fully supported in both fields. If you enter a relative path it is prepended with the media folder root; an absolute path is used as-is.

---

## Usage

### JSON-RPC

```json
["youtube", "download", "url:https://www.youtube.com/watch?v=VIDEO_ID"]
```

```json
["youtube", "download", "url:https://www.youtube.com/playlist?list=PLAYLIST_ID"]
```

Fetch the log of the most recent download session:

```json
["youtube", "download", "log"]
```

### Telnet

```
youtube download url:https://www.youtube.com/watch?v=VIDEO_ID
youtube download url:https://www.youtube.com/playlist?list=PLAYLIST_ID
youtube download log
```

### Accepted URL forms

| URL form | Downloads as |
|---|---|
| `https://www.youtube.com/watch?v=<id>` | single video |
| `https://youtu.be/<id>` | single video |
| `https://music.youtube.com/watch?v=<id>` | single video |
| `https://www.youtube.com/playlist?list=<id>` | playlist |
| `https://music.youtube.com/playlist?list=<id>` | playlist |
| `https://www.youtube.com/channel/<id>` | channel |
| `https://www.youtube.com/c/<name>` | channel |
| `https://www.youtube.com/user/<name>` | channel |
| `youtube://www.youtube.com/v/<id>` | single video (LMS internal URL) |
| `ytplaylist://playlistId=<id>` | playlist (LMS internal URL) |
| `ytplaylist://channelId=<id>` | channel (LMS internal URL) |

The LMS internal URL forms are the ones used by the YouTube plugin internally — useful if you are building integrations on top of both plugins.

### Command responses

Both JSON-RPC and telnet return an `item_loop` result with status lines:

**On success:**
```
Download started
https://www.youtube.com/watch?v=...
Process ID: 12345
Files will be saved to /mnt/music
View download log
```

**On failure:**
```
Download failed
https://www.youtube.com/watch?v=...
<error message>
```

### Download log

Each download run appends to `yt-dlp-download.log` in the LMS log directory (the same directory as `server.log`). Each run is delimited by a timestamp header:

```
=== 2025-04-01 14:23:11 ===
/usr/bin/yt-dlp https://www.youtube.com/watch?v=... -x -o ...
[yt-dlp output]
```

The log file is also accessible as a browser page at:

```
http://<LMS_HOST>:9000/plugins/YouTubeDL/downloadlog.html
```

This page auto-refreshes every 2 seconds and always shows only the most recent session, so you can watch a download in progress.

---

## yt-dlp command details

The plugin invokes yt-dlp with the following fixed arguments:

```
yt-dlp <url>
  -x                             # extract audio only
  -f bestaudio                   # best available audio quality
  -o <output template>
  --parse-metadata 'playlist_index:%(track_number)s'
  --parse-metadata '%(release_date,upload_date)s:(?P<meta_date>[0-9]{4})'
  --embed-metadata               # write tags into the audio file
  --embed-thumbnail              # embed cover art
  --convert-thumbnails jpg       # normalise thumbnail format
  --postprocessor-args 'ThumbnailsConvertor:-vf scale=500:500:...'
  --no-abort-on-error            # (playlists only) continue past individual failures
  --ffmpeg-location <path>       # (only if custom ffmpeg path is configured)
```

The `release_date`/`upload_date` metadata fallback ensures correct year tags on YouTube Music content where `release_date` is available.

---

## Technical notes

### Binary resolution

The yt-dlp binary is resolved in this order:

1. The **yt-dlp binary** field in YouTubeDL's own settings (absolute path)
2. The YouTube plugin's configured binary, resolved via `Plugins::YouTube::Utils::yt_dlp_bin()` — this handles platform-specific filenames like `yt-dlp_linux` against the YouTube plugin's `Bin/` directory
3. `yt-dlp` on the system PATH

### Process launch

Downloads run fully detached from LMS. On Linux/macOS this uses `fork`+`exec` with `POSIX::setsid()` to create a new session leader — init reaps the child when it exits. On Windows `Win32::Process::Create` is used via `cmd.exe /c`, mirroring the approach used by the YouTube plugin's `ProtocolHandler`.

**Important:** `SIGCHLD` is never modified in the LMS parent process. The YouTube plugin's AnyEvent event loop uses an internal SIGCHLD watcher to track its own yt-dlp child processes; clobbering it would break playlist-to-playlist transitions in the YouTube plugin.

All file descriptor manipulation uses raw POSIX calls rather than Perl's `open()`, because LMS ties STDIN/STDOUT/STDERR to its logging subsystem (`Slim::Utils::Log::Trapper`), which does not implement the `OPEN` tied-handle method.

### Perl module dependencies

No new CPAN dependencies are required beyond what LMS already ships, with two minor caveats:

- **`File::ReadBackwards`** — used for efficient log tail reading. Pure-Perl, commonly included in LMS distributions. If missing, the log viewer returns an empty result rather than crashing.
- **`Win32::Process`** — Windows only, loaded with `eval { require }` so a missing module produces a log error rather than an exception.

---

## Disclaimer

This plugin is experimental and personal. It has been tested on Linux. Windows and macOS support is implemented but less thoroughly tested.

**It is not supported.** Feel free to give it a spin, but issues and pull requests on this repository may or may not receive a response. Do not use this in a production environment you depend on.

The plugin is not affiliated with [Philippe](https://github.com/philippe44)'s [LMS YouTube plugin](https://github.com/philippe44/LMS-YouTube), though it is designed to coexist with it and optionally share its yt-dlp binary.

---

## License

GPLv2