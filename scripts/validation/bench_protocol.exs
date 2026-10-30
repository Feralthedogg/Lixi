defmodule Lixi.Validation.ProtocolBench do
  def run do
    context = :crypto.strong_rand_bytes(32)
    payload = :binary.copy(<<123>>, 65_536)
    copied = fn request -> <<1, 4, 0::16, context::binary, request::64, payload::binary>> end
    gathered = fn request -> [<<1, 4, 0::16, context::binary, request::64>>, payload] end
    true = copied.(42) == IO.iodata_to_binary(gathered.(42))

    results =
      for {name, build} <- [binary: copied, iodata: gathered] do
        measurements =
          for _ <- 1..3 do
            task =
              Task.async(fn ->
                :erlang.garbage_collect()
                {before_gc, _, _} = :erlang.statistics(:garbage_collection)

                {microseconds, bytes} =
                  :timer.tc(fn ->
                    Enum.reduce(1..10_000, 0, fn request, bytes ->
                      bytes + :erlang.iolist_size(build.(request))
                    end)
                  end)

                {after_gc, _, _} = :erlang.statistics(:garbage_collection)
                %{microseconds: microseconds, bytes: bytes, collections: after_gc - before_gc}
              end)

            Task.await(task, 10_000)
          end

        {name, measurements}
      end

    IO.inspect(
      %{
        stage: "BEAM READ_AT command construction, not Port throughput",
        iterations: 10_000,
        payloadBytes: byte_size(payload),
        results: results
      },
      pretty: true
    )
  end
end

Lixi.Validation.ProtocolBench.run()
