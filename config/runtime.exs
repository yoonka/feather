require Logger

if config_path = System.get_env("FEATHER_CONFIG_PATH") do
  Logger.debug("Loading FeatherMail config from #{config_path}")

  {config, _} = Code.eval_file(config_path)

  Enum.each(config, fn {key, value} ->
    Application.put_env(:feather, key, value)
  end)
end
