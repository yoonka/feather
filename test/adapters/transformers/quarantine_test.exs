defmodule FeatherAdapters.Transformers.QuarantineTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.Quarantine

  setup do
    base = Path.join(System.tmp_dir!(), "feather_quarantine_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody.\r\n"

  test "passes through unchanged when meta[:quarantine] is not true", %{base: base} do
    assert {@msg, %{}} = Quarantine.transform_data(@msg, %{}, %{}, store_path: base)
    refute File.exists?(base)
  end

  test "stores file and adds header in :store_and_deliver (default)", %{base: base} do
    meta = %{quarantine: true, rcpt: ["user@local"]}

    {out, new_meta} = Quarantine.transform_data(@msg, meta, %{}, store_path: base)

    assert String.starts_with?(out, "X-Feather-Quarantined: ")
    assert String.contains?(out, "\r\nFrom: a@b\r\n")
    assert new_meta.rcpt == ["user@local"]
    assert is_binary(new_meta.quarantine_path)
    assert File.exists?(new_meta.quarantine_path)
    assert File.read!(new_meta.quarantine_path) == @msg
  end

  test ":store_only clears rcpt to suppress delivery", %{base: base} do
    meta = %{quarantine: true, rcpt: ["user@local"]}

    {_out, new_meta} =
      Quarantine.transform_data(@msg, meta, %{}, store_path: base, mode: :store_only)

    assert new_meta.rcpt == []
    assert File.exists?(new_meta.quarantine_path)
  end

  test "filename uses configured prefix", %{base: base} do
    meta = %{quarantine: true}

    {_out, new_meta} =
      Quarantine.transform_data(@msg, meta, %{},
        store_path: base,
        filename_prefix: "spam-"
      )

    assert Path.basename(new_meta.quarantine_path) =~ ~r/^spam-\d{8}T\d{6}-[0-9a-f]+\.eml$/
  end

  test "applies configured file mode bits", %{base: base} do
    meta = %{quarantine: true}

    {_out, new_meta} =
      Quarantine.transform_data(@msg, meta, %{}, store_path: base, mode_bits: 0o640)

    %File.Stat{mode: mode} = File.stat!(new_meta.quarantine_path)
    # Only check the low 9 permission bits.
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  test "unknown :mode raises" do
    meta = %{quarantine: true}

    assert_raise ArgumentError, ~r/unknown :mode/, fn ->
      Quarantine.transform_data(@msg, meta, %{},
        store_path: System.tmp_dir!(),
        mode: :nonsense
      )
    end
  end
end
