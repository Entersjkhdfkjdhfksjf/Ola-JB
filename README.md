# S1 Toolkit

A from-scratch, independently written toolkit for reaching the stock Android
screens (Settings, Wi-Fi, an AOSP browser if the build ships one) on an
Ola S1 / S1 Pro head unit via its root diagnostics channel, plus a small
CLI for scripting the same thing from a PC.

## Why this exists

There's an existing community tool (`Asjohn720/ola-s1-mods`) that does
something similar. This repo is **not a fork or a copy of it** -- it's a
clean-room reimplementation written after reading its public README and
source for the protocol details, with every line of code rewritten from
scratch. The main practical difference: this repo ships **no pre-compiled
third-party APKs**. The Android app here only ever runs `am start` /
`input` commands against stock AOSP components that already exist on the
head unit -- it doesn't install anything.

## How it works

The MoveOS head unit runs a root (`uid 0`) diagnostics gRPC daemon on TCP
port 50005, reachable over IPv6 (usually link-local, `fe80::...`) on
whatever Wi-Fi network you share with it -- e.g. your phone's hotspot. The
daemon takes a single `command` string and returns a status code plus a
message. No authentication, no ADB, no pairing. This looks like the same
service field technicians' tools use.

**Nothing here touches the boot, system, vendor or recovery partitions,
the motor controller, BMS, or any powertrain/safety subsystem.** It talks
only to the userland Android infotainment layer.

## Python CLI (`python/ola.py`)

```bash
pip install -r python/requirements.txt

python python/ola.py settings  --ipv6 fe80::1234:5678:9abc:def0%6
python python/ola.py browser   --ipv6 fe80::1234:5678:9abc:def0%6
python python/ola.py info      --ipv6 fe80::1234:5678:9abc:def0%6
python python/ola.py shell "pm list packages" --ipv6 fe80::...%6
python python/ola.py screenshot dash.png --ipv6 fe80::...%6
```

A link-local address needs an interface scope id -- append it with `%6`
(find your interface number from `ipconfig`/`ip link`) or pass `--scope 6`
separately.

## Android app (`android/`)

One screen: paste the scooter's IPv6 address, tap Connect, then tap
Settings / Wi-Fi / Browser / Home / Back, or type a one-off shell command.
Built with plain Android Views (no Compose) to keep the build simple, and
`io.grpc:grpc-okhttp` for the transport with a hand-written byte
marshaller -- no generated `.proto` stub, since the daemon only has the one
weakly-typed method.

## Building (Android)

GitHub Actions (`.github/workflows/build-apk.yml`) builds a debug APK on
every push and uploads it as a workflow artifact -- check the Actions tab
after pushing, download the artifact, and sideload it. You never have to
trust a binary someone else compiled, including this one: you can read
every line and build it yourself.

To build locally instead: open `android/` in Android Studio, or run
`cd android && gradle assembleDebug` with Gradle installed.

## iOS app (`ios/`)

Same idea, same wire protocol, written in Swift against
[grpc-swift](https://github.com/grpc/grpc-swift) with the same hand-rolled
byte payload trick as the Python/Kotlin clients -- no generated `.proto`
stub needed.

The project is described with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`ios/project.yml`) instead of a committed `.xcodeproj`, so there's nothing
binary to review -- the whole project is readable text.

**Running it on your own iPhone** (the only way to get it signed without
handing anyone your Apple ID or a paid developer account):

```bash
brew install xcodegen
cd ios
xcodegen generate
open S1Toolkit.xcodeproj
```

In Xcode: select your iPhone as the run destination, pick your personal
team under Signing & Capabilities (free, no paid account needed for a
development build), and hit Run. That's the normal way any indie iOS dev
side-loads a debug build to their own device -- no credentials ever leave
your Mac.

`.github/workflows/build-ios.yml` builds the Simulator target on every
push (no signing required for that), purely so CI catches compile errors
before you ever open Xcode.

## Safety notes

- This talks to a vehicle. The daemon can run arbitrary root shell
  commands -- don't run anything in `shell`/`exec` you don't understand.
- Nothing here is officially supported by Ola Electric. Use at your own
  risk, and don't do this on a scooter you're about to ride somewhere that
  matters if something goes sideways.
- Everything is userland/HMI-only by design, but "by design" isn't a
  safety guarantee -- read the code before you run it, especially the
  `shell` command path.

## License

MIT. See `LICENSE`.
