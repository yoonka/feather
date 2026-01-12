defmodule Feather.Session do
  @behaviour :gen_smtp_server_session

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

    {:ok, smtp_extensions ++ extensions, state}
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
  def handle_MAIL(from, %{meta: meta} = state) do
    # Enforce authentication requirement: sessions must be authenticated before sending mail
    # Auth adapters (PamAuth, NoAuth, etc.) set meta.authenticated or meta.user
    cond do
      # Check if authenticated via meta.authenticated flag
      Map.get(meta, :authenticated, false) ->
        step(:mail, from, state)

      # Check if authenticated via meta.user presence
      Map.has_key?(meta, :user) ->
        step(:mail, from, state)

      # Otherwise reject - authentication required
      true ->
        {:error, "530 5.7.0 Authentication required", state}
    end
  end

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
    meta = Map.merge(meta, %{from: from, to: to})

    step(:data, data, %{state | meta: meta})
    |> case do
      {:ok, updated_state} ->
        {:ok, "250 2.0.0 OK: message accepted", updated_state}

      {:error, reason, failed_state} ->
        {:error, reason, failed_state}
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


  defp format_reason({mod, reason}) do
    if function_exported?(mod, :format_reason, 1) do
      mod.format_reason(reason)
    else
      "550 #{inspect(reason)}"
    end
  end
end
