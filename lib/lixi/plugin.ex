defmodule Lixi.Plugin do
  @moduledoc "Trusted BEAM extensions. Each installed version uses its own module namespace."
  @callback metadata() :: %{name: String.t(), version: String.t(), sources: [String.t()]}
  @callback load(String.t(), map()) :: map()
  @callback request(map(), map()) :: {:ok, 200..599, term()}
  @optional_callbacks load: 2, request: 2

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/, name)

  def valid_version?(version), do: is_binary(version) and byte_size(version) in 1..64

  def descriptor(module, config) when is_atom(module) and is_map(config) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :metadata, 0),
         %{name: name, version: version, sources: sources} <- module.metadata(),
         true <- valid_name?(name),
         true <- valid_version?(version),
         true <- is_list(sources) and length(sources) <= 16,
         true <-
           Enum.all?(
             sources,
             &(is_binary(&1) and byte_size(&1) in 1..64 and String.ends_with?(&1, ":") and
                 &1 not in ["http:", "https:", "file:"])
           ),
         true <- sources == [] or function_exported?(module, :load, 2),
         true <- Enum.any?([:load, :request], &function_exported?(module, &1, 2)),
         {:ok, json} <- Jason.encode(config),
         true <- byte_size(json) <= 65_536 do
      code_hash = module.module_info(:md5)
      hash = :crypto.hash(:sha256, :erlang.term_to_binary({code_hash, config}, [:deterministic]))

      {:ok,
       %{
         name: name,
         version: version,
         sources: sources,
         module: module,
         config: config,
         code_hash: code_hash,
         hash: hash
       }}
    else
      _ -> {:error, :invalid_plugin}
    end
  rescue
    _ -> {:error, :invalid_plugin}
  end

  def descriptor(_, _), do: {:error, :invalid_plugin}

  def public(descriptor), do: Map.take(descriptor, [:name, :version, :sources, :hash, :package])
end
