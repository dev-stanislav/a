# Building & Installing the iOS `.ipa` Edition (GitHub Actions + Sideloading)

**Phantom Court Online — iOS Local Offline Edition** runs 100% self-contained on iPhone and iPad with **zero backend server required**:
- **Exhibition vs Phantom AI:** `1v1`, `2v2`, and `3v3` across `Rookie`, `Pro`, `All-Star`, and `Phantom` difficulty tiers.
- **Full Roster & Fighting-Game Combos:** All 5 original anime archetypes, all 4 universal signature combos (`Phantom Drive`, `Meteor Dunk`, `Ankle Breaker`, `Mirror Step`), all 5 class skills, **THE ZONE** awakening, cel/outline/aura shaders (Mobile renderer), and procedural 44.1 kHz audio.
- **Local Ranked Glicko-2 Career:** Persistent offline Glicko-2 rating (`user://local_career.json`), Ranked Divisions (`Bronze` through `Phantom`), match history, and Rival AI Ladder Leaderboard.
- **Skill Training Dojo:** Interactive step-by-step combo tutorials, timing analysis, 5-spot shot practice, and programmable `DefensiveDummy`.
- **Ergonomic Multi-Touch Controls & Safe Area UI:** Left virtual stick (with outer-ring auto-sprint), right-half camera swipe, ergonomic thumb arc (`SHOOT/BLK`, `PASS`, `JUMP`, `STEAL`, `STANCE`, `Q/E/R` combo skill arc, pulsing `ZONE` button, `PAUSE`), and iPhone notch / Dynamic Island / Home Indicator Safe Area insets.

---

## 1. Automated Cloud Build via GitHub Actions (No Mac Required)

Because Apple's iOS SDK (`iphoneos`) and `xcodebuild` run exclusively on macOS, this repository includes a ready-to-run GitHub Actions workflow at [`.github/workflows/build-ios-ipa.yml`](.github/workflows/build-ios-ipa.yml) that builds **`PhantomCourtOnline-iOS-unsigned.ipa`** on GitHub's `macos-latest` runner.

### Step-by-Step Build Instructions
1. **Create a GitHub repository** (public or private) and push this project:
   ```powershell
   git add .
   git commit -m "Phantom Court Online — PC + iOS Local Offline Edition"
   git branch -M main
   git remote add origin https://github.com/<your-username>/phantom-court-online.git
   git push -u origin main
   ```
2. **Watch or Trigger the Build:**
   - Pushing to `main` (or `master`) automatically starts the **Build iOS IPA** workflow under your repository's **Actions** tab.
   - You can also trigger it manually anytime via **Actions → Build iOS IPA → Run workflow**.
3. **What the Workflow Does Automatically (`macos-latest`):**
   - Downloads official **Godot `4.7.2-stable` macOS Universal** (`Godot_v4.7.2-stable_macos.universal.zip`) and **Export Templates** (`Godot_v4.7.2-stable_export_templates.tpz`).
   - Imports all resources (`client/assets/ios/icon_*.png`, `launch_splash.png`, `.gdshader` files) and runs a headless boot sanity check.
   - Exports the iOS Xcode project (`PhantomCourtOnline.xcodeproj` + embedded `.pck`).
   - Compiles the `arm64` Release iOS app bundle (`PhantomCourtOnline.app`) via `xcodebuild -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
   - Packages `Payload/PhantomCourtOnline.app` into **`PhantomCourtOnline-iOS-unsigned.ipa`** and uploads it as a downloadable workflow artifact (plus Xcode project zip for optional local Xcode signing).
4. **Download the `.ipa`:**
   - Once the workflow turns green (~4–7 minutes), scroll to **Artifacts** at the bottom of the workflow summary page and download **`PhantomCourtOnline-iOS-ipa`** (unzip the GitHub artifact archive once to get `PhantomCourtOnline-iOS-unsigned.ipa`).

---

## 2. Installing `.ipa` onto Your iPhone / iPad (Windows or macOS)

Apple requires iOS apps running on physical devices to carry a provisioning signature, which **sideloading tools apply automatically using a free Apple ID** (no $99/year Apple Developer Program needed):

### Option A — Sideloadly (Recommended on Windows & macOS)
1. Install **[Sideloadly](https://sideloadly.io/)** (and iTunes + iCloud non-Microsoft-Store versions on Windows if prompted).
2. Connect your iPhone/iPad via USB and tap **Trust This Computer**.
3. Drag **`PhantomCourtOnline-iOS-unsigned.ipa`** into Sideloadly, enter your Apple ID, and click **Start**.
4. On your iPhone, open **Settings → General → VPN & Device Management**, trust your Apple ID developer certificate, and enable **Developer Mode** (**Settings → Privacy & Security → Developer Mode** on iOS 16+).
5. Launch **Phantom Court Online** in landscape orientation!

### Option B — AltStore / SideStore
1. Copy `PhantomCourtOnline-iOS-unsigned.ipa` to your iPhone (via iCloud Drive, AirDrop, or local file share).
2. Open **AltStore** or **SideStore** → **My Apps** → tap **`+`** in the top-left → select `PhantomCourtOnline-iOS-unsigned.ipa`.

### Option C — Xcode Direct Install (macOS)
1. Download the `PhantomCourtOnline-iOS-xcodeproj` artifact (or export locally on macOS).
2. Open `PhantomCourtOnline.xcodeproj` in Xcode, select the `PhantomCourtOnline` target → **Signing & Capabilities**, enable **Automatically manage signing**, choose your **Personal Team**, select your connected iPhone, and press **Cmd + R**.

---

## 3. Previewing iOS Offline Mode & Touch Controls on Windows PC

You can test the exact iOS touch layout and Local Offline Career on Windows without an iPhone:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_client.ps1 -WindowResolution 1280x720 -ExtraArgs @('--offline-edition')
```
Then open **Settings → Gameplay → Touch Controls → On** and enter **Play vs AI** or **Practice Dojo**!
