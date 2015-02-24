alias Plug.Conn.Unfetched

defmodule Plug.Conn do
  @moduledoc """
  The Plug connection.

  This module defines a `Plug.Conn` struct and the main functions
  for working with Plug connections.

  Note request headers are normalized to lowercase and response
  headers are expected to have lower-case keys.

  ## Request fields

  Those fields contain request information:

  * `host` - the requested host as a binary, example: `"www.example.com"`
  * `method` - the request method as a binary, example: `"GET"`
  * `path_info` - the path split into segments, example: `["hello", "world"]`
  * `script_name` - the initial portion of the URL's path that corresponds to the application
    routing, as segments, example: ["sub","app"]. It can be used to recover the `full_path/1`
  * `port` - the requested port as an integer, example: `80`
  * `peer` - the actual TCP peer that connected, example: `{{127, 0, 0, 1}, 12345}`. Often this
    is not the actual IP and port of the client, but rather of a load-balancer or request-router.
  * `remote_ip` - the IP of the client, example: `{151, 236, 219, 228}`. This field is meant to
    be overwritten by plugs that understand e.g. the `X-Forwarded-For` header or HAProxy's PROXY
    protocol. It defaults to peer's IP.
  * `req_headers` - the request headers as a list, example: `[{"content-type", "text/plain"}]`
  * `scheme` - the request scheme as an atom, example: `:http`
  * `query_string` - the request query string as a binary, example: `"foo=bar"`

  ## Fetchable fields

  Those fields contain request information and they need to be explicitly fetched.
  Before fetching those fields return a `Plug.Conn.Unfetched` record.

  * `cookies`- the request cookies with the response cookies
  * `params` - the request params
  * `req_cookies` - the request cookies (without the response ones)

  ## Response fields

  Those fields contain response information:

  * `resp_body` - the response body, by default is an empty string. It is set
    to nil after the response is set, except for test connections.
  * `resp_charset` - the response charset, defaults to "utf-8"
  * `resp_cookies` - the response cookies with their name and options
  * `resp_headers` - the response headers as a dict, by default `cache-control`
    is set to `"max-age=0, private, must-revalidate"`
  * `status` - the response status

  Furthermore, the `before_send` field stores callbacks that are invoked
  before the connection is sent. Callbacks are invoked in the reverse order
  they are registered (callbacks registered first are invoked last) in order
  to reproduce a pipeline ordering.

  ## Connection fields

  * `assigns` - shared user data as a dict
  * `owner` - the Elixir process that owns the connection
  * `halted` - the boolean status on whether the pipeline was halted
  * `secret_key_base` - a secret key used to verify and encrypt cookies.
    the field must be set manually whenever one of those features are used.
    This data must be kept in the connection and never used directly, always
    use `Plug.Crypto.KeyGenerator.generate/3` to derive keys from it
  * `state` - the connection state

  The connection state is used to track the connection lifecycle. It starts
  as `:unset` but is changed to `:set` (via `Plug.Conn.resp/3`) or `:file`
  (when invoked via `Plug.Conn.send_file/3`). Its final result is
  `:sent` or `:chunked` depending on the response model.

  ## Private fields

  Those fields are reserved for libraries/framework usage.

  * `adapter` - holds the adapter information in a tuple
  * `private` - shared library data as a dict
  """

  @type adapter         :: {module, term}
  @type assigns         :: %{atom => any}
  @type before_send     :: [(t -> t)]
  @type body            :: iodata | nil
  @type cookies         :: %{binary => binary}
  @type halted          :: boolean
  @type headers         :: [{binary, binary}]
  @type host            :: binary
  @type int_status      :: non_neg_integer | nil
  @type owner           :: pid
  @type method          :: binary
  @type param           :: binary | %{binary => param} | [param]
  @type params          :: %{binary => param}
  @type peer            :: {:inet.ip_address, :inet.port_number}
  @type port_number     :: :inet.port_number
  @type query_string    :: String.t
  @type resp_cookies    :: %{binary => %{}}
  @type scheme          :: :http | :https
  @type secret_key_base :: binary | nil
  @type segments        :: [binary]
  @type state           :: :unset | :set | :file | :chunked | :sent
  @type status          :: atom | int_status

  @type t :: %__MODULE__{
              adapter:         adapter,
              assigns:         assigns,
              before_send:     before_send,
              cookies:         cookies | Unfetched.t,
              host:            host,
              method:          method,
              owner:           owner,
              params:          params | Unfetched.t,
              path_info:       segments,
              port:            :inet.port_number,
              private:         assigns,
              query_string:    query_string,
              peer:            peer,
              remote_ip:       :inet.ip_address,
              req_cookies:     cookies | Unfetched.t,
              req_headers:     headers,
              resp_body:       body,
              resp_cookies:    resp_cookies,
              resp_headers:    headers,
              scheme:          scheme,
              script_name:     segments,
              secret_key_base: secret_key_base,
              state:           state,
              status:          int_status}

  defstruct adapter:         {Plug.Conn, nil},
            assigns:         %{},
            before_send:     [],
            cookies:         %Unfetched{aspect: :cookies},
            halted:          false,
            host:            "www.example.com",
            method:          "GET",
            owner:           nil,
            params:          %Unfetched{aspect: :params},
            path_info:       [],
            port:            0,
            private:         %{},
            query_string:    "",
            peer:            nil,
            remote_ip:       nil,
            req_cookies:     %Unfetched{aspect: :cookies},
            req_headers:     [],
            resp_body:       nil,
            resp_cookies:    %{},
            resp_headers:    [{"cache-control", "max-age=0, private, must-revalidate"}],
            scheme:          :http,
            script_name:     [],
            secret_key_base: nil,
            state:           :unset,
            status:          nil

  defmodule NotSentError do
    defexception message: "no response was set nor sent from the connection"

    @moduledoc """
    Error raised when no response is sent in a request
    """
  end

  defmodule AlreadySentError do
    defexception message: "the response was already sent"

    @moduledoc """
    Error raised when trying to modify or send an already sent response
    """
  end

  alias Plug.Conn
  @already_sent {:plug_conn, :sent}
  @unsent [:unset, :set]

  @doc """
  Receives the connection and returns the full requested path as a string.

  The full path of a request is made by joining its `script_name`
  with its `path_info`.

  ## Examples

      iex> conn = %{conn | script_name: ["foo"], path_info: ["bar", "baz"]}
      iex> full_path(conn)
      "/foo/bar/baz"

  """
  @spec full_path(t) :: String.t
  def full_path(conn)

  def full_path(%Conn{script_name: [], path_info: []}), do:
    "/"
  def full_path(%Conn{script_name: script, path_info: path}), do:
    "/" <> Enum.join(script ++ path, "/")

  @doc """
  Assigns a value to a key in the connection

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = assign(conn, :hello, :world)
      iex> conn.assigns[:hello]
      :world

  """
  @spec assign(t, atom, term) :: t
  def assign(%Conn{assigns: assigns} = conn, key, value) when is_atom(key) do
    %{conn | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Starts a task to assign a value to a key in the connection.

  `await_assign/2` can be used to wait for the async task to complete and
  retrieve the resulting value.

  Behind the scenes, it uses `Task.async/1`.

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = async_assign(conn, :hello, fn -> :world end)
      iex> conn.assigns[:hello]
      %Task{...}

  """
  @spec async_assign(t, atom, (() -> term)) :: t
  def async_assign(%Conn{} = conn, key, fun) when is_atom(key) and is_function(fun, 0) do
    assign(conn, key, Task.async(fun))
  end

  @doc """
  Awaits the completion of an async assign.

  Returns a connection with the value resulting from the async assignment placed
  under `key` in the `:assigns` field.

  Behind the scenes, it uses `Task.await/2`.

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = async_assign(conn, :hello, fn -> :world end)
      iex> conn = await_assign(conn, :hello) # blocks until `conn.assings[:hello]` is available
      iex> conn.assigns[:hello]
      :world

  """
  @spec await_assign(t, atom, timeout) :: t
  def await_assign(%Conn{} = conn, key, timeout \\ 5000) when is_atom(key) do
    task = Map.fetch!(conn.assigns, key)
    assign(conn, key, Task.await(task, timeout))
  end

  @doc """
  Assigns a new **private** key and value in the connection.

  This storage is meant to be used by libraries and frameworks to avoid writing
  to the user storage (the `:assigns` field). It is recommended for
  libraries/frameworks to prefix the keys with the library name.

  For example, if some plug needs to store a `:hello` key, it
  should do so as `:plug_hello`:

      iex> conn.private[:plug_hello]
      nil
      iex> conn = put_private(conn, :plug_hello, :world)
      iex> conn.private[:plug_hello]
      :world

  """
  @spec put_private(t, atom, term) :: t
  def put_private(%Conn{private: private} = conn, key, value) when is_atom(key) do
    %{conn | private: Map.put(private, key, value)}
  end

  @doc """
  Stores the given status code in the connection.

  The status code can be `nil`, an integer or an atom. The list of allowed
  atoms is available in `Plug.Conn.Status`.
  """
  @spec put_status(t, status) :: t
  def put_status(%Conn{state: state} = conn, nil)
      when state in @unsent, do: %{conn | status: nil}
  def put_status(%Conn{state: state} = conn, status)
      when state in @unsent, do: %{conn | status: Plug.Conn.Status.code(status)}
  def put_status(%Conn{}, _status), do: raise AlreadySentError


  @doc """
  Sends a response to the client.

  It expects the connection state to be `:set`, otherwise raises an
  `ArgumentError` for `:unset` connections or a `Plug.Conn.AlreadySentError` for
  already `:sent` connections.

  At the end sets the connection state to `:sent`.
  """
  @spec send_resp(t) :: t | no_return
  def send_resp(conn)

  def send_resp(%Conn{state: :unset}) do
    raise ArgumentError, message: "cannot send a response that was not set"
  end

  def send_resp(%Conn{adapter: {adapter, payload}, state: :set, owner: owner} = conn) do
    conn = run_before_send(conn, :set)
    {:ok, body, payload} = adapter.send_resp(payload, conn.status, conn.resp_headers, conn.resp_body)
    send owner, @already_sent
    %{conn | adapter: {adapter, payload}, resp_body: body, state: :sent}
  end

  def send_resp(%Conn{}) do
    raise AlreadySentError
  end

  @doc """
  Sends a file as the response body with the given `status`
  and optionally starting at the given offset until the given length.

  If available, the file is sent directly over the socket using
  the operating system `sendfile` operation.

  It expects a connection that has not been `:sent` yet and sets its
  state to `:sent` afterwards. Otherwise raises `Plug.Conn.AlreadySentError`.
  """
  @spec send_file(t, status, filename :: binary, offset ::integer, length :: integer | :all) :: t | no_return
  def send_file(%Conn{adapter: {adapter, payload}, owner: owner} = conn, status, file, offset \\ 0, length \\ :all)
      when is_binary(file) do
    conn = run_before_send(%{conn | status: Plug.Conn.Status.code(status), resp_body: nil}, :file)
    {:ok, body, payload} = adapter.send_file(payload, conn.status, conn.resp_headers, file, offset, length)
    send owner, @already_sent
    %{conn | adapter: {adapter, payload}, state: :sent, resp_body: body}
  end

  @doc """
  Sends the response headers as a chunked response.

  It expects a connection that has not been `:sent` yet and sets its
  state to `:chunked` afterwards. Otherwise raises `Plug.Conn.AlreadySentError`.
  """
  @spec send_chunked(t, status) :: t | no_return
  def send_chunked(%Conn{adapter: {adapter, payload}, state: state, owner: owner} = conn, status)
      when state in @unsent do
    conn = run_before_send(%{conn | status: Plug.Conn.Status.code(status), resp_body: nil}, :chunked)
    {:ok, body, payload} = adapter.send_chunked(payload, conn.status, conn.resp_headers)
    send owner, @already_sent
    %{conn | adapter: {adapter, payload}, resp_body: body}
  end

  def send_chunked(%Conn{}, status) do
    _ = Plug.Conn.Status.code(status)
    raise AlreadySentError
  end

  @doc """
  Sends a chunk as part of a chunked response.

  It expects a connection with state `:chunked` as set by
  `send_chunked/2`. It returns `{:ok, conn}` in case of success,
  otherwise `{:error, reason}`.
  """
  @spec chunk(t, body) :: {:ok, t} | {:error, term} | no_return
  def chunk(%Conn{adapter: {adapter, payload}, state: :chunked} = conn, chunk) do
    case adapter.chunk(payload, chunk) do
      :ok                  -> {:ok, conn}
      {:ok, body, payload} -> {:ok, %{conn | resp_body: body, adapter: {adapter, payload}}}
      {:error, _} = error  -> error
    end
  end

  def chunk(%Conn{}, chunk) when is_binary(chunk) or is_list(chunk) do
    raise ArgumentError, message: "chunk/2 expects a chunked response. Please ensure " <>
                                  "you have called send_chunked/2 before you send a chunk"
  end

  @doc """
  Sends a response with given status and body.

  See `send_resp/1` for more information.
  """
  @spec send_resp(t, status, body) :: t | no_return
  def send_resp(%Conn{} = conn, status, body) do
    conn |> resp(status, body) |> send_resp()
  end

  @doc """
  Sets the response to the given `status` and `body`.

  It sets the connection state to `:set` (if not already `:set`)
  and raises `Plug.Conn.AlreadySentError` if it was already `:sent`.
  """
  @spec resp(t, status, body) :: t
  def resp(%Conn{state: state} = conn, status, body)
      when state in @unsent and (is_binary(body) or is_list(body)) do
    %{conn | status: Plug.Conn.Status.code(status), resp_body: body, state: :set}
  end

  def resp(%Conn{}, status, body) when is_binary(body) or is_list(body) do
    _ = Plug.Conn.Status.code(status)
    raise AlreadySentError
  end

  @doc """
  Returns the values of the request header specified by `key`.
  """
  @spec get_req_header(t, binary) :: [binary]
  def get_req_header(%Conn{req_headers: headers}, key) when is_binary(key) do
    for {k, v} <- headers, k == key, do: v
  end

  @doc """
  Returns the values of the response header specified by `key`.

  ## Examples

      iex> conn = %{conn | resp_headers: [{"content-type", "text/plain"}]}
      iex> conn |> get_resp_header("content-type")
      ["text/plain"]

  """
  @spec get_resp_header(t, binary) :: [binary]
  def get_resp_header(%Conn{resp_headers: headers}, key) when is_binary(key) do
    for {k, v} <- headers, k == key, do: v
  end

  @doc """
  Adds a new response header (`key`) if not present, otherwise replaces the
  previous value of that header with `value`.

  Raises a `Plug.Conn.AlreadySentError` if the connection has already been
  `:sent`.
  """
  @spec put_resp_header(t, binary, binary) :: t
  def put_resp_header(%Conn{resp_headers: headers, state: state} = conn, key, value) when
      is_binary(key) and is_binary(value) and state != :sent do
    %{conn | resp_headers: List.keystore(headers, key, 0, {key, value})}
  end

  def put_resp_header(%Conn{}, key, value) when is_binary(key) and is_binary(value) do
    raise AlreadySentError
  end

  @doc """
  Deletes a response header if present.

  Raises a `Plug.Conn.AlreadySentError` if the connection has already been
  `:sent`.
  """
  @spec delete_resp_header(t, binary) :: t
  def delete_resp_header(%Conn{resp_headers: headers, state: state} = conn, key) when
      is_binary(key) and state != :sent do
    %{conn | resp_headers: List.keydelete(headers, key, 0)}
  end

  def delete_resp_header(%Conn{}, key) when is_binary(key) do
    raise AlreadySentError
  end

  @doc """
  Updates a response header if present, otherwise it sets it to an initial
  value.

  Raises a `Plug.Conn.AlreadySentError` if the connection has already been
  `:sent`.
  """
  @spec update_resp_header(t, binary, binary, (binary -> binary)) :: t
  def update_resp_header(%Conn{state: state} = conn, key, initial, fun) when
      is_binary(key) and is_binary(initial) and is_function(fun, 1) and state != :sent do
    case get_resp_header(conn, key) do
      []          -> put_resp_header(conn, key, initial)
      [current|_] -> put_resp_header(conn, key, fun.(current))
    end
  end

  def update_resp_header(%Conn{}, key, initial, fun) when
      is_binary(key) and is_binary(initial) and is_function(fun, 1) do
    raise AlreadySentError
  end

  @doc """
  Sets the value of the `"content-type"` response header taking into account the
  `charset`.
  """
  @spec put_resp_content_type(t, binary, binary | nil) :: t
  def put_resp_content_type(conn, content_type, charset \\ "utf-8")

  def put_resp_content_type(conn, content_type, nil) when is_binary(content_type) do
    conn |> put_resp_header("content-type", content_type)
  end

  def put_resp_content_type(conn, content_type, charset) when
      is_binary(content_type) and is_binary(charset) do
    conn |> put_resp_header("content-type", "#{content_type}; charset=#{charset}")
  end

  @doc """
  Fetches parameters from the query string.

  This function does not fetch parameters from the body. To fetch
  parameters from the body, use the `Plug.Parsers` plug.
  """
  @spec fetch_params(t, Keyword.t) :: t
  def fetch_params(conn, opts \\ [])

  def fetch_params(%Conn{params: %Unfetched{}, query_string: query_string} = conn, _opts) do
    %{conn | params: Plug.Conn.Query.decode(query_string)}
  end

  def fetch_params(%Conn{} = conn, _opts) do
    conn
  end

  @doc """
  Reads the request body.

  This function reads a chunk of the request body. If there is more data to be
  read, then `{:more, partial_body, conn}` is returned. Otherwise
  `{:ok, body, conn}` is returned. In case of error reading the socket,
  `{:error, reason}` is returned as per `:gen_tcp.recv/2`.

  Because the request body can be of any size, reading the body will only
  work once, as Plug will not cache the result of these operations. If you
  need to access the body multiple times, it is your responsibility to store
  it. Finally keep in mind some plugs like `Plug.Parsers` may read the body,
  so the body may be unavailable after accessing such plugs.

  This function is able to handle both chunked and identity transfer-encoding
  by default.

  ## Options

  * `:length` - sets the max body length to read, defaults to 8_000_000 bytes;
  * `:read_length` - set the amount of bytes to read at one time, defaults to 1_000_000 bytes;
  * `:read_timeout` - set the timeout for each chunk received, defaults to 15_000 ms;

  ## Examples

      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

  """
  @spec read_body(t, Keyword.t) :: {:ok, binary, t} |
                                   {:more, binary, t} |
                                   {:error, term}
  def read_body(%Conn{adapter: {adapter, state}} = conn, opts \\ []) do
    case adapter.read_req_body(state, opts) do
      {:ok, data, state} ->
        {:ok, data, %{conn | adapter: {adapter, state}}}
      {:more, data, state} ->
        {:more, data, %{conn | adapter: {adapter, state}}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches cookies from the request headers.
  """
  @spec fetch_cookies(t, Keyword.t) :: t
  def fetch_cookies(conn, opts \\ [])

  def fetch_cookies(%Conn{req_cookies: %Unfetched{},
                          resp_cookies: resp_cookies,
                          req_headers: req_headers} = conn, _opts) do
    req_cookies =
      for {"cookie", cookie} <- req_headers,
          kv <- Plug.Conn.Cookies.decode(cookie),
          into: %{},
          do: kv

    cookies = Enum.reduce(resp_cookies, req_cookies, fn
      {key, opts}, acc ->
        if value = Map.get(opts, :value) do
          Map.put(acc, key, value)
        else
          Map.delete(acc, key)
        end
    end)

    %{conn | req_cookies: req_cookies, cookies: cookies}
  end

  def fetch_cookies(%Conn{} = conn, _opts) do
    conn
  end

  @doc """
  Puts a response cookie.

  ## Options

    * `:domain` - the domain the cookie applies to
    * `:max_age` - the cookie max-age
    * `:path` - the path the cookie applies to
    * `:http_only` - when false, the cookie is accessible beyond http
    * `:secure` - if the cookie must be sent only over https. Defaults
      to true when the connection is https

  """
  @spec put_resp_cookie(t, binary, binary, Keyword.t) :: t
  def put_resp_cookie(%Conn{resp_cookies: resp_cookies, scheme: scheme} = conn, key, value, opts \\ []) when
      is_binary(key) and is_binary(value) and is_list(opts) do
    cookie = [{:value, value}|opts] |> :maps.from_list() |> maybe_secure_cookie(scheme)
    resp_cookies = Map.put(resp_cookies, key, cookie)
    %{conn | resp_cookies: resp_cookies} |> update_cookies(&Map.put(&1, key, value))
  end

  defp maybe_secure_cookie(cookie, :https), do: Map.put_new(cookie, :secure, true)
  defp maybe_secure_cookie(cookie, _),      do: cookie

  @epoch {{1970, 1, 1}, {0, 0, 0}}

  @doc """
  Deletes a response cookie.

  Deleting a cookie requires the same options as to when the cookie was put.
  Check `put_resp_cookie/4` for more information.
  """
  @spec delete_resp_cookie(t, binary, Keyword.t) :: t
  def delete_resp_cookie(%Conn{resp_cookies: resp_cookies} = conn, key, opts \\ []) when
      is_binary(key) and is_list(opts) do
    opts = [universal_time: @epoch, max_age: 0] ++ opts
    resp_cookies = Map.put(resp_cookies, key, :maps.from_list(opts))
    %{conn | resp_cookies: resp_cookies} |> update_cookies(&Map.delete(&1, key))
  end

  @doc """
  Fetches the session from the session store. Will also fetch cookies.
  """
  @spec fetch_session(t, Keyword.t) :: t
  def fetch_session(conn, opts \\ [])

  def fetch_session(%Conn{private: private} = conn, _opts) do
    case Map.fetch(private, :plug_session_fetch) do
      {:ok, :done} -> conn
      {:ok, fun} -> conn |> fetch_cookies |> fun.()
      :error -> raise ArgumentError, "cannot fetch session without a configured session plug"
    end
  end

  @doc """
  Puts the specified `value` in the session for the given `key`.

  The key can be a string or an atom, where atoms are
  automatically convert to strings.
  """
  @spec put_session(t, String.t | atom, any) :: t
  def put_session(conn, key, value) do
    put_session(conn, &Map.put(&1, session_key(key), value))
  end

  @doc """
  Returns session value for the given `key`.

  The key can be a string or an atom, where atoms are
  automatically convert to strings.
  """
  @spec get_session(t, String.t | atom) :: any
  def get_session(conn, key) do
    conn |> get_session |> Map.get(session_key(key))
  end

  @doc """
  Deletes the session for the given `key`.

  The key can be a string or an atom, where atoms are
  automatically convert to strings.
  """
  @spec delete_session(t, String.t | atom) :: t
  def delete_session(conn, key) do
    put_session(conn, &Map.delete(&1, session_key(key)))
  end

  @doc """
  Configures the session.

  ## Options

    * `:renew` - generates a new session id for the cookie
    * `:drop` - drops the session, a session cookie will not be included in the
      response

  """
  @spec configure_session(t, Keyword.t) :: t
  def configure_session(conn, opts) do
    # Ensure the session is available.
    _ = get_session(conn)

    cond do
      opts[:renew] -> put_private(conn, :plug_session_info, :renew)
      opts[:drop]  -> put_private(conn, :plug_session_info, :drop)
      true         -> conn
    end
  end

  @doc """
  Registers a callback to be invoked before the response is sent.

  Callbacks are invoked in the reverse order they are defined (callbacks
  defined first are invoked last).
  """
  @spec register_before_send(t, (t -> t)) :: t
  def register_before_send(%Conn{before_send: before_send, state: state} = conn, callback)
      when is_function(callback, 1) and state in @unsent do
    %{conn | before_send: [callback|before_send]}
  end

  def register_before_send(%Conn{}, callback) when is_function(callback, 1) do
    raise AlreadySentError
  end

  @doc """
  Halts the Plug pipeline by preventing further plugs downstream from being
  invoked. See the docs for `Plug.Builder` for more informations on halting a
  plug pipeline.
  """
  @spec halt(t) :: t
  def halt(%Conn{} = conn) do
    %{conn | halted: true}
  end

  ## Helpers

  defp run_before_send(%Conn{state: state, before_send: before_send} = conn, new) when
      state in @unsent do
    conn = Enum.reduce before_send, %{conn | state: new}, &(&1.(&2))
    if conn.state != new do
      raise ArgumentError, message: "cannot send/change response from run_before_send callback"
    end
    %{conn | resp_headers: merge_headers(conn.resp_headers, conn.resp_cookies)}
  end

  defp run_before_send(_conn, _new) do
    raise AlreadySentError
  end

  defp merge_headers(headers, cookies) do
    Enum.reduce(cookies, headers, fn {key, opts}, acc ->
      [{"set-cookie", Plug.Conn.Cookies.encode(key, opts)}|acc]
    end)
  end

  defp update_cookies(%Conn{state: :sent}, _fun),
    do: raise AlreadySentError
  defp update_cookies(%Conn{cookies: %Unfetched{}} = conn, _fun),
    do: conn
  defp update_cookies(%Conn{cookies: cookies} = conn, fun),
    do: %{conn | cookies: fun.(cookies)}

  defp session_key(binary) when is_binary(binary), do: binary
  defp session_key(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp get_session(%Conn{private: private}) do
    if session = Map.get(private, :plug_session) do
      session
    else
      raise ArgumentError, message: "session not fetched, call fetch_session/2"
    end
  end

  defp put_session(conn, fun) do
    private = conn.private
              |> Map.put(:plug_session, get_session(conn) |> fun.())
              |> Map.put_new(:plug_session_info, :write)

    %{conn | private: private}
  end
end

defimpl Inspect, for: Plug.Conn do
  def inspect(conn, opts) do
    conn =
      if opts.limit == :infinity do
        conn
      else
        update_in conn.adapter, fn {adapter, _data} -> {adapter, :...} end
      end

    Inspect.Any.inspect(conn, opts)
  end
end
