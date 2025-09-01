import Config

default_folder =
  case :os.type() do
    {:unix, :freebsd} -> "/usr/local/etc/feather"
    {:unix, _linux}   -> "/etc/feather"
    _                 -> "/etc/feather"
  end

config_folder =
  System.get_env("FEATHER_CONFIG_FOLDER") || default_folder

config :feather, :config_folder, config_folder
