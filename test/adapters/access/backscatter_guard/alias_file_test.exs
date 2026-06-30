defmodule FeatherAdapters.Access.BackscatterGuard.AliasFileTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Access.BackscatterGuard.AliasFile

  setup do
    path = Path.join(System.tmp_dir!(), "feather_aliases_#{System.unique_integer([:positive])}")

    File.write!(path, """
    # sample aliases
    postmaster: root
    support: alice, bob
    """)

    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  describe "valid_recipient?/2 with :domains (plural)" do
    test "skips recipients outside the configured domains", %{path: path} do
      opts = [path: path, domains: ["example.com"]]

      # Regression: a recipient for an external domain must SKIP, not be denied.
      # Returning false here would override sibling guards' :skip in permissive
      # mode and wrongly reject external recipients (backscatter guard bug).
      assert AliasFile.valid_recipient?("someone@other.com", opts) == :skip
    end

    test "validates recipients within a configured domain", %{path: path} do
      opts = [path: path, domains: ["example.com"]]

      assert AliasFile.valid_recipient?("postmaster@example.com", opts) == true
      assert AliasFile.valid_recipient?("unknown@example.com", opts) == false
    end

    test "matches any of multiple configured domains", %{path: path} do
      opts = [path: path, domains: ["example.com", "mail.example.com"]]

      assert AliasFile.valid_recipient?("support@mail.example.com", opts) == true
      assert AliasFile.valid_recipient?("support@other.com", opts) == :skip
    end

    test "domain matching is case-insensitive", %{path: path} do
      opts = [path: path, domains: ["Example.COM"]]

      assert AliasFile.valid_recipient?("Postmaster@EXAMPLE.com", opts) == true
    end
  end

  describe "valid_recipient?/2 bare aliases" do
    test "bare alias is checked regardless of configured domains", %{path: path} do
      opts = [path: path, domains: ["example.com"]]

      assert AliasFile.valid_recipient?("postmaster", opts) == true
      assert AliasFile.valid_recipient?("nobody", opts) == false
    end
  end

  describe "valid_recipient?/2 without domains" do
    test "checks every domain when :domains is omitted", %{path: path} do
      opts = [path: path]

      assert AliasFile.valid_recipient?("postmaster@anything.com", opts) == true
      assert AliasFile.valid_recipient?("unknown@anything.com", opts) == false
    end
  end

  describe "valid_recipient?/2 legacy :domain (singular)" do
    test "still honors a single :domain string", %{path: path} do
      opts = [path: path, domain: "example.com"]

      assert AliasFile.valid_recipient?("postmaster@example.com", opts) == true
      assert AliasFile.valid_recipient?("postmaster@other.com", opts) == :skip
    end
  end
end
