# Privacy Policy for Soccer Referee App

**Last updated:** 2025-11-13

This Privacy Policy describes how the RoboCup Junior Soccer Referee App (“we”, “us”, “our”) collect, use, share and protect information in the mobile application *RCJ Soccer RefMate* (the “App”), available for iOS.

## 1. Information We Collect

### 1.1 Bluetooth & Device Identifiers  
- The App uses Bluetooth Low Energy (BLE) to discover, pair with and control robot modules.  
- We may access Bluetooth device identifiers or ephemeral peripheral identifiers necessary for the pairing/communication.  
- Purpose: to enable the core functionality of controlling the robot modules and synchronising match state.

### 1.2 Match Data & User-Provided Information  
- You can enter team names, table numbers, match IDs, and start/stop match phases.  
- The App offers an optional feature to publish live match data (team names, scores, match time, phase) to an MQTT broker you configure.  
- Purpose: to enable live score display and optional external real-time publishing of match state.

### 1.3 Network & Server Communication
- The App may fetch match metadata from remote tournament servers when a match ID is entered (HTTP/HTTPS).
- If you configure an MQTT broker, the App will transmit match state updates over the network to that broker.
- Purpose: to provide functionality such as automatic match info load, remote scoreboards, live streaming integration.

### 1.4 Third-Party SDKs / Crash & Analytics
- The App does *not* integrate any third-party analytics, advertising, or crash-reporting SDKs.

## 2. How We Use Your Information
- Bluetooth/identifier data: exclusively for pairing and communication with the robot modules; not used for marketing.
- Match and user-provided data: used to load match info, control robots, and optionally publish live match state to external services you configure.
- Network data: used to facilitate communication with external services (tournament servers, MQTT brokers) as per your configured use.

## 3. Sharing & Disclosure
- We do *not* sell your data to third parties.
- The only sharing of data is what you explicitly configure:
  - When you enter a tournament server URL or broker address, your match data (team names, scores, match time/phase) may be sent to that external service.
  - Bluetooth identifiers remain local between your device and the robot module; we do not send them off-device.
- If in the future the App uses a third-party analytics/crash service, data shared with that service will be described here.

## 4. Data Retention & Deletion  
- Match data entered and stored locally remains on your device unless you clear it.
- If you publish match data to an external server (MQTT broker), that server may retain the data according to its own policy — we recommend you review those external services’ policies.  
- If you stop using the App, local data remains unless you delete/uninstall the App; no automatic remote purge initiated by us.

## 5. Children’s Privacy  
- The App is not specifically directed to children under the age of 13 (or applicable local age).  
- We do not knowingly collect personal information from children under the applicable age.  
- If you believe we have collected data from a child in violation of local law, please contact us (see Section 7) to request deletion.

## 6. Transfers & International Use  
- The App runs on devices worldwide and may communicate with servers or brokers located in various countries.  
- By using the App and configuring external services, you agree to such transfers.  
- If you are located in the European Economic Area (EEA), please note this may involve cross-border data transfers; you should ensure any external service you use (MQTT broker) has appropriate safeguards.

## 7. Your Rights & Contact Information  
- You have the right to access, correct, export or request deletion of your data stored by us (if applicable).  
- If you wish to exercise any of these rights, or if you have questions about this policy, please contact us at:  
  **privacy-rcj-refmate@f-wllr.de**  
- Effective date of this policy: 2025-11-13. We may update this policy from time to time. We will post any material changes here with a new “Last updated” date.

## 8. Changes to This Policy  
- We reserve the right to update this Privacy Policy at any time.  
- Your continued use of the App after changes means you accept the updated policy.

---

**Thank you for using Soccer Referee App.**  
