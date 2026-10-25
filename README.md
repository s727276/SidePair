# AquaSign

AquaSign is an iOS app for pairing a device over Remote Pairing and signing and installing IPA files with an Apple developer account. It is intended for non-jailbroken devices: AquaSign does not jailbreak iOS or include jailbreak exploits.

## What it does

- Hosts an Apple Remote Pairing session and shows the pairing code in the app and a notification.
- Connects to the paired device through a user-installed LocalDevVPN-compatible loopback tunnel.
- Signs imported IPA apps with an Apple Development certificate and a provisioning profile for the selected team and device, then installs them over the connection.
- Refreshes and reinstalls apps using newly issued provisioning profiles when Apple permits it.

AquaSign does not bypass Apple's signing rules. App IDs, devices, certificates, profile expiration, and entitlements remain subject to Apple's account and provisioning limits. Personal-team profiles commonly expire after about seven days; check the expiration shown by Apple.

## Set up AquaSign on iPhone

1. Install AquaSign using your preferred trusted sideloading method.
2. On the iPhone, enable Developer Mode in Settings under Privacy & Security.
3. In AquaSign, tap **Start pairing** and allow notifications. Open Developer Mode settings, choose **Pair with AquaSign**, and enter the displayed code.
4. Install and configure a LocalDevVPN-compatible loopback tunnel separately. Connect it, then enter the tunnel's **Device IP** in AquaSign. The default is `10.7.0.1`; use the Device IP shown by the VPN, not its “Connected To” address.
5. Connect the device in AquaSign. Remote Pairing and the on-device tunnel require iOS 27 or later.
6. Open Apple signing, enter your Apple ID and password, and complete any two-factor verification. AquaSign registers the connected device before requesting its provisioning profile. It creates or selects a development certificate automatically; no certificate PEM or `.sideconf` import is needed. If Apple returns error 7460, AquaSign may list active iOS Development certificates. It never revokes one automatically: revocation requires your selection and explicit confirmation, invalidates profiles containing that certificate, and triggers one replacement attempt. Error 7460 can also indicate a pending request; if no eligible certificate is listed, AquaSign will not revoke anything.
7. In **App Library**, choose an IPA from Files and use **Sign & install**. The IPA must be eligible for signing and installation with your Apple team and device.

Your Apple ID password is sent to Apple for authentication and is not saved by AquaSign. The signing session is stored in Keychain and signing data is kept in the app's protected local storage. Anisette verification uses a remote provider. Pairing records contain sensitive device credentials; share them only with software and people you trust.

## Build with GitHub Actions

A push to `main` starts the **AquaSign unsigned IPA** workflow. It builds the Rust signing bridge and iOS app, then uploads the unsigned **AquaSign-unsigned-ipa** artifact and a universal **Aqua-Installer-macOS-universal** artifact for Apple silicon and Intel Macs. The workflow can also be started manually with `workflow_dispatch`; artifacts are retained for 14 days.

Aqua Installer imports that unsigned AquaSign IPA, checks its bundle identifier, signs it locally with your Apple developer account, then installs the signed app to a wired iPhone with Apple's `devicectl`. Apple ID passwords and signing sessions are not uploaded to GitHub; the session is stored in the Mac's Keychain. Apple authentication uses the signing bridge's remote Anisette verification provider. The Mac needs an Xcode installation with `devicectl` available through `xcrun`, and the iPhone must be unlocked, paired with the Mac, and have Developer Mode enabled. Apple's signing and device/profile limits still apply.

The GitHub IPA remains unsigned and is not an App Store release. The Aqua Installer macOS artifact is ad-hoc signed and not notarized; macOS may require you to approve it the first time you open it. A successful GitHub Actions run only confirms the build completed; it does not mean AquaSign has been signed for your account or installed on a device.

## Project status

The app's visible name is AquaSign and its bundle identifier is `com.Andrewdev.aquasign`. The Xcode target and some internal bridge and storage identifiers retain the earlier SidePair name for compatibility.

No `LICENSE` file is included at this time. Public repository visibility does not by itself grant permission to reuse or redistribute the code.

This project is vibe coded.
