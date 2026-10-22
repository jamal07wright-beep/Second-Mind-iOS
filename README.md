# Second-Mind (iPhone app)

Stage 1: connect to the glasses and Reading mode.

Built from Meta's CameraAccess sample in the
[Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios).
Using the toolkit means agreeing to Meta's developer terms (see `META_SDK_LICENSE.txt`).

## What it does

* **Connect glasses** sends you to Meta AI to say yes, then back.
* **Start reading** turns on the glasses camera (light comes on).
* When words hold still for about a second, it takes a sharp photo, finds the words on the phone, and reads them out loud through the glasses.
* It won't repeat the same page. Look at something new, or tap **Read**.
* **Again** repeats. **Hush** stops talking. **Speed** slider sets how fast.
* **Practice** uses the phone camera as pretend glasses, so you can try it without wearing them.
* If the phone's secure storage breaks after Sideloadly, an orange note tells you.

Text never leaves the phone. No internet needed to read (Meta AI needs internet once to connect).

## How a build happens

1. Push this folder to GitHub.
2. GitHub's free Mac makes the project, runs the tests against Meta's mock glasses, and checks the settings.
3. Only if all of that passes, it makes `SecondMind.ipa`.
4. Download it: GitHub repo > **Actions** > newest green run > **SecondMind-ipa**. Unzip it to get the .ipa.

A public repo gets free Mac time with no limit. A private repo gets about 15 builds a month free.

## Install on your iPhone (Sideloadly)

1. Plug the iPhone into the PC. Open Sideloadly.
2. Drag in `SecondMind.ipa`. Type your Apple ID. Click **Start**.
3. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > **Trust**.
4. First time only: Settings > Privacy & Security > **Developer Mode** on (iPhone restarts).
5. In Meta AI: Settings > your glasses > **Developer Mode** on. It turns off after glasses updates, so check it if things stop working.

Free installs last 7 days. In Sideloadly turn on auto refresh so it renews over Wi-Fi when you're home.

## Files

* `project.yml` describes the Xcode project (XcodeGen makes the real one on the Mac).
* `SecondMind/` app code. `Reading/` has the reading parts.
* `SecondMindTests/` tests with mock glasses.
* `.github/workflows/build.yml` the free Mac build.
* `scripts/` setting checks.
