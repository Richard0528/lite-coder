# lite-coder

A coding-interview practice app built on [Lite XL], which is itself a small
Lua editor derived from [lite]. The editor is unchanged. A `prep` plugin adds
practice rounds, a way to run Python and Node, an AI review, and a daily quiz.

Upstream Lite XL releases do not include this plugin. Build this repository
to get the app. The [Lite XL website][website] still covers the editor itself.

## Build and run

Install Meson (>= 0.63), Ninja, a C compiler, SDL3, PCRE2, and FreeType. Lua 5.4 is bundled when it is not already installed. On macOS:

```sh
brew install meson ninja pkg-config sdl3 pcre2 freetype
```

From this directory:

```sh
meson setup --buildtype=release build
meson compile -C build
ln -sfn "$PWD/data" build/src/data
./build/src/lite-xl
```

The link puts `data/` next to the binary, which is where Lite XL looks for it. If a Homebrew upgrade moves PCRE2, FreeType, or SDL3 and linking fails, run `meson setup --reconfigure build` and compile again.

Python 3 and Node are needed only after the app is open, to run solutions.

## Practice rounds

The sidebar has four rounds. The file tree starts hidden; `treeview:toggle`
brings it back.

| Tab | What you do |
| --- | --- |
| Code | Solve a problem in Python or Node. |
| Design | Write a system design in the editor. There is nothing to run. |
| Debug | Fix a starter that already contains a bug. The AI will answer 3 questions for that problem. |
| Explain | Read the given code and write the explanation in the scratchpad. The AI stays off until you click Done. |

Open a question from the list, or with **Find Question** (`Cmd+Option+P` on macOS, `Ctrl+Alt+P` elsewhere). A dot marks each question as new, attempted, or solved.

The editor keeps your solution. The panel on the right has five tabs:

- **Question** shows the prompt, and a short note from each earlier attempt.
- **Output** shows what the program printed, including errors.
- **Scratchpad** is a normal document for notes.
- **AI** is a hint chat. Ask with the Ask button or `Cmd+Shift+A` / `Ctrl+Shift+A`.
- **Review** is the write-up from Done.

## Running code

**Run** (`Cmd+Return` / `Ctrl+Return`) runs the file you are editing when it belongs to the open question. **Examples** calls the solution on each sample input when the question defines a function signature. **Stop** kills a run. A run is stopped after 10 seconds.

Python and Node are both available. Click the language name in the status bar to switch. The first run looks the binary up through your login shell, so an app opened from Finder can still find nvm or pyenv. The Output tab prints the path it used. Set `config.plugins.prep.python` or `config.plugins.prep.node` to a full path if the lookup picks the wrong one.

Both runtimes preload the helpers interviews usually assume: `collections`, `heapq`, lists, trees, heaps, and deques. Your code runs as you, with only the timeout as a limit.

## AI review and memory

Set `OPENAI_API_KEY`, or enter a key when asked. It is saved in your Lite XL user directory at `prep/secrets.lua`, readable only by you. Any OpenAI-compatible endpoint works. In the user module (`core:open-user-module`):

```lua
config.plugins.prep.llm.base_url = "https://api.openai.com/v1"
config.plugins.prep.llm.model = "gpt-4o-mini"
```

**Done** (`Cmd+Shift+Return` / `Ctrl+Shift+Return`) sends the question, your code, the scratchpad, the last run, and the short notes from earlier attempts. The full write-up stays in that question's Review tab.

What is remembered across sessions is small and tied to the question: status, at most five session lines (date, verdict, a short summary, and the missing piece), and at most four flashcards. Code is not stored in that record. The flashcards show up in the daily quiz.

In a coding round the AI gives hints only. In a design round it interviews you. In a debug round you get 3 questions for that problem, spent when you ask and returned if the call fails. Clicking Done starts a fresh budget.

## Question bank

A small curated set ships with the app: a few coding problems, system-design prompts, debug starters, explain-the-code snippets, and a multiple-choice quiz. **Prep: Sync Questions** downloads more.

The script is [scripts/prep/fetch_questions.py](scripts/prep/fetch_questions.py). It follows the LeetCode requests used by [vscode-leetcode](https://github.com/LeetCode-OpenSource/vscode-leetcode) (problem list, question detail, cookie headers). From a terminal:

```sh
python3 scripts/prep/fetch_questions.py --per-difficulty 20
```

`--per-difficulty` defaults to 150. The result is written under `data/plugins/prep/bank/`, which is gitignored because LeetCode's text is not ours to commit. From inside the app, sync writes to `prep/bank` in your Lite XL user directory instead, so an installed copy does not need a writable application folder.

**Menu**, at the left of the status bar, opens LeetCode's login page in a separate browser window. Sign in there. The app reads the cookie from that window and stores it, then the status bar shows your username. That window uses its own profile, so it does not change the browser you use every day. It needs Chrome, Chromium, Edge, or Brave. **Paste a LeetCode cookie** in the same menu is the fallback: paste the Cookie header from a `leetcode.com` request, including `cf_clearance`. If LeetCode still refuses, set `config.plugins.prep.user_agent` to your browser's User-Agent. **Sign out of LeetCode** clears the saved cookie.

## Daily quiz

With no file open, the editor shows one quiz card: five questions for the day, mixed with flashcards that are due. Press 1–4 or click an answer. A line at the bottom shows your streak, how many questions you have solved, and the last question so you can continue it.

## Overview

Lite XL is derived from [lite].
It is a lightweight text editor written mostly in Lua — it aims to provide
something practical, pretty, *small* and fast, easy to modify and extend,
or to use without doing either.

The aim of Lite XL compared to lite is to be more user friendly,
improve the quality of font rendering, and reduce CPU usage. The differences
are listed in the [changelog].

## Customization

Additional functionality can be added through plugins which are available in
the [plugins repository] or in the [Lite XL plugins repository].

Additional color themes can be found in the [colors repository].
These color themes are bundled with all releases of Lite XL by default.

## Quick Build Guide

To compile Lite XL yourself, you must have the following dependencies installed
via your desired package manager, or manually.

### Prerequisites

- Meson (>=0.63)
- Ninja
- SDL3
- PCRE2
- FreeType2
- Lua 5.4
- A working C compiler (GCC / Clang / MSVC)

PCRE2, FreeType2 and Lua will be downloaded by Meson
if `--wrap-mode=forcefallback` or `--wrap-mode=default` is specified.
SDL3 is not bundled. On macOS, `brew install sdl3`.

> [!NOTE]
> MSVC is used in the CI, but MSVC-compiled binaries are not distributed officially
> or tested extensively for bugs.

On Linux, you may install the following dependencies for the SDL2 X11 and/or Wayland backend to work properly:

- `libX11-devel`
- `libXi-devel`
- `libXcursor-devel`
- `libxkbcommon-devel`
- `libXrandr-devel`
- `wayland-devel`
- `wayland-protocols-devel`
- `dbus-devel`
- `ibus-devel`

The following command can be used to install the dependencies in Ubuntu:

```sh
apt-get install python3.8 python3-pip build-essential git cmake wayland-protocols libsdl2-dev
pip3 install meson ninja
```

Please refer to [lite-xl-build-box] for a working Linux build environment used to package official Lite XL releases.

On macOS, you must install bash via Brew, as the default bash version on macOS is antiquated
and may not run the build script correctly.

### Building

See [Build and run](#build-and-run). `scripts/build.sh --help` lists packaging and cross-compile options.

## Installing Prebuilt

Head over to [releases](https://github.com/lite-xl/lite-xl/releases) and download the version for your operating system.

The prebuilt releases supports the following OSes:

- Windows 7 and above
- Ubuntu 18.04 and above (glibc 2.27 and above)
- OS X El Capitan and above (version 10.11 and above)

Some distributions may provide custom binaries for their platforms.

### Windows

Lite XL comes with installers on Windows for typical installations.
Alternatively, we provide ZIP archives that you can download and extract anywhere and run directly.

To make Lite XL portable (e.g. running Lite XL from a thumb drive),
simply create a `user` folder where `lite-xl.exe` is located.
Lite XL will load and store all your configurations and plugins in the folder.

### macOS

We provide DMG files for macOS. Simply drag the program into your Applications folder.

> **Important**
> Newer versions of Lite XL are signed with a self-signed certificate,
> so you'll have to follow these steps when running Lite XL for the first time.
>
> 1. Find Lite XL in Finder (do not open it in Launchpad).
> 2. Control-click Lite XL, then choose `Open` from the shortcut menu.
> 3. Click `Open` in the popup menu.
>
> The correct steps may vary between macOS versions, so you should refer to
> the [macOS User Guide](https://support.apple.com/en-my/guide/mac-help/mh40616/mac).
>
> On an older version of Lite XL, you will need to run these commands instead:
> 
> ```sh
> # clears attributes from the directory
> xattr -cr /Applications/Lite\ XL.app
> ```
>
> Otherwise, macOS will display a **very misleading error** saying that the application is damaged.

### Linux

Unzip the file and `cd` into the `lite-xl` directory:

```sh
tar -xzf <file>
cd lite-xl
```

To run lite-xl without installing:

```sh
./lite-xl
```

To install lite-xl copy files over into appropriate directories:

```sh
rm -rf  $HOME/.local/share/lite-xl $HOME/.local/bin/lite-xl
mkdir -p $HOME/.local/bin && cp lite-xl $HOME/.local/bin/
mkdir -p $HOME/.local/share/lite-xl && cp -r data/* $HOME/.local/share/lite-xl/
```

#### Add Lite XL to PATH

To run Lite XL from the command line, you must add it to PATH.

If `$HOME/.local/bin` is not in PATH:

```sh
echo -e 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
```

Alternatively on recent versions of GNOME and KDE Plasma,
you can add `$HOME/.local/bin` to PATH via `~/.config/environment.d/envvars.conf`:

```ini
PATH=$HOME/.local/bin:$PATH
```

> **Note**
> Some systems might not load `.bashrc` when logging in.
> This can cause problems with launching applications from the desktop / menu.

#### Add Lite XL to application launchers

To get the icon to show up in app launcher, you need to create a desktop
entry and put it into `/usr/share/applications` or `~/.local/share/applications`.

Here is an example for a desktop entry in `~/.local/share/applications/com.lite_xl.LiteXL.desktop`,
assuming Lite XL is in PATH:

```ini
[Desktop Entry]
Type=Application
Name=Lite XL
Comment=A lightweight text editor written in Lua
Exec=lite-xl %F
Icon=lite-xl
Terminal=false
StartupWMClass=lite-xl
Categories=Development;IDE;
MimeType=text/plain;inode/directory;
```

To get the icon to show up in app launcher immediately, run:

```sh
xdg-desktop-menu forceupdate
```

Alternatively, you may log out and log in again.

#### Uninstall

To uninstall Lite XL, run:

```sh
rm -f $HOME/.local/bin/lite-xl
rm -rf $HOME/.local/share/icons/hicolor/scalable/apps/lite-xl.svg \
          $HOME/.local/share/applications/com.lite_xl.LiteXL.desktop \
          $HOME/.local/share/metainfo/com.lite_xl.LiteXL.appdata.xml \
          $HOME/.local/share/lite-xl
```

## Contributing

Any additional functionality that can be added through a plugin should be done
as a plugin, after which a pull request to the [Lite XL plugins repository] can be made.

Pull requests to improve or modify the editor itself are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] file for details on licenses used by the required dependencies.


[CI]:                         https://github.com/lite-xl/lite-xl/actions/workflows/build.yml/badge.svg
[Discord Badge Image]:        https://img.shields.io/discord/847122429742809208?label=discord&logo=discord
[screenshot-dark]:            https://user-images.githubusercontent.com/433545/111063905-66943980-84b1-11eb-9040-3876f1133b20.png
[lite]:                       https://github.com/rxi/lite
[website]:                    https://lite-xl.com
[build]:                      https://lite-xl.com/setup/building-from-source/
[Get Lite XL]:                https://github.com/lite-xl/lite-xl/releases/latest
[Get plugins]:                https://github.com/lite-xl/lite-xl-plugins
[Get color themes]:           https://github.com/lite-xl/lite-xl-colors
[changelog]:                  https://github.com/lite-xl/lite-xl/blob/master/changelog.md
[Lite XL plugins repository]: https://github.com/lite-xl/lite-xl-plugins
[plugins repository]:         https://github.com/rxi/lite-plugins
[colors repository]:          https://github.com/lite-xl/lite-xl-colors
[LICENSE]:                    LICENSE
[licenses]:                   licenses/licenses.md
[lite-xl-build-box]:          https://github.com/lite-xl/lite-xl-build-box
