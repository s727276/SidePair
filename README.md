# AquaSign

AquaSign is an iOS app for pairing a device over Remote Pairing and signing and installing IPA files with an Apple developer account. It is intended for non-jailbroken devices: AquaSign does not jailbreak iOS or include jailbreak exploits.

## What it does

- Hosts an Apple Remote Pairing session and shows the pairing code in the app and a notification.
- Connects to the paired device through a user-installed LocalDevVPN-compatible loopback tunnel.
- Signs imported IPA apps with an Apple Development certificate and a provisioning profile for the selected team and device, then installs them over the connection.
- Refreshes and reinstalls apps using newly issued provisioning profiles when Apple permits it.

AquaSign does not bypass Apple's signing rules. App IDs, devices, certificates, profile expiration, and entitlements remain subject to Apple's account and provisioning limits. Personal-team profiles commonly expire after about seven days; check the expiration shown by Apple.

## Set up an iPhone to manage an iPad

AquaSign runs on the **controller iPhone**. The **target iPad** is paired to it through Apple's normal Remote Pairing flow, then managed over the controller's LocalDevVPN-compatible tunnel. Pairing requires approval on the target iPad; an IP address alone never authorizes a device. The same steps work with another iPhone as the target.

### On the controller iPhone

1. Install AquaSign using your preferred trusted sideloading method.
2. Install and configure a LocalDevVPN-compatible loopback tunnel on the iPhone. Connect the tunnel and allow AquaSign to use the local network when prompted.
3. Keep the iPhone and iPad on the same Wi-Fi network for pairing. In AquaSign, open **Pair** and tap **Start pairing**. Allow notifications and keep AquaSign available; the pairing code appears in the app and in a notification.

### On the target iPad

4. Enable **Developer Mode** in Settings under **Privacy & Security** and follow any restart and passcode prompts.
5. On the iPad, open **Settings → Privacy & Security → Developer Mode**, choose **Pair with AquaSign**, and enter the code displayed on the controller iPhone. Verify and approve the pairing on the iPad. This is Apple's on-device approval step; AquaSign cannot pair an iPad just by knowing its network address.

### Select and connect the iPad

6. After approval, AquaSign saves this iPad's Remote Pairing record separately from other devices. On the controller iPhone, open **Device → Paired Devices**. If the iPad is not already active, tap **Select**. If its action says **Set IP**, tap it and enter the iPad's **Device IP** shown by LocalDevVPN in AquaSign's Pair tab. Use **Device IP**, not LocalDevVPN's “Connected To” address. AquaSign saves the IP with that iPad's pairing record; when a valid IP is set, it attempts the RSD connection.
7. AquaSign connects only with the selected device's saved pairing record and Device IP. Open **Device Manager** after the RSD connection succeeds; a device is not shown as connected until AquaSign confirms that connection. If it shows **Connect**, tap it to retry. If the connection fails, check that LocalDevVPN is connected and that the selected iPad's Device IP is correct.
8. To manage another paired device, return to **Paired Devices** and select it. AquaSign disconnects the previous RSD session and uses only the newly selected device's record and IP. Device switching is unavailable during pairing or an IPA install.

AquaSign's Remote Pairing host and RSD tunnel require iOS 27 or later on the controller iPhone. The target iPad must support Developer Mode and show the standard **Pair with AquaSign** option. For app signing, open Apple signing on the controller iPhone, enter your Apple ID and password, and complete any two-factor verification. AquaSign registers the selected target device before requesting its provisioning profile. It creates or selects a development certificate automatically; no certificate PEM or `.sideconf` import is needed. If Apple returns error 7460, AquaSign may list active iOS Development certificates. It never revokes one automatically: revocation requires your selection and explicit confirmation, invalidates profiles containing that certificate, and triggers one replacement attempt. Error 7460 can also indicate a pending request; if no eligible certificate is listed, AquaSign will not revoke anything.

In **App Library**, choose an IPA from Files and use **Sign & install**. The IPA must be eligible for signing and installation with your Apple team and the selected target device.

Your Apple ID password is sent to Apple for authentication and is not saved by AquaSign. The signing session is stored in Keychain and signing data is kept in the app's protected local storage. Anisette verification uses a remote provider. Pairing records contain sensitive device credentials; share them only with software and people you trust.

## Build with GitHub Actions

A push to `main` starts the **AquaSign unsigned IPA** workflow. It builds the Rust signing bridge and iOS app without Apple code signing, packages an unsigned IPA, and uploads it as the **AquaSign-unsigned-ipa** artifact. Publishing a GitHub Release with the tag `1.2` also attaches the IPA as a direct release asset, alongside the Actions artifact. The workflow can also be started manually with `workflow_dispatch`; artifacts are retained for 14 days.

Aqua Installer imports that unsigned AquaSign IPA, checks its bundle identifier, signs it locally with your Apple developer account, then installs the signed app to a wired iPhone with Apple's `devicectl`. Apple ID passwords and signing sessions are not uploaded to GitHub; the session is stored in the Mac's Keychain. Apple authentication uses the signing bridge's remote Anisette verification provider. The Mac needs an Xcode installation with `devicectl` available through `xcrun`, and the iPhone must be unlocked, paired with the Mac, and have Developer Mode enabled. Apple's signing and device/profile limits still apply.

The GitHub IPA remains unsigned and is not an App Store release. A successful GitHub Actions run only confirms the build completed; it does not mean AquaSign has been signed for your account or installed on a device.

## Project status

The app's visible name is AquaSign and its bundle identifier is `com.Andrewdev.aquasign`. The Xcode target and some internal bridge and storage identifiers retain the earlier SidePair name for compatibility.

No `LICENSE` file is included at this time. Public repository visibility does not by itself grant permission to reuse or redistribute the code.

This project is vibe coded.
