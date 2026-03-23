defmodule Feather.Session do
  @behaviour :gen_smtp_server_session
  require Logger

  @impl true
  def init(hostname, session_count, ip, opts) do
    name = Application.get_env(:feather, :smtp_server)[:name]
    banner = ["#{hostname} #{name} ready #{session_count}"]
    options = Application.get_env(:feather, :smtp_server)[:sessionoptions]

    pipeline =
      Feather.PipelineManager.get_pipeline()
      |> Enum.map(fn {mod, adapter_opts} ->
        merged_opts = Keyword.merge(adapter_opts, opts)
        {mod, mod.init_session(merged_opts)}
      end)

    state = %{
      hostname: hostname,
      pipeline: pipeline,
      meta: %{ip: ip},
      opts: options
    }

    {:ok, banner, state}
  end

  def handle_EHLO(domain, extensions, {:ok, state}) do
    handle_EHLO(domain, extensions, state)
  end

  @impl true
  def handle_EHLO(_domain, extensions, state) do
    opts = state.opts || %{}
    tls_mode = opts[:tls]
    tls_active? = Map.get(state, :tls_active, false)
    max_size = opts[:max_size] || 10_485_760  # 10MB default

    # Base extensions available in all modes
    smtp_extensions = [
      {~c"SIZE", ~c"#{max_size}"},
      {~c"PIPELINING", true},
      {~c"8BITMIME", true},
      {~c"ENHANCEDSTATUSCODES", true}
    ]

    # Only advertise AUTH when connection is secure:
    # - After STARTTLS has been negotiated (tls_active? = true)
    # - OR when using implicit TLS (tls_mode = :always)
    smtp_extensions =
      if tls_active? or tls_mode == :always do
        [{~c"AUTH", ~c"PLAIN LOGIN"} | smtp_extensions]
      else
        smtp_extensions
      end

    # Only advertise STARTTLS when:
    # - TLS is available (tls_mode = :if_available)
    # - AND TLS is not yet active (tls_active? = false)
    smtp_extensions =
      if tls_mode == :if_available and not tls_active? do
        [{~c"STARTTLS", true} | smtp_extensions]
      else
        smtp_extensions
      end

    # Allow adapters to modify extensions via ehlo/3 callback
    state_with_exts = %{state | meta: Map.put(state.meta, :extensions, smtp_extensions)}

    case step(:ehlo, smtp_extensions, state_with_exts) do
      {:ok, %{meta: meta} = updated_state} ->
        final_extensions = Map.get(meta, :extensions, smtp_extensions)
        clean_meta = Map.delete(meta, :extensions)
        {:ok, final_extensions ++ extensions, %{updated_state | meta: clean_meta}}

      {:error, reason, failed_state} ->
        {:error, reason, failed_state}
    end
  end

  def handle_HELO(domain, {:ok, state}) do
    handle_HELO(domain, state)
  end

  @impl true
  def handle_HELO(domain, state), do: step(:helo, domain, state)

  def handle_AUTH(type, username, password, {:ok, state}) do
    handle_AUTH(type, username, password, state)
  end

  @impl true
  def handle_AUTH(_type, username, password, state) do
    step(:auth, {username, password}, state)
  end

  def handle_MAIL(from, {:ok, state}) do
    handle_MAIL(from, state)
  end

  @impl true
  def handle_MAIL(from, state), do: step(:mail, from, state)

  @impl :gen_smtp_server_session
  def handle_MAIL_extension(_extension, _state) do
    :error
  end

  def handle_RCPT(to, {:ok, state}) do
    handle_RCPT(to, state)
  end

  @impl true
  def handle_RCPT(to, state), do: step(:rcpt, to, state)

  @impl true
  def handle_RCPT_extension(_extension, _state) do
    :error
  end

  @impl true
  def handle_DATA(from, to, data, %{meta: meta} = state) do
    case sanitize_headers(data) do
      {:ok, sanitized} ->
        meta = Map.merge(meta, %{from: from, to: to})
        delivery_state = %{state | meta: meta}
        hostname = state.hostname

        # Accept message immediately, deliver asynchronously.
        # RFC 5321 §4.5.5 / RFC 3461 §4: once we return 250, we take
        # responsibility for the message. If delivery fails, we MUST
        # notify the sender via DSN.
        Task.Supervisor.start_child(Feather.DeliverySupervisor, fn ->
          case step(:data, sanitized, delivery_state) do
            {:ok, _} ->
              Logger.info("[SESSION] Message delivered successfully from #{from}")

            {:error, reason, _} ->
              Logger.warning(
                "[SESSION] Delivery failed from #{from}: #{inspect(reason)}"
              )

              Feather.DSN.notify_failure(from, to, reason,
                hostname: hostname,
                diagnostic_code: "smtp; 550 5.0.0 Delivery failed: #{inspect(reason)}",
                status: "5.0.0"
              )
          end
        end)

        {:ok, "250 2.0.0 OK: message queued for delivery", delivery_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_RSET(state), do: {:ok, state}

  @impl true
  def handle_STARTTLS(state) do
    # Mark TLS as active in state to control AUTH advertisement
    {:ok, Map.put(state, :tls_active, true)}
  end

  @impl true
  def handle_VRFY(_address, state), do: {:ok, ~c"252 Not supported", state}

  @impl true
  def handle_other(_cmd, _args, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{pipeline: pipeline, meta: meta}) do
    Enum.each(pipeline, fn {mod, adapter_state} ->
      if function_exported?(mod, :terminate, 3) do
        mod.terminate(reason, meta, adapter_state)
      end
    end)

    {:ok, reason, nil}
  end

  def terminate(reason, _state) do
    {:ok, reason, nil}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}



  defp step(phase, arg, %{pipeline: pipeline, meta: meta} = state) do
    Enum.reduce_while(pipeline, {[], meta}, fn {mod, adapter_state}, {acc, meta} ->
      if function_exported?(mod, phase, 3) do
        case apply(mod, phase, [arg, meta, adapter_state]) do
          {:ok, new_meta, new_state} ->
            {:cont, {[{mod, new_state} | acc], new_meta}}

          {:halt, reason, new_state} ->
            formatted = format_reason({mod, reason})

            {:halt,
             {:error, formatted,
              %{state | pipeline: acc ++ [{mod, new_state} | tl(pipeline)], meta: meta}}}
        end
      else
        {:cont, {[{mod, adapter_state} | acc], meta}}
      end
    end)
    |> case do
      {:error, reply, new_state} ->
        {:error, reply, new_state}

      {new_pipeline, new_meta} ->
        {:ok, %{state | pipeline: Enum.reverse(new_pipeline), meta: new_meta}}
    end
  end


  # Validates and sanitizes the header section of an RFC 5322 message.
  #
  # Rejects messages with:
  # 1. NUL bytes or bare CR in headers (RFC 5322 §2.2 violation)
  # 2. Malformed header lines (invalid field name syntax)
  # 3. Bcc headers present in submission (MUA must strip before sending)
  # 4. MTA-only headers that clients must not set (Return-Path, Received, etc.)
  # 5. Duplicate singleton headers (RFC 5322 §3.6)
  # 6. Continuation lines that look like injected headers
  defp sanitize_headers(data) do
    {separator, parts} = split_headers_body(data)

    case parts do
      {headers_raw, body} ->
        if String.contains?(headers_raw, "\0") do
          {:error, "550 5.6.0 Message rejected: NUL byte in header"}
        else
          lines = String.split(headers_raw, ~r/\r?\n/)

          with :ok <- validate_header_lines(lines),
               :ok <- validate_no_duplicate_singletons(lines) do
            cleaned = strip_forbidden_headers(lines)
            {:ok, Enum.join(cleaned, separator) <> separator <> separator <> body}
          end
        end

      :no_body ->
        {:ok, data}
    end
  end

  defp split_headers_body(data) do
    cond do
      String.contains?(data, "\r\n\r\n") ->
        [h, b] = String.split(data, "\r\n\r\n", parts: 2)
        {"\r\n", {h, b}}

      String.contains?(data, "\n\n") ->
        [h, b] = String.split(data, "\n\n", parts: 2)
        {"\n", {h, b}}

      true ->
        {"\r\n", :no_body}
    end
  end

  # Headers that submission clients must not set — these are added by MTAs,
  # MDAs, or security infrastructure. Allowing them enables header injection
  # attacks (bounce hijacking, auth bypass, spam filter evasion).
  @forbidden_headers MapSet.new([
    "return-path",          # RFC 5321 §4.4 — set by MTA from envelope
    "received",             # RFC 5321 — set by each relay
    "authentication-results", # RFC 8601 — set by receiving MTA
    "dkim-signature",       # RFC 6376 — set by signing MTA
    "arc-seal",             # RFC 8617 — ARC protocol
    "arc-message-signature", # RFC 8617
    "arc-authentication-results", # RFC 8617
    "x-spam-status",        # SpamAssassin — set by spam filter
    "x-spam-flag",          # SpamAssassin
    "x-spam-score"          # SpamAssassin
  ])

  defp validate_header_lines(lines) do
    result =
      Enum.find_value(lines, fn line ->
        cond do
          String.contains?(line, "\0") ->
            {:error, "550 5.6.0 Message rejected: NUL byte in header"}

          String.contains?(line, "\r") ->
            {:error, "550 5.6.0 Message rejected: bare CR in header"}

          String.match?(line, ~r/^Bcc:/i) ->
            {:error, "550 5.6.0 Message rejected: Bcc header must not be present in submission"}

          continuation_line_injection?(line) ->
            {:error, "550 5.6.0 Message rejected: header injection via continuation line"}

          not valid_header_line?(line) ->
            {:error, "550 5.6.0 Message rejected: malformed header"}

          true ->
            nil
        end
      end)

    result || :ok
  end

  # RFC 5322 §3.6: these headers MUST NOT appear more than once.
  @singleton_headers MapSet.new([
    "from", "sender", "reply-to", "to", "cc", "subject",
    "date", "message-id", "in-reply-to", "references",
    "mime-version", "content-type", "content-transfer-encoding"
  ])

  defp validate_no_duplicate_singletons(lines) do
    lines
    |> Enum.reject(fn line -> line == "" or String.match?(line, ~r/^[ \t]/) end)
    |> Enum.reduce_while(%{}, fn line, seen ->
      case String.split(line, ":", parts: 2) do
        [name, _value] ->
          key = String.downcase(name)

          if MapSet.member?(@singleton_headers, key) and Map.has_key?(seen, key) do
            {:halt, {:error, "550 5.6.0 Message rejected: duplicate #{name} header"}}
          else
            {:cont, Map.put(seen, key, true)}
          end

        _ ->
          {:cont, seen}
      end
    end)
    |> case do
      {:error, _} = err -> err
      %{} -> :ok
    end
  end

  # Detects continuation lines (starting with whitespace) that contain
  # what looks like an injected header field (e.g. "\tReply-To: attacker@evil.com").
  defp continuation_line_injection?(line) do
    case line do
      <<c, rest::binary>> when c in [?\s, ?\t] ->
        trimmed = String.trim_leading(rest)
        Regex.match?(~r/^[A-Za-z][A-Za-z0-9\-]*:\s/, trimmed)

      _ ->
        false
    end
  end

  # Silently strips headers that authenticated clients must not set.
  # These are MTA/MDA-only headers; their presence in submission is
  # either a misconfigured client or an injection attempt.
  defp strip_forbidden_headers(lines) do
    {kept, _skipping} =
      Enum.reduce(lines, {[], false}, fn line, {acc, skipping_folded} ->
        cond do
          # Continuation line (starts with whitespace) — belongs to previous header
          String.match?(line, ~r/^[ \t]/) ->
            if skipping_folded, do: {acc, true}, else: {[line | acc], false}

          forbidden_header?(line) ->
            # Drop this header and any following continuation lines
            {acc, true}

          true ->
            {[line | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  defp forbidden_header?(line) do
    case String.split(line, ":", parts: 2) do
      [name, _value] ->
        MapSet.member?(@forbidden_headers, String.downcase(name))

      _ ->
        false
    end
  end

  defp valid_header_line?(""), do: true
  defp valid_header_line?(<<c, _rest::binary>>) when c in [?\s, ?\t], do: true

  defp valid_header_line?(line) do
    case String.split(line, ":", parts: 2) do
      [name, _value] ->
        byte_size(name) > 0 and valid_field_name?(name)

      _ ->
        false
    end
  end

  # RFC 5322 field names: printable US-ASCII except colon and space
  defp valid_field_name?(name) do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(fn c -> c >= 33 and c <= 126 and c != ?:  end)
  end

  defp format_reason({mod, reason}) do
    if function_exported?(mod, :format_reason, 1) do
      mod.format_reason(reason)
    else
      "550 #{inspect(reason)}"
    end
  end
end
