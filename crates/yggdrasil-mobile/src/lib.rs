uniffi::include_scaffolding!("yggdrasil_mobile");

mod mobile;

pub use mobile::{
    AndroidNetworkInterface,
    MulticastInterfaceConfig,
    YggdrasilConfig,
    YggdrasilError,
    YggdrasilMobile,
    YggdrasilState,
    YggdrasilStateListener,
    generate_config,
    get_version,
};
