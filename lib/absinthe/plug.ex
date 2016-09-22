defmodule Absinthe.Plug do
  @moduledoc """
  A plug for using Absinthe

  See [The Guides](http://absinthe-graphql.org/guides/plug-phoenix/) for usage details
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @type opts :: [
    schema: atom,
    adapter: atom,
    path: binary,
    context: map,
    json_codec: atom | {atom, Keyword.t}
  ]

  @doc """
  Sets up and validates the Absinthe schema
  """
  @spec init(opts :: opts) :: map
  def init(opts) do
    adapter = Keyword.get(opts, :adapter)
    context = Keyword.get(opts, :context, %{})

    json_codec = case Keyword.get(opts, :json_codec, Poison) do
      module when is_atom(module) -> %{module: module, opts: []}
      other -> other
    end

    schema_mod = opts |> get_schema

    %{adapter: adapter, schema_mod: schema_mod, context: context, json_codec: json_codec}
  end

  defp get_schema(opts) do
    default = Application.get_env(:absinthe, :schema)
    schema = Keyword.get(opts, :schema, default)
    try do
      Absinthe.Schema.types(schema)
    rescue
      UndefinedFunctionError ->
        raise ArgumentError, "The supplied schema: #{inspect schema} is not a valid Absinthe Schema"
    end
    schema
  end

  @doc """
  Parses, validates, resolves, and executes the given Graphql Document
  """
  def call(conn, %{json_codec: json_codec} = config) do
    {conn, result} = conn  |> execute(config)

    case result do
      {:input_error, msg} ->
        conn
        |> send_resp(400, msg)

      {:ok, %{data: _} = result} ->
        conn
        |> json(200, result, json_codec)

      {:ok, %{errors: _} = result} ->
        conn
        |> json(400, result, json_codec)

      {:error, {:http_method, text}, _} ->
        conn
        |> send_resp(405, text)

      {:error, error, _} when is_binary(error) ->
        conn
        |> send_resp(500, error)

    end
  end

  @doc false
  def execute(conn, config)do
    {conn, body} = load_body_and_params(conn)

    result = with {:ok, input, opts} <- prepare(conn, body, config),
    {:ok, input} <- validate_input(input),
    pipeline <- setup_pipeline(conn, config, opts),
    {:ok, absinthe_result, _} <- Absinthe.Pipeline.run(input, pipeline) do
      {:ok, absinthe_result}
    end

    {conn, result}
  end

  def setup_pipeline(conn, config, opts) do
    Absinthe.Pipeline.for_document(config.schema_mod, opts)
    |> Absinthe.Pipeline.insert_after(
      Absinthe.Phase.Document.CurrentOperation,
      {Absinthe.Plug.Validation.HTTPMethod, method: conn.method}
    )
  end

  @doc false
  def prepare(conn, body, %{json_codec: json_codec} = config) do
    raw_input = Map.get(conn.params, "query", body)

    Logger.debug("""
    GraphQL Document:
    #{raw_input}
    """)

    variables = Map.get(conn.params, "variables") || "{}"
    operation_name = conn.params["operationName"]

    with {:ok, variables} <- decode_variables(variables, json_codec) do
        absinthe_opts = [
          variables: variables,
          context: Map.merge(config.context, conn.private[:absinthe][:context] || %{}),
          operation_name: operation_name
        ]
        {:ok, raw_input, absinthe_opts}
    end
  end

  defp validate_input(nil), do: {:input_error, "No query document supplied"}
  defp validate_input(""), do: {:input_error, "No query document supplied"}
  defp validate_input(doc), do: {:ok, doc}

  defp decode_variables(%{} = variables, _), do: {:ok, variables}
  defp decode_variables("", _), do: {:ok, %{}}
  defp decode_variables("null", _), do: {:ok, %{}}
  defp decode_variables(nil, _), do: {:ok, %{}}
  defp decode_variables(variables, codec), do: codec.module.decode(variables)

  def load_body_and_params(conn) do
    case get_req_header(conn, "content-type") do
      ["application/graphql"] ->
        {:ok, body, conn} = read_body(conn)
        {fetch_query_params(conn), body}
      _ ->
        {conn, ""}
    end
  end

  @doc false
  def json(conn, status, body, json_codec) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, json_codec.module.encode!(body, json_codec.opts))
  end

end