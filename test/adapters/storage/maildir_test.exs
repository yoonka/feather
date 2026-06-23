defmodule FeatherAdapters.Storage.MaildirTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Storage.Maildir

  setup do
    base = Path.join(System.tmp_dir!(), "feather_maildir_test_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "creates cur/new/tmp under base_path/user", %{base: base} do
    assert :ok = Maildir.ensure_maildir("alice@example.com", base)

    user_dir = Path.join(base, "alice@example.com")
    assert File.dir?(Path.join(user_dir, "cur"))
    assert File.dir?(Path.join(user_dir, "new"))
    assert File.dir?(Path.join(user_dir, "tmp"))
  end

  test "is idempotent across repeated calls", %{base: base} do
    assert :ok = Maildir.ensure_maildir("alice@example.com", base)
    assert :ok = Maildir.ensure_maildir("alice@example.com", base)
    assert :ok = Maildir.ensure_maildir("alice@example.com", base)
  end

  test "applies the configured mode to created dirs", %{base: base} do
    assert :ok = Maildir.ensure_maildir("bob@example.com", base, 0o750)

    %File.Stat{mode: mode} = File.stat!(Path.join([base, "bob@example.com", "cur"]))
    assert Bitwise.band(mode, 0o777) == 0o750
  end

  test "rejects path-traversal attempts in user", %{base: base} do
    for bad <- ["../evil", "sub/dir", ".hidden", "..hidden", ""] do
      assert {:error, :invalid_user} = Maildir.ensure_maildir(bad, base)
    end
  end

  test "use Maildir imports ensure_maildir/2 and /3", %{base: base} do
    defmodule UsesMaildir do
      use FeatherAdapters.Storage.Maildir

      def call(user, base, mode), do: ensure_maildir(user, base, mode)
      def call(user, base), do: ensure_maildir(user, base)
    end

    assert :ok = UsesMaildir.call("carol@example.com", base)
    assert :ok = UsesMaildir.call("dave@example.com", base, 0o755)
  end
end
