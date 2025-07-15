# RCJ Soccer RefMate

**RCJ Soccer RefMate** is an Android application designed for managing RoboCup Junior Soccer matches with real-time robot control, score tracking, and advanced referee tools.

> Officially tailored for the [RoboCupJunior Soccer League](https://junior.robocup.org/soccer/), this app turns your Android device into a powerful assistant for live match handling, communication with robots, and seamless integration with tournaments and live streams.

---

## 🏆 Features

### 🕒 Match Timing & Game Flow
- Adjustable match duration and halftime length
- Automated transitions between:
  - First Half
  - Halftime
  - Second Half
- Visual countdowns for each phase
- Robot penalty tracking

### ⚽ Score & Team Management
- Manual score tracking via **double-tap** gestures
- Editable team names via **long-press**
- Supports team side switching and score editings

### 🤖 Robot Control via Bluetooth
- Connect and manage up to **10 robot modules**
- Compatible with [RoboCup Junior Communication Modules](https://github.com/robocup-junior/soccer-communication-module)
- Individual robot states:
  - Play / Stop
  - Temporary penalty with countdown
- Robot identifiers (e.g., A1, B2) and states displayed on module OLEDs
- Game state sync: robots stop/start based on match phase or penalties

### 🔗 Easy Pairing with Modules
- **Long-press** robot button (e.g., A1, A2…) to pair via:
  - BLE scan
  - QR code displayed on module OLED

### 📡 MQTT Integration (Optional)
- Publish live game data to an MQTT server
- Includes:
  - Team names
  - Scores
  - Match time & phase
  - Match stage (1st half, halftime, 2nd half, game over)
- Customizable MQTT broker address and topic
- Ideal for:
  - Scoreboards
  - Live streams
  - Tournament dashboards

### 🌐 Tournament Match Preloading
- Pull match info from web using match ID
- Automatically sets:
  - Team names
  - Table number
  - MQTT topic (for clean tournament routing)

---

## 🎮 App Interaction

### Quick Controls
| Action | Gesture |
|--------|---------|
| Add goal | Double-tap score number |
| Apply penalty | Double-tap robot button |
| Edit score/team name | Long-press score/team label |
| Connect robot module | Long-press robot button |
| Open settings | Single-tap ⚙️ icon in top right |

### Global Settings
Accessible via the settings menu:
- Number of robots (2–10, even only)
- Match and halftime duration
- Penalty duration
- Side switching
- MQTT configuration
- Match preload via web
- Reset all modules / match state

---

## 📥 Download

Available on [Google Play] *(Work in progress)*

---

## 🧩 Communication Module Info

This app pairs with official RoboCup Junior-compatible modules.

- Open-source hardware & firmware:  
  📦 https://github.com/robocup-junior/soccer-communication-module  
- Purchase ready-made modules:  
  🛒 https://robofuze.com/

Features:
- OLED screen with robot ID, score, state, countdowns
- QR pairing support
- Command logic synced with app via BLE

---

## 🛠️ Tech Stack

- Kotlin / Android SDK
- BLE (Bluetooth Low Energy)
- MQTT protocol
- JSON config management
- Offline-first design

---

## 📄 License

This project is licensed under the **Apache License 2.0**.  

---

## 👤 Author

**Martin Faltus**  

---

## 🤝 Contributions & Feedback

We welcome bug reports, feature requests, and contributions.  
Feel free to open an issue or submit a pull request.

---

## 🚀 Made for RoboCup Junior Soccer

Designed by RoboCup enthusiasts to simplify referee workflows and enhance fairness and automation during matches.

---
