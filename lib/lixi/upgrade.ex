defmodule Lixi.Upgrade do
  @moduledoc "Atomic compatible BEAM patches; additive state changes never suspend media actors."
  use GenServer
  @allowed [Lixi.Router, Lixi.Info, Lixi.Filters, Lixi.Sources, Lixi.Player, Lixi.Sessions]
  @stateful [Lixi.Player, Lixi.Sessions]
  @defaults {__MODULE__, :defaults}
  @version {__MODULE__, :version}
  @transaction {__MODULE__, :transaction}
  @recovery {__MODULE__, :recovery}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def apply_bundle(path), do: GenServer.call(__MODULE__, {:apply, path}, 30_000)
  def rollback, do: GenServer.call(__MODULE__, :rollback, 30_000)
  def recover, do: GenServer.call(__MODULE__, :recover, 30_000)
  def version, do: :persistent_term.get(@version, Application.spec(:lixi, :vsn) |> to_string())
  def defaults(module, state), do: Map.merge(Map.get(all_defaults(), module, %{}), state)

  def status,
    do: %{
      version: version(),
      supported_modules: Enum.map(@allowed, &inspect/1),
      recovery_required: :persistent_term.get(@recovery, nil) != nil
    }

  defp all_defaults, do: :persistent_term.get(@defaults, %{})
  defp state_file, do: Path.join(Application.fetch_env!(:lixi, :data_dir), "hot-upgrade.json")
  defp loader, do: Application.get_env(:lixi, :upgrade_loader, Lixi.Upgrade.Loader)

  def bootstrap do
    with {:ok, journal} <- read_journal(),
         {:ok, committed} <- committed_state(journal["patches"]) do
      installed =
        committed.target == version() and
          Enum.all?(committed.modules, fn {module, hash} ->
            Code.ensure_loaded?(module) and module.module_info(:md5) == hash
          end)

      if installed do
        :persistent_term.put(@defaults, merge_defaults(all_defaults(), committed.defaults))
        :ok
      else
        replay(journal["patches"])
      end
    end
  end

  defp committed_state(paths) do
    Enum.reduce_while(paths, {:ok, %{target: nil, modules: %{}, defaults: %{}}}, fn path,
                                                                                    {:ok, state} ->
      with {:ok, bundle} <- read_bundle(path),
           true <- state.target == nil or state.target == bundle.base do
        modules =
          Enum.reduce(bundle.modules, state.modules, fn {module, _, binary}, hashes ->
            {:ok, {^module, hash}} = :beam_lib.md5(binary)
            Map.put(hashes, module, hash)
          end)

        {:cont,
         {:ok,
          %{
            target: bundle.target,
            modules: modules,
            defaults: merge_defaults(state.defaults, bundle.defaults)
          }}}
      else
        _ -> {:halt, {:error, :invalid_committed_upgrade}}
      end
    end)
  end

  defp replay(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      with {:ok, bundle} <- read_bundle(path),
           true <- bundle.base == version(),
           :ok <- purge_old(bundle.modules),
           {:ok, prepared} <- Lixi.Upgrade.Loader.prepare(bundle.modules),
           :ok <- Lixi.Upgrade.Loader.finish(prepared) do
        :persistent_term.put(@defaults, merge_defaults(all_defaults(), bundle.defaults))
        :persistent_term.put(@version, bundle.target)
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_committed_upgrade}}
      end
    end)
  end

  @impl true
  def init(_) do
    case recover_interrupted() do
      :ok -> with {:ok, journal} <- read_journal(), do: {:ok, %{journal: journal}}
      _ -> {:ok, %{journal: :persistent_term.get(@recovery).old_journal}}
    end
  end

  @impl true
  def handle_call({:apply, path}, _, state), do: apply_unless_recovering(path, state)

  def handle_call(:recover, _, state) do
    with :ok <- recover_interrupted(), {:ok, journal} <- read_journal() do
      {:reply, :ok, %{state | journal: journal}}
    else
      _ -> {:reply, {:error, :recovery_required}, state}
    end
  end

  def handle_call(:rollback, _, %{journal: %{"rollback" => nil}} = state),
    do: {:reply, {:error, :no_rollback}, state}

  def handle_call(:rollback, _, state),
    do: apply_unless_recovering(state.journal["rollback"], state)

  defp apply_unless_recovering(path, state) do
    if :persistent_term.get(@recovery, nil),
      do: {:reply, {:error, :recovery_required}, state},
      else: perform(path, state)
  end

  defp perform(path, state) do
    with {:ok, input} <- read_bundle(path),
         true <- input.base == version(),
         true <- length(state.journal["patches"]) < 32,
         :ok <- compatible_defaults(input.defaults),
         {:ok, bundle} <- store_bundle(input),
         {:ok, old} <- old_objects(bundle.modules),
         :ok <- purge_old(bundle.modules),
         {:ok, prepared} <- loader().prepare(bundle.modules) do
      {:ok, previous_mode} = Lixi.Lifecycle.upgrade_start()
      ref = make_ref()

      recovery = %{
        ref: ref,
        phase: :prepared,
        old_defaults: all_defaults(),
        old_journal: state.journal,
        modules: bundle.modules,
        defaults: bundle.defaults,
        target: bundle.target,
        mode: previous_mode
      }

      :persistent_term.put(@recovery, recovery)
      :persistent_term.put(@transaction, ref)
      result = activate(bundle, prepared, old, state.journal, ref)
      :persistent_term.erase(@transaction)

      case result do
        {:ok, journal} ->
          :persistent_term.put(@version, bundle.target)
          :persistent_term.erase(@recovery)
          restore_mode(previous_mode)
          if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
          {:reply, {:ok, %{version: bundle.target}}, %{state | journal: journal}}

        {:error, _} = error ->
          mark_phase(:rollback_required)
          rollback_additions(recovery)

          case write_journal(state.journal) do
            :ok ->
              :persistent_term.erase(@recovery)
              restore_mode(previous_mode)
              {:reply, error, state}

            _ ->
              mark_phase(:rollback_required)
              Lixi.Lifecycle.drain()
              {:reply, {:error, :recovery_required}, state}
          end
      end
    else
      false -> {:reply, {:error, :version_or_history_limit}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp activate(bundle, prepared, old, journal, ref) do
    try do
      :persistent_term.put(@defaults, merge_defaults(all_defaults(), bundle.defaults))

      for {module, additions} <- bundle.defaults, pid <- actor_pids(module) do
        caller = self()

        result =
          :sys.replace_state(
            pid,
            fn state ->
              if :persistent_term.get(@transaction, nil) == ref do
                send(caller, {:defaults_applied, ref, self()})
                Map.merge(additions, state)
              else
                state
              end
            end,
            30
          )

        if not is_map(result), do: throw(:state_migration_failed)

        receive do
          {:defaults_applied, ^ref, ^pid} -> :ok
        after
          0 -> throw(:state_migration_failed)
        end
      end

      rollback = write_backup(old, bundle.target, version())

      next = %{
        "schema" => 1,
        "patches" => journal["patches"] ++ [bundle.path],
        "rollback" => rollback
      }

      :ok = write_journal(next)
      mark_phase(:activation_ready)

      case loader().finish(prepared) do
        :ok ->
          mark_phase(:activated)
          {:ok, next}

        _ ->
          {:error, :code_load_failed}
      end
    catch
      :throw, reason when is_atom(reason) -> {:error, reason}
      _, _ -> {:error, :upgrade_failed}
    end
  end

  defp rollback_additions(recovery) do
    :persistent_term.erase(@transaction)
    :persistent_term.put(@defaults, recovery.old_defaults)

    for {module, fields} <- recovery.defaults, pid <- actor_pids(module) do
      new = Map.keys(fields) -- Map.keys(Map.get(recovery.old_defaults, module, %{}))

      try do
        :sys.replace_state(
          pid,
          fn state ->
            # A late undo must not delete a field installed by a later transaction.
            active = Map.get(all_defaults(), module, %{})
            Map.drop(state, Enum.reject(new, &Map.has_key?(active, &1)))
          end,
          30
        )
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp recover_interrupted do
    case :persistent_term.get(@recovery, nil) do
      nil ->
        :ok

      recovery ->
        active =
          Enum.all?(recovery.modules, fn {module, _, binary} ->
            {:ok, {_, hash}} = :beam_lib.md5(binary)
            module.module_info(:md5) == hash
          end)

        result =
          if recovery.phase in [:activation_ready, :activated] and active do
            :persistent_term.put(@version, recovery.target)
            :ok
          else
            rollback_additions(recovery)
            write_journal(recovery.old_journal)
          end

        :persistent_term.erase(@transaction)

        if result == :ok do
          :persistent_term.erase(@recovery)
          restore_mode(recovery.mode)
          :ok
        else
          mark_phase(:rollback_required)
          Lixi.Lifecycle.drain()
          {:error, :recovery_required}
        end
    end
  end

  defp mark_phase(phase) do
    recovery = :persistent_term.get(@recovery)
    :persistent_term.put(@recovery, %{recovery | phase: phase})
  end

  defp restore_mode(:draining), do: Lixi.Lifecycle.drain()
  defp restore_mode(_), do: Lixi.Lifecycle.resume()

  defp actor_pids(Lixi.Player),
    do:
      DynamicSupervisor.which_children(Lixi.PlayerSupervisor)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&is_pid/1)

  defp actor_pids(Lixi.Sessions), do: List.wrap(Process.whereis(Lixi.Sessions))

  defp compatible_defaults(defaults) do
    if Enum.all?(defaults, fn {module, fields} ->
         old = Map.get(all_defaults(), module, %{})

         map_size(Map.merge(old, fields)) <= 256 and
           Enum.all?(fields, fn {key, value} ->
             not Map.has_key?(old, key) or old[key] == value
           end)
       end), do: :ok, else: {:error, :state_defaults_conflict}
  end

  defp merge_defaults(old, new), do: Map.merge(old, new, fn _, a, b -> Map.merge(b, a) end)

  def read_bundle(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, %{type: :regular, size: size}} <- File.lstat(Path.join(path, "manifest.json")),
         true <- size <= 65_536,
         {:ok, body} <- File.read(Path.join(path, "manifest.json")),
         {:ok, %{"schema" => 1, "from" => base, "to" => target, "modules" => entries} = manifest} <-
           Jason.decode(body),
         true <-
           is_binary(base) and is_binary(target) and byte_size(base) in 1..64 and
             byte_size(target) in 1..64,
         true <- is_list(entries) and length(entries) in 1..6,
         {:ok, modules} <- read_modules(path, entries),
         true <- length(Enum.uniq(Enum.map(modules, &elem(&1, 0)))) == length(modules),
         true <-
           Enum.sum(Enum.map(modules, fn {_, _, bytes} -> byte_size(bytes) end)) <= 8_388_608,
         {:ok, defaults} <- read_defaults(Map.get(manifest, "stateDefaults", %{}), modules) do
      {:ok, %{path: path, base: base, target: target, modules: modules, defaults: defaults}}
    else
      _ -> {:error, :invalid_upgrade_bundle}
    end
  end

  defp read_modules(path, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, modules} ->
      module = if is_map(entry), do: Enum.find(@allowed, &(inspect(&1) == entry["module"]))

      if module do
        filename = Path.join(path, Atom.to_string(module) <> ".beam")

        with {:ok, %{type: :regular, size: size}} <- File.lstat(filename),
             true <- size <= 4_194_304,
             {:ok, binary} <- File.read(filename),
             true <- Base.encode16(:crypto.hash(:sha256, binary), case: :lower) == entry["sha256"],
             {:ok, {^module, chunks}} <- :beam_lib.chunks(binary, [:exports, :attributes]),
             false <- Keyword.has_key?(chunks[:attributes], :on_load) do
          {:cont, {:ok, [{module, String.to_charlist(filename), binary} | modules]}}
        else
          _ -> {:halt, {:error, :invalid_beam}}
        end
      else
        {:halt, {:error, :unsupported_upgrade_module}}
      end
    end)
  end

  defp read_defaults(values, modules) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, fields}, {:ok, result} ->
      module = Enum.find(@stateful, &(inspect(&1) == name))

      binary =
        Enum.find_value(modules, fn {candidate, _, bytes} -> if candidate == module, do: bytes end)

      if binary && is_map(fields) && map_size(fields) <= 32 do
        {:ok, {_, [atoms: atoms]}} = :beam_lib.chunks(binary, [:atoms])

        converted =
          Enum.reduce_while(fields, %{}, fn {key, value}, fields ->
            atom =
              Enum.find_value(atoms, fn {_, atom} -> if Atom.to_string(atom) == key, do: atom end)

            if atom && String.starts_with?(key, "upgrade_"),
              do: {:cont, Map.put(fields, atom, value)},
              else: {:halt, :invalid}
          end)

        if converted == :invalid,
          do: {:halt, {:error, :unknown_state_field}},
          else: {:cont, {:ok, Map.put(result, module, converted)}}
      else
        {:halt, {:error, :invalid_state_defaults}}
      end
    end)
  end

  defp read_defaults(_, _), do: {:error, :invalid_state_defaults}

  defp old_objects(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn {module, _, _}, {:ok, objects} ->
      filename = :code.which(module)

      with true <- is_list(filename),
           {:ok, binary} <- File.read(filename),
           {:ok, {^module, hash}} <- :beam_lib.md5(binary),
           true <- hash == module.module_info(:md5) do
        {:cont, {:ok, [{module, filename, binary} | objects]}}
      else
        _ -> {:halt, {:error, :current_object_code_unavailable}}
      end
    end)
  end

  defp purge_old(modules) do
    if Enum.all?(modules, fn {module, _, _} -> :code.soft_purge(module) end),
      do: :ok,
      else: {:error, :old_code_in_use}
  end

  defp store_bundle(bundle) do
    directory = write_backup(bundle.modules, bundle.base, bundle.target, bundle.defaults)
    read_bundle(directory)
  catch
    _, _ -> {:error, :bundle_store_failed}
  end

  defp write_backup(objects, from, target, defaults \\ %{}) do
    objects = Enum.sort_by(objects, fn {module, _, _} -> module end)
    payload = Enum.map(objects, fn {module, _, bytes} -> [Atom.to_string(module), bytes] end)

    digest =
      :crypto.hash(:sha256, [
        from,
        target,
        payload,
        :erlang.term_to_binary(defaults, [:deterministic])
      ])
      |> Base.encode16(case: :lower)

    directory = Path.join([Application.fetch_env!(:lixi, :data_dir), "upgrade-history", digest])
    File.mkdir_p!(directory)

    entries =
      Enum.map(objects, fn {module, _, bytes} ->
        write_immutable(Path.join(directory, Atom.to_string(module) <> ".beam"), bytes)

        %{
          "module" => inspect(module),
          "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }
      end)

    defaults =
      Map.new(defaults, fn {module, values} ->
        {inspect(module), Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end)}
      end)

    write_immutable(
      Path.join(directory, "manifest.json"),
      Jason.encode!(%{
        schema: 1,
        from: from,
        to: target,
        modules: entries,
        stateDefaults: defaults
      })
    )

    directory
  end

  defp write_immutable(path, body) do
    case File.read(path) do
      {:ok, ^body} -> :ok
      {:error, :enoent} -> File.write!(path, body, [:exclusive])
      _ -> throw(:history_conflict)
    end
  end

  defp read_journal do
    case File.read(state_file()) do
      {:error, :enoent} ->
        {:ok, %{"schema" => 1, "patches" => [], "rollback" => nil}}

      {:ok, body} ->
        with {:ok, %{"schema" => 1, "patches" => patches} = value} <- Jason.decode(body),
             true <- is_list(patches) and length(patches) <= 32 do
          {:ok, Map.put_new(value, "rollback", nil)}
        else
          _ -> {:error, :invalid_upgrade_journal}
        end

      _ ->
        {:error, :upgrade_state_unreadable}
    end
  end

  defp write_journal(journal) do
    path = state_file()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".pending", Jason.encode!(journal), [:sync]),
         :ok <- File.rename(path <> ".pending", path),
         do: :ok,
         else: (_ -> {:error, :upgrade_state_write_failed})
  end
end
