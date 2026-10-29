# DVD Toolbox

A native Mac app for one job: a DVD in the drive goes into a Jellyfin library on a server, named the way
Radarr and Sonarr name things. Not a player.

- **Disc**: a DVD that goes in is read with HandBrake (every title, its length, chapters, audio and
  subtitle tracks) and looked up on TMDB from its label (`FRIENDS_S1_D2` is Friends, season 1, disc 2).
  Movie or TV is guessed from the titles (episodes are titles of similar length; a "play all" title and
  copies a disc carries to confuse rippers are left out) and can be switched. The match, the season, the
  first episode, the titles and the library are all editable. When the server already has the show, the
  season's episodes there are read and the disc starts after the last one.
- **Rip**: each title is encoded by HandBrakeCLI to MKV: H.265 (x265, or H.264, or the Mac's hardware
  H.265, in Settings), every audio track copied as it is, every subtitle track, chapters. Progress and
  Cancel; a file whose length is not the title's is not kept, and HandBrake's log of each rip is in
  `~/Library/Logs/DVD Toolbox`. HandBrake reads the raw drive (`/dev/rdiskN`): the mounted `/dev/diskN` is
  busy, and libdvdcss cannot open it. The disc is ejected when its rip is done.
- **Names**: `Movies/Title (Year)/Title (Year).mkv` with `movie.nfo` (TMDB and IMDb ids) and the poster;
  `Shows/Show (Year)/Season 1/Show - S01E01 - Episode.mkv` with `tvshow.nfo` and the poster. A folder the
  server already has keeps its name and its files: a film already there gets ` - DVD` as another version.
- **Upload**: rsync over ssh into the library's folder on the server (found from the library's path in
  Jellyfin), nothing replaced, then Jellyfin is told the folder is new and the app waits until the movie
  or the episodes are in it. **Rips** lists every rip, its state, and Upload for one that did not go.
- **UI is labels only**: counts, names and controls. No hint lines, taglines or captions.

## Needs

macOS 26, Xcode, and from Homebrew: `handbrake` (HandBrakeCLI), `libdvdcss` (commercial DVDs are
encrypted), `rsync` 3.1+ and `ffmpeg` (ffprobe checks each file's length).

```sh
brew install handbrake libdvdcss rsync ffmpeg
```

## Build

```sh
./build.sh && open "build/DVD Toolbox.app"
```

Signed with an Apple Development identity if the keychain has one, ad hoc otherwise (`DVD_SIGN` picks).

## First run

Settings asks for a TMDB key (the API key or the read access token, from themoviedb.org's API settings),
Jellyfin's address and an API key made in its Dashboard, and the ssh address and media folder of the server
that holds the library. The keys are kept in the Keychain. Nothing about a server is built into the app.

## Test

```sh
./selftest.sh [WORK]          # stand-ins for TMDB and Jellyfin, a pretend server, folders of video as discs
./selftest.sh WORK --real     # the DVD in the drive: read, its titles listed, the first minute ripped
```

The app drives its own rip, upload and Jellyfin code; the script then checks the files on the pretend
server. Pictures land in `WORK/out`. The window is on screen for a few minutes.
