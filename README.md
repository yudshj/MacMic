# MacMic for Mac (Unofficial)

Language: **English** | [简体中文](README_ZH.md)

**MacMic** is an unofficial native macOS audio client built for Apple Silicon (M-series chips), compatible with the WO Mic communication protocol. Written in pure Swift / SwiftUI, it features a lightweight footprint, fast cold start, and routes phone microphone audio directly into **BlackHole 2ch** virtual audio device.

> **📌 Architecture Note**  
> Currently, the pre-built application binary supports **Apple Silicon (M1/M2/M3/M4 series chips)**. Let me know if you need an Intel version.

> **💻 Windows Users Note**  
> This project will **NOT** provide a Windows version. Windows users please support and use the official software by Wolicheng Tech: [https://wolicheng.com/womic/](https://wolicheng.com/womic/).

> **Disclaimer & Note to WO Mic Developers**  
> 1. **Unofficial Port**: This project is an independent open-source port and has no affiliation, sponsorship, or endorsement from Wolicheng Tech. **Please DO NOT ask the developers of WO Mic for help regarding this unofficial port.**  
> 2. **To Developers of WO Mic**: We deeply appreciate Wolicheng Tech's work on WO Mic. This software is created solely for macOS interoperability research and personal convenience. If Wolicheng Tech does not approve of this port or has any concerns, please contact `maghsk2017@gmail.com`. The repository will be immediately taken down upon request.  
> 3. **Trademarks**: WO Mic is a trademark of its respective owner. This project is not affiliated with, endorsed or sponsored by Wolicheng Tech / WO Mic.


---

## Key Highlights

Official WO Mic support has long lacked a clean native client for macOS. Previously, using WO Mic on Mac required Wine, virtual machines, or fragile Python scripts, often suffering from audio latency, popping, or disconnects.

MacMic directly implements low-level network communication and CoreAudio pipelines in Swift, statically linking `libopus` with zero runtime dependencies.

---

## Features

- **Real-time AI Noise Suppression** (three modes):
  - **Off**: pure bypass, zero latency and zero extra cost.
  - **Apple Voice Isolation** (default): the system `AUSoundIsolation` unit FaceTime uses; stronger and cheaper (~4% CPU measured), at ~56 ms extra latency, no extra install size.
  - **RNNoise**: xiph's open model, lowest latency (~20 ms extra), ~5-6% of one CPU core measured on M5 Pro (whole pipeline included); used automatically below macOS 13.
  - A strength slider mixes the denoised signal with the original; the dry path is delayed to the same length, so there is no comb filtering.
  - All denoising runs on the audio worker thread, never on the real-time render thread.
- **Three Connection Modes** (USB first / default):
  - **USB (ADB)**: Plug in an Android phone; port forwarding is automatic and you can pick among multiple attached devices.
  - **Wi-Fi**: Wireless connection over local network (supports iOS & Android).
  - **Wi-Fi Direct**: Direct hotspot connection.
- **Audio Routing & Processing**:
  - Auto-detects and outputs audio into **BlackHole 2ch** virtual microphone.
  - Smooth level bar with a -60 to 0 dBFS scale and a peak marker.
  - 0% to 200% gain adjustment and one-click mute.
- **Internationalization (9 Languages Supported)** 🌐:
  - Full native i18n support with instant dynamic switching:
    - 🇨🇳 **简体中文** (Simplified Chinese)
    - 🇭🇰 **繁體中文** (Traditional Chinese)
    - 🇺🇸 **English**
    - 🇯🇵 **日本語** (Japanese)
    - 🇰🇷 **한국어** (Korean)
    - 🇪🇸 **Español** (Spanish)
    - 🇫🇷 **Français** (French)
    - 🇷🇺 **Русский** (Russian)
    - 🇩🇪 **Deutsch** (German)
  - Automatically matches macOS system language or customizes in Preferences.
- **macOS Native Integration**:
  - Menu Bar resident mode with quick status popover controls.
  - Supports Light, Dark, and System appearance themes.
  - Launch at Login option (powered by Apple's `SMAppService`).
- **Native & Lightweight**: Single standalone binary without background daemons.

---

## Usage

Mobile app setup is identical to the official connection procedure. Here are the step-by-step instructions:

### 1. Install Virtual Audio Driver (BlackHole)
macOS does not allow applications to inject audio directly into other apps' microphone input. Therefore, a virtual audio driver like **BlackHole 2ch** is required.

Install via Homebrew:
```bash
brew install blackhole-2ch
```
Or download the installer from the [BlackHole Website](https://existential.audio/blackhole/).

### 2. Mobile App Setup

#### iOS (iPhone)
1. Download and open **WO Mic** from the App Store.
2. Connect your iPhone and Mac to the same Wi-Fi network.
3. In WO Mic settings, set **Transport** to **Wi-Fi** (*Note: WO Mic for iOS officially supports Wi-Fi mode only*).
4. Tap the Play button at the top and note the IP address shown on screen (e.g., `192.168.1.105`).

#### Android
- **Wi-Fi Mode**: Same steps as iOS.
- **USB Mode**:
  1. Enable **USB Debugging** under Developer Options on your Android device.
  2. Connect to Mac via USB cable, set Transport to **USB** in WO Mic app, and tap Play.
  3. Select **USB (ADB)** mode in MacMic client and click Connect (ADB forwards port 8125 automatically).

### 3. Mac Client Connection

1. Download `MacMic.app` from Releases, move it to `/Applications`, and open it.
2. In the **Audio Routing** dropdown, select **`BlackHole 2ch [Virtual Microphone]`**:

   ![MacMic Interface](assets/main_ui.png)

3. Enter your phone's IP address (or select the appropriate Transport mode) and click **Connect**.
4. **⚠️ System Permissions Requirement**: When clicking Connect for the first time, macOS will present two system permission dialogs as shown below. **You MUST click "Allow" on BOTH popups**. Declining will block network traffic or microphone audio output:

   | Local Network Permission | Microphone Access Permission |
   | :---: | :---: |
   | ![Local Network Permission](assets/permission_local_network.png) | ![Microphone Permission](assets/permission_microphone.png) |

### 4. Input Source & Global Audio Management

- **Basic Setup**: Open WeChat, Zoom, Teams, OBS, or macOS System Settings -> Sound, and select **BlackHole 2ch** as your Microphone (Input Device).
- **Recommended Advanced Tool (FineTune)**:  
  For per-app audio input routing and comprehensive system-wide volume control, we recommend pairing MacMic with **FineTune**, a free menu-bar audio utility for macOS.  
  - Repository: [https://github.com/ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune)

---

## Wi-Fi connection / handshake 0x65 failed

1. **Check the phone first:** WO Mic must show **Waiting for connection**. If it shows **Connected** with no working client, tap the top-right **Stop → Start** button. WO Mic accepts one client; a failed/abandoned handshake can leave that slot occupied. Disconnect other clients before trying again.
2. Keep WO Mic **in the foreground and the phone screen awake** during diagnosis. Confirm the phone is actually connected to Wi-Fi and use its current LAN IP, not a mobile-data or personal-hotspot interface address. The Mac must be on a reachable LAN. Poor signal, roaming and packet loss can exceed a 4-second handshake timeout even when occasional pings succeed.
3. A **TCP connect timeout** indicates a reachability/listener problem; **0 bytes / EOF** means the peer closed the connection (possibly an occupied client slot); a **0x65 read timeout** means TCP connected but no complete protocol response arrived. None alone proves Android sleep/APF filtering. Reset WO Mic before another attempt; avoid repeated bare TCP probes, which themselves can occupy its slot.
4. Wi-Fi needs **TCP 8125** to the phone and **UDP 8125** on the Mac. Another client's occupied UDP port must be released. The Python client binds UDP before advertising its actual port in 0x66, retries at most 3 times with 1s/2s backoff, and gives each complete network attempt a 5s budget by default. Cleanup attempts 0x68 then abortive TCP close; this cannot guarantee recovery of an already-stuck phone server.
5. **USB (ADB) is the most reliable alternative on unstable Wi-Fi.** On Android select USB transport in WO Mic, tap Start, then select USB (ADB) in MacMic. For the Python reference client (with its audio dependencies installed):

   ```bash
   python3 macmic_cli.py --usb
   ```

   An audio-free Python diagnostic uses one TCP connection for both reachability and 0x65 (no audio capture):

   ```bash
   python3 macmic_cli.py --diagnose 192.168.1.105
   # Optional: an already-created ADB forward, e.g. local 18125 → phone 8125
   python3 macmic_cli.py --diagnose 127.0.0.1 --port 18125
   ```

   Diagnosis does not test UDP audio or 0x66/0x67. An ADB forward is a TCP proxy: a reset on the Mac side does not prove the phone-side socket received a reset. If the phone still shows Connected after diagnosis, tap Stop → Start again.

## Closing the Window

MacMic is a menu-bar app. Closing the main window keeps everything running (mic, denoise
and audio routing are unaffected) and **automatically releases the memory used by the window UI**:

| State | Memory (Activity Monitor footprint) |
| --- | --- |
| Window open | ~144 MB |
| Window closed | ~67 MB |

Reopening from "Open Panel" in the menu bar takes about 0.1 s, with all state preserved
(transport, denoise settings). There is no toggle; this is simply how close behaves.

---

## Noise Suppression Tips

- **Default is Apple Voice Isolation**: measured both stronger and cheaper (~4% vs ~6% CPU); it costs ~56 ms extra latency, which is unnoticeable in calls.
- **Switch to RNNoise** when latency matters more, e.g. live monitoring or lip-sync (~20 ms extra).

### Measured performance (M5 Pro, USB stream, window open)

| Denoise mode | CPU (share of one core) | Extra latency |
| --- | --- | --- |
| Off | ~1-4% | 0 |
| RNNoise | ~6-7% | ~20 ms |
| Apple Voice Isolation | ~5-7% | ~56 ms |

> Figures include the whole pipeline (receive, Opus decode, denoise, meter, AUHAL output) and fluctuate with audio content and window state. The two denoisers are within ~1 point of each other, so pick by latency requirement.
- **Strength slider**: 100% is full denoise. Drop to 60–80% if voices sound muffled or over-processed.
- **Don't stack denoisers**: with MacMic denoising on, set the built-in noise suppression in Zoom / Teams / WeChat to low or off. Two denoisers in series tend to sound "underwater" and clip word endings.
- **Try the phone-side source mode first**: WO Mic exposes several input modes on the phone; mode 3 is documented as suited to noisy environments.

---

## Building from Source

### Prerequisites
- macOS 12.0+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- libopus (`brew install opus`)

> RNNoise needs no manual install: on the first `build_app.sh` run, `scripts/build_rnnoise.sh` fetches the pinned xiph/rnnoise revision plus its model weights (sha256-verified) and statically compiles `third_party/rnnoise/lib/librnnoise.a`.

### Build Command
```bash
git clone https://github.com/yudshj/MacMic.git
cd MacMic
./build_app.sh
```
The compiled `MacMic.app` bundle will be generated in the root directory.

---

## Source Layout

```text
swift-src/
├── main.swift                 # Application entrypoint & window styling
├── ContentView.swift          # SwiftUI interface & VU meter rendering
├── ViewModel.swift            # State management & event dispatching
├── MacMicClient.swift         # Communication protocol implementation
├── AudioEngine.swift          # CoreAudio / AudioQueue output, ring buffer, level meter
├── Denoiser.swift             # Real-time denoise: RNNoise / Apple Voice Isolation / bypass
├── OpusDecoder.swift          # C libopus decoding wrapper
├── AudioDeviceManager.swift   # macOS audio device enumeration
├── ADBHelper.swift            # Android USB ADB port forwarding helper
├── MenuBarManager.swift       # Menu bar icon & quick action popover
├── SettingsView.swift         # Multi-language & autostart preferences
├── Localization.swift         # Multi-language i18n support
└── LaunchAtLoginHelper.swift  # SMAppService login item manager
```

---

## License

Distributed under the [MIT License](LICENSE).

The macOS app statically links [Opus](https://opus-codec.org/) (BSD-3-Clause) and [RNNoise](https://github.com/xiph/rnnoise) (BSD-3-Clause). Their license texts ship with the app in `MacMic.app/Contents/Resources/licenses/` (sources: [`licenses/`](licenses/), [`third_party/rnnoise/COPYING`](third_party/rnnoise/COPYING)).

The Android phone app now lives in [MacMic-Android](https://github.com/yudshj/MacMic-Android).

## Acknowledgements

- Built on [luanyufei/MacMic](https://github.com/luanyufei/MacMic) (MIT); thanks to the original author for the foundational work.
- [xiph/rnnoise](https://github.com/xiph/rnnoise) — BSD-3-Clause noise suppression model.
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) — virtual audio driver.
- WO Mic is a trademark of its respective owner. This project is not affiliated with, endorsed or sponsored by Wolicheng Tech / WO Mic.

## Maintainer

- GitHub: [@yudshj](https://github.com/yudshj)
- Project: [github.com/yudshj/MacMic](https://github.com/yudshj/MacMic)
- Email: `maghsk2017@gmail.com`
