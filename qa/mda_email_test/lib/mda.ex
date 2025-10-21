defmodule MtaEmailTest.MDA do
  @moduledoc """
  Simple in-memory MDA for tests with procmail-like per-user rules.

  API:
    * start_link(port: integer, users: %{user_email => [%{pattern: regex_or_string, field: :subject|:from|:to, folder: "FolderName"}]})
    * add_rule(user_email, rule) -- synchronous (returns :ok after rule is stored)
    * rule_exists?(user_email, folder) -- check if a rule exists (sync)
    * wait_for_mail(user_email, folder \\ "INBOX", subject, timeout \\ 5_000)
    * get_messages(user_email, folder \\ "INBOX")

  Notes:
    * Lightweight SMTP subset for test purposes.
    * Stores parsed headers and raw message per user/folder.
    * Deduplicates identical `raw` message bodies per user (any folder).
  """

  use GenServer
  require Logger

  ## ===== Public API =====

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_rule(String.t(), map()) :: :ok
  def add_rule(user, rule) do
    GenServer.call(__MODULE__, {:add_rule_sync, normalize_email(user), normalize_rule(rule)})
  end

  @spec rule_exists?(String.t(), String.t()) :: boolean()
  def rule_exists?(user, folder) do
    GenServer.call(__MODULE__, {:rule_exists, normalize_email(user), folder || "INBOX"})
  end

  @spec wait_for_mail(String.t(), String.t(), String.t(), non_neg_integer()) :: boolean()
  def wait_for_mail(user, folder \\ "INBOX", subject, timeout \\ 5_000) do
    GenServer.call(
      __MODULE__,
      {:wait_for_mail, normalize_email(user), folder || "INBOX", subject, timeout},
      timeout + 500
    )
  end

  @spec get_messages(String.t(), String.t()) :: [map()]
  def get_messages(user, folder \\ "INBOX") do
    GenServer.call(__MODULE__, {:get_messages, normalize_email(user), folder || "INBOX"})
  end

  ## ===== GenServer callbacks =====

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 2627)

    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    state = %{
      socket: socket,
      # %{user => %{folder => [msg, ...]}} where msg = %{raw, subject, from, to}
      messages: %{},
      # rules is %{user_email => [%{pattern, field, folder}]}
      rules: normalize_rules(Keyword.get(opts, :users, %{}))
    }

    # Accept SMTP connections in a background task
    Task.start_link(fn -> accept_loop(socket, state) end)

    {:ok, state}
  end

  ## ===== handle_cast =====

  @impl true
  def handle_cast({:store, user, folder, msg}, state) do
    user = normalize_email(user)
    raw = to_string(msg[:raw] || "")

    # Deduplicate by exact raw body per user (any folder)
    if raw != "" and raw_already_stored?(state, user, raw) do
      Logger.debug("MDA.store -> duplicate raw for user=#{user}, skipping")
      {:noreply, state}
    else
      user_msgs = Map.get(state.messages, user, %{})
      folder_msgs = Map.get(user_msgs, folder, [])
      user_msgs = Map.put(user_msgs, folder, [msg | folder_msgs])
      Logger.info("MDA.store -> user=#{user} folder=#{folder} subject=#{inspect(msg[:subject] || "")}")
      {:noreply, %{state | messages: Map.put(state.messages, user, user_msgs)}}
    end
  end

  # Centralized ingestion of raw SMTP message:
  # - Parse headers
  # - Resolve rcpt (from SMTP session or To:/From: fallback)
  # - Determine folder by rules
  # - Deduplicate and store
  def handle_cast({:receive_raw, user, raw}, state) do
    user_norm = normalize_email(user)
    raw_s = to_string(raw || "")

    # If already stored for provided user hint, skip
    if raw_s != "" and raw_already_stored?(state, user_norm, raw_s) do
      Logger.debug("MDA.receive_raw -> duplicate raw for user=#{user_norm}, skipping")
      {:noreply, state}
    else
      parsed = parse_headers(raw_s)

      rcpt =
        cond do
          user_norm != "" -> user_norm
          true -> parse_to_from_parsed(parsed) |> normalize_email()
        end

      folder = determine_folder_for_user(rcpt, parsed, state.rules)

      # Double-check dedupe under resolved rcpt
      if raw_s != "" and raw_already_stored?(state, rcpt, raw_s) do
        Logger.debug("MDA.receive_raw -> duplicate raw for rcpt=#{rcpt}, skipping")
        {:noreply, state}
      else
        user_msgs = Map.get(state.messages, rcpt, %{})
        folder_msgs = Map.get(user_msgs, folder, [])
        user_msgs = Map.put(user_msgs, folder, [parsed | folder_msgs])
        Logger.info("MDA.receive_raw -> rcpt=#{rcpt} folder=#{folder} subject=#{inspect(parsed.subject)}")
        {:noreply, %{state | messages: Map.put(state.messages, rcpt, user_msgs)}}
      end
    end
  end

  ## ===== handle_call =====

  @impl true
  def handle_call({:add_rule_sync, user, rule}, _from, state) do
    rules = Map.update(state.rules, user, [rule], fn r -> [rule | r] end)
    Logger.info("MDA.add_rule_sync -> user=#{user} rule=#{inspect(rule)}")
    {:reply, :ok, %{state | rules: rules}}
  end

  def handle_call({:rule_exists, user, folder}, _from, state) do
    exists =
      Map.get(state.rules, user, [])
      |> Enum.any?(fn r -> r.folder == (folder || "INBOX") end)

    {:reply, exists, state}
  end

  def handle_call({:wait_for_mail, user, folder, subject, timeout}, _from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      wait_until(deadline, fn ->
        messages = Map.get(state.messages, user, %{}) |> Map.get(folder, [])
        Enum.any?(messages, fn m ->
          sub = (m[:subject] || "") |> to_string()
          raw = (m[:raw] || "") |> to_string()
          String.contains?(sub <> raw, to_string(subject))
        end)
      end)

    {:reply, result, state}
  end

  def handle_call({:get_messages, user, folder}, _from, state) do
    msgs = Map.get(state.messages, user, %{}) |> Map.get(folder, []) |> Enum.reverse()
    {:reply, msgs, state}
  end

  ## ===== SMTP accept loop and session =====

  # Accept loop keeps listening for new TCP clients and spawns a task per session
  defp accept_loop(socket, state) do
    {:ok, client} = :gen_tcp.accept(socket)
    :gen_tcp.send(client, "220 mda.local ESMTP MDA ready\r\n")
    Task.start(fn -> handle_smtp_session(client, state) end)
    accept_loop(socket, state)
  end

  defp handle_smtp_session(client, state) do
    do_handle_smtp_session(client, state, "")
  end

  # Minimal SMTP command handling to avoid client timeouts in tests
  defp do_handle_smtp_session(client, state, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        Logger.debug("MDA chunk: #{inspect(data)}")
        line = data |> to_string() |> String.trim_leading()
        up   = String.upcase(line)

        cond do
          String.starts_with?(up, "EHLO") or String.starts_with?(up, "HELO") ->
            # Advertise minimal capabilities and keep the session open
            :gen_tcp.send(client, "250-mda.local\r\n250 PIPELINING\r\n")
            do_handle_smtp_session(client, state, acc <> data)

          String.starts_with?(up, "MAIL FROM:") ->
            :gen_tcp.send(client, "250 OK\r\n")
            do_handle_smtp_session(client, state, acc <> data)

          String.starts_with?(up, "RCPT TO:") ->
            :gen_tcp.send(client, "250 OK\r\n")
            do_handle_smtp_session(client, state, acc <> data)

          String.starts_with?(up, "DATA") ->
            :gen_tcp.send(client, "354 End data with <CR><LF>.<CR><LF>\r\n")
            {:ok, msg} = recv_data(client, "")
            :gen_tcp.send(client, "250 OK\r\n")

            rcpt = extract_first_rcpt(acc) |> normalize_email()
            GenServer.cast(__MODULE__, {:receive_raw, rcpt, msg})

            do_handle_smtp_session(client, state, "")

          String.starts_with?(up, "RSET") ->
            :gen_tcp.send(client, "250 OK\r\n")
            do_handle_smtp_session(client, state, "")

          String.starts_with?(up, "NOOP") ->
            :gen_tcp.send(client, "250 OK\r\n")
            do_handle_smtp_session(client, state, acc)

          String.starts_with?(up, "QUIT") ->
            :gen_tcp.send(client, "221 Bye\r\n")
            :gen_tcp.close(client)

          true ->
            # Unknown/ignored line – respond OK to keep client flowing
            :gen_tcp.send(client, "250 OK\r\n")
            do_handle_smtp_session(client, state, acc <> data)
        end

      {:error, _} ->
        :ok
    end
  end

  # Receive message body until single line "." appears
  defp recv_data(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, ".\r\n"} -> {:ok, acc}
      {:ok, data} -> recv_data(client, acc <> data)
      {:error, _} -> {:ok, acc}
    end
  end

  ## ===== Helpers: RCPT extraction, header parsing, normalization, rules =====

  # Extract first RCPT TO from accumulated SMTP dialogue
  defp extract_first_rcpt(acc) when is_binary(acc) do
    acc
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find_value("", fn line ->
      case Regex.run(~r/^\s*RCPT\s+TO\s*:\s*<?\s*([^>\s]+@[^>\s]+)\s*>?/i, line) do
        [_, addr] -> String.trim(addr)
        _ -> nil
      end
    end)
    |> case do
      "" ->
        # Fallback: try to get To: header if it somehow appeared in dialogue
        acc
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.find_value("", fn line ->
          case Regex.run(~r/^\s*To\s*:\s*(.*)$/i, line) do
            [_, val] ->
              case Regex.run(~r/([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/, val) do
                [_, email] -> String.trim(email)
                _ -> nil
              end

            _ -> nil
          end
        end)

      other -> other
    end
  end

  defp extract_first_rcpt(_), do: ""

  # Parse top headers and keep raw as well
  defp parse_headers(raw) when is_binary(raw) do
    lines = String.split(raw, "\r\n")
    {headers, _body} = Enum.split_while(lines, &(&1 != ""))

    unfolded = unfold_headers(headers)

    subject = header_value(unfolded, "subject")
    from = header_value(unfolded, "from")
    to = header_value(unfolded, "to")

    %{
      raw: raw,
      subject: subject || "",
      from: from || "",
      to: to || ""
    }
  end

  # Join folded headers
  defp unfold_headers(lines) do
    Enum.reduce(lines, [], fn
      line, [] -> [line]
      line, acc ->
        if String.match?(line, ~r/^\s+/) do
          [prev | rest] = acc
          [prev <> " " <> String.trim(line) | rest]
        else
          [line | acc]
        end
    end)
    |> Enum.reverse()
  end

  defp header_value(headers, key) do
    headers
    |> Enum.find_value(nil, fn line ->
      case Regex.run(~r/^\s*#{Regex.escape(key)}\s*:\s*(.*)$/i, line) do
        [_, val] -> String.trim(val)
        _ -> nil
      end
    end)
  end

  # Prefer To header, then From; used to resolve rcpt when SMTP rcpt hint is missing
  defp parse_to_from_parsed(parsed) do
    parsed.to || parsed.from || ""
  end

  # Basic email normalization used for user keys in maps
  defp normalize_email(nil), do: ""
  defp normalize_email(bin) when is_binary(bin) do
    bin
    |> String.trim()
    |> (fn b ->
      b = Regex.replace(~r/^.*<\s*/, b, "")
      b = Regex.replace(~r/\s*>.*$/, b, "")
      b = Regex.replace(~r/^"(.*)"\s*$/, b, "\\1")
      String.trim(b, "\" ")
    end).()
    |> String.downcase()
  end

  # True if a message with identical raw body is already stored for user (any folder)
  defp raw_already_stored?(state, user, raw) do
    user = normalize_email(user)

    state.messages
    |> Map.get(user, %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.any?(fn m -> to_string(m[:raw] || "") == raw end)
  end

  # Decide target folder using per-user rules; default is INBOX
  defp determine_folder_for_user("", _parsed, _rules), do: "INBOX"

  defp determine_folder_for_user(rcpt, parsed, rules) do
    user_rules = Map.get(rules, String.downcase(rcpt), [])

    Enum.find_value(user_rules, "INBOX", fn rule ->
      field_val =
        case rule.field do
          :subject -> parsed.subject || ""
          :from -> parsed.from || ""
          :to -> parsed.to || ""
        end

      case rule.pattern do
        %Regex{} = rx ->
          if Regex.match?(rx, field_val), do: rule.folder, else: nil

        bin when is_binary(bin) ->
          if String.contains?(String.downcase(field_val), String.downcase(bin)), do: rule.folder, else: nil

        _ -> nil
      end
    end)
  end

  # Normalize "users" map at init
  defp normalize_rules(map) when is_map(map) do
    map
    |> Enum.map(fn {user, rules} ->
      {String.downcase(to_string(user)), Enum.map(rules, &normalize_rule/1)}
    end)
    |> Enum.into(%{})
  end

  # Allow pattern either as binary or regex, field defaults to :subject, folder defaults to INBOX
  defp normalize_rule(%{pattern: p, field: f, folder: folder}) when is_binary(p) do
    %{pattern: p, field: f || :subject, folder: folder || "INBOX"}
  end

  defp normalize_rule(%{pattern: %Regex{} = p, field: f, folder: folder}) do
    %{pattern: p, field: f || :subject, folder: folder || "INBOX"}
  end

  defp normalize_rule({field, pattern, folder}) do
    %{pattern: pattern, field: field, folder: folder}
  end

  # Simple polling helper for wait_for_mail
  defp wait_until(deadline, fun) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        wait_until(deadline, fun)
      else
        false
      end
    end
  end
end
