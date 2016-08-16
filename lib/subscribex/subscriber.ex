defmodule Subscribex.Subscriber do
  @type payload :: term
  @type body :: String.t

  @callback deserialize(body) :: {:ok, payload} | {:error, term}
  @callback exchange()                       :: String.t
  @callback queue()                          :: String.t
  @callback routing_key()                    :: String.t
  @callback provide_channel?                 :: boolean
  @callback auto_ack?                        :: boolean
  @callback handle_payload(payload)          :: term
  @callback handle_payload(payload, channel) :: term
  @callback handle_payload(payload, delivery_tag, channel)
  :: {:ok, :ack} |
     {:ok, :manual}

  @type delivery_tag :: any
  @type channel :: %AMQP.Channel{}

  use GenServer
  require Logger

  defmodule NoConnectionSpecified do
    defexception [:message]
  end

  defmodule State do
    defstruct channel: nil,
      connection: nil,
      module: nil,
      monitor: nil
  end

  @reconnect_interval :timer.seconds(30)

  def publish(channel, exchange, routing_key, payload) do
    AMQP.Basic.publish(channel, exchange, routing_key, payload)
  end

  def ack(channel, delivery_tag) do
    AMQP.Basic.ack(channel, delivery_tag)
  end

  def start_link(callback_module, opts \\ []) do
    connection_name = Keyword.get(opts, :connection_name, nil)

    if connection_name == nil do
      raise NoConnectionSpecified, message: "You must specify a connection or name for a connection when starting a subscriber"
    end

    GenServer.start_link(__MODULE__, [connection_name, callback_module], [])
  end

  def init([connection, callback_module]) do
    IO.inspect "Starting subscriber"
    {:ok, channel, monitor} = setup(connection, callback_module)

    state = %State{
      channel: channel,
      connection: connection,
      module: callback_module,
      monitor: monitor}
    IO.inspect "Started subscriber"

    {:ok, state}
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_deliver, body, %{delivery_tag: tag, redelivered: _redelivered}}, state) do
    case apply(state.module, :deserialize, [body]) do
      {:ok, payload} ->
        delegate(payload, tag, state)
      {:error, reason} ->
        error_message = "Parsing payload: #{body} failed because: #{inspect reason}"
        Logger.error(error_message)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason},
                  %State{module: callback_module, connection: connection, monitor: monitor} = state) do

    Logger.warn("Rabbit connection died. Trying to restart subscriber")
    {:ok, channel, monitor} = setup(connection, callback_module)
    Logger.info("Rabbit subscriber channel reestablished.")

    state = %{state | connection: connection, channel: channel, monitor: monitor}

    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warn("Received unknown message: " <> inspect(message))
    {:noreply, state}
  end

  defp delegate(payload, tag, state) do
    try do
      response =
        if apply(state.module, :auto_ack?, []) do
          args =
            if apply(state.module, :provide_channel?, []), do: [payload, state.channel], else: [payload]
          apply(state.module, :handle_payload, args)
          {:ok, :ack}
        else
          apply state.module, :handle_payload,  [payload, tag, state.channel]
        end

      handle_response(response, tag, state.channel)
    rescue
      error ->
        Logger.error(inspect error)
        AMQP.Basic.ack(state.channel, tag)
    end
  end

  defp handle_response({:ok, :ack}, delivery_tag, channel) do
    ack(channel, delivery_tag)
  end

  defp handle_response(_response, _delivery_tag, _channel), do: nil

  defp setup(connection, callback_module) do
    pid = Process.whereis(connection)

    if pid do
      do_connect(callback_module, pid)
    else
      30
      |> :timer.seconds
      |> :timer.sleep

      setup(connection, callback_module)
    end
  end

  defp do_connect(callback_module, pid) do
    connection = %AMQP.Connection{pid: pid}

    {:ok, channel} = AMQP.Channel.open(connection)

    monitor = Process.monitor(connection.pid)

    queue = apply(callback_module, :queue, [])
    exchange = apply(callback_module, :exchange, [])
    routing_key = apply(callback_module, :routing_key, [])

    AMQP.Basic.qos(channel, prefetch_count: 10)

    AMQP.Queue.declare(channel, queue, durable: true)
    AMQP.Exchange.topic(channel, exchange)
    AMQP.Queue.bind(channel, queue, exchange, [routing_key: routing_key])
    {:ok, _consumer_tag} = AMQP.Basic.consume(channel, queue)

    {:ok, channel, monitor}
  end

  defmacro __using__(_arg) do
    quote do
      @behaviour Subscribex.Subscriber
      use AMQP

      require Subscribex.Subscriber.Macros
      import Subscribex.Subscriber.Macros
      import Subscribex

      def handle_payload(payload), do: raise "undefined callback handle_payload/1"
      def handle_payload(payload, channel), do: raise "undefined callback handle_payload/2"
      def handle_payload(payload, delivery_tag, channel), do: raise "undefined callback handle_payload/3"

      def deserialize(payload), do: {:ok, payload}
      def auto_ack?, do: true
      def provide_channel?, do: false

      defoverridable [deserialize: 1]
      defoverridable [auto_ack?: 0]
      defoverridable [provide_channel?: 0]
      defoverridable [handle_payload: 1]
      defoverridable [handle_payload: 2]
      defoverridable [handle_payload: 3]
    end
  end
end
