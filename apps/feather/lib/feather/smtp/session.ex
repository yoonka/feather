defmodule Feather.Smtp.Session do
  @behaviour :gen_smtp_server_session

  @impl true
  def init(hostname, session_count, ip, _opts) do
    name = Application.get_env(:feather, :smtp_server)[:name]
    banner = ["#{hostname} #{name} ready #{session_count}"]

    pipeline =
      Application.get_env(:feather, :smtp_server)[:pipeline]
      |> Enum.map(fn {mod, adapter_opts} ->
        {mod, mod.init_session(adapter_opts)}
      end)

    state = %{
      hostname: hostname,
      pipeline: pipeline,
      meta: %{ip: ip}
    }

    {:ok, banner, state}
  end

  @impl true
  def handle_EHLO(_domain, extensions, state) do
    {:ok, [{~c"AUTH", ~c"PLAIN LOGIN"} | extensions], state}
  end

  @impl true
  def handle_HELO(domain, state), do: step(:helo, domain, state)

  @impl true
  def handle_AUTH(_type, username, password, state) do
    step(:auth, {username, password}, state)
  end

  @impl true
  def handle_MAIL(from, state), do: step(:mail, from, state)

  @impl :gen_smtp_server_session
  def handle_MAIL_extension(_extension, _state) do
    :error
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
  def handle_STARTTLS(state), do: {:ok, state}

  @impl true
  def handle_VRFY(_address, state), do: {:ok, ~c"252 Not supported", state}

  @impl true
  def handle_other(cmd, args, state) do
    IO.inspect({:unhandled, cmd, args})
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
