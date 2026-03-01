# BitsBlink - Optical Modem

BitsBlink is a high-speed optical modem system that allows devices to communicate via visible light (Li-Fi concepts). It transmits data by flashing a screen or smartphone flashlight, and receives data by decoding the video feed from a smartphone camera.

## Setup & Running

This project uses Flutter for the UI and camera processing, and Kotlin for the native hardware integration.

### Prerequisites
- Flutter SDK installed
- Android device (required for camera and flashlight testing — Emulators do not support camera APIs well)
- Python 3 (optional, for screen-based testing)

### Running the App
1. Connect your Android device.
2. Run the Flutter application:
   ```bash
   flutter run
   ```

### Screen-Based Transmitter (Alternative Testing)
If you only have one phone, you can use the included Python screen transmitter to send data to your phone's receiver.
1. From the root directory, run:
   ```bash
   python tools/transmitter.py
   ```
2. Point your phone's camera at the flashing window on your computer.

---

## Core Business Logic

Due to hardware limitations—such as camera frame rates (capped ~30fps) and auto-exposure adjustments—transmitting data quickly and accurately requires a multi-layered approach involving robust tracking, dynamic synchronization, and error correction.

### 1. Frame-Level On-Off Keying (OOK)
To maximize reliability, BitsBlink uses Frame-Level OOK. 
- A bright source is a `1` bit.
- A dark source is a `0` bit.
- The chip duration is set higher than the camera frame time (currently ~204ms per chip, or roughly 6 frames). This ensures that every bit spans multiple camera frames clearly without getting lost in camera exposure latency.

### 2. ROI Tracking & Contrast Verification
To read the signal without interference from room lighting, the receiver isolates a Region of Interest (ROI) around the light source:
- **Contrast Lock:** The app scans for the brightest spot and checks its contrast against the average background brightness, ignoring diffuse ambient light (like windows or lamps).
- **Sticky Tracking:** During `0` bits (light is OFF), the ROI *freezes* at its last known position rather than jumping to background lights. It only resets its position globally after ~2 seconds of continuous darkness.

### 3. Edge-Triggered PLL Decoder
Camera capture timing and transmitter timers often drift out of sync. A Phase-Locked Loop (PLL) decoder is used to intelligently sample the data:
- **Preamble Analysis:** The transmitter starts with an alternating pattern (`101010...`). The decoder marks every transition edge.
- **Dynamic Clock Recovery:** By analyzing the spacing between these edges, the receiver continuously calculates an ultra-precise "chip width" (e.g., exactly 6.13 frames per bit).
- **Center-Tap Sampling:** After finding the start-of-frame sync word (`11001100`), the decoder steps forward by the precise chip width, "tapping" the center of each bit to extract its value safely away from transition edges.

### 4. Reed-Solomon Error Correction
Optical data transfer is naturally noisy. Blocking the camera slightly, motion blur, or dropped frames can flip bits.
- **Encoding:** The payload is wrapped with Reed-Solomon forward error correction over `GF(256)`.
- **Parity:** For every byte of data, a parity byte is added (1:1 ratio).
- **Decoding:** At the receiver, the RS decoder repairs lost, dropped, or corrupted bytes before performing the UTF-8 conversion, ensuring clean text delivery even if the optical signal stutters.
