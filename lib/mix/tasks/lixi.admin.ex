defmodule Mix.Tasks.Lixi.Admin do
  use Mix.Task
  @shortdoc "Calls the authenticated Lixi management API without starting a server"

  @impl true
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments,
        strict: [url: :string, body: :string, body_file: :string]
      )

    unless invalid == [] and match?([_, _], positional),
      do: Mix.raise("Usage: mix lixi.admin GET|POST|DELETE /path [--url URL] [--body-file FILE]")

    [method, path] = positional
    method = %{"GET" => :get, "POST" => :post, "DELETE" => :delete}[method]

    unless method && Regex.match?(~r{^/[a-zA-Z0-9_/-]*$}, path),
      do: Mix.raise("Invalid method or path")

    password = System.fetch_env!("LIXI_PASSWORD")
    token = System.fetch_env!("LIXI_ADMIN_TOKEN")
    if options[:body] && options[:body_file], do: Mix.raise("Choose --body or --body-file")
    body = if file = options[:body_file], do: File.read!(file), else: options[:body] || "{}"
    if byte_size(body) > 262_144, do: Mix.raise("Request body exceeds 256 KiB")
    Mix.Task.run("loadpaths")
    Jason.decode!(body)

    base = options[:url] || "http://127.0.0.1:2333"
    uri = URI.parse(base)

    unless ((uri.scheme in ["http", "https"] and uri.host) && uri.userinfo == nil &&
              uri.path in [nil, "", "/"]) and uri.query == nil and uri.fragment == nil,
           do: Mix.raise("--url must be an HTTP(S) origin")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    headers = [
      {~c"authorization", String.to_charlist(password)},
      {~c"x-lixi-admin-token", String.to_charlist(token)}
    ]

    url = String.to_charlist(String.trim_trailing(base, "/") <> "/v4/lixi" <> path)

    request =
      if method == :post, do: {url, headers, ~c"application/json", body}, else: {url, headers}

    http_options = [
      timeout: 35_000,
      connect_timeout: 5_000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_, status, _}, _, response}} ->
        Mix.shell().info(response)
        if status not in 200..299, do: Mix.raise("Management API returned HTTP #{status}")

      {:error, _} ->
        Mix.raise("Management API is unavailable")
    end
  end
end
