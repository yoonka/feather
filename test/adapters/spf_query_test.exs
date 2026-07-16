defmodule FeatherAdapters.SPFQueryTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.SPFQuery

  # Every fixture below is verbatim output captured from libspf2's spfquery
  # (spfquery 1.2.x, FreeBSD) — not hand-written approximations.

  describe "args/3" do
    test "uses libspf2's single-dash long options and no -timeout flag" do
      args = SPFQuery.args({203, 0, 113, 5}, "user@example.org", "mail.example.org")

      assert args == [
               "-ip",
               "203.0.113.5",
               "-sender",
               "user@example.org",
               "-helo",
               "mail.example.org"
             ]
    end

    test "omits -helo when the HELO identity is unknown" do
      for helo <- [nil, ""] do
        args = SPFQuery.args({203, 0, 113, 5}, "user@example.org", helo)
        refute "-helo" in args
        assert args == ["-ip", "203.0.113.5", "-sender", "user@example.org"]
      end
    end

    test "never passes an option spfquery does not accept" do
      # Regression: `--timeout` made spfquery print its usage text and exit
      # without evaluating SPF, which was then parsed as a confident "none".
      args = SPFQuery.args({203, 0, 113, 5}, "user@example.org", "mail.example.org")
      refute Enum.any?(args, &String.starts_with?(&1, "--"))
      refute "-timeout" in args
    end
  end

  describe "parse/1 — real spfquery output" do
    test "pass, where the explanation line is preceded by a blank line" do
      output = """
      pass

      spfquery: domain of gmail.com designates 209.85.220.41 as permitted sender
      Received-SPF: pass (spfquery: domain of gmail.com designates 209.85.220.41 as permitted sender) client-ip=209.85.220.41; envelope-from=test@gmail.com; helo=mail.example.com;
      """

      assert {:pass, comment} = SPFQuery.parse(output)
      assert comment == "domain of gmail.com designates 209.85.220.41 as permitted sender"
    end

    test "softfail, where line 2 is the openspf URL rather than the explanation" do
      output = """
      softfail
      Please see http://www.openspf.org/Why?id=test%40gmail.com&ip=198.51.100.7&receiver=spfquery : Reason: mechanism
      spfquery: transitioning domain of gmail.com does not designate 198.51.100.7 as permitted sender
      """

      assert {:softfail, comment} = SPFQuery.parse(output)

      assert comment ==
               "transitioning domain of gmail.com does not designate 198.51.100.7 as permitted sender"

      refute comment =~ "openspf.org"
    end

    test "fail" do
      output = """
      fail
      Please see http://www.openspf.org/Why?id=test%40iana.org&ip=198.51.100.7&receiver=spfquery : Reason: mechanism
      spfquery: domain of iana.org does not designate 198.51.100.7 as permitted sender
      """

      assert {:fail, "domain of iana.org does not designate 198.51.100.7 as permitted sender"} =
               SPFQuery.parse(output)
    end

    test "no SPF record / NXDOMAIN reports an error block, which is :none (RFC 7208 §2.6.1)" do
      output = """
      StartError
      Context: Failed to query MAIL-FROM
      ErrorCode: (2) Could not find a valid SPF record
      Error: Host 'definitely-not-a-real-domain-zzz9.com' not found.
      """

      assert {:none, comment} = SPFQuery.parse(output)
      assert comment == "no valid SPF record found"
    end
  end

  describe "parse/1 — a checker that did not evaluate must not claim :none" do
    test "usage text yields :temperror, not :none" do
      # The exact regression seen in production: `Received-SPF: none (...: Usage:)`
      output = """
      spfquery: unrecognized option `--timeout'
      Usage:

      spfquery [control options | data options] ...

      Valid data options are:
          -ip <IP address>           The IP address that is sending email
      """

      assert {:temperror, _} = SPFQuery.parse(output)
    end

    test "empty output yields :temperror" do
      assert {:temperror, _} = SPFQuery.parse("")
    end

    test "a crash yields :temperror" do
      output = """
      spf_request.c:144    Error: from is NULL
      Abort trap (core dumped)
      """

      assert {:temperror, _} = SPFQuery.parse(output)
    end
  end

  describe "run/5" do
    test "a missing binary is a temporary error, not a verdict" do
      assert {:temperror, _} =
               SPFQuery.run(
                 "definitely-not-a-real-binary-zzz9",
                 {203, 0, 113, 5},
                 "u@e.org",
                 nil,
                 500
               )
    end

    test "enforces the timeout itself, since spfquery has no -timeout flag" do
      # Stands in for a spfquery wedged on a DNS lookup: ignores its arguments
      # and hangs well past the deadline. `exec` so the sleep replaces the
      # shell and the spawned pid is the hanging process, as it is for the real
      # single-binary spfquery.
      marker = unique_marker()
      stub = stub_binary("#!/bin/sh\nexec sleep #{marker}\n")

      {elapsed_us, result} =
        :timer.tc(fn -> SPFQuery.run(stub, {203, 0, 113, 5}, "user@example.org", nil, 200) end)

      assert {:temperror, comment} = result
      assert comment =~ "timed out"
      assert div(elapsed_us, 1000) < 5_000, "run/5 did not return at the deadline"

      # Closing a port does not kill what it spawned, so a timeout must reap the
      # child explicitly — otherwise every wedged lookup leaks a process.
      assert wait_until_gone(marker), "timed-out child was left running"
    end
  end

  # A sleep duration long enough to outlive the test, unique enough to pgrep for.
  defp unique_marker, do: 40_000 + System.unique_integer([:positive, :monotonic])

  defp stub_binary(script) do
    path = Path.join(System.tmp_dir!(), "spfquery_stub_#{System.unique_integer([:positive])}")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp wait_until_gone(marker, attempts \\ 20) do
    cond do
      not alive?(marker) -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && wait_until_gone(marker, attempts - 1)
    end
  end

  defp alive?(marker) do
    case System.cmd("pgrep", ["-f", "sleep #{marker}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  describe "format_ip/1" do
    test "renders IPv4 and IPv6 tuples and passes strings through" do
      assert SPFQuery.format_ip({203, 0, 113, 5}) == "203.0.113.5"
      assert SPFQuery.format_ip({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == "2001:db8::1"
      assert SPFQuery.format_ip("203.0.113.5") == "203.0.113.5"
      assert SPFQuery.format_ip(nil) == ""
    end
  end
end
