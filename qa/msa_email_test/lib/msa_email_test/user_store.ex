defmodule MsaEmailTest.UserStore do
  @moduledoc false

  # Fake "user store" for the test environment.
  @users %{
    "frodo" => %{
      password: "s3cret",
      allowed_from: ["maxlabmobile.com", "frodo@maxlabmobile.com"]
    },
    "sam" => %{
      password: "pass",
      allowed_from: ["maxlabmobile.com"]
    }
  }

  # Retrieve a user record by username
  def get(username), do: Map.get(@users, username)

  # Verify username and password against the store
  def verify(username, password) when is_binary(password) do
    case get(username) do
      %{password: ^password} -> :ok
      %{} -> {:error, :auth_failed}
      nil -> {:error, :auth_failed}
    end
  end
  def verify(_username, _password), do: {:error, :auth_failed}

  # Get allowed "From" addresses for a user
  def allowed_from(username) do
    case get(username) do
      %{allowed_from: list} when is_list(list) -> list
      _ -> []
    end
  end
end
