use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, AppToken, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi,
        certificates::{CertificatesApi, DevelopmentCertificate},
        developer_session::DeveloperSession,
        device_type::DeveloperDeviceType,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{
        TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
        cert_identity::CertificateIdentity,
        sideloader::Sideloader,
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        fs_storage::FsStorage,
    },
};
use rootcause::prelude::*;
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    ptr,
    sync::OnceLock,
};
use zeroize::Zeroizing;

pub type SigningTwoFactorCallback = Option<
    extern "C" fn(
        context: *mut c_void,
        request_json: *const c_char,
        response_json: *mut c_char,
        response_capacity: usize,
    ) -> i32,
>;

#[derive(Clone, Copy)]
struct CallbackContext {
    callback: SigningTwoFactorCallback,
    context: *mut c_void,
}

unsafe impl Send for CallbackContext {}
unsafe impl Sync for CallbackContext {}

type TwoFactorFuture = Pin<
    Box<dyn Future<Output = Result<TwoFactorCallbackResponse, rootcause::Report>> + Send>,
>;
type TwoFactorHandler = Box<
    dyn Fn(TwoFactorCallbackParams) -> TwoFactorFuture + Send + Sync + 'static,
>;

impl CallbackContext {
    fn answer(self, request_json: String) -> Result<TwoFactorCallbackResponse, String> {
        let Some(callback) = self.callback else {
            return Ok(TwoFactorCallbackResponse::Abort);
        };
        let request = CString::new(request_json).map_err(|error| error.to_string())?;
        let mut response = vec![0i8; 4096];
        let result = callback(
            self.context,
            request.as_ptr(),
            response.as_mut_ptr(),
            response.len(),
        );
        if result == 0 {
            return Ok(TwoFactorCallbackResponse::Abort);
        }
        let response = unsafe { CStr::from_ptr(response.as_ptr()) }
            .to_str()
            .map_err(|error| format!("invalid 2FA response: {error}"))?;
        let value: serde_json::Value = serde_json::from_str(response)
            .map_err(|error| format!("could not parse 2FA response: {error}"))?;
        match value.get("action").and_then(serde_json::Value::as_str) {
            Some("code") => value
                .get("code")
                .and_then(serde_json::Value::as_str)
                .map(|code| TwoFactorCallbackResponse::SubmitCode(code.to_string()))
                .ok_or_else(|| "2FA response did not include a code".to_string()),
            Some("sms") => value
                .get("id")
                .and_then(serde_json::Value::as_u64)
                .and_then(|id| u32::try_from(id).ok())
                .map(TwoFactorCallbackResponse::SendSms)
                .ok_or_else(|| "2FA SMS response did not include a valid phone number ID".to_string()),
            Some("devices") => Ok(TwoFactorCallbackResponse::SendToDevices),
            Some("resend") => Ok(TwoFactorCallbackResponse::ResendCode),
            Some("abort") => Ok(TwoFactorCallbackResponse::Abort),
            _ => Err("2FA response contained an unsupported action".to_string()),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredSession {
    apple_id: String,
    adsid: String,
    team_id: String,
    #[serde(default)]
    certificate_machine_name: Option<String>,
    token: String,
    duration: u64,
    expiry: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SigningStatus {
    apple_id: String,
    team_name: String,
    team_id: String,
    certificate_name: String,
    certificate_serial: String,
    certificate_status: String,
    certificate_expiration: String,
    profile_status: String,
    profile_uuid: String,
    profile_expiration: String,
    profile_error: String,
}

static INIT_RESULT: OnceLock<Result<(), String>> = OnceLock::new();

fn initialize() -> Result<(), String> {
    INIT_RESULT
        .get_or_init(|| {
            rustls::crypto::ring::default_provider()
                .install_default()
                .map_err(|_| "could not initialize the TLS provider".to_string())?;
            isideload::init().map_err(|error| format!("could not initialize isideload: {error}"))
        })
        .clone()
}

fn create_anisette_provider(storage_dir: &Path) -> Result<RemoteV3AnisetteProvider, String> {
    let provider = RemoteV3AnisetteProvider::default()
        .map_err(|error| format!("could not initialize anisette provider: {error}"))?;
    Ok(provider.set_storage(Box::new(FsStorage::new(storage_dir.to_path_buf()))))
}

fn make_two_factor_callback(
    callback: SigningTwoFactorCallback,
    context: *mut c_void,
) -> TwoFactorHandler {
    let context = CallbackContext { callback, context };
    Box::new(move |params| {
        let context = context;
        let request_json = serde_json::to_string(&params)
            .unwrap_or_else(|_| "{}".to_string());
        Box::pin(async move {
            tokio::task::spawn_blocking(move || context.answer(request_json))
                .await
                .map_err(|error| report!("2FA callback failed: {error}"))?
                .map_err(|error| report!("2FA callback failed: {error}"))
        })
    })
}

async fn sign_in(
    apple_id: String,
    password: Zeroizing<String>,
    storage_dir: PathBuf,
    bundle_id: String,
    device_name: String,
    device_udid: String,
    callback: SigningTwoFactorCallback,
    callback_context: *mut c_void,
) -> Result<(String, SigningStatus), String> {
    let anisette_provider = create_anisette_provider(&storage_dir)?;
    let mut account = AppleAccount::builder(&apple_id)
        .anisette_provider(anisette_provider)
        .login(
            password.as_str(),
            make_two_factor_callback(callback, callback_context),
        )
        .await
        .map_err(|error| format!("Apple sign-in failed: {error}"))?;

    let app_token = account
        .get_app_token("xcode.auth")
        .await
        .map_err(|error| format!("Apple developer session failed: {error}"))?;
    let adsid = account
        .spd
        .as_ref()
        .and_then(|dictionary| dictionary.get("adsid"))
        .and_then(|value| value.as_string())
        .map(str::to_string)
        .ok_or_else(|| "Apple sign-in did not provide an account session identifier".to_string())?;

    let mut developer_session = DeveloperSession::new(
        app_token.clone(),
        adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    let team = select_team(&mut developer_session).await?;
    developer_session
        .ensure_device_registered(&team, &device_name, &device_udid, None)
        .await
        .map_err(|error| format!("could not register this iPhone for development signing: {error}"))?;
    let storage = FsStorage::new(storage_dir.clone());
    let certificate_machine_name = "SidePair".to_string();
    let cert_behavior: MaxCertsBehavior<MaxCertsCallbackBox> = MaxCertsBehavior::Error;
    let identity = CertificateIdentity::retrieve(
        &certificate_machine_name,
        &apple_id,
        &mut developer_session,
        &team,
        &storage,
        &cert_behavior,
    )
    .await
    .map_err(|error| format!("could not create or select the Apple Development certificate: {error}"))?;

    let certificate = developer_session
        .list_ios_certs(&team)
        .await
        .map_err(|error| format!("could not read the development certificate: {error}"))?
        .into_iter()
        .find(|certificate| {
            certificate.serial_number.as_deref() == Some(identity.get_serial_number().as_str())
        });

    let (profile_status, profile_uuid, profile_expiration, profile_error) =
        provision_profile(&mut developer_session, &team, &bundle_id, &storage_dir).await;

    let session = StoredSession {
        apple_id: apple_id.clone(),
        adsid,
        team_id: team.team_id.clone(),
        certificate_machine_name: Some(certificate_machine_name),
        token: app_token.token,
        duration: app_token.duration,
        expiry: app_token.expiry,
    };
    let session_json = serde_json::to_string(&session)
        .map_err(|error| format!("could not serialize signing session: {error}"))?;
    let status = make_status(
        &apple_id,
        &team,
        certificate.as_ref(),
        profile_status,
        profile_uuid,
        profile_expiration,
        profile_error,
    );
    Ok((session_json, status))
}

async fn restore_session(
    session_json: String,
    storage_dir: PathBuf,
    bundle_id: String,
) -> Result<SigningStatus, String> {
    let saved: StoredSession = serde_json::from_str(&session_json)
        .map_err(|error| format!("saved signing session is invalid: {error}"))?;
    let certificate_machine_name = saved
        .certificate_machine_name
        .clone()
        .unwrap_or_else(|| "SidePair".to_string());
    let anisette_provider = create_anisette_provider(&storage_dir)?;
    let account = AppleAccount::builder(&saved.apple_id)
        .anisette_provider(anisette_provider)
        .build()
        .await
        .map_err(|error| format!("could not restore Apple account session: {error}"))?;
    let token = AppToken {
        token: saved.token,
        duration: saved.duration,
        expiry: saved.expiry,
    };
    let mut developer_session = DeveloperSession::new(
        token,
        saved.adsid,
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    let team = developer_session
        .list_teams()
        .await
        .map_err(|error| format!("saved Apple developer session expired; sign in again: {error}"))?
        .into_iter()
        .find(|team| team.team_id == saved.team_id)
        .ok_or_else(|| "the saved Apple developer team is no longer available; sign in again".to_string())?;

    let storage = FsStorage::new(storage_dir.clone());
    let cert_behavior: MaxCertsBehavior<MaxCertsCallbackBox> = MaxCertsBehavior::Error;
    let identity = CertificateIdentity::retrieve(
        &certificate_machine_name,
        &saved.apple_id,
        &mut developer_session,
        &team,
        &storage,
        &cert_behavior,
    )
    .await
    .map_err(|error| format!("could not restore the development certificate: {error}"))?;
    let certificate = developer_session
        .list_ios_certs(&team)
        .await
        .map_err(|error| format!("could not read the development certificate: {error}"))?
        .into_iter()
        .find(|certificate| {
            certificate.serial_number.as_deref() == Some(identity.get_serial_number().as_str())
        });

    let (profile_status, profile_uuid, profile_expiration, profile_error) =
        provision_profile(&mut developer_session, &team, &bundle_id, &storage_dir).await;
    Ok(make_status(
        &saved.apple_id,
        &team,
        certificate.as_ref(),
        profile_status,
        profile_uuid,
        profile_expiration,
        profile_error,
    ))
}

async fn sign_ipa_for_session(
    session_json: String,
    storage_dir: PathBuf,
    ipa_path: PathBuf,
    device_name: String,
    device_udid: String,
) -> Result<String, String> {
    let saved: StoredSession = serde_json::from_str(&session_json)
        .map_err(|error| format!("saved signing session is invalid: {error}"))?;
    let certificate_machine_name = saved
        .certificate_machine_name
        .clone()
        .unwrap_or_else(|| "SidePair".to_string());
    let anisette_provider = create_anisette_provider(&storage_dir)?;
    let account = AppleAccount::builder(&saved.apple_id)
        .anisette_provider(anisette_provider)
        .build()
        .await
        .map_err(|error| format!("could not restore Apple account session: {error}"))?;
    let token = AppToken {
        token: saved.token,
        duration: saved.duration,
        expiry: saved.expiry,
    };
    let mut developer_session = DeveloperSession::new(
        token,
        saved.adsid,
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    let team = developer_session
        .list_teams()
        .await
        .map_err(|error| format!("could not list Apple developer teams: {error}"))?
        .into_iter()
        .find(|team| team.team_id == saved.team_id)
        .ok_or_else(|| "the saved Apple developer team is no longer available; sign in again".to_string())?;
    developer_session
        .ensure_device_registered(&team, &device_name, &device_udid, None)
        .await
        .map_err(|error| format!("could not register this iPhone for development signing: {error}"))?;

    let cert_behavior: MaxCertsBehavior<MaxCertsCallbackBox> = MaxCertsBehavior::Error;
    let extensions_behavior: ExtensionsBehaviorSelection<ExtensionsBehaviorCallbackBox> =
        ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::RegisterAll);
    let mut sideloader = Sideloader::new(
        developer_session,
        saved.apple_id,
        TeamSelection::First,
        cert_behavior,
        certificate_machine_name,
        Box::new(FsStorage::new(storage_dir)),
        extensions_behavior,
        false,
    );
    let (signed_app_path, _) = sideloader
        .sign_app(
            ipa_path,
            Some(team),
            false,
            None::<fn(f32) -> std::future::Ready<()>>,
            None,
            None,
        )
        .await
        .map_err(|error| format!("could not sign IPA with the saved Apple account: {error}"))?;

    Ok(signed_app_path.to_string_lossy().into_owned())
}

async fn select_team(developer_session: &mut DeveloperSession) -> Result<DeveloperTeam, String> {
    let teams = developer_session
        .list_teams()
        .await
        .map_err(|error| format!("could not list Apple developer teams: {error}"))?;
    teams
        .iter()
        .find(|team| {
            team.r#type
                .as_deref()
                .is_some_and(|kind| kind.to_lowercase().contains("individual"))
        })
        .cloned()
        .or_else(|| teams.into_iter().next())
        .ok_or_else(|| "no Apple developer team is available for this account".to_string())
}

// SideStore can leave its previous signing team's suffix on the installed bundle ID.
fn team_scoped_bundle_identifier(bundle_id: &str, team_id: &str) -> String {
    let mut components: Vec<&str> = bundle_id.split('.').collect();
    if components.len() > 2
        && components.last().is_some_and(|suffix| {
            suffix.len() == 10
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        })
    {
        components.truncate(components.len() - 1);
    }
    format!("{}.{}", components.join("."), team_id)
}

async fn provision_profile(
    developer_session: &mut DeveloperSession,
    team: &DeveloperTeam,
    bundle_id: &str,
    storage_dir: &Path,
) -> (String, String, String, String) {
    let result = async {
        let profile_bundle_id = team_scoped_bundle_identifier(bundle_id, &team.team_id);
        let app_ids = developer_session
            .list_app_ids(team, DeveloperDeviceType::Ios)
            .await
            .map_err(|error| format!("could not list App IDs: {error}"))?;
        let app_id = match app_ids
            .app_ids
            .into_iter()
            .find(|app_id| app_id.identifier == profile_bundle_id)
        {
            Some(app_id) => app_id,
            None => developer_session
                .add_app_id(team, "AquaSign", &profile_bundle_id, DeveloperDeviceType::Ios)
                .await
                .map_err(|error| {
                    format!(
                        "could not register AquaSign's team-specific App ID '{profile_bundle_id}': {error}"
                    )
                })?,
        };
        let profile = developer_session
            .download_team_provisioning_profile(team, &app_id, DeveloperDeviceType::Ios)
            .await
            .map_err(|error| format!("could not download a development provisioning profile: {error}"))?;

        let directory = storage_dir.join("profiles");
        std::fs::create_dir_all(&directory)
            .map_err(|error| format!("could not create the profile storage directory: {error}"))?;
        let path = directory.join(format!("{profile_bundle_id}.mobileprovision"));
        let temporary_path = path.with_extension("mobileprovision.tmp");
        std::fs::write(&temporary_path, profile.encoded_profile.as_ref())
            .map_err(|error| format!("could not save the provisioning profile: {error}"))?;
        std::fs::rename(&temporary_path, &path)
            .map_err(|error| format!("could not save the provisioning profile: {error}"))?;

        Ok::<_, String>((profile.uuid, profile.date_expire.to_xml_format()))
    }
    .await;

    match result {
        Ok((uuid, expiration)) => ("Ready".to_string(), uuid, expiration, String::new()),
        Err(error) => ("Needs attention".to_string(), String::new(), String::new(), error),
    }
}

fn make_status(
    apple_id: &str,
    team: &DeveloperTeam,
    certificate: Option<&DevelopmentCertificate>,
    profile_status: String,
    profile_uuid: String,
    profile_expiration: String,
    profile_error: String,
) -> SigningStatus {
    SigningStatus {
        apple_id: apple_id.to_string(),
        team_name: team.name.clone().unwrap_or_else(|| "Personal Team".to_string()),
        team_id: team.team_id.clone(),
        certificate_name: certificate
            .and_then(|value| value.name.clone())
            .unwrap_or_else(|| "Apple Development".to_string()),
        certificate_serial: certificate
            .and_then(|value| value.serial_number.clone())
            .unwrap_or_default(),
        certificate_status: certificate
            .and_then(|value| value.status.clone())
            .unwrap_or_else(|| "Ready".to_string()),
        certificate_expiration: certificate
            .and_then(|value| value.expiration_date.as_ref())
            .map(|date| date.to_xml_format())
            .unwrap_or_default(),
        profile_status,
        profile_uuid,
        profile_expiration,
        profile_error,
    }
}

fn ffi_string(value: String) -> *mut c_char {
    CString::new(value.replace('\0', " "))
        .unwrap_or_else(|_| CString::new("signing bridge error").unwrap())
        .into_raw()
}

unsafe fn read_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("missing {name}"));
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

unsafe fn write_out(out: *mut *mut c_char, value: String) {
    if !out.is_null() {
        unsafe { *out = ffi_string(value) };
    }
}

fn run_sign_in(
    apple_id: String,
    password: Zeroizing<String>,
    storage_dir: PathBuf,
    bundle_id: String,
    device_name: String,
    device_udid: String,
    callback: SigningTwoFactorCallback,
    callback_context: *mut c_void,
) -> Result<(String, SigningStatus), String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("could not start signing runtime: {error}"))?;
    runtime.block_on(sign_in(
        apple_id,
        password,
        storage_dir,
        bundle_id,
        device_name,
        device_udid,
        callback,
        callback_context,
    ))
}

fn run_sign_ipa(
    session_json: String,
    storage_dir: PathBuf,
    ipa_path: PathBuf,
    device_name: String,
    device_udid: String,
) -> Result<String, String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("could not start signing runtime: {error}"))?;
    runtime.block_on(sign_ipa_for_session(
        session_json,
        storage_dir,
        ipa_path,
        device_name,
        device_udid,
    ))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sidepair_sign_in(
    apple_id: *const c_char,
    password: *const c_char,
    storage_dir: *const c_char,
    bundle_id: *const c_char,
    device_name: *const c_char,
    device_udid: *const c_char,
    callback: SigningTwoFactorCallback,
    callback_context: *mut c_void,
    out_session_json: *mut *mut c_char,
    out_status_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_session_json.is_null() || out_status_json.is_null() || out_error.is_null() {
        return 2;
    }
    unsafe {
        *out_session_json = ptr::null_mut();
        *out_status_json = ptr::null_mut();
        *out_error = ptr::null_mut();
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        initialize()?;
        let apple_id = unsafe { read_string(apple_id, "Apple ID") }?;
        let password = Zeroizing::new(unsafe { read_string(password, "Apple ID password") }?);
        let storage_dir = PathBuf::from(unsafe { read_string(storage_dir, "storage directory") }?);
        let bundle_id = unsafe { read_string(bundle_id, "bundle identifier") }?;
        let device_name = unsafe { read_string(device_name, "device name") }?;
        let device_udid = unsafe { read_string(device_udid, "device identifier") }?;
        run_sign_in(
            apple_id,
            password,
            storage_dir,
            bundle_id,
            device_name,
            device_udid,
            callback,
            callback_context,
        )
    }));

    match result {
        Ok(Ok((session_json, status))) => {
            unsafe {
                write_out(out_session_json, session_json);
                write_out(out_status_json, serde_json::to_string(&status).unwrap_or_default());
            }
            0
        }
        Ok(Err(error)) => {
            unsafe { write_out(out_error, error) };
            1
        }
        Err(_) => {
            unsafe { write_out(out_error, "unexpected panic in signing bridge".to_string()) };
            2
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sidepair_restore_session(
    session_json: *const c_char,
    storage_dir: *const c_char,
    bundle_id: *const c_char,
    out_status_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_status_json.is_null() || out_error.is_null() {
        return 2;
    }
    unsafe {
        *out_status_json = ptr::null_mut();
        *out_error = ptr::null_mut();
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        initialize()?;
        let session_json = unsafe { read_string(session_json, "saved signing session") }?;
        let storage_dir = PathBuf::from(unsafe { read_string(storage_dir, "storage directory") }?);
        let bundle_id = unsafe { read_string(bundle_id, "bundle identifier") }?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("could not start signing runtime: {error}"))?;
        runtime.block_on(restore_session(session_json, storage_dir, bundle_id))
    }));

    match result {
        Ok(Ok(status)) => {
            unsafe { write_out(out_status_json, serde_json::to_string(&status).unwrap_or_default()) };
            0
        }
        Ok(Err(error)) => {
            unsafe { write_out(out_error, error) };
            1
        }
        Err(_) => {
            unsafe { write_out(out_error, "unexpected panic while restoring signing session".to_string()) };
            2
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sidepair_sign_ipa(
    session_json: *const c_char,
    storage_dir: *const c_char,
    ipa_path: *const c_char,
    device_name: *const c_char,
    device_udid: *const c_char,
    out_signed_app_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_signed_app_path.is_null() || out_error.is_null() {
        return 2;
    }
    unsafe {
        *out_signed_app_path = ptr::null_mut();
        *out_error = ptr::null_mut();
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        initialize()?;
        let session_json = unsafe { read_string(session_json, "saved signing session") }?;
        let storage_dir = PathBuf::from(unsafe { read_string(storage_dir, "storage directory") }?);
        let ipa_path = PathBuf::from(unsafe { read_string(ipa_path, "IPA path") }?);
        let device_name = unsafe { read_string(device_name, "device name") }?;
        let device_udid = unsafe { read_string(device_udid, "device identifier") }?;
        run_sign_ipa(session_json, storage_dir, ipa_path, device_name, device_udid)
    }));

    match result {
        Ok(Ok(signed_app_path)) => {
            unsafe { write_out(out_signed_app_path, signed_app_path) };
            0
        }
        Ok(Err(error)) => {
            unsafe { write_out(out_error, error) };
            1
        }
        Err(_) => {
            unsafe { write_out(out_error, "unexpected panic while signing IPA".to_string()) };
            2
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sidepair_signing_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
